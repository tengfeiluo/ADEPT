#!/usr/bin/env python3
# update_FFV.py
# Usage: python update_FFV.py PID
#
# Reads calc_FFV.py result files in the *current directory*:
#   {PID}_FFV_result.dat      -> FFV_MD.csv      (column: FFV_BONDI)
#   {PID}_FFV_GEOM_result.dat -> FFV_MD.csv      (column: FFV_GEOM)
#   {PID}_FAV_HE_result.dat   -> FAV_HE_MD.csv   (column: FAV_HE)
#   {PID}_FAV_CO2_result.dat  -> FAV_CO2_MD.csv  (column: FAV_CO2)
#   {PID}_FAV_O2_result.dat   -> FAV_O2_MD.csv   (column: FAV_O2)
#   {PID}_FAV_N2_result.dat   -> FAV_N2_MD.csv   (column: FAV_N2)
#   {PID}_FAV_CH4_result.dat  -> FAV_CH4_MD.csv  (column: FAV_CH4)
#   {PID}_CAVR_result.dat     -> CAVR_MD.csv     (column: CAVR)
#
# Looks up SMILES for PID from ../../../SMILES.csv (expects headers: PID,SMILES)
# Appends/updates CSVs under ../../RESULTS/
# Schema: PID,SMILES,<VALUE_COL>[,<VALUE_COL>...]
# A legacy FFV_MD.csv with a single FFV column is migrated to FFV_BONDI.

import sys, csv, re
from pathlib import Path

PID_COL, SMILES_COL = "PID", "SMILES"
FLOAT_RE = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")

# Fixed locations (relative to POLYMER_DATA/FREE_VOLUME/<PID>/)
SMILES_CSV = Path("../../..") / "SMILES.csv"
OUT_DIR    = Path("../../RESULTS")

# Source → target mapping
JOBS = [
    # (out_csv_name, [(source_file_pattern, value_col_name), ...])
    ("FFV_MD.csv",     [("{pid}_FFV_result.dat",      "FFV_BONDI"),
                        ("{pid}_FFV_GEOM_result.dat", "FFV_GEOM")]),
    ("FAV_HE_MD.csv",  [("{pid}_FAV_HE_result.dat",   "FAV_HE")]),
    ("FAV_CO2_MD.csv", [("{pid}_FAV_CO2_result.dat",  "FAV_CO2")]),
    ("FAV_O2_MD.csv",  [("{pid}_FAV_O2_result.dat",   "FAV_O2")]),
    ("FAV_N2_MD.csv",  [("{pid}_FAV_N2_result.dat",   "FAV_N2")]),
    ("FAV_CH4_MD.csv", [("{pid}_FAV_CH4_result.dat",  "FAV_CH4")]),
    ("CAVR_MD.csv",    [("{pid}_CAVR_result.dat",     "CAVR")]),
]

def usage():
    print("Usage: python update_FFV.py PID")
    sys.exit(1)

def first_number(text: str):
    m = FLOAT_RE.search(text)
    return m.group(0) if m else None

def load_smiles(pid: str) -> str:
    if not SMILES_CSV.exists():
        return ""
    with SMILES_CSV.open(newline="", encoding="utf-8") as fh:
        rdr = csv.DictReader(fh)
        if not rdr.fieldnames:
            return ""
        lower_map = {k.lower(): k for k in rdr.fieldnames}
        pid_key = lower_map.get("pid"); smi_key = lower_map.get("smiles")
        if not pid_key or not smi_key:
            return ""
        for row in rdr:
            if (row.get(pid_key) or "").strip() == pid:
                return (row.get(smi_key) or "").strip()
    return ""

def upsert(csv_path: Path, pid: str, smiles: str, values: dict, value_cols: list):
    rows = []
    found = False
    # Read existing (if any) and normalize to desired value_cols;
    # columns not updated this run keep their old values
    if csv_path.exists():
        with csv_path.open(newline="", encoding="utf-8") as fh:
            rdr = csv.DictReader(fh)
            fields = rdr.fieldnames or []
            # legacy file: map its first unknown value column onto value_cols[0]
            src = {c: c for c in value_cols}
            extra = [c for c in fields if c not in (PID_COL, SMILES_COL) and c not in value_cols]
            if extra and value_cols[0] not in fields:
                src[value_cols[0]] = extra[0]
            for row in rdr:
                norm = {
                    PID_COL: (row.get(PID_COL) or "").strip(),
                    SMILES_COL: row.get(SMILES_COL) or "",
                }
                for c in value_cols:
                    norm[c] = row.get(src[c]) or ""
                if norm[PID_COL] == pid:
                    norm[SMILES_COL] = smiles
                    norm.update(values)
                    found = True
                rows.append(norm)
    if not found:
        rows.append({PID_COL: pid, SMILES_COL: smiles, **values})

    tmp = csv_path.with_suffix(csv_path.suffix + ".tmp")
    with tmp.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=[PID_COL, SMILES_COL] + value_cols)
        w.writeheader()
        for row in rows:
            w.writerow({c: row.get(c, "") for c in [PID_COL, SMILES_COL] + value_cols})
    tmp.replace(csv_path)

def main():
    if len(sys.argv) != 2:
        usage()
    pid = sys.argv[1].strip()
    if not pid:
        usage()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    smiles = load_smiles(pid)

    for out_csv_name, sources in JOBS:
        values = {}
        for pattern, value_col in sources:
            src = Path(pattern.format(pid=pid))
            if not src.exists():
                print(f"[SKIP] {src.name}: not found")
                continue

            try:
                text = src.read_text(encoding="utf-8", errors="ignore")
            except Exception:
                print(f"[SKIP] {src.name}: cannot read")
                continue

            val = first_number(text)
            if val is None:
                print(f"[SKIP] {src.name}: no numeric value found")
                continue
            values[value_col] = val
            print(f"[OK] {src.name} → {out_csv_name}: PID={pid} {value_col}={val}")

        if values:
            upsert(OUT_DIR / out_csv_name, pid, smiles, values, [c for _, c in sources])

if __name__ == "__main__":
    main()
