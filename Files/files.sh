#!/bin/bash

#==============================================================
# Per-PID workflow (sourced by submit.sh)
#==============================================================

# Use initial_dir from environment (set in submit.sh), or fall back to current dir
initial_dir="${initial_dir:-$PWD}"

# Checkpoint / resume helpers (OSPool eviction-safe)
# shellcheck source=Files/checkpoint.sh
source "${initial_dir}/Files/checkpoint.sh"

# ---------------- Helpers ----------------
is_true() {
  case "$(echo "${1:-0}" | tr '[:upper:]' '[:lower:]')" in
    1|y|yes|true|on) return 0 ;; *) return 1 ;;
  esac
}

is_number() {
  [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

lmp_mpi_procs() {
  # Authoritative core count = HTCondor's allocation (NSLOTS == request_cpus,
  # or _CONDOR_CPUS). Do NOT trust plain `nproc`: coreutils `nproc` honors
  # OMP_NUM_THREADS, and OSPool sets OMP_NUM_THREADS=1 inside the container, so
  # `nproc` reports 1 even when 16 cores are provisioned. That previously forced
  # single-rank MPI (~16x slower) and made DC exceed the 40h wall limit.
  local req avail_all
  req="${1:-${NSLOTS:-${_CONDOR_CPUS:-1}}}"
  is_number "$req" || req=1
  (( req < 1 )) && req=1
  # Cap only by the machine's *physical* core count. `nproc --all` ignores the
  # OMP/affinity mask, so it is a safe upper bound (prevents absurd
  # oversubscription); it never shrinks a valid 16-core allocation to 1.
  if command -v nproc >/dev/null 2>&1; then
    avail_all="$(nproc --all 2>/dev/null)"
    if is_number "$avail_all" && (( avail_all >= 1 && req > avail_all )); then
      req="$avail_all"
    fi
  fi
  echo "$req"
}

run_lmp_mpi() {
  local procs
  procs="$(lmp_mpi_procs "$NSLOTS")"
  # #region agent log
  echo "[DEBUG-MPI] START $(date -Is) procs=${procs} NSLOTS=${NSLOTS:-unset} nproc=$(nproc 2>/dev/null) nproc_all=$(nproc --all 2>/dev/null) _CONDOR_CPUS=${_CONDOR_CPUS:-unset} OMP=${OMP_NUM_THREADS:-unset} affinity=$(grep -i Cpus_allowed_list /proc/self/status 2>/dev/null | awk '{print $2}') cwd=$(pwd) cmd=$*" 2>&1
  agent_checkpoint_log "H1H2H4" "files.sh:run_lmp_mpi" "lammps start" "{\"procs\":\"${procs}\",\"nproc\":\"$(nproc 2>/dev/null)\",\"nproc_all\":\"$(nproc --all 2>/dev/null)\",\"cmd\":\"$*\"}"
  # #endregion
  # --bind-to none: with 16 ranks across a 16-core cgroup, let the OS scheduler
  # place ranks; avoids Open MPI binding all ranks onto a single core.
  mpirun --oversubscribe --bind-to none -n "$procs" "$@"
}

# Path to Python Tg predictor (RF + MACCS), inside 3.Analysis
PREDICT_TG_SCRIPT="${PREDICT_TG_SCRIPT:-$initial_dir/3.Analysis/predict_tg.py}"

# Return Tg (K) for a PID using RF+MACCS predictor (Python script)
# Expects predictor to print a single numeric Tg on stdout.
get_tg_for_pid() {
  local pid="$1"
  local script="$PREDICT_TG_SCRIPT"

  # Check predictor script exists
  if [[ ! -f "$script" ]]; then
    echo "[WARN] Tg predictor script not found: $script" >&2
    return 0
  fi

  # Run Python predictor; expect a single numeric Tg on stdout
  local val
  val=$(python "$script" "$pid" 2>/dev/null | head -n1 | tr -d '[:space:]')

  # Validate and print Tg (K) with 2 decimals, or return empty on failure
  if [[ -n "$val" ]] && is_number "$val"; then
    awk -v t="$val" 'BEGIN { printf "%.2f\n", t + 0 }'
  else
    echo "[WARN] Tg predictor returned no valid value for PID=$pid" >&2
    return 0
  fi
}

# Return MD Tg (K) for a PID from RESULTS/TG_MD.csv (PID,Tg_MD or PID,Tg)
# Can override path via TG_MD_FILE env; default RESULTS/TG_MD.csv.
get_tg_md_for_pid() {
  local pid="$1"
  local file="${TG_MD_FILE:-RESULTS/TG_MD.csv}"

  # If file doesn't exist, just return (no Tg)
  [[ -f "$file" ]] || { return 0; }

  local val
  val=$(awk -F',' -v pid="$pid" '
    BEGIN { pid_col=-1; tg_col=-1 }
    NR==1 {
      for (i=1;i<=NF;i++){
        h=$i; gsub(/\r/,"",h); tl=tolower(h);
        if (tl=="pid")   pid_col=i;
        if (tl=="tg_md" || tl=="tg") tg_col=i;
      }
      next
    }
    {
      for (i=1;i<=NF;i++){
        gsub(/\r/,"",$i);
        gsub(/^ +| +$/,"",$i);
      }
      if (pid_col>0 && tg_col>0 && $pid_col==pid) {
        print $tg_col;
        exit
      }
    }
  ' "$file")

  # Trim spaces
  val="$(echo -n "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  # If numeric, print as Tg in K with 2 decimals
  if [[ -n "$val" ]] && is_number "$val"; then
    awk -v t="$val" 'BEGIN { printf "%.2f\n", t + 0 }'
  else
    return 0
  fi
}

#==============================================================
# --- Job submission / PID resolution (no nested qsub) ---
#==============================================================

# If PID is already provided (single-job mode), run workflow
if [[ -n "${PID:-}" ]]; then
  echo "[INFO] PID already set (${PID}); running workflow."
else
  # CSV mode: require SGE_TASK_ID and map it to SMILES.csv
  if [[ -z "${SGE_TASK_ID:-}" ]]; then
    echo "[ERROR] No PID and no SGE_TASK_ID found."
    echo "       Submit as an array job, e.g.: qsub -t 1-N submit.sh"
    exit 1
  fi

  line=$((CSV_START_LINE + SGE_TASK_ID - 1))
  PID=$(sed -n "${line}p" "$SMILES_FILE" | cut -d',' -f1 | tr -d '\r')
  export PID
  echo "[INFO] CSV mode: ${SMILES_FILE} line ${line} → PID=${PID}"
fi

# Safety check
if [[ -z "$PID" ]]; then
  echo "[ERROR] No PID resolved! Exiting."
  exit 1
fi

#==============================================================
# --- Workflow (per PID) with property toggles ---
#==============================================================

# Step 1: Amorphous Polymer Generation (APG)
if is_true "$DO_APG"; then
  if step_done_apg "$PID"; then
    echo "[SKIP] APG already complete for $PID"
    agent_checkpoint_log "H2" "files.sh:apg" "skipped completed step" "{\"pid\":\"${PID}\"}"
  else
  method_norm="$(echo "$CHARGE_METHOD" | tr '[:lower:]' '[:upper:]')"
  case "$method_norm" in
    RESP)      apg_script="APG_resp.py" ;;
    GASTEIGER) apg_script="APG_gas.py"  ;;
    *)
      echo "[ERROR] CHARGE_METHOD must be RESP or GASTEIGER (got: '$CHARGE_METHOD')"
      exit 1
      ;;
  esac

  echo "[RUN ] APG for $PID with $method_norm charges ($apg_script)"
  cd 1.AmorphousGeneration
  python "$apg_script" "$PID" "$NSLOTS"
  cd "$initial_dir"
  checkpoint_barrier "apg"
  fi
