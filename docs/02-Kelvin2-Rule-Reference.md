# Kelvin2 rule name reference

`bash run_Kelvin.sh <target>` requires an **exact** match — either an output
file path, or a rule name spelled exactly as it appears in `workflow/rules/`.
There's no fuzzy or partial-name matching: `bash run_Kelvin.sh bowtie` does
not resolve to anything. Fuzzy matching wouldn't even help, since
**"bowtie2" alone is ambiguous** — six valid rule names cover it across
three modules:

| Rule name | Module | What it runs |
|---|---|---|
| `preprocess__bowtie2` | Preprocess | Every host-decontamination bowtie2 step (build + map + extract), every sample |
| `preprocess__bowtie2__extract_nonhost` | Preprocess | Just the non-host extraction step, every sample |
| `assemble__bowtie2` | Assemble | Map every sample to every assembly it belongs to (for binning coverage) |
| `assemble__bowtie2__build` | Assemble | Index every assembly for bowtie2 |
| `quantify__bowtie2` | Quantify | Align every sample to the dereplicated genome catalogue |
| `quantify__bowtie2__build` | Quantify | Index the dereplicated genome catalogue |

Use the tables below to find the exact string to type.

## Why there's no fuzzy matching

Snakemake targets are always **files**. A rule name is shorthand for "the
file(s) this rule produces" — see
[00-Kelvin2-Quickstart.md](00-Kelvin2-Quickstart.md), Section 5. Two
constraints follow from that:

- **Only wildcard-free rules can be targeted by bare name.** Most tool rules
  are wildcarded (one instance per sample/assembly, e.g.
  `preprocess__fastp__run`) — targeting one directly fails with
  `WorkflowError: Target rules may not contain wildcards`. Every module
  defines a wildcard-free **aggregator** rule instead (e.g. `preprocess__fastp`)
  that lists every instance as its `input:` — that's what you target. The
  tables below list only these, confirmed against `--list-target-rules`.
- **No single file represents "a whole module" or "a whole tool."** The
  aggregator rule name is the only thing that stands in for "all of this at
  once" — hence targeting by rule name instead of an output path.

To target a specific file, sample, or assembly instead, see
`workflow/rules/folders.smk` and
[00-Kelvin2-Quickstart.md](00-Kelvin2-Quickstart.md) Section 5, or run
`bash run_Kelvin.sh -n <rule-name>` to print every file the aggregator
would touch.

---

## Reads and reference

| Tool / step | Rule name | What it does |
|---|---|---|
| Link raw reads | `reads__link` | Symlink every sample's raw FASTQs to their pipeline-facing names |
| FastQC (raw reads) | `reads__fastqc` | QC report for every raw FASTQ |
| Everything above | `reads` | Both of the above |
| Host reference prep | `reference__hosts` | Recompress/index every configured host reference genome |
| Everything above | `reference` | Same as `reference__hosts` |

## Preprocess

| Tool / step | Rule name | What it does |
|---|---|---|
| fastp | `preprocess__fastp` | Adapter/quality trimming, every sample |
| FastQC (post-fastp) | `preprocess__fastqc__fastp` | QC report after fastp, every sample |
| FastQC (post-decontamination) | `preprocess__fastqc__nonhost` | QC report after host removal, every sample |
| Both FastQC steps | `preprocess__fastqc` | Both of the above |
| bowtie2 (host decontamination) | `preprocess__bowtie2` | Build + map + extract for every configured host, every sample |
| bowtie2 (non-host extraction only) | `preprocess__bowtie2__extract_nonhost` | Just the extract-to-FASTQ step |
| samtools stats | `preprocess__samtools` | CRAM stats for every sample |
| Everything above | `preprocess` | The whole module, every sample |

## Read Annotate

| Tool | Rule name | What it does |
|---|---|---|
| Kraken2 | `read_annotate__kraken2` | Taxonomic classification, every sample, every configured database |
| Krona | `read_annotate__krona` | Krona plots from the Kraken2 output |
| Diamond | `read_annotate__diamond` | Protein-level homology search, every sample |
| HumanN3 | `read_annotate__humann` | Functional profiling, every sample |
| MetaPhlAn | `read_annotate__metaphlan` | Taxonomic profiling, every sample |
| Nonpareil | `read_annotate__nonpareil` | Coverage/diversity estimation, every sample |
| PhyloFlash | `read_annotate__phyloflash` | 16S/18S profiling, every sample |
| SingleM | `read_annotate__singlem` | Marker-gene profiling, every sample |
| Sylph | `read_annotate__sylph` | Taxonomic profiling via sketching, every sample |
| NCycDB | `read_annotate__ncyc` | Nitrogen-cycle gene annotation, every sample |
| Everything above except NCycDB | `read_annotate` | The whole module (NCycDB is intentionally separate, see below) |
| NCycDB (separately) | `read_annotate_extra` | Same as `read_annotate__ncyc` |

## Assemble

