# Running this pipeline on Kelvin2 (QUB)

This page is specific to this fork. It covers prerequisites, cloning, setting
up a project, launching, and what the resource-tiering system means day to
day. If you're not on Kelvin2 at Queen's University Belfast, use the
[upstream repository](https://github.com/fischuu/Snakebite-Holoruminant-MetaG)
instead — none of this applies there.

## 1. Prerequisites

- A Kelvin2 account with a working home directory and access to `/mnt/scratch2`.
- `snakemake` and `apptainer`/`singularity` available in your shell (via
  `module load`, or already present). Developed and tested against
  `snakemake/9.9.0` and `apps/apptainer/1.5.1`.
- Read access to the shared stores under `/mnt/scratch2/igfs-databases/`:
  - `HoloR-MetaG-pipeline-resources/` — host reference genomes and databases.
  - `HoloR-MetaG-pipeline-containers/` — the shared Apptainer/Singularity
    image cache, so you don't re-pull every container from scratch.
  Both are already populated and group-readable — no setup needed.
- Sequencing reads somewhere under `/mnt/scratch2`, following (or adaptable
  to) `<name>_R1_<...>.fastq.gz` / `<name>_R2_<...>.fastq.gz`.

## 2. Get your own copy of the code

Clone your **own** copy — don't point your project at someone else's working
checkout. A project's `run_Kelvin.sh` bakes in an absolute path to whichever
clone bootstrapped it; if that clone changes under you, a live run can break
mid-way.

```bash
git clone git@github.com:CreeveyLab/Pipeline-Holoruminant-Meta.git
```

Pin to a commit or tag if you want a stable target instead of tracking `main`.

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

**First time on this account, or a new shared store?** Add `--verify` to
also submit one real, cheap job and wait for it, on top of the dry-run
self-check. A dry run only confirms the pipeline's dependency graph
resolves — it never invokes Apptainer and never checks a file's actual
read permission, so it can't catch a broken container bind-mount or a
permissions problem on the shared stores. `--verify` catches both, at the
cost of one real (short) queue-wait — worth it once, not on every project
you set up routinely.

## 4. Launch

From inside your project directory:

```bash
bash run_Kelvin.sh                                  # run everything
bash run_Kelvin.sh mag_annotate                     # run one module (grouped rules run in groups)
bash run_Kelvin.sh <specific/output/path>           # run only what's needed for one target file
```

**You don't need `nohup`, `tmux`, or `screen`.** For a real launch,
`run_Kelvin.sh` backgrounds and detaches the orchestrator itself, so it
survives logout and returns control to your shell immediately. Check on it
any time with:

```bash
bash check_progress_kelvin.sh
```

This reports the orchestrator's status, every SLURM job it has submitted for
this project, and recent progress from its log — whether you check a minute
after launching or the next day.

(Dry runs, `-n`/`--dry-run`, run in the foreground — fast, read-only, and
you'll want to see the output immediately.)

Before a real launch, `run_Kelvin.sh` runs a safety check
(`kelvin_launch_guard.sh`) that refuses to start a second orchestrator if a
previous run for this project is still active — either SLURM jobs still
queued/running, or an orchestrator process that didn't fully exit. If it
finds one, it runs `check_progress_kelvin.sh` for you instead of launching a
duplicate.

## 5. Finding the right target to run

`bash run_Kelvin.sh <target>` accepts anything Snakemake accepts as a
target: an output file path, or a **rule name**. Every module has a
top-level rule named after itself, so these all work directly:

```bash
bash run_Kelvin.sh preprocess       # every sample's preprocessing
bash run_Kelvin.sh assemble         # assembly through dereplication, every sample
bash run_Kelvin.sh read_annotate    # every read-level profiling tool, every sample
bash run_Kelvin.sh mag_annotate
bash run_Kelvin.sh quantify
```

**A tool within a module isn't always one unambiguous name** — e.g. "bowtie2"
covers six different rules across three modules. Target names must match
exactly; there's no fuzzy matching. See
[02-Kelvin2-Rule-Reference.md](02-Kelvin2-Rule-Reference.md) for the full
module → tool → exact rule name table.

For a specific file, sample, or intermediate step, two ways to find the path
without reading rule files by hand:

- **`workflow/rules/folders.smk`** — maps every module's output folders to
  short names (e.g. `DREP = ASSEMBLE / "drep/"`, `PRE_BOWTIE2 = PRE / "bowtie2"`).
  Fastest way to see the on-disk layout in one place.
- **A dry run** (`bash run_Kelvin.sh -n <module-name>`) prints every rule
  it would run, including `input:`/`output:` paths — useful even if you
  never open a `.smk` file.

## 6. Understanding the resource-tier system

Every rule is assigned a named resource tier (`config/escalation.yaml` maps
rules to tiers; `config/config.yaml`'s `resource_sets:` defines what each
tier requests: runtime, memory, CPUs, SLURM partition(s)). This keeps
small/fast rules off contended queues, routing them to `k2-medpri` or
`k2-hipri` where their cost allows it, instead of every rule defaulting to
the same oversized, slow-queue-only request.

**If a job fails with an out-of-memory or time-limit error**: this is a
tuning gap, not a problem with your data. Give the tier in `config/config.yaml`
a larger `mem_mb` or `runtime`. Base the new value on `benchmark:` TSVs
(written alongside each rule's output), not a guess — several tiers already
carry comments showing this pattern.

**Grouped rules** (`preprocess` and `assemble/magscot` bundle several small,
sequential steps into one SLURM job each, to cut queue-wait): a few things
behave differently for these —
- `squeue`/`sacct` show **one** job per group, not one per step.
- All member rules must agree on the same SLURM partition list — a mismatch
  fails the whole submission (Snakemake raises this at DAG-build time,
  before submitting).
- Multi-tier `retries:` escalation does **not** work for a grouped rule — a
  retry re-executes inside the same already-running SLURM allocation, which
  can't be given more memory or time. Size grouped rules generously up
  front on a single tier instead.

## 7. Known limitations

- **Multi-user use isn't fully validated.** The shared stores (resources,
  containers) are designed for concurrent use, but two users running real
  projects at once hasn't been exercised yet. Report anything that looks
  like a cross-project conflict.
- **Per-module resource calibration is in progress.** `preprocess` and
  `read_annotate` have real benchmark data behind their tiers. `assemble`,
  `mag_annotate`, `contig_annotate`, and `quantify` still carry more
  generic tiers pending real runs.
- **`sylph`, `ncyc`, and Krona's taxonomy database** aren't yet in the
  central resource store — rules depending on them will fail until sourced.
  Every other `read_annotate` tool (`kraken2`, `diamond`, `humann`,
  `metaphlan`, `phyloflash`, `singlem`, `nonpareil`) has been validated
  against real data.

## 8. Worked example: raw reads to MAGs

For a step-by-step walkthrough of the most common path through this
pipeline — including both grouped rules (`preprocess` and
`assemble/magscot`) in practice — see
[docs/01-Kelvin2-Walkthrough-ReadsToMAGs.md](01-Kelvin2-Walkthrough-ReadsToMAGs.md).

## 9. Getting help

Check `docs/10-Troubleshooting.md` for general pipeline issues. For
Kelvin2-specific problems (SLURM submission errors, resource tiers,
`run_Kelvin.sh`/`bootstrap_project.sh` behavior), open an issue on this
fork's GitHub repository rather than upstream.
