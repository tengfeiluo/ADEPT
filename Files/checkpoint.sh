#!/bin/bash
# Checkpoint / resume helpers for ADEPT on OSPool (eviction-safe step skip).

# #region agent log
agent_checkpoint_log() {
    local hypothesis_id="$1"
    local location="$2"
    local message="$3"
    local data="${4:-{}}"
    local ts
    ts="$(date +%s000)"
    local payload="{\"event\":\"checkpoint\",\"hypothesisId\":\"${hypothesis_id}\",\"location\":\"${location}\",\"message\":\"${message}\",\"data\":${data},\"timestamp\":${ts}}"
    printf '%s\n' "$payload" >> "${initial_dir}/Log_Files/debug-agent.log" 2>/dev/null || true
}
# #endregion

csv_has_pid() {
    local csv="$1"
    local pid="$2"
    [[ -f "$csv" ]] || return 1
    awk -F',' -v p="$pid" '
        NR == 1 { next }
        {
            gsub(/\r/, "", $1)
            gsub(/^ +| +$/, "", $1)
            if ($1 == p) { found = 1; exit }
        }
        END { exit !found }
    ' "$csv"
}

write_checkpoint_status() {
    local task_index="$1"
    local pid="$2"
    local status_file="${initial_dir}/checkpoint_status.${task_index}.txt"

    {
        echo "timestamp=$(date -Is)"
        echo "task=${task_index}"
        echo "pid=${pid}"
        echo "apg=$(step_done_apg "$pid" && echo yes || echo no)"
        echo "opt=$(step_done_opt "$pid" && echo yes || echo no)"
        echo "mono_electronic=$(step_done_mono_electronic "$pid" && echo yes || echo no)"
        echo "dc=$(step_done_dc "$pid" && echo yes || echo no)"
        echo "tc=$(step_done_tc "$pid" && echo yes || echo no)"
        echo "tg=$(step_done_tg "$pid" && echo yes || echo no)"
        echo "visc=$(step_done_visc "$pid" && echo yes || echo no)"
        echo "emd=$(step_done_emd "$pid" && echo yes || echo no)"
    } > "$status_file"
}

init_checkpoint_artifacts() {
    local task_index="$1"
    local pid="$2"
    mkdir -p "${initial_dir}/Log_Files" "${initial_dir}/POLYMER_DATA/RESULTS"
    [[ -f "${initial_dir}/Log_Files/debug-agent.log" ]] || : > "${initial_dir}/Log_Files/debug-agent.log"
    write_checkpoint_status "$task_index" "$pid"
    agent_checkpoint_log "H4" "checkpoint.sh:init" "checkpoint artifacts initialized" "{\"task\":\"${task_index}\",\"pid\":\"${pid}\"}"
}

# Map a barrier step name to its step_done_* completion check.
step_is_done() {
    local step="$1" pid="$2"
    case "$step" in
        apg)             step_done_apg "$pid" ;;
        opt)             step_done_opt "$pid" ;;
        mono_electronic) step_done_mono_electronic "$pid" ;;
        dc)              step_done_dc "$pid" ;;
        tc)              step_done_tc "$pid" ;;
        # Mid-TC chunk checkpoint: allow exit 85 when restart/thermo progress exists
        # even though TC_MD.csv is not written yet.
        tc_chunk)        tc_has_resume_artifacts "$pid" ;;
        tg)              step_done_tg "$pid" ;;
        # Mid-Tg chunk checkpoint: allow exit 85 when the scan has produced
        # restart/density progress even though TG_MD.csv is not written yet.
        tg_chunk)        tg_has_resume_artifacts "$pid" ;;
        # Mid-eq2 chunk checkpoint (resumable cooling ramp / hold).
        eq2_chunk)       eq2_has_resume_artifacts "$pid" ;;
        # Mid-stage chunks of eq1, dielectric constant, viscosity and EMD (Files/stage_resume.sh).
        eq1_chunk)       eq1_has_resume_artifacts "$pid" ;;
        dc_chunk)        dc_has_resume_artifacts "$pid" ;;
        visc_chunk)      visc_has_resume_artifacts "$pid" ;;
        emd_chunk)       emd_has_resume_artifacts "$pid" ;;
        visc)            step_done_visc "$pid" ;;
        emd)             step_done_emd "$pid" ;;
        *)               return 0 ;;
    esac
}

