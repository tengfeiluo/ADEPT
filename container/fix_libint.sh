#!/bin/bash
# Ensure Psi4 can load libint2.so.2 (SONAME libint2.so.2).
# libint 2.13 only ships libint2.so and segfaults when symlinked as .so.2.

fix_libint_for_psi4() {
    local runtime_prefix="${1:-${CONDA_PREFIX:-}}"
    shift || true
    local fixdir=""
    local candidate
    local libdir soname stagedir

    if [[ -z "$runtime_prefix" || ! -d "$runtime_prefix/lib" ]]; then
        return 0
    fi

    libdir="${runtime_prefix}/lib"
    if [[ -e "${libdir}/libint2.so.2" ]]; then
        if command -v readelf >/dev/null 2>&1; then
            soname="$(readelf -d "${libdir}/libint2.so.2" 2>/dev/null | awk '/SONAME/ {print $NF}' | tr -d '[]' || true)"
        elif [[ -f "${libdir}/libint2.so.2.9.0" ]]; then
            soname="libint2.so.2"
        fi
        if [[ "$soname" == "libint2.so.2" ]]; then
            echo "[INFO] libint2.so.2 already OK (SONAME=${soname}); skip libint fix"
            return 0
        fi
    fi

    for candidate in "$@"; do
        if [[ -f "${candidate}/libint2.so.2.9.0" ]]; then
            fixdir="$candidate"
            break
        fi
    done

    if [[ -z "$fixdir" ]]; then
        fixdir="${initial_dir:-}/container/libint-2.9-lib"
    fi

    if [[ ! -f "${fixdir}/libint2.so.2.9.0" ]]; then
        echo "[WARN] libint 2.9 fix bundle missing: ${fixdir}/libint2.so.2.9.0"
        return 0
    fi

    if [[ -w "$libdir" ]]; then
        cp -a "${fixdir}"/libint2.so* "$libdir/" 2>/dev/null || true
        echo "[INFO] Installed libint 2.9 libs into ${libdir}"
        return 0
    fi

    stagedir="${initial_dir:-.}/.libint_runtime/lib"
    mkdir -p "$stagedir"
    cp -a "${fixdir}"/libint2.so* "$stagedir/" 2>/dev/null || true
    export LD_LIBRARY_PATH="${stagedir}:${LD_LIBRARY_PATH:-}"
    echo "[INFO] Staged libint 2.9 at ${stagedir} (container lib dir read-only)"
}
