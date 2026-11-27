#!/usr/bin/env python3
# calc_FFV.py
# Usage: python calc_FFV.py PID [--frames 10] [--h 0.5] [--cavity-probe 1.30]
#
# Free volume and cavity analysis, run from POLYMER_DATA/FREE_VOLUME/<PID>/.
# Reads:
#   {PID}_ffv.lammpstrj                        (custom dump with type and x/y/z or xu/yu/zu,
#                                               any column order, orthogonal box)
#   ../../OPTIMIZATION/{PID}/{PID}_eq2.data    (Masses -> Bondi vdW radii; Atoms + Bonds -> topology)
#   $SMILES_FILE                               (repeat-unit SMILES, only needed if the chain has rings)
#
# The two FFVs are computed independently, so they can be checked against each other:
#   Bondi FFV     : NO grid. Vw from the Zhao/Abraham/Zissimos (J. Org. Chem. 2003, 68, 7368)
#                   group-additivity formula, built on Bondi radii:
#                       Vw = sum(4/3 pi r^3) - 5.92 N_bonds - 14.7 R_aromatic - 3.8 R_nonaromatic   (A^3)
#                   atoms / bonds / total rings from the data file topology, aromatic rings from RDKit
#                   on the repeat-unit SMILES. V is the box volume of each frame (= M / rho).
#                   FFV = 1 - 1.3 Vw/V
#   geometric FFV : grid count. Fraction of grid points outside every vdW sphere.
# The grid also gives its own Vw (union of spheres), reported as Vw_grid next to Vw_bondi in the json.
#
# Grids each frame, computes the distance from every grid point to the nearest
# atom SURFACE (PBC-aware), and writes:
#   {PID}_FFV_result.dat         Bondi FFV = 1 - 1.3 Vw/V   (group-additivity Vw, no grid)
#   {PID}_FFV_GEOM_result.dat    geometric FFV = fraction of the cell outside all vdW spheres (grid)
#   {PID}_FAV_<GAS>_result.dat   accessible volume fraction for a probe of that gas
#                                (fraction of the cell a probe CENTRE can occupy)
#   {PID}_CAVR_result.dat        equivalent-sphere radius (A) of the mean cavity at --cavity-probe
#   {PID}_ffv.json               all of the above with standard errors over frames,
#                                plus Vw_bondi, Vw_grid, volume, density, the topology counts
#                                and the full cavity statistics

import os, sys, csv, json, argparse
from pathlib import Path
import numpy as np

try:
    from scipy import ndimage
except ImportError:
    ndimage = None

# Bondi van der Waals radii (A), keyed by atomic mass
RVDW = {1.008: 1.20, 12.01: 1.70, 14.01: 1.55, 16.00: 1.52, 19.00: 1.47, 28.09: 2.10,
        30.97: 1.80, 32.06: 1.80, 35.45: 1.75, 79.90: 1.85, 126.90: 1.98}
#        H           C            N            O            F            Si
#        P           S            Cl           Br           I
PROBES = [0.0, 1.30, 1.65, 1.73, 1.82, 1.90]     # -, He, CO2, O2, N2, CH4
PLABEL = ["geometric", "He", "CO2", "O2", "N2", "CH4"]
CAV_KEYS = ("ncav", "cav_mean", "cav_max", "cav_r_mean", "cav_r_max")

# Zhao/Abraham/Zissimos corrections (A^3): per bond, per aromatic ring, per non-aromatic ring
ZHAO_BOND, ZHAO_AROM, ZHAO_NONAROM = 5.92, 14.7, 3.8
CAP_ATOMS = 8          # each chain is capped with CH3 at both ends (APG_*.py PolymerGen)
NA = 6.02214076e23