# Exit-driven self-checkpoint barrier (OSPool exit code 85).
#
# When ADEPT_CHECKPOINT_MODE=exit85, this is called after each completed step.
# It exits 85 once the wall-clock budget (ADEPT_CKPT_BUDGET_SEC) has elapsed, so
# HTCondor spools transfer_checkpoint_files, requeues the SAME job, restores
# state, and the next execution skips finished steps (step_done_*) and runs the
# next one. With ADEPT_CKPT_BUDGET_SEC=0 (current setting) the budget is always
# "reached", so each execution runs exactly ONE step then checkpoints. This is
# required because single MD steps run for many hours (DC ~5-12h, TC/EMD ~20-28h
# at 16 cores); batching several steps into one execution overran the 40h wall
# limit, and the ON_EXIT HOLD that followed transferred nothing, discarding every
# step finished in that execution.
#
# Infinite-loop guard: only exit 85 if the step we just ran actually persisted
# its step_done_* marker. If a step somehow finishes without a marker, exiting 85
# would requeue and re-run the SAME step forever; instead we log loudly and
# `return 0` so the pipeline advances to the next step (at worst that step batches
# with the next one, still far under 40h). Genuine step failures abort earlier via
# `set -e` in the caller (non-zero, not 85), so HTCondor never mistakes them for
# a checkpoint.
#
# CRITICAL: the caller runs under `set -e`. We disable it locally so that no
# stray non-zero status can abort before `exit 85` (which would make HTCondor
# see a failure code instead of the checkpoint code and drop the job).
checkpoint_barrier() {
    local step="$1"
    [[ "${ADEPT_CHECKPOINT_MODE:-off}" == "exit85" ]] || return 0

    set +e
    local now start budget elapsed
    now="$(date +%s)"
    start="${ADEPT_EXEC_START_EPOCH:-$now}"
    budget="${ADEPT_CKPT_BUDGET_SEC:-43200}"
    elapsed=$(( now - start ))

    if (( elapsed < budget )); then
        agent_checkpoint_log "H5" "checkpoint.sh:barrier" "within budget, continue" \
            "{\"step\":\"${step}\",\"elapsed\":${elapsed},\"budget\":${budget}}"
        set -e
        return 0
    fi

    local task="${SGE_TASK_ID:-unknown}"
    local pid="${PID:-unknown}"

    if ! ( cd "$initial_dir" 2>/dev/null && step_is_done "$step" "$pid" ); then
        echo "[CKPT][WARN] step '${step}' finished but wrote no step_done marker; NOT exiting 85 (would loop). Continuing to next step."
        agent_checkpoint_log "H5" "checkpoint.sh:barrier" "no marker, continue (loop-guard)" \
            "{\"task\":\"${task}\",\"pid\":\"${pid}\",\"step\":\"${step}\"}"
        set -e
        return 0
    fi

    ( cd "$initial_dir" 2>/dev/null && write_checkpoint_status "$task" "$pid" ) || true
    echo "[CKPT] step '${step}' complete (elapsed ${elapsed}s, budget ${budget}s); checkpoint + requeue (exit 85)"
    agent_checkpoint_log "H5" "checkpoint.sh:barrier" "step done, exit 85" \
        "{\"task\":\"${task}\",\"pid\":\"${pid}\",\"step\":\"${step}\",\"elapsed\":${elapsed}}"
    exit 85
}

