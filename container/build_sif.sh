#!/bin/bash
# Build ADEPT Apptainer/Singularity runtime image for OSPool container-universe jobs.
#
# Preferred path: pack the local conda env, build a sandbox, then publish a
# single-file squashfs image to OSDF. HTCondor stages that image via osdf://
# without transferring the conda-pack tarball as a normal input file per job.
#
# Usage:
#   ./container/build_sif.sh [image-name.sqsh]
#   OSDF_TARGET=/ospool/apXX/data/$USER/containers/adept-v2.sqsh ./container/build_sif.sh adept-v2.sqsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADEPT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_NAME="${1:-adept-v2.sqsh}"
OUTPUT="${ADEPT_DIR}/${IMAGE_NAME}"
SANDBOX="${ADEPT_DIR}/${IMAGE_NAME%.*}.sandbox"
OSDF_TARGET="${OSDF_TARGET:-/ospool/ap40/data/${USER}/containers/${IMAGE_NAME}}"

TMP_BASE="${TMPDIR:-${HOME}/.tmp}"
mkdir -p "${TMP_BASE}" "${HOME}/.apptainer_cache"
export APPTAINER_TMPDIR="${TMP_BASE}"
export APPTAINER_CACHEDIR="${HOME}/.apptainer_cache"
export TMPDIR="${TMP_BASE}"

if [[ -f "${HOME}/miniconda3/etc/profile.d/conda.sh" ]]; then
    # shellcheck source=/dev/null
    source "${HOME}/miniconda3/etc/profile.d/conda.sh"
elif [[ -f "${HOME}/mambaforge/etc/profile.d/conda.sh" ]]; then
    # shellcheck source=/dev/null
    source "${HOME}/mambaforge/etc/profile.d/conda.sh"
else
    echo "[ERROR] Could not find conda.sh under ~/miniconda3 or ~/mambaforge"
    exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/polymer-workflow.tar.gz" ]]; then
    echo "Packing polymer-workflow env with conda-pack ..."
    conda-pack -n polymer-workflow -o "${SCRIPT_DIR}/polymer-workflow.tar.gz" --ignore-editable-packages
fi

echo "Building sandbox ${SANDBOX} from adept-packed.def ..."
cd "$SCRIPT_DIR"
apptainer build --fakeroot --sandbox "$SANDBOX" adept-packed.def

echo "Sandbox build complete: ${SANDBOX}"

echo "Building squashfs runtime image ${OUTPUT} ..."
mksquashfs "$SANDBOX" "$OUTPUT" -noappend -comp gzip -processors 4 -no-progress

echo "Validating runtime image ..."
apptainer exec "$OUTPUT" bash -lc \
  'getconf GNU_LIBC_VERSION && /opt/conda/envs/polymer-workflow/bin/python --version && /opt/conda/envs/polymer-workflow/bin/lmp -h >/dev/null'

echo ""
echo "To publish to OSDF:"
echo "  mkdir -p $(dirname "${OSDF_TARGET}")"
echo "  cp ${OUTPUT} ${OSDF_TARGET}"
echo ""
echo "Use this in submit files:"
echo "  container_image = osdf://${OSDF_TARGET#/}"
