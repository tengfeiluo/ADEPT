#!/bin/bash
# Merge dedicated-TC-job outputs (POLYMER_DATA_TC) back into the main data tree
# (POLYMER_DATA_full) once submit_TC.sub jobs have completed. Safe to re-run:
# it only copies TC-specific artifacts (TC_MD.csv + THERMAL_CONDUCTIVITY/) and
# never touches results produced by the main pipeline.
set -euo pipefail
cd "$(dirname "$0")"

TASKS_FILE="${1:-tasks_full.txt}"

merged_any=0
while read -r t; do
    [[ -z "$t" ]] && continue
    src="POLYMER_DATA_TC/${t}/POLYMER_DATA"
    dst="POLYMER_DATA_full/${t}/POLYMER_DATA"

    if [[ ! -d "$src" ]]; then
        echo "[skip] task ${t}: no TC output at ${src}"
        continue
    fi

    mkdir -p "${dst}/RESULTS"

    # TC result CSV(s)
    if [[ -f "${src}/RESULTS/TC_MD.csv" ]]; then
        cp -a "${src}/RESULTS/TC_MD.csv" "${dst}/RESULTS/TC_MD.csv"
        echo "[ok]   task ${t}: merged RESULTS/TC_MD.csv"
        merged_any=1
    else
        echo "[warn] task ${t}: TC output present but RESULTS/TC_MD.csv missing (TC may not have finished)"
    fi

    # Raw TC trajectories/profiles (optional, for reprocessing)
    if [[ -d "${src}/THERMAL_CONDUCTIVITY" ]]; then
        mkdir -p "${dst}/THERMAL_CONDUCTIVITY"
        cp -a "${src}/THERMAL_CONDUCTIVITY/." "${dst}/THERMAL_CONDUCTIVITY/"
        echo "[ok]   task ${t}: merged THERMAL_CONDUCTIVITY/"
    fi
done < "$TASKS_FILE"

if [[ "$merged_any" -eq 1 ]]; then
    echo "Done. TC results merged into POLYMER_DATA_full."
else
    echo "No TC_MD.csv results found to merge yet."
fi