def read_data(data_file):
    """parse the LAMMPS data file: Masses, Atoms (atom_style full) and Bonds sections"""
    want = {"Masses", "Atoms", "Bonds"}
    sec = {k: [] for k in want}
    cur = None
    with open(data_file) as fh:
        for ln in fh:
            s = ln.split("#")[0].strip()
            if not s: continue
            if s[0].isalpha():
                cur = s if s in want else None
                continue
            if cur: sec[cur].append(s.split())
    if not sec["Masses"]:
        sys.exit(f"[ffv] no Masses section in {data_file}")
    if not sec["Atoms"]:
        sys.exit(f"[ffv] no Atoms section in {data_file}")
    masses = {int(f[0]): float(f[1]) for f in sec["Masses"]}
    ids = [int(f[0]) for f in sec["Atoms"]]
    types = [int(f[2]) for f in sec["Atoms"]]            # full: id mol type q x y z
    bonds = [(int(f[2]), int(f[3])) for f in sec["Bonds"]]
    return masses, ids, types, bonds


def radii_from_masses(masses):
    """atom type -> Bondi vdW radius, matched by mass"""
    rad = {}
    for t, m in masses.items():
        key = min(RVDW, key=lambda k: abs(k - m))
        if abs(key - m) > 0.5: sys.exit(f"[ffv] unmapped mass {m} for type {t}")
        rad[t] = RVDW[key]
    return rad


def count_components(ids, bonds):
    """number of separate molecules (chains), by union-find over the bond list"""
    par = {i: i for i in ids}
    def find(x):
        while par[x] != x: par[x] = par[par[x]]; x = par[x]
        return x
    for a, b in bonds:
        ra, rb = find(a), find(b)
        if ra != rb: par[ra] = rb
    return len({find(i) for i in ids})


def smiles_for_pid(pid):
    """repeat-unit SMILES for this PID from $SMILES_FILE (None if unavailable)"""
    path = os.environ.get("SMILES_FILE")
    if not path or not os.path.exists(path):
        return None
    with open(path, newline="", encoding="utf-8-sig", errors="ignore") as fh:
        rdr = csv.DictReader(fh)
        low = {k.lower(): k for k in (rdr.fieldnames or [])}
        if "pid" not in low or "smiles" not in low:
            return None
        for row in rdr:
            if (row[low["pid"]] or "").strip() == pid:
                return (row[low["smiles"]] or "").strip() or None
    return None


def repeat_unit_rings(smiles):
    """(atoms incl. H, aromatic rings, non-aromatic rings) of one repeat unit, '*' excluded"""
    from rdkit import Chem
    from rdkit.Chem import rdMolDescriptors
    mol = Chem.MolFromSmiles(smiles)
    if mol is None:
        raise ValueError(f"RDKit cannot parse SMILES {smiles}")
    mh = Chem.AddHs(mol)
    natoms = sum(1 for a in mh.GetAtoms() if a.GetAtomicNum() > 0)
    return (natoms, rdMolDescriptors.CalcNumAromaticRings(mol),
            rdMolDescriptors.CalcNumAliphaticRings(mol))


