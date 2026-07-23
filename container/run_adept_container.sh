#!/bin/bash
# Run inside Apptainer container on OSPool execute nodes.
set -euo pipefail

ADEPT_ROOT="/opt/ADEPT"
TASK_INDEX="${1:-${SGE_TASK_ID:-}}"

if [[ -z "$TASK_INDEX" ]]; then
    echo "[ERROR] No task index provided."
    exit 1
fi

source /opt/conda/etc/profile.d/conda.sh
conda activate polymer-workflow
export LAMMPS_EXEC="${LAMMPS_EXEC:-/opt/conda/envs/polymer-workflow/bin/lmp}"
export PATH="/opt/conda/envs/polymer-workflow/bin:$PATH"
export LD_LIBRARY_PATH="/opt/conda/envs/polymer-workflow/lib:${LD_LIBRARY_PATH:-}"
export OMP_NUM_THREADS=1
export MKL_INTERFACE_LAYER=""
export OMPI_MCA_btl=vader,self
export UCX_TLS=sm,self
export NSLOTS="${_CONDOR_CPUS:-8}"
export SGE_TASK_ID="$TASK_INDEX"

cd "$ADEPT_ROOT"
mkdir -p Log_Files POLYMER_DATA/RESULTS

export DO_APG="${DO_APG:-1}"
export DO_OPT="${DO_OPT:-1}"
export DO_MONO_ELECTRONIC="${DO_MONO_ELECTRONIC:-1}"
export DO_DC="${DO_DC:-1}"
export DO_TC="${DO_TC:-1}"
export DO_TG="${DO_TG:-1}"
export DO_VISC="${DO_VISC:-1}"
export DO_EMD="${DO_EMD:-1}"
export CHARGE_METHOD="${CHARGE_METHOD:-RESP}"
export SMILES_FILE="${SMILES_FILE:-SMILES.csv}"
export CSV_START_LINE="${CSV_START_LINE:-2}"
export initial_dir="$ADEPT_ROOT"

source Files/files.sh
