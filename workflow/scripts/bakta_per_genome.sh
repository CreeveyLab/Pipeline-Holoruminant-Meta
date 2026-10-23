#!/bin/bash
# Usage: ./bakta_per_genome.sh db genomes_dir work_dir total_threads threads_per_genome [bakta options...]
#
# Runs Bakta once per genome (genomes_dir/*.fa.gz), several genomes at a time,
# inside a single job. Each genome's results land in work_dir/<genome>/ named
# <genome>.{tsv,faa,gff3,...}.
#
# Resumable: a genome is only skipped if work_dir/<genome>/.done exists and is
# newer than its input, so a retry after a timeout carries on where the last
# attempt stopped instead of starting over. Folders for genomes no longer in
# genomes_dir are removed. Exits non-zero if any genome failed.

set -euo pipefail
IFS=$'\n\t'

db="$1"
genomes_dir="$2"
work_dir="$3"
total_threads="$4"
threads_per_genome="$5"
shift 5
# Bakta options are plain flags (e.g. --skip-crispr --skip-plot); carried to
# the per-genome workers as one space-separated string
printf -v BAKTA_OPTIONS '%s ' "$@"  # not "$*": IFS above would join with newlines
export BAKTA_OPTIONS

workers=$(( total_threads / threads_per_genome ))
if (( workers < 1 )); then workers=1; fi

mkdir -p "$work_dir"

mapfile -t genomes < <(find "$genomes_dir" -maxdepth 1 -name "*.fa.gz" | sort)
if (( ${#genomes[@]} == 0 )); then
    echo "[ERROR] No *.fa.gz genomes found in $genomes_dir"
    exit 1
fi
echo "[INFO] ${#genomes[@]} genomes, $workers at a time, $threads_per_genome threads each"

# Leftovers from failed genomes in an earlier attempt; those genomes are
# simply redone below
rm -rf "$work_dir"/*.partial "$work_dir"/*.partial.log

# Drop results for genomes that are no longer part of the input set
for dir in "$work_dir"/*/; do
    [[ -d "$dir" ]] || continue
    name=$(basename "$dir")
    [[ -f "$genomes_dir/$name.fa.gz" ]] || { echo "[INFO] Removing stale $name"; rm -rf "$dir"; }
done

annotate_one() {
    local genome="$1"
    local name
    name=$(basename "$genome" .fa.gz)
    local out="$work_dir/$name"
    local -a opts
    IFS=' ' read -ra opts <<< "$BAKTA_OPTIONS"

    if [[ -f "$out/.done" && "$out/.done" -nt "$genome" ]]; then
        echo "[INFO] Skipping $name (already done)"
        return 0
    fi

    rm -rf "$out" "$out.partial"
    if bakta --db "$db" \
             --force \
             --output "$out.partial" \
             --prefix "$name" \
             --threads "$threads_per_genome" \
             "${opts[@]}" \
             "$genome" \
             > "$out.partial.log" 2>&1; then
        mv "$out.partial.log" "$out.partial/$name.bakta.log"
        mv "$out.partial" "$out"
        touch "$out/.done"
        echo "[INFO] Done $name"
    else
        echo "[ERROR] Bakta failed for $name, see $out.partial.log"
        return 1
    fi
}
export -f annotate_one
export db work_dir threads_per_genome

# Failures are counted below rather than aborting the other workers
printf '%s\n' "${genomes[@]}" \
    | xargs -P "$workers" -I{} bash -c 'annotate_one "$1"' _ {} \
    || true

failed=0
for genome in "${genomes[@]}"; do
    name=$(basename "$genome" .fa.gz)
    [[ -f "$work_dir/$name/.done" ]] || { echo "[ERROR] Missing result: $name"; failed=$(( failed + 1 )); }
done

if (( failed > 0 )); then
    echo "[ERROR] $failed of ${#genomes[@]} genomes failed"
    exit 1
fi
echo "[INFO] All ${#genomes[@]} genomes annotated"