def bondi_vw(pid, masses, ids, types, bonds, rad):
    """
    Grid-free van der Waals volume of the whole cell (A^3), Zhao et al. 2003:
        Vw = sum_atoms 4/3 pi r^3 - 5.92 N_bonds - 14.7 R_arom - 3.8 R_nonarom
    Total rings come from the topology (cyclomatic number); the aromatic share comes
    from RDKit on the repeat-unit SMILES. Rings the SMILES does not contain (e.g. formed
    across the repeat-unit junction) are counted as non-aromatic.
    Returns (Vw, info dict) or (None, info) if aromatic rings are needed but unavailable.
    """
    N, NB = len(ids), len(bonds)
    nmol = count_components(ids, bonds)
    rings = NB - N + nmol                                  # independent cycles in the bond graph
    vsum = sum(4.0/3.0*np.pi*rad[t]**3 for t in types)
    info = dict(n_atoms=N, n_bonds=NB, n_chains=nmol, rings_total=rings,
                mass_total=float(sum(masses[t] for t in types)))
    r_arom = 0
    if rings > 0:
        smiles = smiles_for_pid(pid)
        if smiles is None:
            print("[ffv] WARNING: rings present but no SMILES for this PID in $SMILES_FILE; "
                  "Bondi FFV skipped", flush=True)
            return None, info
        try:
            ru_atoms, ru_arom, ru_aliph = repeat_unit_rings(smiles)
        except Exception as e:
            print(f"[ffv] WARNING: aromatic ring count failed ({e}); Bondi FFV skipped", flush=True)
            return None, info
        n_ru = (N - CAP_ATOMS*nmol)/ru_atoms              # repeat units in the whole cell
        if abs(n_ru - round(n_ru)) > 0.05:
            print(f"[ffv] WARNING: atom count gives {n_ru:.2f} repeat units (not an integer); "
                  f"check the CH3 capping / SMILES", flush=True)
        n_ru = int(round(n_ru))
        r_arom = min(n_ru*ru_arom, rings)
        if n_ru*(ru_arom + ru_aliph) != rings:
            print(f"[ffv] NOTE: topology has {rings} rings, SMILES x repeat units gives "
                  f"{n_ru*(ru_arom + ru_aliph)}; the difference is counted as non-aromatic", flush=True)
        info.update(smiles=smiles, n_repeat_units=n_ru, ru_atoms=ru_atoms,
                    ru_rings_aromatic=ru_arom, ru_rings_nonaromatic=ru_aliph)
    r_nonarom = rings - r_arom
    info.update(rings_aromatic=r_arom, rings_nonaromatic=r_nonarom, vw_atom_sum=float(vsum))
    vw = vsum - ZHAO_BOND*NB - ZHAO_AROM*r_arom - ZHAO_NONAROM*r_nonarom
    return float(vw), info


def count_frames(path):
    with open(path) as fh:
        return sum(1 for ln in fh if ln.startswith("ITEM: TIMESTEP"))


def read_frames(path, keep):
    """yield (box, types, xyz) for the frame indices in `keep`; columns located from the ITEM: ATOMS header"""
    keep = set(keep)
    with open(path) as fh:
        i = -1
        while True:
            ln = fh.readline()
            if not ln: return
            if not ln.startswith("ITEM: TIMESTEP"): continue
            i += 1
            fh.readline()
            fh.readline(); n = int(fh.readline())
            if "xy" in fh.readline().split():
                sys.exit("[ffv] triclinic boxes are not supported")
            box = [tuple(map(float, fh.readline().split()[:2])) for _ in range(3)]
            cols = fh.readline().split()[2:]
            if i not in keep:
                for _ in range(n): fh.readline()
                continue
            it = cols.index("type") if "type" in cols else None
            ic = next(([cols.index(c) for c in trio] for trio in (("xu", "yu", "zu"), ("x", "y", "z"))
                       if all(c in cols for c in trio)), None)
            if it is None or ic is None:
                sys.exit(f"[ffv] dump needs type and x/y/z (or xu/yu/zu) columns, got: {' '.join(cols)}")
            a = np.loadtxt([fh.readline() for _ in range(n)], ndmin=2)
            yield box, a[:, it].astype(np.int32), a[:, ic]


