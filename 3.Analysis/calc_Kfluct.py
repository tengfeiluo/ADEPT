#!/usr/bin/env python3
"""Isothermal bulk modulus from the volume fluctuations of the EMD NPT run. No new simulation.

Usage: calc_Kfluct.py PID [--skip 0.1] [--blocks 5]     (run in POLYMER_DATA/STRUCTURE/<PID>)

Reads  ../../EMD/<PID>/<PID>_npt_properties.dat   temperature (K), energy, pressure, volume (A^3),
                                                  density; one row every 100 steps of the 8 ns NPT run
Writes <PID>_KFLUCT_result.dat                    K_T = kB <T> <V> / <dV^2>, mean over blocks   [GPa]
       <PID>_kfluct.json                          the value, its block standard error, the
                                                  whole-record value and the settings

The reported value is the mean of K over equal blocks of the record (default 5). A slow volume
drift adds to the variance of the whole record and lowers K; the block mean is less affected.

This is the relaxed (long-time) bulk modulus of the simulated glass. It does not depend on the hold
time of the strain-step method behind K_MD.csv, which reads about 1.5 times higher.
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

KB = 1.380649e-23          # J/K
A3_TO_M3 = 1.0e-30


def k_fluct(temp, vol):
    return KB * temp.mean() * vol.mean() / vol.var() / A3_TO_M3 / 1.0e9


def main():
    ap = argparse.ArgumentParser(description="Bulk modulus from NPT volume fluctuations")
    ap.add_argument("pid")
    ap.add_argument("--skip", type=float, default=0.1, help="fraction of the record dropped at the start")
    ap.add_argument("--blocks", type=int, default=5, help="blocks for the standard error")
    ap.add_argument("--file", default=None, help="record to read (default ../../EMD/PID/PID_npt_properties.dat)")
    a = ap.parse_args()
    pid = a.pid
    path = Path(a.file or f"../../EMD/{pid}/{pid}_npt_properties.dat")
    if not path.exists():
        sys.exit(f"[kfluct] {path} not found")
    d = np.loadtxt(path, comments="#", usecols=(0, 3))
    d = d[int(a.skip * len(d)):]
    if len(d) < 100 * a.blocks:
        sys.exit(f"[kfluct] only {len(d)} rows in {path}")
    k = k_fluct(d[:, 0], d[:, 1])
    kb = np.array([k_fluct(b[:, 0], b[:, 1]) for b in np.array_split(d, a.blocks)])
    err = float(kb.std(ddof=1) / np.sqrt(a.blocks))
    drift = float((d[-len(d) // 5:, 1].mean() - d[:len(d) // 5, 1].mean()) / d[:, 1].mean())
    Path(f"{pid}_KFLUCT_result.dat").write_text(f"{kb.mean():.6g}\n")
    with open(f"{pid}_kfluct.json", "w") as fh:
        json.dump(dict(pid=pid, K_fluct_GPa=float(kb.mean()), block_sem_GPa=err, whole_record_GPa=k,
                       rows=len(d), skip=a.skip, blocks=a.blocks, temperature_K=float(d[:, 0].mean()),
                       volume_A3=float(d[:, 1].mean()), volume_drift_fraction=drift), fh, indent=1)
    print(f"[kfluct] K = {kb.mean():.3f} +/- {err:.3f} GPa (whole record {k:.3f}) from {len(d)} rows; "
          f"volume drift first to last fifth {100 * drift:+.2f}%")
    if abs(drift) > 0.005:
        print("[kfluct] WARNING: the volume is still drifting; a drift adds to the variance and lowers K")


if __name__ == "__main__":
    main()