else
  echo "[SKIP] APG disabled (DO_APG=$DO_APG)"
fi

# Step 2: Optimization (always run if DO_OPT=true)
if is_true "$DO_OPT"; then
  if step_done_opt "$PID"; then
    echo "[SKIP] Optimization already complete for $PID"
    agent_checkpoint_log "H2" "files.sh:opt" "skipped completed step" "{\"pid\":\"${PID}\"}"
  else
  echo "[RUN ] Optimization for $PID"
  run_lammps_opt_for_pid "$PID"
  checkpoint_barrier "opt"
  fi
else
  echo "[SKIP] Optimization disabled (DO_OPT=$DO_OPT)"
fi


# Step 3: Monomer Electronic Properties
if is_true "$DO_MONO_ELECTRONIC"; then
  if step_done_mono_electronic "$PID"; then
    echo "[SKIP] Monomer electronic already complete for $PID"
    agent_checkpoint_log "H2" "files.sh:dft" "skipped completed step" "{\"pid\":\"${PID}\"}"
  else
  echo "[RUN ] Monomer electronic for $PID"
  mkdir -p "POLYMER_DATA/MONOMER_ELECTRONIC/$PID"
  cd "POLYMER_DATA/MONOMER_ELECTRONIC/$PID"
  python "../../../1.AmorphousGeneration/electronic_properties.py" "$PID" "${PSI_THREADS:-1}"
  python "../../../3.Analysis/update_ep.py" "$PID"
  cd "$initial_dir"
  checkpoint_barrier "mono_electronic"
  fi
