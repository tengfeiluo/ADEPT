# ADEPT

**A**utomated molecular **D**ynamics **E**ngine for **P**olymer simula**T**ions

[![Python](https://img.shields.io/badge/python-3.10-blue.svg)](#)
[![Conda](https://img.shields.io/badge/env-conda-44A833.svg)](#)
[![LAMMPS](https://img.shields.io/badge/MD-LAMMPS-orange.svg)](#)
[![Psi4](https://img.shields.io/badge/DFT-Psi4-8A2BE2.svg)](#)
[![OSPool](https://img.shields.io/badge/HPC-OSPool%20%2F%20HTCondor-red.svg)](#)

ADEPT turns polymer **SMILES** into tabulated physical/chemical properties: amorphous structure generation → LAMMPS MD → Psi4 monomer DFT → analysis CSVs. It is built for **high-throughput array jobs** on OSPool (HTCondor container universe), with step-level and TC mid-run checkpointing so long simulations survive the ~40 h wall-time limit.

> Fork / extension of the original [sobinalosious/ADEPT](https://github.com/sobinalosious/ADEPT) workflow, with OSPool packaging, exit-85 checkpointing, and resumable NEMD thermal conductivity.

---

## Table of contents

- [Features](#features)
- [Computed properties](#computed-properties)
- [Repository layout](#repository-layout)
- [What is *not* in this repo](#what-is-not-in-this-repo)
- [Requirements](#requirements)
- [Quick start (OSPool)](#quick-start-ospool)
- [Container runtime](#container-runtime)
- [Configuration](#configuration)
- [Checkpointing](#checkpointing)
- [Thermal conductivity (TC) job](#thermal-conductivity-tc-job)
- [Outputs](#outputs)
- [Legacy / local HPC](#legacy--local-hpc)
- [Citation](#citation)

---

## Features

- Amorphous polymer generation from SMILES (PySIMM / GAFF2; Gasteiger or RESP charges)
- LAMMPS equilibration and property MD (dielectric, Tg, viscosity, EMD/moduli, …)
- Psi4 monomer electronic properties (HOMO/LUMO, gap, polarizability, …)
- Per-property toggles via environment variables in the HTCondor submit file
- ML Tg guess (`Files/model_mlp_tg.pkl`) fed into the Tg MD protocol
- **OSPool-ready**: Singularity/Apptainer image on OSDF; no `module load lammps` on the AP
- **Checkpoint / resume**: HTCondor `checkpoint_exit_code = 85` after each major step; TC uses LAMMPS restart chunks + heat-flux tally offsets

## Computed properties

| Category | Properties |
| --- | --- |
| Structural | Density, radius of gyration |
| Monomer DFT | HOMO, LUMO, band gap, dipole, polarizability, energies, monomer dielectric / RI |
| Dielectric (MD) | Dielectric constant and related components |
| Thermal | Thermal conductivity (NEMD), Tg, Cp, expansion coefficients |
| Transport | Viscosity (and related) |
| Mechanical | Bulk / shear / Young’s moduli, Poisson’s ratio (from EMD) |

## Repository layout

```text
ADEPT/
├── 1.AmorphousGeneration/   # APG (Gasteiger/RESP) + Psi4 monomer DFT
├── 2.Simulations/           # LAMMPS inputs (eq, DC, TC, Tg, visc, EMD, modulus)
├── 3.Analysis/              # Post-process + CSV updaters + predict_tg.py
├── Files/
│   ├── files.sh             # Per-PID workflow
│   ├── checkpoint.sh        # step_done_*, exit-85 barrier, TC resume helpers
│   └── model_mlp_tg.pkl     # Pretrained Tg model
├── container/               # Image definition + build scripts (not the .sqsh itself)
├── examples/                # Small demo SMILES / task lists
├── tests/                   # Lightweight TC resume checks
├── legacy/                  # Older SGE-style submit helpers
├── run_adept.sh             # HTCondor executable entrypoint
├── setup_env.sh             # Activate container / conda / conda-pack env
├── submit_full.sub          # Main pipeline (16 CPUs; TC off)
├── submit_TC.sub            # Dedicated TC (32 CPUs; resumable chunks)
├── merge_tc_results.sh      # Merge POLYMER_DATA_TC → POLYMER_DATA_full
├── tasks_full.txt           # HTCondor queue task indices
├── SMILES.csv               # Input table: PID,SMILES
├── polymer-workflow.yml     # Conda env recipe (for rebuilding the image)
└── README.md
```

## What is *not* in this repo

Do **not** expect these in Git (they are local / OSDF artifacts):

| Artifact | Why excluded |
| --- | --- |
| `POLYMER_DATA*`, `Log_Files/` | Simulation outputs |
| `adept-*.sqsh`, `*.sandbox/`, `.adept_env/` | Multi‑GB runtime images / unpacked envs |
| `container/polymer-workflow.tar.gz`, `container/libint-2.9-lib/` | Large build intermediates |
| Job manifests / checkpoint status files | Ephemeral HTCondor sidecars |

Share the **squashfs image** separately (OSDF copy or download link). See [Container runtime](#container-runtime).

## Requirements

- OSPool (or similar) access with **Singularity/Apptainer** and OSDF
- An ADEPT container image published under your `osdf:///.../containers/`
- A PATh / OSG project name for `+ProjectName`
- Input `SMILES.csv` (`PID,SMILES`) and a `tasks_*.txt` list of 1-based CSV row indices (see `tasks_full.txt`)

Optional for **building** the image yourself: conda/mamba, `conda-pack`, Apptainer, `mksquashfs`.

## Quick start (OSPool)

1. **Clone**

   ```bash
   git clone https://github.com/RENZHENGZHANG01/ADEPT.git
   cd ADEPT
   mkdir -p Log_Files POLYMER_DATA_full
   ```

2. **Get the runtime image** (do not rebuild unless you must)

   - Copy a known-good `adept-v2.sqsh` into your OSDF data directory, e.g.  
     `/ospool/<ap>/data/$USER/containers/adept-v2.sqsh`  
   - Or build with `./container/build_sif.sh` (see `container/README.md`)

3. **Edit submit files** (`submit_full.sub`, `submit_TC.sub`)

   - `container_image = osdf:///...`
   - `initialdir = /home/$USER/ADEPT`
   - `+ProjectName = "..."`

4. **Prepare inputs**

   ```bash
   # Demo (5 polymers): copy examples into place, or edit SMILES.csv / tasks_full.txt
   cp examples/SMILES_demo.csv SMILES.csv   # optional small demo
   cp examples/tasks_demo.txt tasks_full.txt
   ```

5. **Submit**

   ```bash
   condor_submit submit_full.sub   # APG → opt → DFT → DC → Tg → visc → EMD
   condor_submit submit_TC.sub     # TC only (32 CPUs), parallel to main
   condor_q
   ```

6. **After TC finishes**

   ```bash
   ./merge_tc_results.sh
   ```

Results land under `POLYMER_DATA_full/<task>/POLYMER_DATA/` (and `POLYMER_DATA_TC/` for TC until merged).

## Container runtime

OSG access points typically **do not** provide LAMMPS/Psi4 modules. ADEPT ships dependencies inside an Apptainer/Singularity image:

- Image recipe: `container/adept.def` / `adept-packed.def`
- Build helper: `container/build_sif.sh`
- At job start, `setup_env.sh` activates `/opt/conda/envs/polymer-workflow` inside the image (`lmp`, `python`, `mpirun`, Psi4, …)

**Collaborators:** prefer sharing one published `.sqsh` on OSDF (same versions) rather than each person rebuilding conda. Put **code on GitHub**; put the **image on OSDF**.

## Configuration

Environment variables (set in the submit `environment = "..."` string):

| Variable | Role |
| --- | --- |
| `CHARGE_METHOD` | `GASTEIGER` or `RESP` |
| `DO_APG` / `DO_OPT` / `DO_MONO_ELECTRONIC` / `DO_DC` / `DO_TC` / `DO_TG` / `DO_VISC` / `DO_EMD` | Stage toggles (`0`/`1`) |
| `ADEPT_CHECKPOINT_MODE` | `exit85` enables self-checkpoint barriers |
| `ADEPT_CKPT_BUDGET_SEC` | `0` = checkpoint after every completed step |
| `ADEPT_TC_TOTAL_STEPS` | TC production length (default `20000000`) |
| `ADEPT_TC_CHUNK_STEPS` | TC chunk size between restarts (default `4000000`) |
| `NSLOTS` | MPI ranks (usually `=$(request_cpus)`) |

## Checkpointing

- **Main pipeline:** after each finished stage, the job exits **85**; HTCondor stores `POLYMER_DATA` and requeues. Resume uses `step_done_*` markers (result CSVs / success files).
- **Do not enable** `stream_output` / `stream_error` on APs where StreamHandler Holds jobs (`Invalid argument` on `*.err`).
- **TC:** cannot rely on a single uninterrupted 20M-step run under a 40 h wall. `submit_TC.sub` runs **chunks**, writes LAMMPS restart files, offset-corrects Langevin tallies for `calc_TC.py`, and exit-85 checkpoints between chunks.

## Thermal conductivity (TC) job

TC is **split** from `submit_full.sub` (`DO_TC=0`) because the NEMD cell is `replicate 3 1 1` and needs more wall time / CPUs. Use `submit_TC.sub` (32 CPUs). Outputs go to `POLYMER_DATA_TC/`; merge with `./merge_tc_results.sh`.

## Outputs

Per task, under `POLYMER_DATA_full/<task>/POLYMER_DATA/`:

- `MODEL/`, `OPTIMIZATION/`, `MONOMER_ELECTRONIC/`, `DIELECTRIC_CONSTANT/`, …
- `RESULTS/*.csv` — tabulated properties keyed by PID

Logs: `Log_Files/full.<task>.{out,err}`, `Log_Files/tc.<task>.{out,err}`.

## Legacy / local HPC

`legacy/submit_sge.sh` is an older Grid Engine–style driver (`module load` LAMMPS). Prefer the OSPool container path above for portability.

## Citation

If you use ADEPT, please cite the original ADEPT project and relevant method papers (LAMMPS, Psi4, PySIMM, etc.). See the upstream repository: [sobinalosious/ADEPT](https://github.com/sobinalosious/ADEPT).

## License

Follow the license of the upstream ADEPT project unless otherwise noted in this repository.
