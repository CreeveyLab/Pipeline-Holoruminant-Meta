# Walkthrough: raw reads to annotated, taxonomically classified, quality-checked MAGs on Kelvin2

A worked, step-by-step example of the most common path through this pipeline —
raw sequencing reads in, annotated, taxonomically classified, quality-checked
metagenome-assembled genomes (MAGs) out. This intentionally stops before
`read_annotate` (read-level taxonomic/functional profiling) and `quantify`
(relative MAG abundance across samples) — both run independently of
everything below and aren't needed to get here; see
[docs/00-Kelvin2-Quickstart.md](00-Kelvin2-Quickstart.md) for the general
setup and the resource-tier/grouped-rule concepts this walkthrough assumes.

**A real caveat, upfront**: unlike `preprocess` and `read_annotate`, nothing
from `assemble` onward has actually been run to completion with real data in
this fork yet (as of this writing) — no real MAGs have been produced.
`assemble`'s and `mag_annotate`'s resource tiers are still the generic,
un-recalibrated defaults, not real-benchmark-based like `preprocess`'s. The
grouped-rule mechanics described below (magscot specifically) have been
verified for real, but the tools themselves haven't been. Treat this as a
map of the real path, not a guarantee every step's resource tier is already
right for your data.

This assumes you already have a bootstrapped project (`bootstrap_project.sh`,
covered in the quickstart) with real reads in place. Throughout, `SAMPLE` is
a stand-in for your own sample ID as it appears in `config/samples.tsv`.

## The path, in order

```
raw reads → preprocess (grouped) → assemble → bin → refine (grouped) → dereplicate → MAGs → annotate/classify/QC
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

**Checking progress**: `bash check_progress_kelvin.sh` — shows the
orchestrator's own status, every real job it has submitted, and recent log
progress, all in one place. (Under the hood this is one job in `squeue`, not
one per host or per step — its name will be a UUID, not something
human-readable, which is exactly why `check_progress_kelvin.sh` is easier
than matching things up yourself.) This step alone can run for many hours,
so this is worth checking in on rather than watching the terminal.

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

**Checking progress**: `bash check_progress_kelvin.sh` — same as every
other step in this walkthrough. Worth checking on this one specifically if
it's been running a long time with no sign of finishing; a real
out-of-memory failure shows up there once it happens.

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

**Checking progress**: `bash check_progress_kelvin.sh` again — since all
three binners run concurrently as separate jobs, this is the easiest way to
see all three at once rather than checking each individually.

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

**Checking progress**: `bash check_progress_kelvin.sh` — again, one job for
the whole refinement chain, not 8, same as Step 1.

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

**Checking progress**: `bash check_progress_kelvin.sh`, as with every other
step — this also works if you ran the whole path in one command above,
showing every job across all of Steps 2-5 at once, not just dRep's.

**Output**:
- `results/assemble/drep/dereplicated_genomes.fa.gz` — all final MAGs, concatenated.
- `results/assemble/drep/dereplicated_genomes/` — the same genomes as individual FASTA files, one per MAG.

## Step 6: MAG annotation, taxonomy, and quality control

Everything from here on consumes the dereplicated MAG set from Step 5. Unlike
Steps 1-5, this module (`mag_annotate`) is a collection of independent tools —
like `read_annotate`, not a linear pipeline — so there's no single "grouped
chain" here; each tool is its own separate job. Organised by what you asked
for:

**Taxonomy** — `GTDB-Tk` classifies each MAG:

```bash
bash run_Kelvin.sh results/mag_annotate/gtdbtk/gtdbtk.summary.tsv
```

**Quality control** — `CheckM2` estimates genome completeness/contamination
per MAG; `QUAST` reports assembly-quality statistics across the MAG set:

```bash
bash run_Kelvin.sh mag_annotate__checkm2
bash run_Kelvin.sh mag_annotate__quast
```

**Functional annotation** — `DRAM`, `eggNOG-mapper`, `CAMPER`, `Bakta`,
`ProteinOrtho`, and `PhyloPhlAn` all run against the MAG set too. One real
cross-tool dependency worth knowing: `DRAM`'s own annotation rule requires
GTDB-Tk's taxonomy output as an input, not just the MAG set — so running
`DRAM` on its own still triggers a real GTDB-Tk classification first if you
haven't run it already; this is normal, not a mistake in what you targeted.

```bash
bash run_Kelvin.sh mag_annotate__dram_mags
bash run_Kelvin.sh mag_annotate__eggnog
bash run_Kelvin.sh mag_annotate__camper
bash run_Kelvin.sh mag_annotate__bakta_mags
bash run_Kelvin.sh mag_annotate__proteinortho
bash run_Kelvin.sh mag_annotate__phylophlan
```

Or, all of the above at once — every tool in this module, for every MAG:

```bash
bash run_Kelvin.sh mag_annotate
```

**Checking progress**: `bash check_progress_kelvin.sh`, same as every other
step — with this many independent tools potentially running at once, this is
the easiest way to see everything together rather than checking each one.

**Output**: `results/mag_annotate/`, one subfolder per tool (`gtdbtk/`,
`checkm2/`, `quast/`, `dram/`, `eggnog/`, `camper/`, `bakta_mags/`,
`proteinortho/`, `phylophlan/`).

## Run everything in one command

Every step above — preprocessing through MAG annotation/taxonomy/quality —
is really just one dependency chain. Targeting the furthest-downstream output
pulls in everything upstream of it automatically:

```bash
bash run_Kelvin.sh mag_annotate
```

**Does grouping still apply when you invoke it this way, rather than one step
at a time?** Yes — confirmed directly, not assumed: a real dry run
(`bash run_Kelvin.sh -n mag_annotate`) shows `Group job magscot_37131`
appearing in the dispatch exactly as it does when `assemble` is targeted
directly, even though the actual target here is several steps further
downstream. Grouping is a property of the rule itself, not of how you invoke
it — Snakemake builds the full dependency graph backward from whatever
target you give it, and any grouped rule that ends up in that graph stays
grouped, whether it's the thing you asked for directly or just something
upstream of it. The same applies to `preprocess`'s group.

## Not covered here: `read_annotate` and `quantify`

Read-level profiling (`kraken2`, `diamond`, `humann`, `metaphlan`, `phyloflash`,
`singlem`, `nonpareil`) runs entirely independently of everything above — it
only needs Step 1's decontaminated reads, not anything from assembly onward.
It's deliberately left out of this walkthrough while its own resource tiers
are still being actively tuned; see `config/escalation.yaml`'s `read_annotate__*`
entries and their comments for the current state.

`quantify` (relative abundance of each MAG across samples) consumes Step 6's
output but isn't covered here either; check `workflow/rules/quantify/` for
what it needs.
