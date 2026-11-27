#!/usr/bin/env python3
"""Green-Kubo viscosity and MSD diffusion coefficient from the raw record of the resumable viscosity run.

Usage: calc_visc.py PID      (run in POLYMER_DATA/VISCOSITY/<PID>)

Reads  <PID>_visc_raw.dat    step pxy pxz pyz msd   (atm, A^2; one row every 10 steps, from step 0)
       <PID>_visc_state.dat  Tfinal volume          (K, A^3; written at the start of production)
Writes <PID>_viscosity_result.dat  "Tfinal viscosity"   (Pa s)
       <PID>_diffusion_result.dat  "Tfinal D"           (cm^2/s)
       <PID>_GK.dat                lag (steps), <pxy pxy>, <pxz pxz>, <pyz pyz> (atm^2)

The formulas are those lammps_visc.in evaluated inside LAMMPS, which cannot be carried across a restart:
  fix ave/correlate 10 2000 20000 ... type auto ave running  ->  C(k) = mean over all t of P(t) P(t-k), k = 0..1999
  viscosity = V/(kB T) * trapezoid(C) * (10 fs), averaged over xy, xz, yz
  D = least-squares slope of MSD vs. sample index / (6 * 10 fs), in cm^2/s
"""
import sys
import numpy as np

S, P, DT = 10, 2000, 1.0                       # sample interval (steps), correlation length (samples), fs
KB, ATM2PA, A2M, FS2S = 1.380649e-23, 101325.0, 1.0e-10, 1.0e-15


def autocorr(x, nlag):
    """C[k] = sum_t x[t] x[t-k] / (number of pairs), the running average of fix ave/correlate type auto."""
    n = len(x)
    nfft = 1 << int(np.ceil(np.log2(2 * n)))
    f = np.fft.rfft(x, nfft)
    c = np.fft.irfft(f * np.conj(f), nfft)[:nlag]
    return c / (n - np.arange(nlag))


def main():
    if len(sys.argv) != 2:
        sys.exit("Usage: calc_visc.py PID")
    pid = sys.argv[1]
    raw = np.loadtxt(f"{pid}_visc_raw.dat", comments="#")
    tfinal, vol = np.loadtxt(f"{pid}_visc_state.dat").ravel()[:2]
    step, msd = raw[:, 0], raw[:, 4]
    if not np.all(np.diff(step) == S):
        sys.exit(f"Error: {pid}_visc_raw.dat is not a continuous record every {S} steps")
    nlag = min(P, len(raw))
    corr = np.array([autocorr(raw[:, j], nlag) for j in (1, 2, 3)])
    scale = ATM2PA * ATM2PA * FS2S * A2M ** 3 / (KB * tfinal) * vol * S * DT
    trap = corr.sum(axis=1) - 0.5 * (corr[:, 0] + corr[:, -1])
    visc = float(np.mean(trap * scale))
    idx = np.arange(len(msd), dtype=float)
    d_slope = float(np.polyfit(idx, msd, 1)[0]) / (6.0 * S * DT) * 0.1
    with open(f"{pid}_viscosity_result.dat", "w") as fh:
        fh.write(f"{tfinal:.10g} {visc:.10g}\n")
    with open(f"{pid}_diffusion_result.dat", "w") as fh:
        fh.write(f" {tfinal:.10g} {d_slope:.10g} \n")
    np.savetxt(f"{pid}_GK.dat", np.column_stack([np.arange(nlag) * S, corr.T]),
               header="lag_steps <pxy*pxy> <pxz*pxz> <pyz*pyz> (atm^2), running average over the whole run")
    print(f"viscosity {visc:.6g} Pa s, D {d_slope:.6g} cm^2/s at {tfinal:g} K from {len(raw)} samples")


if __name__ == "__main__":
    main()
