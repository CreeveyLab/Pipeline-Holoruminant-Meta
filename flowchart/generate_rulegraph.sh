#!/usr/bin/env bash
set -euo pipefail

# Regenerates flowchart/flowchart.png directly from this fork's actual current
# rule files, using Snakemake's own --rulegraph (piped through graphviz's
# `dot`) instead of the old hand-maintained flowchart/flowchart.R. Advantage:
# this always reflects the real current rule graph and can't drift out of
# sync the way a hand-drawn diagram can. Downside: it shows raw rule names
# (mag_annotate__dram_mag__distill) rather than friendly "tool name, version"
# labels -- flowchart.R's style, if you want that back, needs a working R
# install with DiagrammeR/DiagrammeRsvg/rsvg, which is NOT currently
# available anywhere on Kelvin2 (every r-base conda env found is missing
# shared libs -- libicuuc/libicui18n/libreadline/libbz2/libiconv -- checked
# 2026-09-20).
#
# Real gotchas hit building this, all handled below:
#
# 1. Must run from inside a real project directory (not this pipeline repo).
#    config.yaml's `sample-file: "config/samples.tsv"` is a relative path,
#    resolved against the CURRENT WORKING DIRECTORY at invocation -- run
#    from the pipeline repo and it silently picks up this repo's own
#    placeholder config/samples.tsv (sample ERR2019410, no real reads)
#    instead of the project's real one.
#
# 2. The project's config/profiles/Kelvin profile sets --executor slurm,
#    which needs snakemake-executor-plugin-slurm -- not installed in the
#    snakemake_8.20.1 conda env used here. Override with --executor dryrun
#    (rulegraph never actually submits anything, so this is safe and
#    sufficient).
#
# 3. This pipeline's own helper code (get_escalation_order, __functions__.smk)
#    prints [DEBUG] lines straight to stdout, not stderr -- these land mixed
#    in with the actual `digraph {...}` output and break `dot`'s parser.
#    Stripped below with `sed -n '/^digraph/,$p'`.
#
# 4. --rulegraph in this Snakemake version still fully resolves the concrete
#    DAG (it is not a purely abstract rule-shape graph) -- targeting the
#    default "all" rule fails with MissingInputException on any database
#    genuinely missing from the central store (confirmed missing as of
#    2026-09-20: resources/databases/sylph/gtdb-r220-c200-dbv1.syldb,
#    resources/databases/diamond/hyddb.20251125.dmnd -- used by
#    read_annotate__sylph and contig_annotate__diamond/hmmer respectively).
#    Worked around by targeting every module's umbrella rule EXCEPT those
#    still-missing branches individually. Revisit this target list once
#    those databases are actually populated (see CLAUDE.md).
#
# Usage: run from a real, already-bootstrapped project directory:
#   /path/to/holor-pipeline-fork/flowchart/generate_rulegraph.sh

PIPELINE_FOLDER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PATH="/mnt/scratch2/igfs-anaconda/conda-envs/snakemake_8.20.1/bin:$PATH"

TARGETS="reads reference preprocess assemble mag_annotate quantify \
contig_annotate__camper contig_annotate__eggnog contig_annotate__eggnog7 \
contig_annotate__prodigal read_annotate__diamond read_annotate__kraken2 \
read_annotate__krona read_annotate__humann read_annotate__metaphlan \
read_annotate__nonpareil read_annotate__phyloflash read_annotate__singlem"

RAW_OUT="$(mktemp)"
trap 'rm -f "$RAW_OUT"' EXIT

snakemake -s "$PIPELINE_FOLDER/workflow/Snakefile" \
    --configfile config/config.yaml \
    --profile config/profiles/Kelvin \
    --executor dryrun \
    --rulegraph $TARGETS > "$RAW_OUT"

sed -n '/^digraph/,$p' "$RAW_OUT" | dot -Tpng > "$PIPELINE_FOLDER/flowchart/flowchart.png"

echo "Wrote $PIPELINE_FOLDER/flowchart/flowchart.png"
