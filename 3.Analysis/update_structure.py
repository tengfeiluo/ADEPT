#!/usr/bin/env python3
"""Collect the structure-analysis results of one PID into the RESULTS CSVs.

Usage: update_structure.py PID      (run in POLYMER_DATA/STRUCTURE/<PID>)

Reads the one-number files written by calc_Kfluct.py, calc_structure.py and calc_FFV.py in the
current directory and upserts, keyed by PID, into ../../RESULTS/:

  <PID>_KFLUCT_result.dat    -> KFLUCT_MD.csv   (KFLUCT)     bulk modulus from volume fluctuations [GPa]
  <PID>_QPEAK_result.dat     -> QPEAK_MD.csv    (QPEAK)      main X-ray S(q) peak [1/A]
  <PID>_REE_result.dat       -> REE_MD.csv      (REE)        rms end-to-end distance [A]
  <PID>_CN_result.dat        -> CN_MD.csv       (CN)         characteristic ratio [-]
  <PID>_LP_result.dat        -> LP_MD.csv       (LP)         persistence length [A]
  <PID>_FFV_result.dat       -> FFV_MD.csv      (FFV_BONDI)  fractional free volume, 1 - 1.3 Vw/V [-]
  <PID>_FFV_GEOM_result.dat  -> FFV_MD.csv      (FFV_GEOM)   fraction of the cell outside all vdW spheres [-]
  <PID>_FAV_<GAS>_result.dat -> FAV_<GAS>_MD.csv (FAV_<GAS>) accessible volume fraction, GAS = HE, CO2, O2, N2, CH4 [-]
  <PID>_CAVR_result.dat      -> CAVR_MD.csv     (CAVR)       mean cavity radius at a 1.30 A probe [A]

A missing source file leaves that column unchanged. Schema: PID,SMILES,<columns>.
SMILES comes from $SMILES_FILE, or ../../../SMILES.csv when that is not set.
"""
import csv
import os
import sys
from pathlib import Path

OUT_DIR = Path("../../RESULTS")
JOBS = [("KFLUCT_MD.csv", [("KFLUCT", "KFLUCT")]),
        ("QPEAK_MD.csv", [("QPEAK", "QPEAK")]),
        ("REE_MD.csv", [("REE", "REE")]),
        ("CN_MD.csv", [("CN", "CN")]),
        ("LP_MD.csv", [("LP", "LP")]),
        ("FFV_MD.csv", [("FFV", "FFV_BONDI"), ("FFV_GEOM", "FFV_GEOM")]),
        ("CAVR_MD.csv", [("CAVR", "CAVR")])]
JOBS += [(f"FAV_{g}_MD.csv", [(f"FAV_{g}", f"FAV_{g}")]) for g in ("HE", "CO2", "O2", "N2", "CH4")]


def load_smiles(pid):
    path = Path(os.environ.get("SMILES_FILE") or "../../../SMILES.csv")
    if not path.exists():
        return ""
    with path.open(newline="", encoding="utf-8-sig", errors="ignore") as fh:
        rdr = csv.DictReader(fh)
        low = {k.lower(): k for k in (rdr.fieldnames or [])}
        if "pid" not in low or "smiles" not in low:
            return ""
        for row in rdr:
            if (row[low["pid"]] or "").strip() == pid:
                return (row[low["smiles"]] or "").strip()
    return ""


def upsert(path, pid, smiles, values):
    rows, cols = [], ["PID", "SMILES"]
    if path.exists():
        with path.open(newline="", encoding="utf-8-sig") as fh:
            rdr = csv.DictReader(fh)
            cols = list(rdr.fieldnames or cols)
            rows = [r for r in rdr]
    cols += [c for c in values if c not in cols]
    row = next((r for r in rows if (r.get("PID") or "").strip() == pid), None)
    if row is None:
        row = {"PID": pid}
        rows.append(row)
    row["SMILES"] = smiles or row.get("SMILES", "")
    row.update(values)
    tmp = path.with_suffix(".tmp")
    with tmp.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows({c: r.get(c, "") for c in cols} for r in rows)
    tmp.replace(path)


def main():
    if len(sys.argv) != 2:
        sys.exit("Usage: update_structure.py PID")
    pid = sys.argv[1]
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    smiles = load_smiles(pid)
    for out, sources in JOBS:
        values = {}
        for tag, col in sources:
            src = Path(f"{pid}_{tag}_result.dat")
            if src.exists():
                try:
                    values[col] = f"{float(src.read_text().split()[0]):.6g}"
                except (ValueError, IndexError):
                    print(f"[WARN] {src} has no number; skipped")
        if values:
            upsert(OUT_DIR / out, pid, smiles, values)
            print(f"[OK] {out}: " + ", ".join(f"{c}={v}" for c, v in values.items()))
        else:
            print(f"[SKIP] {out}: no result file")


if __name__ == "__main__":
    main()