def analyse(box, types, xyz, rad, h_target, cavity_probe):
    L = np.array([b[1]-b[0] for b in box]); lo = np.array([b[0] for b in box])
    n = np.maximum((L/h_target).astype(int), 8)
    h = L/n
    # distance from each grid point to the nearest atom surface
    dsurf = np.full(tuple(n), 1e9, dtype=np.float32)
    r = np.array([rad[t] for t in types])
    reach = r.max() + max(max(PROBES), cavity_probe) + h.max()
    span = np.ceil(reach/h).astype(int)
    ax = [(np.arange(-span[d], span[d]+1)) for d in range(3)]
    ox, oy, oz = np.meshgrid(*ax, indexing="ij")
    for p, ri in zip(xyz, r):
        c = np.floor((p - lo)/h).astype(int)
        ix = (c[0]+ox) % n[0]; iy = (c[1]+oy) % n[1]; iz = (c[2]+oz) % n[2]
        gx = lo[0]+(c[0]+ox+0.5)*h[0]; gy = lo[1]+(c[1]+oy+0.5)*h[1]; gz = lo[2]+(c[2]+oz+0.5)*h[2]
        d = np.sqrt((gx-p[0])**2 + (gy-p[1])**2 + (gz-p[2])**2) - ri
        np.minimum.at(dsurf, (ix, iy, iz), d.astype(np.float32))
    vox = float(np.prod(h)); V = float(np.prod(L))
    out = dict(volume=V, nvox=int(dsurf.size))
    out["Vw_grid"] = float((dsurf <= 0).sum())*vox       # grid union-of-spheres volume (not used for Bondi FFV)
    out["accessible"] = {lab: float((dsurf > pr).sum())*vox/V for pr, lab in zip(PROBES, PLABEL)}
    if ndimage is None:
        return out
    # cavity clustering at the chosen probe, merged across periodic faces
    lab, nl = ndimage.label(dsurf > cavity_probe)
    if not nl:
        return out
    par = np.arange(nl+1)
    def find(x):
        while par[x] != x: par[x] = par[par[x]]; x = par[x]
        return x
    def uni(x, y):
        x, y = find(x), find(y)
        if x != y: par[max(x, y)] = min(x, y)
    for ax_ in range(3):
        A = np.take(lab, 0, axis=ax_); B = np.take(lab, -1, axis=ax_)
        m = (A > 0) & (B > 0)
        for u, v in zip(A[m].ravel(), B[m].ravel()): uni(int(u), int(v))
    roots = np.array([find(i) if i else 0 for i in range(nl+1)])
    sizes = np.bincount(roots[lab.ravel()], minlength=nl+1)[1:]
    sizes = sizes[sizes > 0]*vox
    if len(sizes):
        out["ncav"] = int(len(sizes))
        out["cav_mean"] = float(sizes.mean())
        out["cav_max"] = float(sizes.max())
        # radius of a sphere of equal volume
        out["cav_r_mean"] = float((3*sizes.mean()/(4*np.pi))**(1/3))
        out["cav_r_max"] = float((3*sizes.max()/(4*np.pi))**(1/3))
    return out


def mean_sem(v):
    v = np.asarray(v, dtype=float)
    return (float(v.mean()), float(v.std(ddof=1)/len(v)**.5) if len(v) > 1 else 0.0)


