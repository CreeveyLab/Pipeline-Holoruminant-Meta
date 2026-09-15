#!/usr/bin/env bash
set -euo pipefail

# Scaffold a new holor-pipeline-fork project directory on Kelvin2: copies
# config/, points pipeline_folder at this fork, wires up the central
# resources store, detects samples (or reuses an existing samples.tsv),
# generates a run wrapper, and self-checks with a dry run before declaring
# success. Automates what was previously done by hand (see the project's
# CLAUDE.md, Section 5b / 6 step 8) -- mirrors the manual steps documented in
# docs/02-Installation.md / docs/03-Setup.md, adapted for Kelvin and this
# fork's now-central resource store.
#
# Usage:
#   bootstrap_project.sh <project_dir> \
#     [--reads-dir DIR]            # auto-detect samples from *_R1_*/*_R2_*.fastq.gz
#     [--samples-tsv FILE]         # reuse an existing samples.tsv instead
#     [--sample-id-delimiter CHAR] # default '-'; the one real filename seen so
#                                  # far (37131-R-wk35-LandM_..._R1_001.fastq.gz)
#                                  # needs sample_id=37131, i.e. split on '-',
#                                  # NOT '_' like workflow/scripts/createSampleSheet.sh
#                                  # defaults to -- override if your lab's real
#                                  # naming convention differs.
#     [--resources PATH]           # default: the central Holoruminant store
#
# Exactly one of --reads-dir / --samples-tsv is required.

PIPELINE_FOLDER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESOURCES_PATH="/mnt/scratch2/igfs-databases/HoloR-MetaG-pipeline-resources"
SAMPLE_ID_DELIM="-"
READS_DIR=""
SAMPLES_TSV=""
PROJECT_DIR=""

usage() {
  echo "Usage: $0 <project_dir> [--reads-dir DIR | --samples-tsv FILE] [--sample-id-delimiter CHAR] [--resources PATH]" >&2
  exit 1
}

[[ $# -ge 1 ]] || usage
PROJECT_DIR="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reads-dir) READS_DIR="$2"; shift 2 ;;
    --samples-tsv) SAMPLES_TSV="$2"; shift 2 ;;
    --sample-id-delimiter) SAMPLE_ID_DELIM="$2"; shift 2 ;;
    --resources) RESOURCES_PATH="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

if [[ -z "$READS_DIR" && -z "$SAMPLES_TSV" ]]; then
  echo "ERROR: must supply either --reads-dir or --samples-tsv" >&2
  usage
fi
if [[ -n "$READS_DIR" && -n "$SAMPLES_TSV" ]]; then
  echo "ERROR: supply only one of --reads-dir or --samples-tsv, not both" >&2
  usage
fi

# Refuse to clobber an existing, non-empty project directory -- don't
# silently overwrite someone else's in-progress work.
if [[ -e "$PROJECT_DIR" && -n "$(ls -A "$PROJECT_DIR" 2>/dev/null)" ]]; then
  echo "ERROR: $PROJECT_DIR already exists and is not empty -- refusing to overwrite." >&2
  echo "If you meant to re-bootstrap, move it aside first." >&2
  exit 1
fi

echo "Bootstrapping project at : $PROJECT_DIR"
echo "Pipeline folder          : $PIPELINE_FOLDER"
echo "Resources                : $RESOURCES_PATH"

mkdir -p "$PROJECT_DIR"/{config,reads,tmp,slurm_out}

# Copy config/ wholesale -- same pattern docs/02-Installation.md documents
# ("cp -r config $PROJECTFOLDER"), just sourced from this fork.
cp -r "$PIPELINE_FOLDER"/config/. "$PROJECT_DIR"/config/

# Point pipeline_folder at this fork (the checked-in default is the
# upstream author's own path and doesn't exist on Kelvin).
sed -i "s|^pipeline_folder:.*|pipeline_folder: \"$PIPELINE_FOLDER/\"|" "$PROJECT_DIR/config/config.yaml"

if [[ -n "$SAMPLES_TSV" ]]; then
  cp "$SAMPLES_TSV" "$PROJECT_DIR/config/samples.tsv"
  awk -F'\t' 'NR>1 && $1 !~ /^#/ {print $3; print $4}' "$SAMPLES_TSV" | sort -u | while read -r relpath; do
    [[ -z "$relpath" ]] && continue
    fname="$(basename "$relpath")"
    src="$(dirname "$SAMPLES_TSV")/$relpath"
    if [[ -f "$src" ]]; then
      ln -sf "$(cd "$(dirname "$src")" && pwd)/$fname" "$PROJECT_DIR/reads/$fname"
    else
      echo "WARNING: could not locate $relpath (referenced in $SAMPLES_TSV) to symlink" >&2
    fi
  done
