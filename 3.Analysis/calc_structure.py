#!/usr/bin/env python3
"""Structure analysis from the snapshots the EMD stage already saves. No new simulation.

Usage: calc_structure.py PID [--frames 20] [--dr 0.05] [--rmax 20]
       (run in POLYMER_DATA/STRUCTURE/<PID>)

Reads  ../../EMD/<PID>/eq2_<step>.data   LAMMPS data files written every 80 ps of the 8 ns NPT run
                                         at 300 K (atom_style full, with image flags)

Writes <PID>_rdf.dat             r (A), g(r) over all atoms, g(r) over non-hydrogen atoms,
                                 X-ray weighted G(r)
       <PID>_sq.dat              q (1/A), X-ray structure factor S(q)
       <PID>_structure.json      everything below with standard errors, plus the settings used
       <PID>_QPEAK_result.dat    q of the highest S(q) peak below 3 1/A (the amorphous halo)   [1/A]
       <PID>_REE_result.dat      root-mean-square end-to-end distance of the chains           [A]
       <PID>_CN_result.dat       characteristic ratio C_n = <R^2> / (n <l^2>)                  [-]
       <PID>_LP_result.dat       persistence length (C_n + 1) l / 2                            [A]

Definitions
  g_ab(r)   partial radial distribution functions between elements, minimum image, averaged over frames.
  G(r)      sum_ab c_a c_b Z_a Z_b g_ab(r) / (sum_a c_a Z_a)^2, i.e. X-ray weights with the atomic
            number in place of the q-dependent form factor.
  S(q)      1 + 4 pi rho * integral r^2 [G(r) - 1] sin(qr)/(qr) W(r) dr, with the Lorch window
            W(r) = sin(pi r / rmax) / (pi r / rmax). q below 3 pi / rmax is not reported (about
            0.55 1/A for a 34 A box); the cut at rmax limits the q resolution to about pi / rmax
            and can leave S(q) slightly below zero at the lowest q.
  Backbone  for each chain, the longest shortest path between two non-hydrogen atoms in the bond
            graph. R is the vector between its two ends (unwrapped with the image flags), n its
            number of bonds and l^2 the mean squared length of those bonds. In a chain with rings
            in the backbone the path takes the shorter way around each ring.
  Errors    standard error over chains for the chain quantities (frames of a glass at 300 K are
            not independent samples of chain shape), over frames for the peak position.
"""
import argparse
import glob
import json
import re
import sys
from collections import deque
from pathlib import Path

import numpy as np
from scipy.spatial import cKDTree

# mass -> (symbol, atomic number)
ELEMENTS = {1.008: ("H", 1), 12.01: ("C", 6), 14.01: ("N", 7), 16.00: ("O", 8), 19.00: ("F", 9),
            28.09: ("Si", 14), 30.97: ("P", 15), 32.06: ("S", 16), 35.45: ("Cl", 17),
            79.90: ("Br", 35), 126.90: ("I", 53)}


def read_data(path):
    """Box, masses, atoms and bonds of a LAMMPS data file (atom_style full, orthogonal box)."""
    want = {"Masses", "Atoms", "Bonds"}
    sec = {k: [] for k in want}
    lo, length, cur = np.zeros(3), np.zeros(3), None
    with open(path) as fh:
        for ln in fh:
            s = ln.split("#")[0].strip()
            if not s:
                continue
            f = s.split()
            if len(f) == 4 and f[2] in ("xlo", "ylo", "zlo"):
                d = "xyz".index(f[2][0])
                lo[d], length[d] = float(f[0]), float(f[1]) - float(f[0])
                continue
            if "xy" in f and "xz" in f:
                sys.exit(f"[structure] {path}: triclinic boxes are not supported")
            if s[0].isalpha():
                cur = s if s in want else None
                continue
            if cur:
                sec[cur].append(f)
    if not sec["Atoms"] or not sec["Masses"]:
        sys.exit(f"[structure] {path}: no Atoms or Masses section")
    masses = {int(f[0]): float(f[1]) for f in sec["Masses"]}
    a = np.array([[float(x) for x in f[:10]] if len(f) >= 10 else [float(x) for x in f[:7]] + [np.nan] * 3
                  for f in sec["Atoms"]])
    a = a[np.argsort(a[:, 0])]                                  # write_data does not keep the atom order
    bonds = np.array([[int(f[2]), int(f[3])] for f in sec["Bonds"]], dtype=int).reshape(-1, 2)
    return dict(lo=lo, L=length, masses=masses, ids=a[:, 0].astype(int), mol=a[:, 1].astype(int),
                type=a[:, 2].astype(int), xyz=a[:, 4:7], img=a[:, 7:10], bonds=bonds)