| Tool | Rule name | What it does |
|---|---|---|
| MEGAHIT | `assemble__megahit` | Assembly, every sample (if `assembler: megahit` in config) |
| metaSPAdes | `assemble__metaspades` | Assembly, every sample (if `assembler: metaspades` in config) |
| bowtie2 build (index assemblies) | `assemble__bowtie2__build` | Index every assembly |
| bowtie2 map (coverage) | `assemble__bowtie2` | Map every sample to every assembly it belongs to |
| CONCOCT | `assemble__concoct` | Binning, every assembly |
| MaxBin2 | `assemble__maxbin2` | Binning, every assembly |
| MetaBAT2 | `assemble__metabat2` | Binning, every assembly |
| MAGScoT | `assemble__magscot` | Bin refinement/scoring, every assembly |
| dRep (separate bins) | `assemble__drep__separate_bins` | Prep step before dereplication |
| dRep (dereplicate) | `assemble__drep__run` | The actual dereplication run |
| dRep (join genomes) | `assemble__drep__join_genomes` | Concatenate the dereplicated genome set |
| Everything above | `assemble__drep` (dRep steps) or `assemble` (whole module) | See description |

## Contig Annotate

| Tool | Rule name | What it does |
|---|---|---|
| Prodigal | `contig_annotate__prodigal` | Gene prediction, every assembly |
| eggNOG | `contig_annotate__eggnog` | Functional annotation, every assembly |
| eggNOG7 | `contig_annotate__eggnog7` | Functional annotation (v7 annotator), every assembly |
| CAMPER | `contig_annotate__camper` | Carbohydrate/pathway annotation, every assembly |
| HMMER (HydDB) | `contig_annotate__hmmer` | Hydrogenase gene search, every assembly |
| Diamond (contig proteins) | `contig_annotate__diamond` | Protein-level homology search on predicted genes |
| featureCounts | `contig_annotate__featurecounts` | Read-count quantification per predicted gene |
| NCycDB | `contig_annotate__ncyc` | Nitrogen-cycle gene annotation, every assembly |
| Everything above except NCycDB | `contig_annotate` | The whole module |
| NCycDB (separately) | `contig_annotate_extra` | Same as `contig_annotate__ncyc` |

## MAG Annotate

| Tool | Rule name | What it does |
|---|---|---|
| GTDB-Tk | `mag_annotate__gtdbtk` | Taxonomic classification of dereplicated genomes |
| DRAM (genome-level) | `mag_annotate__dram` | Functional annotation + distillation, whole dereplicated set |
| DRAM (per-MAG) | `mag_annotate__dram_mags` | Same, but run per sample-wise MAG |
| CheckM2 | `mag_annotate__checkm2` | Genome completeness/contamination |
| QUAST | `mag_annotate__quast` | Assembly quality stats, per dereplicated MAG |
| Bakta (dereplicated set) | `mag_annotate__bakta` | Genome annotation, whole dereplicated set |
| Bakta (per-MAG) | `mag_annotate__bakta_mags` | Same, per sample-wise MAG |
| eggNOG | `mag_annotate__eggnog` | Functional annotation, dereplicated genomes |
| CAMPER | `mag_annotate__camper` | Carbohydrate/pathway annotation, dereplicated genomes |
| PhyloPhlAn | `mag_annotate__phylophlan` | Phylogenetic placement |
| Proteinortho | `mag_annotate__proteinortho` | Ortholog clustering across Bakta outputs |
| Everything above | `mag_annotate` | The whole module |

## Quantify

| Tool | Rule name | What it does |
|---|---|---|
| bowtie2 build | `quantify__bowtie2__build` | Index the dereplicated genome catalogue |
| bowtie2 map | `quantify__bowtie2` | Align every sample to it |
| CoverM (genome) | `quantify__coverm__genome` | Per-genome abundance, every method |
| CoverM (contig) | `quantify__coverm__contig` | Per-contig abundance, every method |
| Both CoverM steps | `quantify__coverm` | Both of the above |
| samtools stats | `quantify__samtools` | CRAM stats for every sample |
| Everything above | `quantify` | The whole module |

## Report

The report module is under active development upstream and has a naming
quirk: every per-module report has **two** parallel rule names, e.g. both
`report__assemble` and `report_assemble` exist (single vs. double underscore)
and produce the same thing. Either works; pick one. `report` runs everything.

---

*Left out of the tables above:* `all` (the entire pipeline — same as no
target) and `test_error` (a developer-only rule under `workflow/rules/devel/`
that deliberately throws, for testing error handling — not for users).

Generated via Snakemake's own `snakemake --list-target-rules` (which already
excludes wildcarded, non-targetable rules) — regenerate the same way after
adding or renaming a rule:

```bash
cd <your-project-dir>
snakemake -s <pipeline-folder>/workflow/Snakefile \
    --configfile config/config.yaml \
    --profile config/profiles/Kelvin \
    --executor dryrun \
    --list-target-rules
```
