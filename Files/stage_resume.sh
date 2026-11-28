#!/bin/bash
# Mid-stage checkpoints for eq1, dielectric constant, viscosity and EMD (sourced by Files/files.sh).
#
# Each stage runs as a series of chunks. After every chunk LAMMPS writes a restart file
# <prefix>_<step>.rst; the next chunk (in the same job, after an HTCondor exit-85 checkpoint, or after the
# job was killed and resubmitted on any scheduler) continues from the newest one. Every chunk's restart is
# kept by default, so a run can be restarted from any chunk boundary and a finished stage can be extended
# later by raising its ADEPT_<STAGE>_TOTAL_STEPS.
#
#   ADEPT_STAGE_RESUMABLE=1 (default)  use the chunked inputs; 0 = original single-run inputs
#   ADEPT_STAGE_KEEP_RESTARTS=1 (default)  keep every chunk's restart; 0 = keep only the newest one
#   ADEPT_EQ1_CHUNK_STEPS   (1000000)
#   ADEPT_DC_TOTAL_STEPS    (5000000)  ADEPT_DC_CHUNK_STEPS   (1000000)
#   ADEPT_VISC_TOTAL_STEPS  (5000000)  ADEPT_VISC_CHUNK_STEPS (1000000)   production; the 1 ns NPT is fixed
#   ADEPT_EMD_TOTAL_STEPS   (8000000)  ADEPT_EMD_CHUNK_STEPS  (1600000)   multiples of 80000
#   ADEPT_EMD_MODULUS_BATCH (20)       strain-step snapshots per chunk (100 snapshots in all)
#   For short tests only: ADEPT_VISC_NPT_STEPS (1000000), ADEPT_EMD_NSNAP (100)
#
# Needs from the caller: initial_dir, is_true, run_lmp_mpi (files.sh), checkpoint_barrier (checkpoint.sh).
# All functions run under the caller's `set -euo pipefail`: tests are explicit ifs.

stage_resumable() { is_true "${ADEPT_STAGE_RESUMABLE:-1}"; }

# Archive copy of a stage's rolling end-of-chunk restart (eq2, TC, Tg overwrite one file): <src> -> <dst>.
# The copies are not used to resume; they let a run be restarted by hand from an earlier chunk boundary.
stage_rst_archive() {
    local src="$1" dst="$2"
    if ! is_true "${ADEPT_STAGE_KEEP_RESTARTS:-1}"; then return 0; fi
    if [[ -s "$src" ]]; then cp -f "$src" "${dst}.tmp" && mv -f "${dst}.tmp" "$dst"; fi
    return 0
}

# Finish a restart that LAMMPS wrote completely (<prefix>_tmp.rst + <prefix>_tmp.ok) but that was not renamed yet.
stage_rst_commit() {
    local prefix="$1" s
    if [[ -f "${prefix}_tmp.ok" && -f "${prefix}_tmp.rst" ]]; then
        s="$(awk 'NF {v=$1} END {print v+0}' "${prefix}_tmp.ok")"
        mv -f "${prefix}_tmp.rst" "${prefix}_${s}.rst"
    fi
    rm -f "${prefix}_tmp.ok" "${prefix}_tmp.rst"
}

# Step of the newest <prefix>_<step>.rst in the current directory (0 if there is none).
stage_rst_step() {
    local prefix="$1" f s best=0
    for f in "${prefix}"_*.rst; do
        if [[ ! -f "$f" ]]; then continue; fi
        s="${f#"${prefix}"_}"; s="${s%.rst}"
        if [[ "$s" =~ ^[0-9]+$ ]]; then
            if (( s > best )); then best=$s; fi
        fi
    done
    echo "$best"
}

# Delete every <prefix>_<step>.rst except the one at step $2.
stage_rst_prune() {
    local prefix="$1" keep="$2" f
    if is_true "${ADEPT_STAGE_KEEP_RESTARTS:-1}"; then return 0; fi
    for f in "${prefix}"_*.rst; do
        if [[ -f "$f" && "$f" != "${prefix}_${keep}.rst" ]]; then rm -f "$f"; fi
    done
}