else
  echo "Detecting samples in $READS_DIR (sample_id = text before first '$SAMPLE_ID_DELIM')..."
  out="$PROJECT_DIR/config/samples.tsv"
  fwd_adapter="AGATCGGAAGAGCACACGTCTGAACTCCAGTCA"
  rev_adapter="AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT"
  printf "sample_id\tlibrary_id\tforward_filename\treverse_filename\tforward_adapter\treverse_adapter\tassembly_ids\n" > "$out"
  found=0
  reads_dir_abs="$(cd "$READS_DIR" && pwd)"
  for fwd in "$reads_dir_abs"/*_R1_*.fastq.gz; do
    [[ -f "$fwd" ]] || continue
    found=1
    fname="$(basename "$fwd")"
    rev_name="${fname/_R1_/_R2_}"
    rev="$reads_dir_abs/$rev_name"
    if [[ ! -f "$rev" ]]; then
      echo "WARNING: no reverse mate for $fname (expected $rev_name) -- skipping" >&2
      continue
    fi
    sample_id="${fname%%"${SAMPLE_ID_DELIM}"*}"
    ln -sf "$reads_dir_abs/$fname" "$PROJECT_DIR/reads/$fname"
    ln -sf "$reads_dir_abs/$rev_name" "$PROJECT_DIR/reads/$rev_name"
    printf "%s\tlib1\treads/%s\treads/%s\t%s\t%s\t%s\n" \
      "$sample_id" "$fname" "$rev_name" "$fwd_adapter" "$rev_adapter" "$sample_id" >> "$out"
    echo "  found sample: $sample_id ($fname)"
  done
  if [[ "$found" -eq 0 ]]; then
    echo "ERROR: no *_R1_*.fastq.gz files found in $READS_DIR" >&2
    exit 1
  fi
fi

# Central resources store (read-only reference genomes + tool databases,
# shared across every project -- see CLAUDE.md Section 6 step 1).
ln -s "$RESOURCES_PATH" "$PROJECT_DIR/resources"

# Run wrapper, generated from this fork's own validated run_Kelvin.sh
# (same Apptainer bind-mount list, same Kelvin profile wiring).
sed \
  -e "s|^projectFolder=.*|projectFolder=\"$PROJECT_DIR\"|" \
  -e "s|^pipelineFolder=.*|pipelineFolder=\"$PIPELINE_FOLDER\"|" \
  "$PIPELINE_FOLDER/run_Kelvin.sh" > "$PROJECT_DIR/run_Kelvin.sh"
chmod +x "$PROJECT_DIR/run_Kelvin.sh"

echo "Project scaffolded. Running a dry-run self-check..."

cd "$PROJECT_DIR"
if command -v snakemake >/dev/null 2>&1; then
  SNAKEMAKE_BIN=snakemake
elif [[ -n "${SNAKEMAKEENV:-}" ]]; then
  SNAKEMAKE_BIN="$SNAKEMAKEENV/bin/snakemake"
else
  echo "WARNING: snakemake not found on PATH and SNAKEMAKEENV not set -- skipping self-check." >&2
  echo "Load snakemake (e.g. 'module load snakemake/9.9.0') and dry-run manually:" >&2
  echo "  cd $PROJECT_DIR && snakemake -n -s $PIPELINE_FOLDER/workflow/Snakefile --configfile config/config.yaml --profile config/profiles/Kelvin" >&2
  exit 0
fi

# Target just the first sample's reads__link_run output, not the default
# "all" -- "all" needs every module's final output (assemble, mag_annotate,
# read_annotate...), which no fresh project has data for yet and would fail
# for reasons unrelated to whether THIS project's config/samples.tsv is
# actually valid (confirmed directly this session: an unscoped -n dry run
# tries to resolve unrelated branches like read_annotate's sylph database).
first_sample="$(awk -F'\t' 'NR==2{print $1"."$2; exit}' config/samples.tsv)"
if [[ -z "$first_sample" ]]; then
  echo "ERROR: could not read a sample from config/samples.tsv for the self-check" >&2
  exit 1
fi
self_check_target="results/reads/${first_sample}_1.fq.gz"

if "$SNAKEMAKE_BIN" -n \
    -s "$PIPELINE_FOLDER/workflow/Snakefile" \
    --configfile config/config.yaml \
    --profile config/profiles/Kelvin \
    "$self_check_target" \
    > self_check.log 2>&1; then
  echo "Self-check passed: project DAG resolves cleanly."
  echo "Ready. Submit with: cd $PROJECT_DIR && ./run_Kelvin.sh <target>"
else
  echo "ERROR: dry-run self-check failed. See $PROJECT_DIR/self_check.log" >&2
  tail -30 self_check.log >&2
  exit 1
fi
