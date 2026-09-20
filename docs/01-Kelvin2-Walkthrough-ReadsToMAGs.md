# Walkthrough: raw reads to MAGs on Kelvin2

A worked, step-by-step example of the most common path through this pipeline —
raw sequencing reads in, a dereplicated set of metagenome-assembled genomes
(MAGs) out. This intentionally stops before `read_annotate` (read-level
taxonomic/functional profiling) — that module runs independently of
everything below and isn't needed to get to MAGs; see
[docs/00-Kelvin2-Quickstart.md](00-Kelvin2-Quickstart.md) for the general
setup and the resource-tier/grouped-rule concepts this walkthrough assumes.

This assumes you already have a bootstrapped project (`bootstrap_project.sh`,
covered in the quickstart) with real reads in place. Throughout, `SAMPLE` is
a stand-in for your own sample ID as it appears in `config/samples.tsv`.

## The path, in order

```
raw reads  →  preprocess (grouped)  →  assemble  →  bin  →  refine (grouped)  →  dereplicate  →  MAGs
```

Two of these steps are **grouped**: several small, sequential rules bundled
into a single SLURM job, specifically to avoid each one queueing separately.
That's the main thing this walkthrough calls out concretely as you hit it.

## Step 1: Preprocessing (grouped)

This covers adapter/quality trimming (`fastp`) and host-read decontamination
— for this pipeline, a cascade against every configured host genome in turn
(each host's mapped reads are removed before the next host is checked). All
of this, for one sample/library, is bundled into **one** SLURM job.

Run it for every sample in your project with the module's own rule name —
no need to know the output path at all:

```bash
bash run_Kelvin.sh preprocess
```

(If you only want one specific sample/library rather than the whole
project — say, to test on one sample before committing to the rest — target
its real output file instead:
`results/preprocess/bowtie2/decontaminated_reads/SAMPLE.lib1_{1,2}.fq.gz`.
See [docs/00-Kelvin2-Quickstart.md § Finding the right target to run](00-Kelvin2-Quickstart.md#5-finding-the-right-target-to-run)
for how to find paths like this yourself.)

**What to expect in `squeue`**: one job, not one per host or per step — its
name will be a UUID, not something human-readable, but you can confirm it's
the right one by matching the working directory (`squeue -u $USER -o "%.12i %.10T %Z"`)
against your project directory. Easier: `bash check_progress_kelvin.sh` shows
this (and the orchestrator's own status, and recent log progress) without
needing to match anything up yourself — this step alone can run for many
hours, so this is worth checking in on rather than watching the terminal.

**Real timing, for reference**: on a real ~350-million-read paired library,
this full cascade (4 hosts × build/map/extract, plus `fastp`) took around
21 hours end-to-end in that one job. That's the entire point of grouping it
— the same work as separate per-step jobs previously took as long as
**12 calendar days** of mostly queue-wait, for well under a day of actual
compute.

**Output**: `results/preprocess/bowtie2/decontaminated_reads/SAMPLE.lib1_{1,2}.fq.gz`
— your real, decontaminated reads. Everything downstream uses this.

## Step 2: Assembly

Set which assembler to use in `config/config.yaml`'s `assembler:` key —
`"metaspades"` (the default) or `"megahit"`. Both consume the decontaminated
reads from Step 1 directly; you don't need to point anything at them by hand.

```bash
bash run_Kelvin.sh results/assemble/metaspades/SAMPLE.fa.gz   # if assembler: "metaspades"
# or
bash run_Kelvin.sh results/assemble/megahit/SAMPLE.fa.gz      # if assembler: "megahit"
```

This is **not** grouped — it's one job, one rule, because there's nothing
to bundle it with. It's also the heaviest single step in the whole path:
real metagenomic co-assemblies can need very large memory allocations, and
complex/deep samples can genuinely exceed what a given tier provides. If
`metaspades` runs out of memory on a particular sample, `megahit` is the
standard, much lighter-weight fallback — worth trying before assuming the
tier just needs to be bigger.

**Output**: `results/assemble/{metaspades,megahit}/SAMPLE.fa.gz` — your
assembled contigs.

## Step 3: Binning

Three independent binners run against the same assembly: `concoct`,
`maxbin2`, `metabat2`. None of these are grouped with each other — they're
genuinely independent tools with different resource profiles, so Snakemake
just schedules all three as separate jobs and runs them concurrently once
the assembly (and its read-mapping-based coverage info) is ready.

You don't need to target these individually — the next step pulls them in
as dependencies automatically.

## Step 4: Bin refinement (grouped)

`MAGScoT` reconciles the three binners' results into one consensus set of
bins. This is the pipeline's other grouped rule: 8 sequential sub-steps
(gene prediction, two HMM searches, merging, the actual scoring/refinement,
reformatting, renaming) bundled into **one** SLURM job per assembly, same
reasoning as Step 1 — several small steps that would otherwise each queue
on their own.

```bash
bash run_Kelvin.sh results/assemble/magscot/SAMPLE/magscot.refined.out
```

**What to expect in `squeue`**: again, one job for the whole refinement
chain, not 8.

**A real gotcha worth knowing, if you ever add or change a tier this group
uses**: every rule sharing a group must request the *same* SLURM partition
list and the same generic-resource (`gres`) request — a group job is one
`sbatch` submission, and Snakemake can't merge two different values for
either into one request. If you see `Error grouping resources in group
'...'` when dry-running (`bash run_Kelvin.sh -n ...`), that's what's
happening — check `config/escalation.yaml` for which tier each rule in
the group uses, and make sure they agree.

## Step 5: Dereplication

`dRep` removes redundant/highly-similar genomes across the refined bin set,
producing the final MAG set.

```bash
bash run_Kelvin.sh results/assemble/drep/dereplicated_genomes.fa.gz
```

Or, to run the entire path above in one command from a clean project:

```bash
bash run_Kelvin.sh assemble
```

**Output**:
- `results/assemble/drep/dereplicated_genomes.fa.gz` — all final MAGs, concatenated.
- `results/assemble/drep/dereplicated_genomes/` — the same genomes as individual FASTA files, one per MAG.

## What's next

This is real, usable output — but it's not annotated or quantified yet.
`mag_annotate` (taxonomy, functional annotation) and `quantify` (relative
abundance of each MAG across samples) both consume this MAG set as their
starting point. Neither is covered by this walkthrough; check their
respective rule files under `workflow/rules/` for what they need.

## Not covered here: `read_annotate`

Read-level profiling (`kraken2`, `diamond`, `humann`, `metaphlan`, `phyloflash`,
`singlem`, `nonpareil`) runs entirely independently of everything above — it
only needs Step 1's decontaminated reads, not anything from assembly onward.
It's deliberately left out of this walkthrough while its own resource tiers
are still being actively tuned; see `config/escalation.yaml`'s `read_annotate__*`
entries and their comments for the current state.