# Join <base>.part_<step0> files (first column = step) into <base>.
#   $2 = 1: drop the step column (files the original inputs wrote without one); 0: keep it.
# Rows are taken in step order and a step that appears twice (chunk boundary) is kept once.
stage_merge_parts() {
    local base="$1" dropstep="$2" f list=()
    while IFS= read -r f; do list+=("$f"); done < <(ls "${base}".part_* 2>/dev/null | awk -F'.part_' '{print $NF"\t"$0}' | sort -n | cut -f2-)
    if (( ${#list[@]} == 0 )); then echo "[STAGE][ERROR] no part files for ${base}"; return 1; fi
    awk -v drop="$dropstep" '
        /^#/ { if (!hdr && FNR <= 3 && NR == FNR) print; next }
        NF == 0 { next }
        { hdr = 1; if ($1 in seen) next; seen[$1] = 1
          if (drop == 1) { $1 = ""; sub(/^ /, "") }
          print }' "${list[@]}" > "${base}.tmp"
    mv -f "${base}.tmp" "${base}"
}

# True while a stage that already has restart files has not reached its requested length
# (used to let a finished stage continue when ADEPT_<STAGE>_TOTAL_STEPS is raised).
stage_incomplete() {
    local dir="$1" prefix="$2" total="$3" s
    if [[ ! -d "$dir" ]]; then return 1; fi
    s="$(cd "$dir" && stage_rst_commit "$prefix" && stage_rst_step "$prefix")"
    if (( s > 0 && s < total )); then return 0; fi
    return 1
}
dc_incomplete()   { stage_resumable && stage_incomplete "${initial_dir}/POLYMER_DATA/DIELECTRIC_CONSTANT/$1" "$1_dc"   "${ADEPT_DC_TOTAL_STEPS:-5000000}"; }
visc_incomplete() { stage_resumable && stage_incomplete "${initial_dir}/POLYMER_DATA/VISCOSITY/$1"           "$1_visc" "${ADEPT_VISC_TOTAL_STEPS:-5000000}"; }

# One LAMMPS chunk: run, check that the restart for step $upto was written, rename it, drop older restarts.
#   stage_run_chunk <prefix> <upto> <lammps args...>
stage_run_chunk() {
    local prefix="$1" upto="$2"; shift 2
    rm -f "${prefix}_tmp.ok" "${prefix}_tmp.rst"
    run_lmp_mpi lmp "$@" -var rstprefix "$prefix" -var incdir "${initial_dir}/2.Simulations"
    stage_rst_commit "$prefix"
    if [[ ! -f "${prefix}_${upto}.rst" ]]; then
        echo "[STAGE][ERROR] ${prefix}: no restart at step ${upto} after the chunk"; return 1
    fi
    stage_rst_prune "$prefix" "$upto"
}

# Checkpoint between chunks (exit 85 under HTCondor when ADEPT_CHECKPOINT_MODE=exit85; otherwise continue).
stage_barrier() {
    local step="$1" here; here="$(pwd)"
    cd "$initial_dir"; checkpoint_barrier "$step"; cd "$here"
}

# ---------------------------------------------------------------------------
# eq1 (run in POLYMER_DATA/OPTIMIZATION/<pid>)
# ---------------------------------------------------------------------------
eq1_has_resume_artifacts() {
    local d="${initial_dir}/POLYMER_DATA/OPTIMIZATION/$1"
    [[ -f "$d/$1_eq1.data" ]] || compgen -G "$d/$1_eq1_*.rst" > /dev/null
}
run_eq1_resumable() {
    local pid="$1" chunk="${ADEPT_EQ1_CHUNK_STEPS:-1000000}"
    local in="${initial_dir}/2.Simulations/lammps_eq1_resume.in" prefix="${pid}_eq1" step phase end upto rst
    while true; do
        if [[ -f "${pid}_eq1.data" ]]; then echo "[EQ1] complete for ${pid}"; return 0; fi
        stage_rst_commit "$prefix"; step="$(stage_rst_step "$prefix")"
        if   (( step < 20000 ));   then phase=0; end=20000; step=0; rst=none; rm -f "${pid}_eq1.log"
        elif (( step < 1020000 )); then phase=2; end=1020000; rst="${prefix}_${step}.rst"
        elif (( step < 1070000 )); then phase=3; end=1070000; rst="${prefix}_${step}.rst"
        else                            phase=4; end=2070000; rst="${prefix}_${step}.rst"
        fi
        upto=$(( step + chunk )); if (( upto > end )); then upto=$end; fi
        echo "[EQ1] chunk phase=${phase} step=${step} -> ${upto}"
        stage_run_chunk "$prefix" "$upto" -in "$in" -var name "$pid" -var phase "$phase" -var rstfile "$rst" -var run_upto "$upto"
        if [[ -f "${pid}_eq1.data" ]]; then echo "[EQ1] complete for ${pid}"; return 0; fi
        stage_barrier "eq1_chunk"
    done
}

# ---------------------------------------------------------------------------
# Dielectric constant (run in POLYMER_DATA/DIELECTRIC_CONSTANT/<pid>)
# ---------------------------------------------------------------------------
dc_has_resume_artifacts() { compgen -G "${initial_dir}/POLYMER_DATA/DIELECTRIC_CONSTANT/$1/$1_dc_*.rst" > /dev/null; }
run_dc_resumable() {
    local pid="$1" total="${ADEPT_DC_TOTAL_STEPS:-5000000}" chunk="${ADEPT_DC_CHUNK_STEPS:-1000000}"
    local in="${initial_dir}/2.Simulations/lammps_dc_resume.in" prefix="${pid}_dc" step upto resume rst
    while true; do
        stage_rst_commit "$prefix"; step="$(stage_rst_step "$prefix")"
        if (( step >= total )); then break; fi
        if (( step > 0 )); then resume=1; rst="${prefix}_${step}.rst"
        else resume=0; rst=none; rm -f "${pid}_dipole_fluctuation.dat".part_* "${pid}_dc.log"; fi
        upto=$(( step + chunk )); if (( upto > total )); then upto=$total; fi
        echo "[DC] chunk resume=${resume} step=${step} -> ${upto} (total ${total})"
        stage_run_chunk "$prefix" "$upto" -in "$in" -var name "$pid" -var resume "$resume" -var rstfile "$rst" \
            -var run_upto "$upto" -var step0 "$step"
        if (( upto >= total )); then break; fi
        stage_barrier "dc_chunk"
    done
    stage_merge_parts "${pid}_dipole_fluctuation.dat" 1
}

# ---------------------------------------------------------------------------
# Viscosity / diffusion (run in POLYMER_DATA/VISCOSITY/<pid>)
# ---------------------------------------------------------------------------
visc_has_resume_artifacts() {
    local d="${initial_dir}/POLYMER_DATA/VISCOSITY/$1"
    compgen -G "$d/$1_visc_*.rst" > /dev/null || compgen -G "$d/$1_viscnpt_*.rst" > /dev/null
}
run_visc_resumable() {
    local pid="$1" tg="$2" npt="${ADEPT_VISC_NPT_STEPS:-1000000}" total="${ADEPT_VISC_TOTAL_STEPS:-5000000}" chunk="${ADEPT_VISC_CHUNK_STEPS:-1000000}"
    local in="${initial_dir}/2.Simulations/lammps_visc_resume.in" pn="${pid}_viscnpt" pp="${pid}_visc"
    local nstep pstep phase resume rst prodstart upto step0 prefix
    # the temperature is fixed by the first chunk, so a later change of the Tg estimate cannot split the run
    if [[ -f "${pid}_visc_Tg.dat" ]]; then tg="$(awk 'NF {v=$1} END {print v}' "${pid}_visc_Tg.dat")"
    else echo "$tg" > "${pid}_visc_Tg.dat"; fi
    while true; do
        stage_rst_commit "$pn"; stage_rst_commit "$pp"
        nstep="$(stage_rst_step "$pn")"; pstep="$(stage_rst_step "$pp")"
        if (( pstep >= total )); then break; fi
        prodstart=0
        if (( pstep > 0 )); then
            phase=2; resume=1; rst="${pp}_${pstep}.rst"; step0=$pstep; prefix="$pp"
            upto=$(( pstep + chunk )); if (( upto > total )); then upto=$total; fi
        elif (( nstep >= npt )); then
            phase=2; resume=1; rst="${pn}_${nstep}.rst"; step0=0; prefix="$pp"; prodstart=1
            rm -f "${pid}_visc_raw.dat".part_* "${pid}_msd_poly.dat".part_*
            upto=$chunk; if (( upto > total )); then upto=$total; fi
        else
            phase=1; step0=$nstep; prefix="$pn"
            if (( nstep > 0 )); then resume=1; rst="${pn}_${nstep}.rst"; else resume=0; rst=none; rm -f "${pid}_visc.log"; fi
            upto=$(( nstep + chunk )); if (( upto > npt )); then upto=$npt; fi
        fi
        echo "[VISC] chunk phase=${phase} step=${step0} -> ${upto} Tg=${tg}"
        stage_run_chunk "$prefix" "$upto" -in "$in" -var name "$pid" -var Tg "$tg" -var phase "$phase" -var resume "$resume" \
            -var rstfile "$rst" -var prodstart "$prodstart" -var run_upto "$upto" -var step0 "$step0"
        if (( phase == 2 )); then stage_rst_prune "$pn" -1; fi
        if (( phase == 2 && upto >= total )); then break; fi
        stage_barrier "visc_chunk"
    done
    stage_merge_parts "${pid}_visc_raw.dat" 0
    stage_merge_parts "${pid}_msd_poly.dat" 0
    python "${initial_dir}/3.Analysis/calc_visc.py" "$pid"
}

# ---------------------------------------------------------------------------
# EMD: 8 ns NPT (Cp, thermal expansion, 100 snapshots), then strain-step moduli on the snapshots
# (run in POLYMER_DATA/EMD/<pid>)
# ---------------------------------------------------------------------------
emd_has_resume_artifacts() {
    local d="${initial_dir}/POLYMER_DATA/EMD/$1"
    compgen -G "$d/$1_emd_*.rst" > /dev/null || compgen -G "$d/log.elastic_[0-9]*" > /dev/null
}
emd_modulus_done() { [[ -f "log.elastic_$1" ]] && grep -q "Youngs Modulus" "log.elastic_$1"; }
run_emd_resumable() {
    local pid="$1" total="${ADEPT_EMD_TOTAL_STEPS:-8000000}" chunk="${ADEPT_EMD_CHUNK_STEPS:-1600000}"
    local batch="${ADEPT_EMD_MODULUS_BATCH:-20}" nsnap="${ADEPT_EMD_NSNAP:-100}"
    local in="${initial_dir}/2.Simulations/lammps_emd_resume.in" prefix="${pid}_emd" step upto resume rst i first last
    if (( total % 80000 != 0 || chunk % 80000 != 0 )); then echo "[EMD][ERROR] total and chunk steps must be multiples of 80000"; return 1; fi
    # part 1: NPT
    while true; do
        stage_rst_commit "$prefix"; step="$(stage_rst_step "$prefix")"
        if (( step >= total )); then break; fi
        if (( step > 0 )); then resume=1; rst="${prefix}_${step}.rst"
        else resume=0; rst=none; rm -f "${pid}_npt_properties.dat".part_* log.emd_npt; fi
        upto=$(( step + chunk )); if (( upto > total )); then upto=$total; fi
        echo "[EMD] NPT chunk resume=${resume} step=${step} -> ${upto} (total ${total})"
        stage_run_chunk "$prefix" "$upto" -in "$in" -var name "$pid" -var resume "$resume" -var rstfile "$rst" \
            -var run_upto "$upto" -var step0 "$step"
        stage_barrier "emd_chunk"
    done
    stage_merge_parts "${pid}_npt_properties.dat" 1
    # part 2: strain-step moduli, one log per snapshot
    cp "${initial_dir}/2.Simulations/modulus_files/displace.mod" "${initial_dir}/2.Simulations/modulus_files/post_vrh.mod" .
    while true; do
        first=0
        for (( i = 1; i <= nsnap; i++ )); do
            if ! emd_modulus_done "$i"; then first=$i; break; fi
        done
        if (( first == 0 )); then break; fi
        last=$(( first + batch - 1 )); if (( last > nsnap )); then last=$nsnap; fi
        echo "[EMD] modulus snapshots ${first} .. ${last}"
        run_lmp_mpi lmp -in "${initial_dir}/2.Simulations/lammps_emd_modulus.in" -var first "$first" -var last "$last" \
            -var moddir "${initial_dir}/2.Simulations/modulus_files"
        if ! emd_modulus_done "$last"; then echo "[EMD][ERROR] modulus snapshot ${last} did not finish"; return 1; fi
        if (( last >= nsnap )); then break; fi
        stage_barrier "emd_chunk"
    done
    : > log.elastic_T
    for (( i = 1; i <= nsnap; i++ )); do cat "log.elastic_${i}" >> log.elastic_T; done
}
