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
covered in the quickstart) with real reads in place, and more than one sample
in `config/samples.tsv`. Every step below leads with the command for **every
sample in your project at once** — that's the normal way to run this pipeline.
As an aside under each one, you'll also find the equivalent command scoped to
just one sample (a fictional `sample1`, standing in for a real sample ID as
it appears in your own `config/samples.tsv`) — useful for testing on one
sample before committing to a whole project's worth of compute.

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
(each host's mapped reads are removed before the next host is checked). Each
sample/library's whole cascade is bundled into **one** SLURM job.

```bash
bash run_Kelvin.sh preprocess
```

*Aside — just `sample1`:*

```bash
bash run_Kelvin.sh results/preprocess/bowtie2/decontaminated_reads/sample1.lib1_1.fq.gz \
                    results/preprocess/bowtie2/decontaminated_reads/sample1.lib1_2.fq.gz
```

(See [docs/00-Kelvin2-Quickstart.md § Finding the right target to run](00-Kelvin2-Quickstart.md#5-finding-the-right-target-to-run)
for how to find paths like this yourself, for any step.)

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

**Output**: `results/preprocess/bowtie2/decontaminated_reads/{sample}.lib1_{1,2}.fq.gz`,
one pair per sample/library — your real, decontaminated reads. Everything
downstream uses this.

## Step 2: Assembly

Set which assembler to use in `config/config.yaml`'s `assembler:` key —
`"metaspades"` (the default) or `"megahit"`. Both consume Step 1's
decontaminated reads directly; you don't need to point anything at them by
hand.

```bash
bash run_Kelvin.sh assemble__metaspades   # if assembler: "metaspades" -- every sample
# or
bash run_Kelvin.sh assemble__megahit      # if assembler: "megahit" -- every sample
```

*Aside — just `sample1`:*

```bash
bash run_Kelvin.sh results/assemble/metaspades/sample1.fa.gz   # if assembler: "metaspades"
# or
bash run_Kelvin.sh results/assemble/megahit/sample1.fa.gz      # if assembler: "megahit"
```

This is **not** grouped — it's one job per sample, one rule, because there's
nothing to bundle it with. It's also the heaviest single step in the whole
path: real metagenomic co-assemblies can need very large memory allocations,
and complex/deep samples can genuinely exceed what a given tier provides. If
`metaspades` runs out of memory on a particular sample, `megahit` is the
standard, much lighter-weight fallback — worth trying before assuming the
tier just needs to be bigger.

**Checking progress**: `bash check_progress_kelvin.sh` — same as every
other step in this walkthrough. Worth checking on this one specifically if
it's been running a long time with no sign of finishing; a real
out-of-memory failure shows up there once it happens.

**Output**: `results/assemble/{metaspades,megahit}/{sample}.fa.gz`, one per
sample — your assembled contigs.

## Step 3: Binning

Three independent binners run against each assembly: `concoct`, `maxbin2`,
`metabat2`. None of these are grouped with each other — they're genuinely
independent tools with different resource profiles, so Snakemake schedules
each as its own job and runs all three concurrently once an assembly (and
its read-mapping-based coverage info) is ready.

```bash
bash run_Kelvin.sh assemble__concoct    # every sample
bash run_Kelvin.sh assemble__maxbin2    # every sample
bash run_Kelvin.sh assemble__metabat2   # every sample
```

*Aside — just `sample1`:*

```bash
bash run_Kelvin.sh results/assemble/concoct/sample1
bash run_Kelvin.sh results/assemble/maxbin2/sample1
bash run_Kelvin.sh results/assemble/metabat2/sample1
```

You don't need to target any of these individually in the normal case — the
next step pulls all three in as dependencies automatically.

**Checking progress**: `bash check_progress_kelvin.sh` again — since all
three binners run concurrently as separate jobs, this is the easiest way to
see all three at once (across every sample) rather than checking each
individually.

## Step 4: Bin refinement (grouped)

`MAGScoT` reconciles the three binners' results into one consensus set of
bins per assembly. This is the pipeline's other grouped rule: 8 sequential
sub-steps (gene prediction, two HMM searches, merging, the actual
scoring/refinement, reformatting, renaming) bundled into **one** SLURM job
per assembly, same reasoning as Step 1 — several small steps that would
otherwise each queue on their own.

```bash
bash run_Kelvin.sh assemble__magscot
```

*Aside — just `sample1`:*

```bash
bash run_Kelvin.sh results/assemble/magscot/sample1/magscot.refined.out
```

**Checking progress**: `bash check_progress_kelvin.sh` — again, one job per
assembly for the whole refinement chain, not 8, same as Step 1.

**A real gotcha worth knowing, if you ever add or change a tier this group
uses**: every rule sharing a group must request the *same* SLURM partition
list and the same generic-resource (`gres`) request — a group job is one
`sbatch` submission, and Snakemake can't merge two different values for
either into one request. If you see `Error grouping resources in group
'...'` when dry-running (`bash run_Kelvin.sh -n ...`), that's what's
happening — check `config/escalation.yaml` for which tier each rule in
the group uses, and make sure they agree. (Real, not hypothetical: this
exact conflict was found and fixed twice during this fork's development —
once introducing the group's own dedicated tiers, once again as a
regression from an unrelated fix, both times caught by a dry run before
ever reaching real submission.)

## Step 5: Dereplication

`dRep` removes redundant/highly-similar genomes across **every** assembly's
refined bins together, producing one final MAG set for the whole project.
Unlike every step above, there's no meaningful "just `sample1`" version of
this one — dereplication is inherently a cross-sample comparison, not a
per-sample operation.

```bash
bash run_Kelvin.sh results/assemble/drep/dereplicated_genomes.fa.gz
```

Or, to run the entire path above (Steps 2-5) in one command from a clean
project:

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

Everything from here on consumes the dereplicated MAG set from Step 5. Like
Step 5, most of this module operates on the **whole MAG set at once** —
GTDB-Tk, CheckM2, QUAST, eggNOG, PhyloPhlAn, and the non-per-assembly `Bakta`
rule all take the entire dereplicated set as their input, with no per-sample
wildcard at all, so there's no "just `sample1`" version of these either.
`DRAM` (the per-assembly variant), the per-assembly `Bakta` rule, and
`ProteinOrtho` (built from the per-assembly Bakta outputs) are the exception
— those genuinely run per-assembly, so an aside is shown for them.

Organised by what you asked for:

**Taxonomy** — `GTDB-Tk` classifies the whole MAG set (no per-sample variant):

```bash
bash run_Kelvin.sh mag_annotate__gtdbtk
```

**Quality control** — `CheckM2` estimates genome completeness/contamination
per MAG; `QUAST` reports assembly-quality statistics. Both cover the whole
MAG set at once (no per-sample variant):

```bash
bash run_Kelvin.sh mag_annotate__checkm2
bash run_Kelvin.sh mag_annotate__quast
```

**Functional annotation** — `DRAM`, `eggNOG-mapper`, `CAMPER`, `Bakta`,
`ProteinOrtho`, and `PhyloPhlAn`. One real cross-tool dependency worth
knowing: `DRAM`'s (whole-set) annotation rule requires GTDB-Tk's taxonomy
output as an input, not just the MAG set — so running `DRAM` on its own
still triggers a real GTDB-Tk classification first if you haven't run it
already; this is normal, not a mistake in what you targeted. `CAMPER` in
turn depends on that same whole-set `DRAM` output.

```bash
bash run_Kelvin.sh mag_annotate__dram_mags     # per-assembly DRAM run, every assembly
bash run_Kelvin.sh mag_annotate__eggnog        # whole MAG set, no per-sample variant
bash run_Kelvin.sh mag_annotate__camper        # whole MAG set, no per-sample variant
bash run_Kelvin.sh mag_annotate__bakta_mags    # per-assembly Bakta run, every assembly
bash run_Kelvin.sh mag_annotate__proteinortho  # built from every assembly's Bakta output
bash run_Kelvin.sh mag_annotate__phylophlan    # whole MAG set, no per-sample variant
```

*Aside — just `sample1`, for the genuinely per-assembly ones:*

```bash
bash run_Kelvin.sh results/mag_annotate/dram_mags/sample1/genome_stats.tsv
bash run_Kelvin.sh results/mag_annotate/bakta_mags/bakta_sample1.faa
```

(`proteinortho` compares Bakta output *across* assemblies, so like Step 5's
dRep, it doesn't have a meaningful single-sample form either — running it
for `sample1` alone would need every other assembly's Bakta output to be
uninteresting to compare against, which defeats the point.)

Or, all of the above at once — every tool in this module, for every MAG:

```bash
bash run_Kelvin.sh mag_annotate
```

**Checking progress**: `bash check_progress_kelvin.sh`, same as every other
step — with this many independent tools potentially running at once, this is
the easiest way to see everything together rather than checking each one.

**Output**: `results/mag_annotate/`, one subfolder per tool (`gtdbtk/`,
`checkm2/`, `quast/`, `dram/`, `dram_mags/`, `eggnog/`, `camper/`, `bakta/`,
`bakta_mags/`, `proteinortho/`, `phylophlan/`).

## Run everything in one command

Every step above — preprocessing through MAG annotation/taxonomy/quality —
is really just one dependency chain. Targeting the furthest-downstream output
pulls in everything upstream of it automatically, for every sample in the
project:

```bash
bash run_Kelvin.sh mag_annotate
```

**Does grouping still apply when you invoke it this way, rather than one step
at a time?** Yes — confirmed directly, not assumed: a real dry run
(`bash run_Kelvin.sh -n mag_annotate`) shows `Group job magscot_<assembly>`
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