def element_of(mass):
    key = min(ELEMENTS, key=lambda k: abs(k - mass))
    if abs(key - mass) > 0.5:
        sys.exit(f"[structure] no element for mass {mass}")
    return ELEMENTS[key]


def backbone_paths(ids, mol, heavy, bonds):
    """For each chain, atom indices along the longest shortest path between two non-hydrogen atoms."""
    index = {i: k for k, i in enumerate(ids)}
    adj = [[] for _ in ids]
    for a, b in bonds:
        ia, ib = index[a], index[b]
        if heavy[ia] and heavy[ib]:
            adj[ia].append(ib)
            adj[ib].append(ia)

    def bfs(src):
        parent = {src: -1}
        queue, last = deque([src]), src
        while queue:
            last = queue.popleft()
            for nb in adj[last]:
                if nb not in parent:
                    parent[nb] = last
                    queue.append(nb)
        return last, parent

    paths = []
    for m in np.unique(mol):
        members = np.where((mol == m) & heavy)[0]
        if len(members) < 3:
            continue
        end1, _ = bfs(int(members[0]))
        end2, parent = bfs(end1)
        path = [end2]
        while parent[path[-1]] != -1:
            path.append(parent[path[-1]])
        paths.append(np.array(path))
    return paths


def pair_counts(pos_a, pos_b, box, edges, same):
    """Ordered a-b pair counts in each r shell under periodic boundaries."""
    tree_a = cKDTree(pos_a, boxsize=box)
    tree_b = tree_a if same else cKDTree(pos_b, boxsize=box)
    cum = tree_a.count_neighbors(tree_b, edges).astype(float)
    if same:
        cum -= len(pos_a)                                       # an atom is not its own neighbor
    return np.diff(cum)


def mean_sem(v):
    v = np.asarray(v, dtype=float)
    return float(v.mean()), (float(v.std(ddof=1) / np.sqrt(len(v))) if len(v) > 1 else 0.0)


