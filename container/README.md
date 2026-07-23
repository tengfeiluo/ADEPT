# ADEPT container image

This directory defines how to build the **runtime image** used by OSPool
`universe = container` jobs. The multi‑GB `.sqsh` file itself is **not** stored
in Git.

## What goes in the image

- Conda env `polymer-workflow` (Python 3.10, NumPy, Pandas, RDKit, Psi4, scikit-learn, **LAMMPS**, OpenMPI, …)
- See `adept.def` / `polymer-workflow.yml` at the repo root for the package list

## Build and publish

On an access point with Apptainer + conda:

```bash
# Optional: create/update the conda env from polymer-workflow.yml first
conda env create -f polymer-workflow.yml   # or: conda env update -f ...

cd container
./build_sif.sh adept-v2.sqsh

# Publish to your OSDF data directory
mkdir -p /ospool/ap40/data/$USER/containers
cp ../adept-v2.sqsh /ospool/ap40/data/$USER/containers/
```

Then set in `submit_full.sub` / `submit_TC.sub`:

```text
container_image = osdf:///ospool/ap40/data/<USER>/containers/adept-v2.sqsh
```

## Sharing with collaborators

1. Prefer **copying the same `.sqsh`** to their OSDF path (bit‑identical stack).
2. Only ask them to rebuild if they cannot use your OSDF image; pin versions in `polymer-workflow.yml`.

Large files intentionally gitignored here:

- `polymer-workflow.tar.gz` (conda-pack)
- `libint-2.9-lib/` (Psi4 helper libs, if used)
- `*.log`
