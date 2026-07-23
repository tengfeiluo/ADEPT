#!/bin/bash
# Bootstrap and activate ADEPT polymer-workflow environment.
# Supports: pre-built container image, local miniconda, or conda-pack tarball fallback.

setup_adept_runtime_env() {
    local runtime_prefix=""
    local fix_libint="${initial_dir}/container/fix_libint.sh"
    local conda_pack_tarball="${initial_dir}/container/polymer-workflow.tar.gz"
    local home_conda="${HOME}/miniconda3/etc/profile.d/conda.sh"
    if [[ ! -f "$conda_pack_tarball" && -f "${initial_dir}/polymer-workflow.tar.gz" ]]; then
        conda_pack_tarball="${initial_dir}/polymer-workflow.tar.gz"
    fi

    if [[ -f /opt/conda/envs/polymer-workflow/bin/python ]]; then
        # Pre-built ADEPT container image (OSDF adept-*.sqsh)
        source /opt/conda/etc/profile.d/conda.sh
        conda activate polymer-workflow
        runtime_prefix="$CONDA_PREFIX"
    elif [[ -f "${initial_dir}/.adept_env/bin/python" ]]; then
        # Already unpacked in this job workspace
        runtime_prefix="${initial_dir}/.adept_env"
    elif [[ -f "$conda_pack_tarball" ]]; then
        # OSPool: unpack conda-pack tarball once per job
        echo "[INFO] Bootstrapping polymer-workflow from conda-pack tarball: ${conda_pack_tarball}"
        mkdir -p "${initial_dir}/.adept_env"
        tar -xzf "$conda_pack_tarball" -C "${initial_dir}/.adept_env"
        runtime_prefix="${initial_dir}/.adept_env"
        export CONDA_PREFIX="$runtime_prefix"
        export PATH="${runtime_prefix}/bin:${PATH}"
        export LD_LIBRARY_PATH="${runtime_prefix}/lib:${LD_LIBRARY_PATH:-}"
        if [[ -x "${runtime_prefix}/bin/conda-unpack" ]]; then
            "${runtime_prefix}/bin/conda-unpack"
        fi
    elif [[ -f "$home_conda" ]]; then
        # Local access-point / laptop miniconda
        source "$home_conda"
        conda activate polymer-workflow
        runtime_prefix="$CONDA_PREFIX"
    else
        echo "[ERROR] No ADEPT runtime found (container env, tarball, or ~/miniconda3)."
        echo "[ERROR] Checked: /opt/conda/envs/polymer-workflow, ${initial_dir}/.adept_env, ${conda_pack_tarball}, ${home_conda}"
        exit 1
    fi

    export CONDA_PREFIX="$runtime_prefix"
    export PATH="${runtime_prefix}/bin:${PATH}"
    export LD_LIBRARY_PATH="${runtime_prefix}/lib:${LD_LIBRARY_PATH:-}"
    if [[ -z "${LAMMPS_EXEC:-}" || ! -x "${LAMMPS_EXEC:-}" || "${LAMMPS_EXEC}" != "${runtime_prefix}/"* ]]; then
        LAMMPS_EXEC="$(command -v lmp || true)"
    fi
    export LAMMPS_EXEC
    export OMP_NUM_THREADS=1
    export MKL_NUM_THREADS=1
    export OPENBLAS_NUM_THREADS=1
    export MKL_INTERFACE_LAYER=GNU
    export KMP_DUPLICATE_LIB_OK=TRUE
    export OMPI_MCA_btl=vader,self
    export OMPI_MCA_rmaps_base_oversubscribe=1
    export UCX_TLS=sm,self
    export PSI_SCRATCH="${PSI_SCRATCH:-${TMPDIR:-/tmp}/psi_scratch}"
    mkdir -p "$PSI_SCRATCH"

    local bindir="${runtime_prefix}/bin"
    if [[ -f "$fix_libint" ]]; then
        # shellcheck source=/dev/null
        source "$fix_libint"
        fix_libint_for_psi4 "$runtime_prefix" \
            "${initial_dir}/container/libint-2.9-lib" \
            "/opt/libint-2.9-lib"
    fi
    [[ ! -e "${bindir}/mpiexec" ]] && [[ -x "${bindir}/mpirun" ]] && \
        ln -sf mpirun "${bindir}/mpiexec" 2>/dev/null || true

    echo "[INFO] Runtime prefix: ${runtime_prefix}"
    echo "[INFO] Runtime Python: $(command -v python) ($(python --version 2>&1))"
    echo "[INFO] Runtime LAMMPS: ${LAMMPS_EXEC:-not found}"
    echo "[INFO] Runtime GLIBC: $(getconf GNU_LIBC_VERSION 2>/dev/null || echo unknown)"
}