def main():
    ap = argparse.ArgumentParser(description="RDF, structure factor and chain statistics from the EMD snapshots")
    ap.add_argument("pid")
    ap.add_argument("--frames", type=int, default=20, help="snapshots used, evenly spaced over the run")
    ap.add_argument("--dr", type=float, default=0.05, help="RDF bin width (A)")
    ap.add_argument("--rmax", type=float, default=20.0, help="RDF cutoff (A); capped at half the box")
    ap.add_argument("--snapshots", default=None, help="glob of data files (default ../../EMD/PID/eq2_*.data)")
    a = ap.parse_args()
    pid = a.pid

    pattern = a.snapshots or f"../../EMD/{pid}/eq2_*.data"
    files = sorted(glob.glob(pattern), key=lambda p: int(re.findall(r"(\d+)\.data$", p)[0]))
    if not files:
        sys.exit(f"[structure] no snapshots match {pattern}")
    pick = np.unique(np.linspace(0, len(files) - 1, min(a.frames, len(files))).round().astype(int))
    files = [files[i] for i in pick]
    print(f"[structure] {len(files)} snapshots, {Path(files[0]).name} to {Path(files[-1]).name}", flush=True)

    first = read_data(files[0])
    elem = {t: element_of(m) for t, m in first["masses"].items()}
    sym = np.array([elem[t][0] for t in first["type"]])
    znum = np.array([elem[t][1] for t in first["type"]], dtype=float)
    mass = np.array([first["masses"][t] for t in first["type"]])
    heavy = znum > 1
    species = sorted(set(sym), key=lambda s: -np.sum(sym == s))
    natoms = len(sym)
    have_images = not np.isnan(first["img"]).any()
    paths = backbone_paths(first["ids"], first["mol"], heavy, first["bonds"]) if have_images else []
    if not have_images:
        print("[structure] WARNING: no image flags in the snapshots; chain statistics skipped", flush=True)

    frames = [first] + [read_data(f) for f in files[1:]]
    for fr in frames:
        if len(fr["ids"]) != natoms or not np.array_equal(fr["ids"], first["ids"]):
            sys.exit("[structure] snapshots do not contain the same atoms")
    rmax = min(a.rmax, 0.5 * min(fr["L"].min() for fr in frames) - 1e-6)
    edges = np.arange(0.0, rmax + 1e-9, a.dr)
    rmax = edges[-1]
    r = 0.5 * (edges[1:] + edges[:-1])
    shell = 4.0 / 3.0 * np.pi * (edges[1:] ** 3 - edges[:-1] ** 3)

    pairs = [(s1, s2) for i, s1 in enumerate(species) for s2 in species[i:]]
    g_sum = {p: np.zeros(len(r)) for p in pairs}
    g_heavy = np.zeros(len(r))
    q = np.arange(np.ceil(3 * np.pi / rmax / 0.02) * 0.02, 12.0 + 1e-9, 0.02)
    conc = {s: np.mean(sym == s) for s in species}
    zs = {s: znum[sym == s][0] for s in species}
    zbar = sum(conc[s] * zs[s] for s in species)
    window = np.sinc(r / rmax)                                  # Lorch: sin(pi r/rmax)/(pi r/rmax)

    def structure_factor(g_partial, rho):
        big_g = sum((1 if s1 == s2 else 2) * conc[s1] * conc[s2] * zs[s1] * zs[s2] * g_partial[(s1, s2)]
                    for s1, s2 in pairs) / zbar ** 2
        kernel = np.sinc(np.outer(q, r) / np.pi)                # sin(qr)/(qr)
        return big_g, 1.0 + 4 * np.pi * rho * (kernel * (r ** 2 * (big_g - 1.0) * window)).sum(axis=1) * a.dr

    def halo(sq):
        m = q <= 3.0
        return float(q[m][np.argmax(sq[m])])

    r2, rg2, l2, peaks, rho_sum = [], [], [], [], 0.0
    for k, fr in enumerate(frames, 1):
        box = fr["L"]
        vol = float(np.prod(box))
        rho_sum += natoms / vol
        pos = np.mod(fr["xyz"] - fr["lo"], box)
        pos[pos >= box] = 0.0
        g_frame = {}
        for s1, s2 in pairs:
            pa, pb = pos[sym == s1], pos[sym == s2]
            g_frame[(s1, s2)] = pair_counts(pa, pb, box, edges, s1 == s2) / (len(pa) * len(pb) / vol * shell)
            g_sum[(s1, s2)] += g_frame[(s1, s2)]
        ph = pos[heavy]
        g_heavy += pair_counts(ph, ph, box, edges, True) / (len(ph) ** 2 / vol * shell)
        peaks.append(halo(structure_factor(g_frame, natoms / vol)[1]))
        if paths:
            xu = fr["xyz"] + fr["img"] * box
            for m, path in zip(np.unique(fr["mol"]), paths):
                steps = np.diff(xu[path], axis=0)
                r2.append(float(np.sum((xu[path[-1]] - xu[path[0]]) ** 2)))
                l2.append(float(np.mean(np.sum(steps ** 2, axis=1))))
                sel = fr["mol"] == fr["mol"][path[0]]
                com = np.average(xu[sel], axis=0, weights=mass[sel])
                rg2.append(float(np.average(np.sum((xu[sel] - com) ** 2, axis=1), weights=mass[sel])))
        print(f"[structure]  frame {k}/{len(frames)} done", flush=True)

    nfr = len(frames)
    rho = rho_sum / nfr
    g_partial = {p: g / nfr for p, g in g_sum.items()}
    g_heavy /= nfr
    g_all = sum((1 if s1 == s2 else 2) * conc[s1] * conc[s2] * g_partial[(s1, s2)] for s1, s2 in pairs)
    big_g, sq = structure_factor(g_partial, rho)
    q_peak = halo(sq)

    res = dict(pid=pid, nframes=nfr, natoms=natoms, species={s: float(conc[s]) for s in species},
               number_density=rho, rdf_rmax=float(rmax), rdf_dr=a.dr, q_min=float(q[0]),
               q_peak=(q_peak, mean_sem(peaks)[1]), d_spacing=2 * np.pi / q_peak,
               sq_peak_height=float(sq[np.argmin(abs(q - q_peak))]))
    np.savetxt(f"{pid}_rdf.dat", np.column_stack([r, g_all, g_heavy, big_g]), fmt="%.5f",
               header="r(A) g_all_atoms g_non_hydrogen G_xray_weighted")
    np.savetxt(f"{pid}_sq.dat", np.column_stack([q, sq]), fmt="%.5f", header="q(1/A) S_xray(q)")
    results = {"QPEAK": q_peak}

    if paths:
        nch = len(paths)
        per_chain = lambda v: np.array(v).reshape(nfr, nch).mean(axis=0)   # noqa: E731
        r2c, rg2c, l2c = per_chain(r2), per_chain(rg2), per_chain(l2)
        nbonds = np.array([len(p) - 1 for p in paths], dtype=float)
        cn_chain = r2c / (nbonds * l2c)
        bond = float(np.sqrt(l2c.mean()))
        cn, cn_err = mean_sem(cn_chain)
        ree, ree_err = float(np.sqrt(r2c.mean())), float(mean_sem(r2c)[1] / (2 * np.sqrt(r2c.mean())))
        lp = 0.5 * (cn + 1.0) * bond
        res.update(n_chains=nch, backbone_bonds=float(nbonds.mean()), backbone_bond_length=bond,
                   end_to_end=(ree, ree_err), characteristic_ratio=(cn, cn_err),
                   persistence_length=(lp, 0.5 * cn_err * bond),
                   radius_of_gyration=float(np.sqrt(rg2c.mean())),
                   ree2_over_rg2=float(r2c.mean() / rg2c.mean()))
        results.update(REE=ree, CN=cn, LP=lp)

    for name, val in results.items():
        Path(f"{pid}_{name}_result.dat").write_text(f"{val:.6g}\n")
    with open(f"{pid}_structure.json", "w") as fh:
        json.dump(res, fh, indent=1)

    print(f"[structure] S(q) main peak at q = {q_peak:.2f} 1/A (d = {2 * np.pi / q_peak:.2f} A), "
          f"rdf to {rmax:.1f} A")
    if paths:
        print(f"[structure] {res['n_chains']} chains, {res['backbone_bonds']:.0f} backbone bonds, "
              f"l = {bond:.3f} A: R_ee = {ree:.1f} +/- {ree_err:.1f} A, C_n = {cn:.2f} +/- {cn_err:.2f}, "
              f"l_p = {lp:.2f} A, Rg = {res['radius_of_gyration']:.1f} A, "
              f"<R^2>/<Rg^2> = {res['ree2_over_rg2']:.2f}")


if __name__ == "__main__":
    main()
