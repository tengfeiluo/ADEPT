#!/usr/bin/env python3
# calc_FFV.py
# Usage: python calc_FFV.py PID [--frames 10] [--h 0.5] [--cavity-probe 1.30]
#
# Free volume and cavity analysis, run from POLYMER_DATA/FREE_VOLUME/<PID>/.
# Reads:
#   {PID}_ffv.lammpstrj                        (custom dump with type and x/y/z or xu/yu/zu,
#                                               any column order, orthogonal box)
#   ../../OPTIMIZATION/{PID}/{PID}_eq2.data    (Masses -> Bondi vdW radii)
#
# Grids each frame, computes the distance from every grid point to the nearest
# atom SURFACE (PBC-aware), and writes:
#   {PID}_FFV_result.dat         Bondi FFV = 1 - 1.3 Vw/V
#   {PID}_FAV_<GAS>_result.dat   accessible volume fraction for a probe of that gas
#                                (fraction of the cell a probe CENTRE can occupy)
#   {PID}_CAVR_result.dat        equivalent-sphere radius (A) of the mean cavity at --cavity-probe
#   {PID}_ffv.json               all of the above with standard errors over frames,
#                                plus Vw, volume and the full cavity statistics

import sys, json, argparse
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


def read_radii(data_file):
    """atom type -> vdW radius, from the data file's Masses block"""
    masses = {}
    with open(data_file) as fh:
        insec = False
        for ln in fh:
            s = ln.split("#")[0].strip()
            if s == "Masses": insec = True; continue
            if insec:
                if not s: continue
                if s[0].isalpha(): break
                f = s.split(); masses[int(f[0])] = float(f[1])
    if not masses:
        sys.exit(f"[ffv] no Masses section in {data_file}")
    rad = {}
    for t, m in masses.items():
        key = min(RVDW, key=lambda k: abs(k - m))
        if abs(key - m) > 0.5: sys.exit(f"[ffv] unmapped mass {m} for type {t}")
        rad[t] = RVDW[key]
    return rad


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
    out["Vw"] = float((dsurf <= 0).sum())*vox
    out["FFV_bondi"] = 1.0 - 1.3*out["Vw"]/V
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

    rad = read_radii(data)
    nfr = count_frames(traj)
    idx = list(range(nfr))[nfr//2:]
    step = max(1, len(idx)//a.frames)
    idx = idx[::step][:a.frames]
    print(f"[ffv] {nfr} frames in file, analysing {len(idx)} from the second half", flush=True)

    acc = []
    for i, (box, t, xyz) in enumerate(read_frames(traj, idx), 1):
        acc.append(analyse(box, t, xyz, rad, a.h, a.cavity_probe))
        print(f"[ffv]  frame {i}/{len(idx)}: FFV={acc[-1]['FFV_bondi']:.4f} "
              f"He={acc[-1]['accessible']['He']:.4f}", flush=True)
    if not acc:
        print("[ffv] no frames read.")
        sys.exit(1)

    res = dict(pid=pid, file=str(traj), nframes=len(acc), grid_h=a.h, cavity_probe=a.cavity_probe,
               FFV_bondi=mean_sem([x["FFV_bondi"] for x in acc]),
               Vw=mean_sem([x["Vw"] for x in acc]),
               volume=mean_sem([x["volume"] for x in acc]),
               accessible={lab: mean_sem([x["accessible"][lab] for x in acc]) for lab in PLABEL})
    for k in CAV_KEYS:
        v = [x[k] for x in acc if k in x]
        if v: res[k] = mean_sem(v)

    print(f"\n[ffv] FFV(Bondi) = {res['FFV_bondi'][0]:.4f} +/- {res['FFV_bondi'][1]:.4f}")
    for lab in PLABEL:
        m, e = res["accessible"][lab]
        print(f"[ffv]   accessible({lab:9}) = {m:.4f} +/- {e:.4f}")
    if "cav_r_mean" in res:
        print(f"[ffv] cavities at probe {a.cavity_probe} A: n={res['ncav'][0]:.1f}, "
              f"<r>={res['cav_r_mean'][0]:.2f} A, r_max={res['cav_r_max'][0]:.2f} A")

    # one-number result files, picked up by update_FFV.py
    results = {"FFV": res["FFV_bondi"][0]}
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
