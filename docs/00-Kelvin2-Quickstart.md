# Running this pipeline on Kelvin2 (QUB)

This page is specific to this fork. It covers everything needed to go from a
fresh Kelvin2 account to a running pipeline: prerequisites, cloning, setting
up a project, launching, and what the resource-tiering system means for you
day to day. If you're not running on Kelvin2 at Queen's University Belfast,
use the [upstream repository](https://github.com/fischuu/Snakebite-Holoruminant-MetaG)
instead — none of this applies there.

## 1. Prerequisites

- A Kelvin2 account with a working home directory and access to `/mnt/scratch2`.
- `snakemake` and `apptainer`/`singularity` available in your shell (via
  `module load`, or already present in your login environment). This fork
  was developed and tested against `snakemake/9.9.0` and `apps/apptainer/1.5.1`.
- Read access to the shared, central stores under `/mnt/scratch2/igfs-databases/`:
  - `HoloR-MetaG-pipeline-resources/` — host reference genomes and databases.
  - `HoloR-MetaG-pipeline-containers/` — the shared Apptainer/Singularity
    image cache, so you don't re-pull every container from scratch.
  These are already populated and group-readable; you shouldn't need to set
  anything up yourself to use them.
- Real sequencing reads somewhere under `/mnt/scratch2`, following (or
  adaptable to) the naming convention `<name>_R1_<...>.fastq.gz` /
  `<name>_R2_<...>.fastq.gz`.

## 2. Get your own copy of the code

Clone your **own** copy of this repository — don't point your project at
someone else's working checkout. This fork is under active development, and
a project's `run_Kelvin.sh` is generated with an absolute path baked in to
whichever clone you bootstrap it from; if that clone keeps changing under
you, a live pipeline run can break or behave inconsistently mid-run.

```bash
git clone git@github.com:CreeveyLab/Pipeline-Holoruminant-Meta.git
```

Pin to a specific commit or tag if you want a guaranteed-stable target
rather than tracking `main` as it evolves.

## 3. Bootstrap a new project

Each dataset/analysis gets its own project directory, scaffolded from your
fork clone:

```bash
<your-clone>/workflow/scripts/bootstrap_project.sh <project_dir> \
  --reads-dir <directory containing your *_R1_*/*_R2_*.fastq.gz files>
```

This:
- Copies `config/` (including the Kelvin SLURM profile) into your project.
- Points `pipeline_folder:` at your fork clone.
- Symlinks the central resources store into your project.
- Detects your samples and generates `config/samples.tsv` (or copy in your
  own via `--samples-tsv <file>` instead of `--reads-dir`).
- Generates a ready-to-run `run_Kelvin.sh` in your project directory.
- Runs a scoped dry run as a self-check before declaring success.

If your lab's sample-naming convention splits the sample ID on something
other than a hyphen, pass `--sample-id-delimiter <char>`. Run the script
with no arguments for the full option list.

## 4. Launch

From inside your project directory:

```bash
bash run_Kelvin.sh                                  # run everything
bash run_Kelvin.sh <specific/output/path>           # run only what's needed for one target
```

Before doing anything else, `run_Kelvin.sh` runs a safety check
(`kelvin_launch_guard.sh`) that refuses to launch if a previous run for this
same project is still active — either real SLURM jobs still queued/running,
or a Snakemake orchestrator process that didn't fully exit. If it blocks
you, follow what it prints; don't just re-run past it.

## 5. Understanding the resource-tier system

Every rule in the pipeline is assigned a named resource tier (`config/escalation.yaml`
maps rules to tiers, `config/config.yaml`'s `resource_sets:` defines what each
tier actually requests: runtime, memory, CPUs, SLURM partition(s)). This is
what keeps small/fast rules off contended queues and routes them to `k2-medpri`
or `k2-hipri` where their real cost allows it, instead of every rule
defaulting to the same oversized, slow-queue-only request.

**If a job fails with an out-of-memory or time-limit error**: this is a
tuning gap, not something wrong with your data. The relevant tier in
`config/config.yaml` needs a larger `mem_mb` or `runtime` value. Real
benchmark data (`benchmark:` TSVs, written alongside each rule's real
output) is the right basis for that — don't guess. Several tiers already
carry comments documenting exactly this kind of real-evidence correction;
follow the same pattern rather than picking an arbitrarily large number.

**Grouped rules** (`preprocess` and `assemble/magscot` currently bundle
several small, sequential steps into one SLURM job each, to cut down on
per-step queue-wait): a few things behave differently for these —
- `squeue`/`sacct` will show **one** job per group, not one per step.
- All member rules must agree on the same SLURM partition list — mismatched
  partitions between rules sharing a group cause the whole submission to
  fail (Snakemake raises this clearly at DAG-build time, before submitting).
- Multi-tier `retries:`-based escalation does **not** work for a grouped
  rule — a retry re-executes inside the *same* already-running SLURM
  allocation, which can't actually be given more memory/time. Grouped rules
  should be sized generously up front on a single tier, not rely on
  escalation.

## 6. Known limitations

- **Multi-user use is not yet fully validated.** The shared stores
  (resources, containers) are architected for concurrent use by design, but
  hasn't yet been exercised by two users running real projects at the same
  time. If you hit something that looks like a cross-project conflict,
  that's worth reporting rather than assuming it's expected.
- **Per-module resource calibration is a work in progress.** `preprocess`
  and `read_annotate` have been run for real and their tiers are based on
  real benchmark data. Other modules (`assemble`, `mag_annotate`,
  `contig_annotate`, `quantify`) still carry more generic, less-calibrated
  tiers pending real runs.
- **`sylph`, `ncyc`, and Krona's taxonomy database** are not currently
  present in the central resource store — rules depending on them will
  fail until those are sourced. Every other `read_annotate` tool
  (`kraken2`, `diamond`, `humann`, `metaphlan`, `phyloflash`, `singlem`,
  `nonpareil`) has been validated against a real dataset.

## 7. Worked example: raw reads to MAGs

For a concrete, step-by-step walkthrough of the most common path through
this pipeline — including exactly what to expect from both grouped rules
(`preprocess` and `assemble/magscot`) in practice — see
[docs/01-Kelvin2-Walkthrough-ReadsToMAGs.md](01-Kelvin2-Walkthrough-ReadsToMAGs.md).

## 8. Getting help

Check `docs/10-Troubleshooting.md` for general pipeline issues. For
Kelvin2-specific problems (SLURM submission errors, resource tiers,
`run_Kelvin.sh`/`bootstrap_project.sh` behavior), open an issue on this
fork's GitHub repository rather than upstream.
