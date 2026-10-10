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
other than a hyphen, pass `--sample-id-delimiter <char>`. If the sample ID
isn't the first delimiter-separated chunk (e.g. a shared project number
comes first), add `--sample-id-field N` to pick which field is — the
default (field 1) will otherwise silently give every sample the same ID.
Two more optional flags: `--assembly-strip-regex <RE>` co-assembles
replicates that reduce to the same ID once a trailing pattern is stripped
(e.g. `'R[0-9]+$'` so `D10T1R1`/`D10T1R2` share one assembly), and
`--exclude-regex <RE>` skips samples matching a pattern (e.g. `'^NTC$'`
for no-template controls). Run the script with no arguments for the full
option list.

**First time on this account, or a new shared store?** Add `--verify` to
also submit one real, cheap job and wait for it, on top of the dry-run
self-check. A dry run only confirms the pipeline's dependency graph
resolves — it never invokes Apptainer and never checks a file's actual
read permission, so it can't catch a broken container bind-mount or a
permissions problem on the shared stores. `--verify` catches both, at the
cost of one real (short) queue-wait — worth it once, not on every project
you set up routinely.

### Starting from data you already have

You don't have to start from raw reads. Three flags let you drop in data
already processed elsewhere — they're composable, so use any subset
together:

- **Already-cleaned reads** (quality-trimmed, or fully host-decontaminated)
  — `--cleaned-reads-dir <dir> --cleaned-reads-stage {fastp,decontaminated}`
  instead of `--reads-dir`. Same sample detection as `--reads-dir`
  (`--sample-id-delimiter`/`--sample-id-field`/etc. all apply), but it
  drops the files straight into the pipeline's own intermediate path
  instead of `reads/`, so the read-cleaning steps never run. The stage
  matters and isn't defaulted: pass `fastp` if you want Kraken2/Bracken
  specifically (Kraken2 deliberately reads pre-decontamination reads —
  see its rule's own docstring); pass `decontaminated` for every other
  `read_annotate` tool, or if you want the pipeline to assemble from your
  cleaned reads.
- **An assembly you already have** — `--provided-assembly <dir>`, one
  `<assembly_id>.fa.gz` per assembly ID in your `samples.tsv`. Sets
  `assembler: "provided"` in the generated config — every assembly-
  consuming rule already supports this, so it's not a new mechanism.
- **Alignments you already have too** — `--provided-alignments <dir>`
  (requires `--provided-assembly`), one
  `<assembly_id>.<sample_id>.<library_id>.<bam|cram>` per sample mapped to
  that assembly. Missing `.bai`/`.crai` indexes are built automatically if
  `samtools` is on your `PATH` when you run the script.

Example — already-decontaminated reads plus a provided assembly and
alignments, straight to binning:

```bash
<your-clone>/workflow/scripts/bootstrap_project.sh <project_dir> \
  --cleaned-reads-dir <dir> --cleaned-reads-stage decontaminated \
  --provided-assembly <dir> \
  --provided-alignments <dir>
```

Every file is validated before it's wired in — a missing assembly or
alignment for any sample/assembly your `samples.tsv` expects is a loud,
specific error, not a silent gap discovered deep in a SLURM job later. The
dry-run self-check also adapts: it targets whatever's actually the
furthest-along real next step (Kraken2, Nonpareil, CONCOCT, or
bowtie2-build's index) instead of always assuming raw reads are where you
started.

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
previous run for this project is still active — SLURM jobs still
queued/running, an orchestrator process that didn't fully exit, **or** a
recent heartbeat file saying it's still alive even if the first two came
back clear. That third check matters specifically because Kelvin2 has
several login nodes behind round-robin DNS: if you log back in later and
land on a different one than the orchestrator is actually running on, a
local process check alone can't see it. The orchestrator writes that
heartbeat into the project directory itself (shared storage, so it reads
the same from any login node) every 30 seconds while it's alive. If the
guard finds any of the three, it runs `check_progress_kelvin.sh` for you
instead of launching a duplicate.

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
  `metaphlan`, `phyloflash`, `singlem`, `nonpareil`, `bracken`) has been
  validated against real data — `bracken` most recently (2026-10-10): a
  real submitted job (not just a dry run) completed successfully, real
  peak RSS ~98MB (well inside its 4GB tier), with real, sensible output
  (correctly structured abundance table and corrected Kraken-format
  report, sane taxa for this lab's rumen samples).
- **Targeting one rule can trigger an unexpectedly large re-run cascade**
  if a raw input file's modification time is newer than an already-good
  downstream output — Snakemake's dependency tracking is mtime-based by
  default. See
  [10-Troubleshooting.md](10-Troubleshooting.md#targeting-one-rule-re-runs-way-more-than-expected)
  for the real fix (`--touch`) rather than waiting out a needless
  re-derivation.

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