else
  echo "[SKIP] Monomer electronic disabled (DO_MONO_ELECTRONIC=$DO_MONO_ELECTRONIC)"
fi

# Step 4: Dielectric Constant
if is_true "$DO_DC"; then
  if step_done_dc "$PID"; then
    echo "[SKIP] Dielectric constant already complete for $PID"
    agent_checkpoint_log "H2" "files.sh:dc" "skipped completed step" "{\"pid\":\"${PID}\"}"
  else
  echo "[RUN ] Dielectric constant for $PID"
  mkdir -p "POLYMER_DATA/DIELECTRIC_CONSTANT/$PID"
  cd "POLYMER_DATA/DIELECTRIC_CONSTANT/$PID"
  run_lmp_mpi lmp -in "../../../2.Simulations/lammps_dc.in" -var name "$PID"
  python "../../../3.Analysis/calc_DC.py" "$PID"
  python "../../../3.Analysis/update_DC.py" "$PID"
  cd "$initial_dir"
  checkpoint_barrier "dc"
  fi
else
  echo "[SKIP] Dielectric constant disabled (DO_DC=$DO_DC)"
fi

# Step 5: Thermal Conductivity (resumable NEMD with LAMMPS restart + tally offsets)
if is_true "$DO_TC"; then
  if step_done_tc "$PID"; then
    echo "[SKIP] TC already complete for $PID"
    agent_checkpoint_log "H2" "files.sh:tc" "skipped completed step" "{\"pid\":\"${PID}\"}"
  else
  echo "[RUN ] TC for $PID (resumable LAMMPS restart chunks)"
  mkdir -p "POLYMER_DATA/THERMAL_CONDUCTIVITY/$PID"
  # run_tc_lammps_resumable cds into the TC dir, merges chunks, analyzes, and
  # exit-85 checkpoints between chunks when ADEPT_CHECKPOINT_MODE=exit85.
  run_tc_lammps_resumable "$PID"
  checkpoint_barrier "tc"
  fi
else
  echo "[SKIP] TC disabled (DO_TC=$DO_TC)"
fi

# Step 6: Glass Transition Temperature (Tg, uses ML-predicted Tg as input guess to MD)
if is_true "$DO_TG"; then
  if step_done_tg "$PID"; then
    echo "[SKIP] Tg already complete for $PID"
    agent_checkpoint_log "H2" "files.sh:tg" "skipped completed step" "{\"pid\":\"${PID}\"}"
  else
  TG_VAL="$(get_tg_for_pid "$PID")"
  if [[ -z "$TG_VAL" ]]; then
    echo "[SKIP] Tg: no Tg value predicted for PID=$PID → skipping Tg LAMMPS run."
  else
    echo "[RUN ] Tg for $PID using ML Tg=${TG_VAL} K (resumable temperature-point chunks)"
    # run_tg_lammps_resumable cds into the Tg dir, runs the scan in chunks of
    # ADEPT_TG_CHUNK_POINTS temperature points, merges the per-chunk density
    # files, analyzes, and exit-85 checkpoints between chunks so an eviction
    # costs one chunk instead of the whole 31M-step scan.
    run_tg_lammps_resumable "$PID" "$TG_VAL"
    checkpoint_barrier "tg"
  fi
  fi
