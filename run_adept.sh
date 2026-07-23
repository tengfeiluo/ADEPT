#!/bin/bash
set -euo pipefail

# HTCondor entry point for ADEPT full pipeline on OSPool.
# Usage: ./run_adept.sh <task_index>

TASK_INDEX="${1:-${SGE_TASK_ID:-}}"
if [[ -z "$TASK_INDEX" ]]; then
    echo "[ERROR] No task index provided. Pass 1-based SMILES row index as argument."
    exit 1
fi

initial_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$initial_dir"

# Per-execution start time and self-checkpoint wall-clock budget (seconds).
# The submit files pass ADEPT_CKPT_BUDGET_SEC=0, which makes the barrier exit 85
# after EVERY completed step (one step per execution) so no execution can stack
# multiple long steps and blow past the 40h wall. The 43200 fallback only applies
# if the variable is somehow unset. ADEPT_EXEC_START_EPOCH is refreshed each
# execution and used by the (currently always-satisfied) budget check.
export ADEPT_EXEC_START_EPOCH="$(date +%s)"
export ADEPT_CKPT_BUDGET_SEC="${ADEPT_CKPT_BUDGET_SEC:-43200}"

ensure_output_dirs() {
    mkdir -p Log_Files "POLYMER_DATA/RESULTS"
}

finalize_job_artifacts() {
    # CRITICAL: never let a failing command here change the script's exit code.
    # Under `set -e`, a non-zero command in an EXIT trap overrides the pending
    # exit status, which would turn a checkpoint exit (85) into a failure code
    # and make HTCondor drop the job instead of checkpointing it.
    set +e
    ensure_output_dirs
    if [[ -f "${initial_dir}/Files/checkpoint.sh" ]]; then
        # shellcheck source=Files/checkpoint.sh
        source "${initial_dir}/Files/checkpoint.sh"
        local pid="${PID:-}"
        if [[ -z "$pid" && -n "${SGE_TASK_ID:-}" && -f "${SMILES_FILE:-}" ]]; then
            local line=$((CSV_START_LINE + SGE_TASK_ID - 1))
            pid="$(sed -n "${line}p" "$SMILES_FILE" | cut -d',' -f1 | tr -d '\r')"
        fi
        if [[ -n "${SGE_TASK_ID:-}" && -n "$pid" ]]; then
            (
                cd "$initial_dir"
                write_checkpoint_status "$SGE_TASK_ID" "$pid"
            )
        fi
    fi
}

trap finalize_job_artifacts EXIT

echo "[INFO] Job start: $(date -Is)"
echo "[INFO] Host: $(hostname)  CPUs: ${_CONDOR_CPUS:-unknown}"
echo "[INFO] Working directory: ${initial_dir}"

ensure_output_dirs

manifest="job_manifest.${TASK_INDEX}.txt"
{
    echo "timestamp=$(date -Is)"
    echo "host=$(hostname)"
    echo "pwd=${initial_dir}"
    echo "task=${TASK_INDEX}"
    echo "top_level_files:"
    find . -maxdepth 2 -mindepth 1 -printf '%y %p %s bytes\n' | sort | head -200
} > "$manifest"

source "${initial_dir}/setup_env.sh"
setup_adept_runtime_env

export NSLOTS="${_CONDOR_CPUS:-${NSLOTS:-16}}"
export PSI_THREADS="${PSI_THREADS:-1}"
export SGE_TASK_ID="$TASK_INDEX"
export SMILES_FILE="${SMILES_FILE:-${initial_dir}/SMILES.csv}"
export CSV_START_LINE="${CSV_START_LINE:-2}"
export initial_dir

# shellcheck source=Files/checkpoint.sh
source "${initial_dir}/Files/checkpoint.sh"

TASK_PID="$(
    line=$((CSV_START_LINE + TASK_INDEX - 1))
    sed -n "${line}p" "$SMILES_FILE" | cut -d',' -f1 | tr -d '\r'
)"
init_checkpoint_artifacts "$TASK_INDEX" "$TASK_PID"
seed_polymer_data_from_task_store "$TASK_INDEX"
write_checkpoint_status "$TASK_INDEX" "$TASK_PID"

# #region agent log
{
  echo "[DEBUG-RESUME] $(date -Is) pid=${TASK_PID} host=$(hostname) cwd=$(pwd)"
  echo "[DEBUG-RESUME] _CONDOR_CPUS=${_CONDOR_CPUS:-unset} NSLOTS=${NSLOTS:-unset} nproc=$(nproc 2>/dev/null) nproc_all=$(nproc --all 2>/dev/null) OMP=${OMP_NUM_THREADS:-unset} affinity=$(grep -i Cpus_allowed_list /proc/self/status 2>/dev/null | awk '{print $2}')"
  echo "[DEBUG-RESUME] LAMMPS_EXEC=${LAMMPS_EXEC:-unset} python=$(command -v python 2>/dev/null)"
  echo "[DEBUG-RESUME] POLYMER_DATA_file_count=$(find POLYMER_DATA -type f 2>/dev/null | wc -l) size=$(du -sh POLYMER_DATA 2>/dev/null | cut -f1)"
  for s in apg opt mono_electronic dc tc tg visc emd; do
    if step_done_"$s" "$TASK_PID" 2>/dev/null; then echo "[DEBUG-RESUME] step_done_${s}=YES"; else echo "[DEBUG-RESUME] step_done_${s}=no"; fi
  done
} 2>&1
agent_checkpoint_log "H3" "run_adept:resume" "resume-state snapshot" "{\"pid\":\"${TASK_PID}\",\"cpus\":\"${_CONDOR_CPUS:-unset}\",\"nproc\":\"$(nproc 2>/dev/null)\"}"
# #endregion

export DO_APG="${DO_APG:-1}"
export DO_OPT="${DO_OPT:-1}"
export DO_MONO_ELECTRONIC="${DO_MONO_ELECTRONIC:-1}"
export DO_DC="${DO_DC:-1}"
export DO_TC="${DO_TC:-1}"
export DO_TG="${DO_TG:-1}"
export DO_VISC="${DO_VISC:-1}"
export DO_EMD="${DO_EMD:-1}"
export CHARGE_METHOD="${CHARGE_METHOD:-GASTEIGER}"

echo "[INFO] ADEPT HTCondor run: SGE_TASK_ID=${SGE_TASK_ID} NSLOTS=${NSLOTS} CHARGE_METHOD=${CHARGE_METHOD}"
echo "[INFO] Python: $(command -v python)  LAMMPS: ${LAMMPS_EXEC}"
echo "[INFO] GLIBC: $(getconf GNU_LIBC_VERSION 2>/dev/null || echo unknown)"

source Files/files.sh

echo "[INFO] Job end: $(date -Is)"