seed_polymer_data_from_task_store() {
    local task_index="$1"
    local seed_root="${initial_dir}/POLYMER_DATA_full/${task_index}/POLYMER_DATA"

    if [[ ! -d "$seed_root" ]]; then
        echo "[INFO] No resume seed directory: ${seed_root}"
        agent_checkpoint_log "H1" "checkpoint.sh:seed" "no seed dir" "{\"task\":\"${task_index}\"}"
        return 0
    fi

    if [[ -z "$(find "$seed_root" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        echo "[INFO] Resume seed directory is empty: ${seed_root}"
        agent_checkpoint_log "H1" "checkpoint.sh:seed" "empty seed dir" "{\"task\":\"${task_index}\"}"
        return 0
    fi

    mkdir -p "${initial_dir}/POLYMER_DATA"
    # No-clobber: never overwrite files already present from a restored checkpoint
    # (HTCondor spools the latest POLYMER_DATA back before this runs). The seed only
    # fills in files that are missing, so stale on-AP seed data can never regress
    # newer progress recovered from the checkpoint/SPOOL sandbox.
    echo "[INFO] Seeding POLYMER_DATA from ${seed_root} (no-clobber)"
    cp -a -n "${seed_root}/." "${initial_dir}/POLYMER_DATA/" 2>/dev/null || \
        cp -rn "${seed_root}/." "${initial_dir}/POLYMER_DATA/" 2>/dev/null || true
    agent_checkpoint_log "H1" "checkpoint.sh:seed" "seed applied (no-clobber)" "{\"task\":\"${task_index}\",\"seed_files\":$(find "$seed_root" -type f 2>/dev/null | wc -l)}"
}

step_done_apg() {
    local pid="$1"
    [[ -f "POLYMER_DATA/MODEL/${pid}/${pid}_SUCCESS" ]] &&
        [[ -f "POLYMER_DATA/MODEL/${pid}/amorphous_polymer_${pid}.lmps" ]]
}

step_done_opt() {
    local pid="$1"
    [[ -f "POLYMER_DATA/OPTIMIZATION/${pid}/${pid}_eq2.data" ]]
}

step_done_eq1() {
    local pid="$1"
    [[ -f "POLYMER_DATA/OPTIMIZATION/${pid}/${pid}_eq1.data" ]]
}

step_done_mono_electronic() {
    local pid="$1"
    csv_has_pid "POLYMER_DATA/RESULTS/HOMO_DFT.csv" "$pid" ||
        [[ -f "POLYMER_DATA/MONOMER_ELECTRONIC/${pid}/${pid}_homo.dat" ]]
}

step_done_dc() {
    local pid="$1"
    csv_has_pid "POLYMER_DATA/RESULTS/DC_MD.csv" "$pid"
}

step_done_tc() {
    local pid="$1"
    csv_has_pid "POLYMER_DATA/RESULTS/TC_MD.csv" "$pid"
}

# True if TC has mid-run artifacts worth checkpointing / resuming from.
tc_has_resume_artifacts() {
    local pid="$1"
    local tc_dir="${initial_dir}/POLYMER_DATA/THERMAL_CONDUCTIVITY/${pid}"
    [[ -f "${tc_dir}/${pid}_thermo.dat" ]] || \
        [[ -f "${tc_dir}/${pid}_tc_progress.dat" ]] || \
        [[ -f "${tc_dir}/${pid}_rstrt_3" ]] || \
        [[ -f "${tc_dir}/${pid}_rstrt_4" ]] || \
        [[ -f "${tc_dir}/${pid}_rstrt_end" ]]
}

# Newest readable TC restart file for pid, or empty if none.
tc_pick_restart_file() {
    local pid="$1"
    local tc_dir="${initial_dir}/POLYMER_DATA/THERMAL_CONDUCTIVITY/${pid}"
    local best="" best_m=0 f m
    for f in "${tc_dir}/${pid}_rstrt_end" "${tc_dir}/${pid}_rstrt_3" "${tc_dir}/${pid}_rstrt_4"; do
        [[ -f "$f" ]] || continue
        m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        if (( m >= best_m )); then
            best_m=$m
            best=$f
        fi
    done
    echo "$best"
}

# Last completed step / f4c / f5c.
# Prefer ${pid}_tc_progress.dat (written every chunk at the true timestep);
# fall back to the last row of the merged thermo.dat (thermo every 10000 steps).
tc_thermo_state() {
    local pid="$1"
    local tc_dir="${initial_dir}/POLYMER_DATA/THERMAL_CONDUCTIVITY/${pid}"
    local prog="${tc_dir}/${pid}_tc_progress.dat"
    local thermo="${tc_dir}/${pid}_thermo.dat"
    if [[ -s "$prog" ]]; then
        awk 'NF >= 3 { s=$1; o4=$2; o5=$3 } END { if (NR==0) print "0 0.0 0.0"; else print s, o4, o5 }' "$prog"
        return 0
    fi
    if [[ ! -s "$thermo" ]]; then
        echo "0 0.0 0.0"
        return 0
    fi
    awk 'NF >= 13 { s=$1; o4=$12; o5=$13 } END { if (NR==0) print "0 0.0 0.0"; else print s, o4, o5 }' "$thermo"
}

# Merge per-chunk LAMMPS outputs into the cumulative thermo/profile files.
# Skips a duplicate first thermo row when its step matches the current last step.
tc_merge_chunk_outputs() {
    local pid="$1"
    local tc_dir="${initial_dir}/POLYMER_DATA/THERMAL_CONDUCTIVITY/${pid}"
    local chunk_thermo="${tc_dir}/${pid}_thermo.chunk.dat"
    local merged_thermo="${tc_dir}/${pid}_thermo.dat"
    local chunk_prof="${tc_dir}/${pid}_temp.chunk.profile"
    local merged_prof="${tc_dir}/${pid}_temp.profile"

    if [[ -s "$chunk_thermo" ]]; then
        if [[ ! -s "$merged_thermo" ]]; then
            cp -f "$chunk_thermo" "$merged_thermo"
        else
            local last_step first_step
            last_step=$(awk 'NF>=1 {s=$1} END{print s+0}' "$merged_thermo")
            first_step=$(awk 'NF>=1 {print $1; exit}' "$chunk_thermo")
            if [[ "$first_step" == "$last_step" ]]; then
                # Drop duplicate boundary sample (resume reprints current step).
                awk -v skip="$first_step" 'NR==1 && $1==skip {next} {print}' "$chunk_thermo" >> "$merged_thermo"
            else
                cat "$chunk_thermo" >> "$merged_thermo"
            fi
        fi
        echo "[TC] merged thermo chunk -> ${pid}_thermo.dat (lines=$(wc -l < "$merged_thermo"))"
    else
        echo "[TC][WARN] missing chunk thermo: $chunk_thermo"
    fi

    if [[ -s "$chunk_prof" ]]; then
        if [[ ! -s "$merged_prof" ]]; then
            cp -f "$chunk_prof" "$merged_prof"
        else
            # Keep the first file's 3-line header; append only data lines from later chunks.
            awk 'NR<=3 {next} {print}' "$chunk_prof" >> "$merged_prof"
        fi
        echo "[TC] merged temp profile chunk -> ${pid}_temp.profile"
    fi
}

# Run TC LAMMPS in resumable chunks; exit 85 between chunks when checkpointing.
run_tc_lammps_resumable() {
    local pid="$1"
    local total="${ADEPT_TC_TOTAL_STEPS:-20000000}"
    local chunk="${ADEPT_TC_CHUNK_STEPS:-4000000}"
    local tc_dir="${initial_dir}/POLYMER_DATA/THERMAL_CONDUCTIVITY/${pid}"
    local tc_in="${initial_dir}/2.Simulations/lammps_TC.in"
    local state step off4 off5 resume rst run_upto

    mkdir -p "$tc_dir"
    cd "$tc_dir"

    while true; do
        if step_done_tc "$pid"; then
            echo "[TC] already complete for $pid"
            return 0
        fi

        state="$(tc_thermo_state "$pid")"
        step=$(echo "$state" | awk '{print $1+0}')
        off4=$(echo "$state" | awk '{print $2}')
        off5=$(echo "$state" | awk '{print $3}')
        is_number "$step" || step=0
        is_number "$off4" || off4=0.0
        is_number "$off5" || off5=0.0

        if (( step >= total )); then
            echo "[TC] thermo reached ${step} >= ${total}; running analysis"
            break
        fi

        rst="$(tc_pick_restart_file "$pid")"
        if [[ -n "$rst" && "$step" -gt 0 ]]; then
            resume=1
        else
            resume=0
            rst=none
            # Fresh (re)start: drop stale partial merges if no restart to continue from.
            if [[ "$step" -gt 0 && -z "$(tc_pick_restart_file "$pid")" ]]; then
                echo "[TC][WARN] thermo progress without restart file; restarting TC from scratch"
                rm -f "${pid}_thermo.dat" "${pid}_temp.profile" \
                      "${pid}_thermo.chunk.dat" "${pid}_temp.chunk.profile" \
                      "${pid}_tc_progress.dat" "${pid}_tally_offset.inc"
                step=0
                off4=0.0
                off5=0.0
            fi
        fi

        run_upto=$(( step + chunk ))
        if (( run_upto > total )); then
            run_upto=$total
        fi
        # Ensure we always ask LAMMPS to advance at least one thermo interval when
        # resuming at an exact chunk boundary.
        if (( run_upto <= step )); then
            run_upto=$(( step + chunk ))
            if (( run_upto > total )); then run_upto=$total; fi
        fi

        echo "[TC] chunk resume=${resume} step=${step} -> run_upto=${run_upto} off4=${off4} off5=${off5} rst=${rst}"

        rm -f "${pid}_thermo.chunk.dat" "${pid}_temp.chunk.profile"

        # Write offsets via an include file (negative values break "lmp -var").
        cat > "${pid}_tally_offset.inc" <<EOF
variable off4 equal ${off4}
variable off5 equal ${off5}
EOF

        run_lmp_mpi lmp -in "$tc_in" \
            -var name "$pid" \
            -var resume "$resume" \
            -var rstfile "$rst" \
            -var run_upto "$run_upto" \
            -var total_steps "$total"

        tc_merge_chunk_outputs "$pid"

        # Final restart snapshot for the next chunk / eviction recovery.
        if [[ -f "${pid}_rstrt_end" ]]; then
            # Keep end snapshot as the preferred newest restart (mtime-based pick).
            touch "${pid}_rstrt_end"
            stage_rst_archive "${pid}_rstrt_end" "${pid}_tc_${run_upto}.rst"
        fi

        state="$(tc_thermo_state "$pid")"
        step=$(echo "$state" | awk '{print $1+0}')
        echo "[TC] after chunk: step=${step} / ${total}"

        if (( step >= total )); then
            break
        fi

        # Persist mid-TC progress via HTCondor exit-85 self-checkpoint.
        cd "$initial_dir"
        checkpoint_barrier "tc_chunk"
        cd "$tc_dir"
        # If barrier did not exit (checkpoint mode off), continue next chunk in-process.
    done

    echo "[RUN ] TC analysis for $pid"
    python "${initial_dir}/3.Analysis/calc_TC.py" "$pid"
    python "${initial_dir}/3.Analysis/update_TC.py" "$pid"
    cd "$initial_dir"
}

step_done_tg() {
    local pid="$1"
    csv_has_pid "POLYMER_DATA/RESULTS/TG_MD.csv" "$pid"
}

step_done_visc() {
    local pid="$1"
    csv_has_pid "POLYMER_DATA/RESULTS/VISC_MD.csv" "$pid"
}

step_done_emd() {
    local pid="$1"
    csv_has_pid "POLYMER_DATA/RESULTS/E_MD.csv" "$pid" ||
        csv_has_pid "POLYMER_DATA/RESULTS/K_MD.csv" "$pid"
}

run_lammps_opt_for_pid() {
    local pid="$1"
    local opt_dir="${initial_dir}/POLYMER_DATA/OPTIMIZATION/${pid}"
    local eq1_in="${initial_dir}/2.Simulations/lammps_eq1.in"
    local eq2_in="${initial_dir}/2.Simulations/lammps_eq2.in"

    mkdir -p "$opt_dir"
    cd "$opt_dir"

    if [[ -f "${pid}_eq2.data" ]]; then
        echo "[SKIP] OPT LAMMPS already complete (${pid}_eq2.data)"
    else
        if [[ -f "${pid}_eq1.data" ]]; then
            echo "[SKIP] eq1 already complete (${pid}_eq1.data)"
        else
            if stage_resumable; then
                echo "[RUN ] eq1 (resumable chunks) for ${pid}"
                run_eq1_resumable "$pid"
            else
                echo "[RUN ] eq1 for ${pid}"
                run_lmp_mpi lmp -in "$eq1_in" -var name "$pid"
            fi
        fi

        if [[ -f "${pid}_eq1.data" ]]; then
            if is_true "${ADEPT_EQ2_RESUMABLE:-${ADEPT_STAGE_RESUMABLE:-1}}"; then
                echo "[RUN ] eq2 (resumable chunks) for ${pid}"
                run_eq2_resumable "$pid"
            else
                echo "[RUN ] eq2 for ${pid}"
                run_lmp_mpi lmp -in "$eq2_in" -var name "$pid"
            fi
        else
            echo "[WARN] eq1 did not produce ${pid}_eq1.data; skipping eq2"
        fi
    fi

    if [[ -f "${pid}_eq2.data" ]]; then
        if ! csv_has_pid "${initial_dir}/POLYMER_DATA/RESULTS/RG_MD.csv" "$pid"; then
            python "${initial_dir}/3.Analysis/calc_Rg.py" "$pid"
            python "${initial_dir}/3.Analysis/calc_density.py" "$pid"
            python "${initial_dir}/3.Analysis/update_Rg_dens.py" "$pid"
        else
            echo "[SKIP] OPT post-process CSVs already present for ${pid}"
        fi
    fi

    cd "$initial_dir"
}

# ---------------------------------------------------------------------------
# Tg: resumable temperature-point chunks (mirrors the TC pattern above).
#
# The Tg scan is a loop over N temperature points, each eq_steps + prod_steps
# long (default 31 points x 1M steps = 31M steps). lammps_Tg.in runs only
# points [i_start, i_end] per invocation, so an OSPool eviction costs at most
# one chunk instead of the entire scan. Chunks always end on a temperature-
# point boundary, so the merged density file only holds whole points.
#
# Tunable: ADEPT_TG_CHUNK_POINTS (default 2 temperature points per chunk).
# ---------------------------------------------------------------------------

# Temperature-point count for a given ML Tg. MUST mirror the arithmetic in
# 2.Simulations/lammps_Tg.in (scan_range=150, tstep=10, Tmin=50).
tg_num_points() {
    local tg_val="$1"
    awk -v tg="$tg_val" 'BEGIN {
        scan_range = 150; tstep = 10; tmin = 50;
        tstart = tg + scan_range;
        tend_raw = tg - scan_range;
        tend = (tend_raw > tmin) ? tend_raw : tmin;
        n = int((tstart - tend) / tstep + 1);
        if (n < 1) n = 1;
        print n;
    }'
}

# True if Tg has mid-run artifacts worth checkpointing / resuming from.
tg_has_resume_artifacts() {
    local pid="$1"
    local tg_dir="${initial_dir}/POLYMER_DATA/GLASS_TRANSITION/${pid}"
    [[ -f "${tg_dir}/${pid}_tg_density.dat" ]] || \
        [[ -f "${tg_dir}/${pid}_tg_progress.dat" ]] || \
        [[ -f "${tg_dir}/${pid}_tg_rstrt_end" ]]
}

# Restart file written at the last chunk boundary, or empty if none.
tg_pick_restart_file() {
    local pid="$1"
    local tg_dir="${initial_dir}/POLYMER_DATA/GLASS_TRANSITION/${pid}"
    local f="${tg_dir}/${pid}_tg_rstrt_end"
    if [[ -f "$f" ]]; then echo "$f"; else echo ""; fi
}

# Next temperature index to run (1-based). Source of truth is the progress
# sidecar written by lammps_Tg.in at each chunk boundary.
tg_next_index() {
    local pid="$1"
    local tg_dir="${initial_dir}/POLYMER_DATA/GLASS_TRANSITION/${pid}"
    local prog="${tg_dir}/${pid}_tg_progress.dat"
    if [[ -s "$prog" ]]; then
        awk 'NF >= 1 { n = $1 + 0 } END { if (NR == 0 || n < 1) print 1; else print n }' "$prog"
    else
        echo 1
    fi
}

# Append this chunk's density rows to the cumulative file that calc_Tg.py reads.
# np.loadtxt(comments="#") skips the per-chunk headers, so plain concatenation
# is safe.
tg_merge_chunk_outputs() {
    local pid="$1"
    local tg_dir="${initial_dir}/POLYMER_DATA/GLASS_TRANSITION/${pid}"
    local chunk="${tg_dir}/${pid}_tg_density.chunk.dat"
    local merged="${tg_dir}/${pid}_tg_density.dat"

    if [[ -s "$chunk" ]]; then
        if [[ ! -s "$merged" ]]; then
            cp -f "$chunk" "$merged"
        else
            cat "$chunk" >> "$merged"
        fi
        echo "[TG] merged density chunk -> ${pid}_tg_density.dat"
    else
        echo "[TG][WARN] missing chunk density file: $chunk"
    fi
}

# Run the Tg scan in resumable chunks; exit 85 between chunks when checkpointing.
run_tg_lammps_resumable() {
    local pid="$1" tg_val="$2"
    local chunk="${ADEPT_TG_CHUNK_POINTS:-2}"
    local tg_dir="${initial_dir}/POLYMER_DATA/GLASS_TRANSITION/${pid}"
    local tg_in="${initial_dir}/2.Simulations/lammps_Tg.in"
    local total i_start i_end resume rst next
    local last_start=-1

    total="$(tg_num_points "$tg_val")"
    # Self-contained numeric checks: do not depend on is_number() being sourced,
    # because a missing helper here would silently reset the scan index to 1 and
    # loop forever.
    [[ "$chunk" =~ ^[0-9]+$ ]] || chunk=2
    (( chunk >= 1 )) || chunk=1

    mkdir -p "$tg_dir"
    cd "$tg_dir"

    while true; do
        if step_done_tg "$pid"; then
            echo "[TG] already complete for $pid"
            cd "$initial_dir"
            return 0
        fi

        i_start="$(tg_next_index "$pid")"
        [[ "$i_start" =~ ^[0-9]+$ ]] || i_start=1

        # Hard loop guard: the starting index must strictly advance on every
        # iteration. Without this, a malformed/unwritable progress file makes
        # the driver re-run the same temperature points forever, burning the
        # whole 40h wall limit with nothing to show.
        if (( last_start >= 0 && i_start <= last_start )); then
            echo "[TG][ERROR] scan index did not advance (i_start=${i_start}, previous=${last_start}); aborting Tg to avoid an infinite loop"
            cd "$initial_dir"
            return 1
        fi
        last_start=$i_start

        if (( i_start > total )); then
            echo "[TG] all ${total} temperature points done; running analysis"
            break
        fi

        rst="$(tg_pick_restart_file "$pid")"
        if [[ -n "$rst" && "$i_start" -gt 1 ]]; then
            resume=1
        else
            resume=0
            rst=none
            # Progress without a restart to continue from: start the scan over
            # rather than splice incompatible density series together.
            if (( i_start > 1 )); then
                echo "[TG][WARN] progress at index ${i_start} but no restart file; restarting Tg scan from scratch"
                rm -f "${pid}_tg_density.dat" "${pid}_tg_density.chunk.dat" "${pid}_tg_progress.dat"
                i_start=1
            fi
        fi

        i_end=$(( i_start + chunk - 1 ))
        (( i_end > total )) && i_end=$total

        echo "[TG] chunk resume=${resume} points ${i_start}..${i_end} of ${total} rst=${rst}"

        # Drop any partial chunk left by a killed invocation so only whole
        # temperature points ever reach the merged density file.
        rm -f "${pid}_tg_density.chunk.dat"

        run_lmp_mpi lmp -in "$tg_in" \
            -var name "$pid" \
            -var Tg_input "$tg_val" \
            -var resume "$resume" \
            -var rstfile "$rst" \
            -var i_start "$i_start" \
            -var i_end "$i_end"

        tg_merge_chunk_outputs "$pid"
        stage_rst_archive "${pid}_tg_rstrt_end" "${pid}_tg_point${i_end}.rst"

        next="$(tg_next_index "$pid")"
        echo "[TG] after chunk: next index ${next} / ${total}"

        if (( next > total )); then
            break
        fi

        # Guard against a chunk that failed to advance the index, which would
        # otherwise spin forever re-running the same temperature points.
        if (( next <= i_start )); then
            echo "[TG][ERROR] chunk did not advance (next=${next}, i_start=${i_start}); aborting Tg"
            cd "$initial_dir"
            return 1
        fi

        # Persist mid-Tg progress via HTCondor exit-85 self-checkpoint.
        cd "$initial_dir"
        checkpoint_barrier "tg_chunk"
        cd "$tg_dir"
        # If barrier did not exit (checkpoint mode off), continue next chunk in-process.
    done

    echo "[RUN ] Tg analysis for $pid"
    python "${initial_dir}/3.Analysis/calc_Tg.py" "$pid" "$tg_val"
    python "${initial_dir}/3.Analysis/update_Tg.py" "$pid"
    cd "$initial_dir"
}

# ---------------------------------------------------------------------------
# eq2: resumable chunks (2026-10-24). Mirrors the TC/Tg pattern: each invocation runs one chunk of the
# 1000->300 K ramp or the 300 K hold from the newest restart, then exits 85 so HTCondor spools the
# restart. An eviction costs at most one chunk. Enabled with ADEPT_EQ2_RESUMABLE=1.
# Tunables: ADEPT_EQ2_RAMP_STEPS (5000000) ADEPT_EQ2_HOLD_STEPS (8000000) ADEPT_EQ2_CHUNK_STEPS (5000000);
# ADEPT_EQ2_SEG_STEPS (100000, the PPPM-rebuild segment); ramp/hold/chunk must be multiples of it.
# ---------------------------------------------------------------------------
eq2_has_resume_artifacts() {
    local pid="$1"
    [[ -f "${initial_dir}/POLYMER_DATA/OPTIMIZATION/${pid}/${pid}_eq2_end.rst" ]]
}

run_eq2_resumable() {
    local pid="$1"
    local ramp="${ADEPT_EQ2_RAMP_STEPS:-5000000}"
    local hold="${ADEPT_EQ2_HOLD_STEPS:-8000000}"
    local chunk="${ADEPT_EQ2_CHUNK_STEPS:-5000000}"
    local seg="${ADEPT_EQ2_SEG_STEPS:-100000}"
    local total=$(( ramp + hold ))
    local eq2_in="${initial_dir}/2.Simulations/lammps_eq2_resume.in"
    local step resume rst phase upto
    # NOTE: runs under the caller's `set -euo pipefail` -- every test is an explicit if, and no pipeline may fail.
    while true; do
        if [[ -f "${pid}_eq2.data" ]]; then echo "[EQ2] complete for ${pid}"; return 0; fi
        step=0
        if [[ -f "${pid}_eq2_progress.dat" ]]; then
            step="$(awk 'NF {v=$1} END {print v+0}' "${pid}_eq2_progress.dat")"
        fi
        if ! is_number "$step"; then step=0; fi
        if [[ -f "${pid}_eq2_end.rst" && "$step" -gt 0 ]]; then
            resume=1; rst="${pid}_eq2_end.rst"
        else
            resume=0; rst=none; step=0
            rm -f "${pid}_eq2_progress.dat" "${pid}_density.dat" "${pid}_Rg.data" "${pid}_eq2.log"
        fi
        if (( step < ramp )); then
            phase=1; upto=$(( step + chunk ))
            if (( upto > ramp )); then upto=$ramp; fi
        else
            phase=2; upto=$(( step + chunk ))
            if (( upto > total )); then upto=$total; fi
        fi
        echo "[EQ2] chunk resume=${resume} step=${step} -> ${upto} phase=${phase} (ramp=${ramp} total=${total})"
        # A crashed chunk (e.g. PPPM "Out of range atoms") is retried from the last saved restart with one fewer
        # MPI rank: the crash is deterministic for a fixed restart + decomposition, a new decomposition is not.
        local try=0 np_try="$NSLOTS" nd=0 nr=0
        # remember output lengths so a retried chunk does not duplicate density / Rg lines
        if [[ -f "${pid}_density.dat" ]]; then nd=$(wc -l < "${pid}_density.dat"); fi
        if [[ -f "${pid}_Rg.data" ]]; then nr=$(wc -l < "${pid}_Rg.data"); fi
        until NSLOTS="$np_try" run_lmp_mpi lmp -in "$eq2_in" -var name "$pid" -var resume "$resume" -var rstfile "$rst" \
                -var phase "$phase" -var run_upto "$upto" -var ramp_steps "$ramp" -var total_steps "$total" \
                -var incdir "${initial_dir}/2.Simulations" -var seg "$seg"; do
            try=$(( try + 1 ))
            if (( try > 2 )); then echo "[EQ2][ERROR] chunk failed 3 times for ${pid}"; return 1; fi
            np_try=$(( NSLOTS - try ))
            if [[ -f "${pid}_density.dat" ]]; then head -n "$nd" "${pid}_density.dat" > "${pid}_density.tmp" && mv "${pid}_density.tmp" "${pid}_density.dat"; fi
            if [[ -f "${pid}_Rg.data" ]]; then head -n "$nr" "${pid}_Rg.data" > "${pid}_Rg.tmp" && mv "${pid}_Rg.tmp" "${pid}_Rg.data"; fi
            echo "[EQ2][WARN] chunk failed (attempt ${try}); retrying from ${rst} with ${np_try} ranks"
        done
        stage_rst_archive "${pid}_eq2_end.rst" "${pid}_eq2_${upto}.rst"
        if [[ -f "${pid}_eq2.data" ]]; then echo "[EQ2] complete for ${pid}"; return 0; fi
        cd "$initial_dir"
        checkpoint_barrier "eq2_chunk"
        cd "${initial_dir}/POLYMER_DATA/OPTIMIZATION/${pid}"
    done
}