else
  echo "[SKIP] Tg disabled (DO_TG=$DO_TG)"
fi

# Step 7: Viscosity (prefers MD Tg, falls back to ML-predicted Tg)
if is_true "$DO_VISC"; then
  if step_done_visc "$PID"; then
    echo "[SKIP] Viscosity already complete for $PID"
    agent_checkpoint_log "H2" "files.sh:visc" "skipped completed step" "{\"pid\":\"${PID}\"}"
  else
  # 1) Try MD Tg from RESULTS/TG_MD.csv
  TG_VAL_MD="$(get_tg_md_for_pid "$PID")"
  TG_VAL=""

  if [[ -n "$TG_VAL_MD" ]]; then
    TG_VAL="$TG_VAL_MD"
    echo "[INFO] Viscosity: using MD Tg from RESULTS/TG_MD.csv for PID=$PID → Tg=${TG_VAL} K"
  else
    # 2) Fallback: ML-predicted Tg via RF+MACCS
    TG_VAL="$(get_tg_for_pid "$PID")"
    if [[ -n "$TG_VAL" ]]; then
      echo "[INFO] Viscosity: MD Tg not found, using ML-predicted Tg for PID=$PID → Tg=${TG_VAL} K"
    fi
  fi

  if [[ -z "$TG_VAL" ]]; then
    echo "[SKIP] Viscosity: no Tg (MD or ML) available for PID=$PID → skipping viscosity LAMMPS run."
  else
    echo "[RUN ] Viscosity for $PID using Tg=${TG_VAL} K"
    mkdir -p "POLYMER_DATA/VISCOSITY/$PID"
    cd "POLYMER_DATA/VISCOSITY/$PID"
    run_lmp_mpi lmp -in "../../../2.Simulations/lammps_visc.in" \
          -var name "$PID" -var Tg "$TG_VAL"
    python "../../../3.Analysis/update_visc.py" "$PID"
    cd "$initial_dir"
    checkpoint_barrier "visc"
  fi
  fi
else
  echo "[SKIP] Viscosity disabled (DO_VISC=$DO_VISC)"
fi

# Step 8: EMD (bundle: Cp, alpha, modulus, etc. from an EMD run)
if is_true "$DO_EMD"; then
  if step_done_emd "$PID"; then
    echo "[SKIP] EMD already complete for $PID"
    agent_checkpoint_log "H2" "files.sh:emd" "skipped completed step" "{\"pid\":\"${PID}\"}"
  else
  echo "[RUN ] EMD for $PID"
  mkdir -p "POLYMER_DATA/EMD/$PID"
  cd "POLYMER_DATA/EMD/$PID"
  run_lmp_mpi lmp -in "../../../2.Simulations/lammps_emd.in" -var name "$PID"

  # Post-process: modulus, Cp, alpha from EMD trajectory
  python "../../../3.Analysis/calc_modulus.py" "$PID"
  python "../../../3.Analysis/update_modulus.py" "$PID"
  python "../../../3.Analysis/calc_Cp_alphaP.py" "$PID"
  python "../../../3.Analysis/update_Cp_alphaP.py" "$PID"
  python "../../../3.Analysis/update_alphaT.py" "$PID"

  cd "$initial_dir"
  checkpoint_barrier "emd"
  fi
else
  echo "[SKIP] EMD disabled (DO_EMD=$DO_EMD)"
fi

write_checkpoint_status "${SGE_TASK_ID:-unknown}" "$PID"
agent_checkpoint_log "H3" "files.sh:done" "workflow finished for pid" "{\"pid\":\"${PID}\"}"

echo "Workflow complete for PID=$PID"