def main():
    ap = argparse.ArgumentParser(description="Free volume and cavity analysis for one PID")
    ap.add_argument("pid")
    ap.add_argument("--frames", type=int, default=10, help="frames sampled from the last half")
    ap.add_argument("--h", type=float, default=0.5, help="grid spacing (A)")
    ap.add_argument("--cavity-probe", type=float, default=1.30)
    a = ap.parse_args()
    pid = a.pid

    traj = Path(f"{pid}_ffv.lammpstrj")
    data = Path("../../OPTIMIZATION") / pid / f"{pid}_eq2.data"
    for p in (traj, data):
        if not p.exists():
            print(f"[ffv] {p} not found.")
            sys.exit(1)
    if ndimage is None:
        print("[ffv] WARNING: scipy not available, skipping cavity analysis", flush=True)

    masses, ids, types, bonds = read_data(data)
    rad = radii_from_masses(masses)
    vw_bondi, topo = bondi_vw(pid, masses, ids, types, bonds, rad)
    print(f"[ffv] topology: {topo['n_atoms']} atoms, {topo['n_bonds']} bonds, {topo['n_chains']} chains, "
          f"rings {topo['rings_total']} ({topo.get('rings_aromatic', '?')} aromatic)", flush=True)
    if vw_bondi is not None:
        print(f"[ffv] Vw (Bondi/Zhao, no grid) = {vw_bondi:.1f} A^3", flush=True)
    nfr = count_frames(traj)
    idx = list(range(nfr))[nfr//2:]
    step = max(1, len(idx)//a.frames)
    idx = idx[::step][:a.frames]
    print(f"[ffv] {nfr} frames in file, analysing {len(idx)} from the second half", flush=True)

    acc = []
    for i, (box, t, xyz) in enumerate(read_frames(traj, idx), 1):
        fr = analyse(box, t, xyz, rad, a.h, a.cavity_probe)
        # density from this frame's box (g/cm^3); Bondi FFV uses the same V = M/(rho N_A)
        fr["density"] = topo["mass_total"]/(NA*fr["volume"]*1e-24)
        if vw_bondi is not None:
            fr["FFV_bondi"] = 1.0 - 1.3*vw_bondi/fr["volume"]
        acc.append(fr)
        bondi = f"{fr['FFV_bondi']:.4f}" if "FFV_bondi" in fr else "n/a"
        print(f"[ffv]  frame {i}/{len(idx)}: FFV(Bondi)={bondi} FFV(geom)={fr['accessible']['geometric']:.4f} "
              f"He={fr['accessible']['He']:.4f} rho={fr['density']:.4f}", flush=True)
    if not acc:
        print("[ffv] no frames read.")
        sys.exit(1)

    res = dict(pid=pid, file=str(traj), nframes=len(acc), grid_h=a.h, cavity_probe=a.cavity_probe,
               topology=topo, Vw_bondi=vw_bondi,
               Vw_grid=mean_sem([x["Vw_grid"] for x in acc]),
               volume=mean_sem([x["volume"] for x in acc]),
               density=mean_sem([x["density"] for x in acc]),
               accessible={lab: mean_sem([x["accessible"][lab] for x in acc]) for lab in PLABEL})
    if vw_bondi is not None:
        res["FFV_bondi"] = mean_sem([x["FFV_bondi"] for x in acc])
        res["Vw_grid_over_bondi"] = res["Vw_grid"][0]/vw_bondi
    for k in CAV_KEYS:
        v = [x[k] for x in acc if k in x]
        if v: res[k] = mean_sem(v)

    print()
    if "FFV_bondi" in res:
        print(f"[ffv] FFV(Bondi, group-additivity Vw) = {res['FFV_bondi'][0]:.4f} +/- {res['FFV_bondi'][1]:.4f}")
        print(f"[ffv] Vw check: grid {res['Vw_grid'][0]:.1f} / Bondi {vw_bondi:.1f} A^3 "
              f"= {res['Vw_grid_over_bondi']:.3f}")
    else:
        print("[ffv] FFV(Bondi) not computed (see warning above)")
    print(f"[ffv] density = {res['density'][0]:.4f} +/- {res['density'][1]:.4f} g/cm^3")
    for lab in PLABEL:
        m, e = res["accessible"][lab]
        print(f"[ffv]   accessible({lab:9}) = {m:.4f} +/- {e:.4f}")
    if "cav_r_mean" in res:
        print(f"[ffv] cavities at probe {a.cavity_probe} A: n={res['ncav'][0]:.1f}, "
              f"<r>={res['cav_r_mean'][0]:.2f} A, r_max={res['cav_r_max'][0]:.2f} A")

    # one-number result files, picked up by update_FFV.py
    results = {"FFV_GEOM": res["accessible"]["geometric"][0]}
    if "FFV_bondi" in res:
        results["FFV"] = res["FFV_bondi"][0]
    else:
        Path(f"{pid}_FFV_result.dat").unlink(missing_ok=True)   # don't leave a stale value behind
    for lab in PLABEL[1:]:
        results[f"FAV_{lab.upper()}"] = res["accessible"][lab][0]
    if "cav_r_mean" in res:
        results["CAVR"] = res["cav_r_mean"][0]
    for name, val in results.items():
        Path(f"{pid}_{name}_result.dat").write_text(f"{val:.6f}\n")
    with open(f"{pid}_ffv.json", "w") as fh:
        json.dump(res, fh, indent=1)
    print(f"[ffv] Results saved to {pid}_*_result.dat and {pid}_ffv.json")


if __name__ == "__main__":
    main()
