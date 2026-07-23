#!/bin/bash
set -euo pipefail

#############################################################
# Batch submission for ADEPT full pipeline on OSPool/HTCondor
#
# Submits tasks 2-6 -> PID00002 through PID00006 (skips PID00001)
# Full 8-step workflow, GASTEIGER charges, Long category (40h max)
#
# Usage:
#   bash submit_batch.sh
#############################################################

ADEPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ADEPT_DIR"

CSV_FILE="SMILES.csv"
TASKS_FILE="tasks_full.txt"
SUBMIT_FILE="submit_full.sub"
RUNTIME_IMAGE_OSDF="/ospool/ap40/data/renzheng.zhang/containers/adept-v2.sqsh"

echo "============================================"
echo " ADEPT Full Pipeline Batch Submission"
echo " CSV:        ${CSV_FILE}"
echo " Tasks:      2-6 (PID00002-PID00006)"
echo " Wall time:  +JobDurationCategory = Long (40h max)"
echo " Resume:     ON_EXIT_OR_EVICT + POLYMER_DATA_full/<task> seed"
echo "============================================"
echo ""

# --- Preflight checks ---
if [[ ! -f "$RUNTIME_IMAGE_OSDF" ]]; then
    echo "ERROR: Missing ADEPT runtime image on OSDF: ${RUNTIME_IMAGE_OSDF}"
    echo "Build/publish the single-file runtime image before submitting."
    exit 1
fi

echo ">>> Using ADEPT runtime image on OSDF: ${RUNTIME_IMAGE_OSDF}"
echo "    No conda-pack tarball will be transferred with each job."

mkdir -p Log_Files POLYMER_DATA_full

# Ensure per-task resume directories exist so HTCondor can always transfer a seed.
for task in 2 3 4 5 6; do
    mkdir -p "POLYMER_DATA_full/${task}/POLYMER_DATA/RESULTS"
done
echo ">>> Resume seed dirs ready under POLYMER_DATA_full/{2..6}/"

# Validate SMILES rows for tasks 2-6
echo ">>> Validating SMILES.csv task mapping..."
expected_pids=(PID00002 PID00003 PID00004 PID00005 PID00006)
for i in "${!expected_pids[@]}"; do
    task=$((i + 2))
    line=$((2 + task - 1))
    pid=$(sed -n "${line}p" "$CSV_FILE" | cut -d',' -f1 | tr -d '\r')
    if [[ "$pid" != "${expected_pids[$i]}" ]]; then
        echo "ERROR: Task ${task} line ${line} expected ${expected_pids[$i]}, got '${pid}'"
        exit 1
    fi
    echo "    task ${task} -> line ${line} -> ${pid}"
done
echo ""

# Write tasks file
printf '%s\n' 2 3 4 5 6 > "$TASKS_FILE"

echo ">>> Submitting 5 jobs via ${SUBMIT_FILE}..."
submit_out=$(condor_submit "$SUBMIT_FILE" 2>&1)
echo "$submit_out"
cluster=$(echo "$submit_out" | awk '/submitted to cluster/ {print $NF}' | tr -d '.')
echo ""
echo ">>> Submitted cluster: ${cluster}"
echo ">>> Monitor:"
echo "    condor_q"
echo "    condor_q ${cluster}"
echo "    condor_tail ${cluster}.0"
echo "    condor_q -hold"
echo ""
echo ">>> Results will appear under:"
echo "    POLYMER_DATA_full/<task>/POLYMER_DATA/"
echo "    Log_Files/full.<task>.out"
