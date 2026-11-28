# ADEPT

**A**utomated molecular **D**ynamics **E**ngine for **P**olymer simula**T**ions

[![Python](https://img.shields.io/badge/python-3.10-blue.svg)](#)
[![Conda](https://img.shields.io/badge/env-conda-44A833.svg)](#)
[![LAMMPS](https://img.shields.io/badge/MD-LAMMPS-orange.svg)](#)
[![Psi4](https://img.shields.io/badge/DFT-Psi4-8A2BE2.svg)](#)
[![OSPool](https://img.shields.io/badge/HPC-OSPool%20%2F%20HTCondor-red.svg)](#)

ADEPT turns polymer **SMILES** into tabulated physical/chemical properties: amorphous structure generation → LAMMPS MD → Psi4 monomer DFT → analysis CSVs. It is built for **high-throughput array jobs** on OSPool (HTCondor container universe), with step-level and TC mid-run checkpointing so long simulations survive the ~40 h wall-time limit.

> Working repository for the Luo group's ADEPT development: OSPool packaging, exit-85 checkpointing, resumable equilibration and NEMD thermal conductivity, RESP/ESP charges and the LJ tail correction. The original workflow is [sobinalosious/ADEPT](https://github.com/sobinalosious/ADEPT); changes made here are sent there periodically as pull requests.

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
| Structural | Density, radius of gyration, end-to-end distance, characteristic ratio, persistence length, RDF and X-ray structure factor, fractional free volume and accessible volume |
| Monomer DFT | HOMO, LUMO, band gap, dipole, polarizability, energies, monomer dielectric / RI |
| Dielectric (MD) | Dielectric constant and related components |
| Thermal | Thermal conductivity (NEMD), Tg, Cp, expansion coefficients |
| Transport | Viscosity (and related) |
| Mechanical | Bulk / shear / Young’s moduli, Poisson’s ratio (from EMD); bulk modulus from volume fluctuations |

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
   git clone https://github.com/tengfeiluo/ADEPT.git
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
| `CHARGE_METHOD` | `GASTEIGER`, `RESP` or `ESP`. RESP (HF/6-31G*, restrained) and ESP (ωB97X-D/def2-TZVP, unrestrained) are fit with Psi4 on the H-capped monomer; each removed cap-H charge is folded onto its head/tail atom so the repeat unit stays neutral. |
| `DO_APG` / `DO_OPT` / `DO_MONO_ELECTRONIC` / `DO_DC` / `DO_TC` / `DO_TG` / `DO_VISC` / `DO_EMD` | Stage toggles (`0`/`1`) |
| `DO_STRUCT` | Structure analysis of the EMD output (no simulation, about a minute). Follows `DO_EMD` unless set. Set `DO_STRUCT=1` with the other toggles at `0` to add these properties to a finished dataset. |
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

### Result files and units

Each property step writes per-polymer working files under a dedicated subfolder in `POLYMER_DATA/` (e.g. `POLYMER_DATA/OPTIMIZATION/<PID>/`) and appends a summary row to a CSV in `POLYMER_DATA/RESULTS/`:

```text
POLYMER_DATA/
├── OPTIMIZATION/<PID>/
├── MONOMER_ELECTRONIC/<PID>/
├── DIELECTRIC_CONSTANT/<PID>/
├── THERMAL_CONDUCTIVITY/<PID>/
├── GLASS_TRANSITION/<PID>/
├── VISCOSITY/<PID>/
├── EMD/<PID>/
├── STRUCTURE/<PID>/      # <PID>_rdf.dat, <PID>_sq.dat, <PID>_structure.json, <PID>_ffv.json, <PID>_kfluct.json
└── RESULTS/
    ├── RHO_MD.csv        # Density [g/cm^3]
    ├── RG_MD.csv         # Radius of gyration [Å]
    ├── HOMO_DFT.csv      # HOMO (monomer DFT) [eV]
    ├── LUMO_DFT.csv      # LUMO (monomer DFT) [eV]
    ├── BANDGAP_DFT.csv   # HOMO-LUMO gap, LUMO - HOMO (monomer DFT) [eV]
    ├── MU_DFT.csv        # Dipole moment (monomer DFT) [Debye]
    ├── ALPHA_DFT.csv     # Isotropic dipole polarizability (monomer DFT) [Å^3]
    ├── ETOTAL_DFT.csv    # Total energy (monomer DFT) [kcal/mol]
    ├── EDCMONO_DFT.csv   # Dielectric constant, electronic component (monomer estimate) [-]
    ├── ERIMONO_DFT.csv   # Refractive index (monomer estimate) [-]
    ├── EPERMONO_DFT.csv  # Absolute permittivity, electronic (monomer estimate) [F/m]
    ├── DCD_MD.csv        # Dielectric constant, dipole component (polymer) [-]
    ├── DCE_MD.csv        # Dielectric constant, electronic component (polymer) [-]
    ├── DC_MD.csv         # Relative dielectric constant, total (polymer) [-]
    ├── RI_MD.csv         # Refractive index (polymer) [-]
    ├── PE_MD.csv         # Absolute permittivity, total, ε = DC × ε0 (polymer) [pF/m]
    ├── TC_MD.csv         # Thermal conductivity, NEMD, 320/280 K reservoirs (mean 300 K) [W/(m·K)]
    ├── TG_MD.csv         # Glass transition temperature [K]
    ├── VISC_MD.csv       # Viscosity, Green-Kubo at T = Tg + 50 K (TEMP column) [Pa·s]
    ├── D_MD.csv          # Self-diffusion coefficient at T = Tg + 50 K (TEMP column) [cm^2/s]
    ├── CP_MD.csv         # Specific heat capacity Cp [J/(kg·K)]
    ├── ALPHAT_MD.csv     # Thermal diffusivity, κ/(ρ·Cp) [m^2/s]
    ├── ALPHAP_MD.csv     # Volumetric thermal expansion coefficient [1/K]
    ├── ALPHAL_MD.csv     # Linear thermal expansion coefficient, ALPHAP/3 [1/K]
    ├── K_MD.csv          # Bulk modulus [GPa]
    ├── G_MD.csv          # Shear modulus [GPa]
    ├── E_MD.csv          # Young's modulus [GPa]
    ├── NU_MD.csv         # Poisson's ratio [-]
    ├── KFLUCT_MD.csv     # Bulk modulus from NPT volume fluctuations, kB T <V>/<dV^2> [GPa]
    ├── QPEAK_MD.csv      # Position of the main X-ray S(q) peak below 3 1/Å [1/Å]
    ├── REE_MD.csv        # Root-mean-square end-to-end distance of the chains [Å]
    ├── CN_MD.csv         # Characteristic ratio <R^2>/(n <l^2>) [-]
    ├── LP_MD.csv         # Persistence length (C_n + 1) l / 2 [Å]
    ├── FFV_MD.csv        # Fractional free volume: FFV_BONDI = 1 - 1.3 Vw/V, FFV_GEOM = grid [-]
    ├── FAV_<GAS>_MD.csv  # Accessible volume fraction for a probe of that gas (HE, CO2, O2, N2, CH4) [-]
    └── CAVR_MD.csv       # Mean cavity radius at a 1.30 Å probe [Å]
```

The `RESULTS/` CSVs are keyed by `PID`, so results from many array tasks collect into a single table per property.

### Notes on property definitions

- **Units.** Values are written in the units shown in brackets above, with no scaling. Derived datasets may rescale or rename columns. For example, the ADEPT-PolyGraphMT training data store thermal diffusivity as `TD_MD.csv` in units of 10⁻⁷ m²/s (this is the same quantity as `ALPHAT_MD.csv`). Check the units of any derived file before use.
- **`BANDGAP_DFT`** is the HOMO-LUMO gap of the isolated monomer (repeat unit) from Psi4 DFT, not the band gap of a polymer chain or solid. It is typically larger than measured optical band gaps.
- **`DC_MD` vs `PE_MD`.** `DC_MD` is the relative (dimensionless) static dielectric constant, ε = ε_el + ε_dip − 1, where ε_el = n² comes from the DFT polarizability via Lorentz-Lorenz and ε_dip comes from MD dipole fluctuations. `PE_MD` is the absolute permittivity, DC × ε0, in pF/m; it is not a relative permittivity.
- **Glass transition temperature.** `TG_MD` comes from stepwise NPT cooling over Tg_ML ± 150 K (lower bound 50 K) in 10 K steps of 0.5 ns equilibration + 0.5 ns production (about 10 K/ns), followed by a bilinear fit of density vs temperature. The 1000 → 300 K cool-down in the equilibration step (about 140 K/ns) is part of structure preparation and is not the Tg protocol.
- **Structure analysis** (`DO_STRUCT`) uses only what the EMD step already saves: 100 snapshots over its 8 ns NPT run at 300 K and the volume record. `KFLUCT_MD` is the relaxed bulk modulus of the simulated glass and reads lower than `K_MD`, which comes from a 0.25 ps strain step. `QPEAK_MD` uses atomic numbers as X-ray weights (no q-dependent form factors) and an RDF cut at half the box, so q below about 0.55 1/Å is not reported. `REE_MD`, `CN_MD` and `LP_MD` follow the longest path through the non-hydrogen bond graph of each chain; a cell holds only a few chains, which do not rearrange at 300 K, so expect an uncertainty of about 30% on these three (it is written to `<PID>_structure.json`). `FFV_MD` and the accessible volumes are from `calc_FFV.py` (Bondi radii; Zhao et al. group-additivity Vw for `FFV_BONDI`).
- **Viscosity and diffusion** are computed at T = Tg + 50 K, using MD Tg when available and the ML-predicted Tg otherwise; the temperature is recorded in the `TEMP` column.

## Legacy / local HPC

`legacy/submit_sge.sh` is an older Grid Engine–style driver (`module load` LAMMPS). Prefer the OSPool container path above for portability.

## Citation

If you use ADEPT, please cite the original ADEPT project and relevant method papers (LAMMPS, Psi4, PySIMM, etc.). See the upstream repository: [sobinalosious/ADEPT](https://github.com/sobinalosious/ADEPT).

## License

Follow the license of the upstream ADEPT project unless otherwise noted in this repository.
