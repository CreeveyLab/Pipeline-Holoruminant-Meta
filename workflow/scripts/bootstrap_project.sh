#!/usr/bin/env bash
set -euo pipefail

# Scaffold a new holor-pipeline-fork project directory on Kelvin2: copies
# config/, points pipeline_folder at this fork, wires up the central
# resources store, detects samples (or reuses an existing samples.tsv),
# generates a run wrapper, and self-checks with a dry run before declaring
# success. Automates what was previously done by hand, mirroring the manual
# steps documented in docs/02-Installation.md / docs/03-Setup.md, adapted
# for Kelvin and this fork's central resource store.
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
#     [--sample-id-field N]        # default 1 (1-indexed). Real bug found by
#                                  # Lucy 2026-09-28: field 1 is only correct
#                                  # if the FIRST delimiter-separated chunk is
#                                  # what varies per sample. Her real filenames
#                                  # (12223_D10T1R1_S53_R1_001.fastq.gz, '_'
#                                  # delimiter) share "12223" as a project
#                                  # number in field 1 -- every sample -- and
#                                  # need field 2 (D10T1R1) instead. Using
#                                  # field 1 there silently collapsed every
#                                  # sample into one (same sample_id for all).
#     [--assembly-strip-regex RE] # optional. Strips RE (sed -E, applied to
#                                  # the derived sample_id) to get assembly_id
#                                  # -- lets replicates of the same biological
#                                  # sample share one assembly while keeping
#                                  # distinct sample_id rows. Lucy's example:
#                                  # 'R[0-9]+$' strips a trailing replicate
#                                  # marker (R1/R2/...) so D10T1R1/D10T1R2
#                                  # co-assemble as D10T1.
#     [--exclude-regex RE]         # optional. Skip any sample whose derived
#                                  # sample_id matches RE (bash [[ =~ ]]) --
#                                  # e.g. '^NTC$' to drop no-template-control
#                                  # samples that shouldn't be assembled.
#     [--cleaned-reads-dir DIR --cleaned-reads-stage {fastp,decontaminated}]
#                                  # Alternative to --reads-dir, for reads
#                                  # that have already been processed
#                                  # elsewhere. Same *_R1_*/*_R2_* detection
#                                  # (honours --sample-id-delimiter/-field/
#                                  # --assembly-strip-regex/--exclude-regex)
#                                  # but symlinks into the pipeline's OWN
#                                  # intermediate path instead of reads/, so
#                                  # reads__link_run and (for "decontaminated")
#                                  # fastp + host decontamination never run.
#                                  # --cleaned-reads-stage is required, not
#                                  # defaulted -- the two stages feed
#                                  # genuinely different consumers: kraken2
#                                  # alone reads "fastp" (pre-decontamination,
#                                  # deliberately -- see its own rule
#                                  # docstring); every other read_annotate
#                                  # tool, and assemble, reads
#                                  # "decontaminated". Mutually exclusive
#                                  # with --reads-dir/--samples-tsv.
#     [--provided-assembly DIR]    # Already have an assembly? Sets
#                                  # `assembler: "provided"` in the generated
#                                  # config.yaml (an existing, real mechanism
#                                  # -- every assembly-consuming rule already
#                                  # branches on config["assembler"], falling
#                                  # through to results/assemble/<name>/ for
#                                  # any value other than metaspades/megahit).
#                                  # Expects one <assembly_id>.fa.gz per
#                                  # assembly_id referenced in samples.tsv,
#                                  # named exactly that -- requires samples.tsv
#                                  # to already exist (from one of the flags
#                                  # above), since that's what defines which
#                                  # assembly_ids are expected.
#     [--provided-alignments DIR [--provided-alignments-format {bam,cram}]]
#                                  # Already have per-sample alignments
#                                  # against that assembly too? Requires
#                                  # --provided-assembly. Expects one
#                                  # <assembly_id>.<sample_id>.<library_id>.<ext>
#                                  # per (assembly, sample, library) triplet
#                                  # in samples.tsv. Format defaults to
#                                  # whatever config/params.yaml's
#                                  # assemble: samtools: out_type already
#                                  # says (this is a pipeline-wide constant,
#                                  # not overridable per-rule, so a mismatch
#                                  # is a hard error, not silently rewritten).
#                                  # Builds a missing .bai/.crai via `samtools
#                                  # index` if samtools is on PATH; otherwise
#                                  # warns and leaves it for you to build.
#     [--resources PATH]           # default: the central Holoruminant store
#     [--verify]                   # after the dry-run self-check passes, also
#                                  # submit one real, cheap SLURM job (the
#                                  # first sample's reads__link_run) and wait
#                                  # for it to finish. Opt-in, not the
#                                  # default: it's the only way to actually
#                                  # exercise the Apptainer container +
#                                  # bind-mount path (a dry run never touches
#                                  # either -- see docs/00-Kelvin2-Quickstart.md),
#                                  # but costs a real queue-wait, which a user
#                                  # bootstrapping their Nth project doesn't
#                                  # need paying again. Worth it once, for a
#                                  # brand new account/project, not routinely.
#
# Exactly one of --reads-dir / --samples-tsv / --cleaned-reads-dir is required.

PIPELINE_FOLDER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESOURCES_PATH="/mnt/scratch2/igfs-databases/HoloR-MetaG-pipeline-resources"
SAMPLE_ID_DELIM="-"
SAMPLE_ID_FIELD=1
ASSEMBLY_STRIP_REGEX=""
EXCLUDE_REGEX=""
READS_DIR=""
SAMPLES_TSV=""
CLEANED_READS_DIR=""
CLEANED_READS_STAGE=""
PROVIDED_ASSEMBLY_DIR=""
PROVIDED_ALIGNMENTS_DIR=""
PROVIDED_ALIGNMENTS_FORMAT=""
PROJECT_DIR=""
VERIFY=0

usage() {
  echo "Usage: $0 <project_dir> [--reads-dir DIR | --samples-tsv FILE | --cleaned-reads-dir DIR --cleaned-reads-stage {fastp,decontaminated}] [--sample-id-delimiter CHAR] [--sample-id-field N] [--assembly-strip-regex RE] [--exclude-regex RE] [--provided-assembly DIR] [--provided-alignments DIR [--provided-alignments-format {bam,cram}]] [--resources PATH] [--verify]" >&2
  exit 1
}

[[ $# -ge 1 ]] || usage
PROJECT_DIR="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reads-dir) READS_DIR="$2"; shift 2 ;;
    --samples-tsv) SAMPLES_TSV="$2"; shift 2 ;;
    --cleaned-reads-dir) CLEANED_READS_DIR="$2"; shift 2 ;;
    --cleaned-reads-stage) CLEANED_READS_STAGE="$2"; shift 2 ;;
    --sample-id-delimiter) SAMPLE_ID_DELIM="$2"; shift 2 ;;
    --sample-id-field) SAMPLE_ID_FIELD="$2"; shift 2 ;;
    --assembly-strip-regex) ASSEMBLY_STRIP_REGEX="$2"; shift 2 ;;
    --exclude-regex) EXCLUDE_REGEX="$2"; shift 2 ;;
    --provided-assembly) PROVIDED_ASSEMBLY_DIR="$2"; shift 2 ;;
    --provided-alignments) PROVIDED_ALIGNMENTS_DIR="$2"; shift 2 ;;
    --provided-alignments-format) PROVIDED_ALIGNMENTS_FORMAT="$2"; shift 2 ;;
    --resources) RESOURCES_PATH="$2"; shift 2 ;;
    --verify) VERIFY=1; shift ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

READ_SOURCE_COUNT=0
[[ -n "$READS_DIR" ]] && READ_SOURCE_COUNT=$((READ_SOURCE_COUNT + 1))
[[ -n "$SAMPLES_TSV" ]] && READ_SOURCE_COUNT=$((READ_SOURCE_COUNT + 1))
[[ -n "$CLEANED_READS_DIR" ]] && READ_SOURCE_COUNT=$((READ_SOURCE_COUNT + 1))
if [[ "$READ_SOURCE_COUNT" -eq 0 ]]; then
  echo "ERROR: must supply exactly one of --reads-dir, --samples-tsv, or --cleaned-reads-dir" >&2
  usage
fi
if [[ "$READ_SOURCE_COUNT" -gt 1 ]]; then
  echo "ERROR: --reads-dir, --samples-tsv, and --cleaned-reads-dir are mutually exclusive -- pick one" >&2
  usage
fi
if ! [[ "$SAMPLE_ID_FIELD" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --sample-id-field must be a positive integer (got '$SAMPLE_ID_FIELD')" >&2
  exit 1
fi
if [[ -n "$CLEANED_READS_DIR" ]]; then
  if [[ "$CLEANED_READS_STAGE" != "fastp" && "$CLEANED_READS_STAGE" != "decontaminated" ]]; then
    echo "ERROR: --cleaned-reads-dir requires --cleaned-reads-stage fastp|decontaminated" >&2
    echo "  (not defaulted: the two stages feed different, specific consumers -- see usage above)" >&2
    exit 1
  fi
fi
if [[ -n "$PROVIDED_ALIGNMENTS_DIR" && -z "$PROVIDED_ASSEMBLY_DIR" ]]; then
  echo "ERROR: --provided-alignments requires --provided-assembly (alignments are against that assembly)" >&2
  exit 1
fi
if [[ -n "$PROVIDED_ALIGNMENTS_FORMAT" && "$PROVIDED_ALIGNMENTS_FORMAT" != "bam" && "$PROVIDED_ALIGNMENTS_FORMAT" != "cram" ]]; then
  echo "ERROR: --provided-alignments-format must be 'bam' or 'cram' (got '$PROVIDED_ALIGNMENTS_FORMAT')" >&2
  exit 1
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

# Real, on-disk directories the raw reads actually live in -- collected
# below in both branches, then written into config.yaml's raw_reads_dirs:
# so run_Kelvin.sh can bind-mount them automatically. Real bug found
# 2026-09-22: reads/ in the project only holds symlinks; reads__link_run
# runs inside a container and needs the REAL directory bound to actually
# read through them, or it fails -- every new user was hitting this on
# their very first run, since raw reads essentially never live under a
# path this pipeline already binds by default.
RAW_READS_DIRS=()

if [[ -n "$SAMPLES_TSV" ]]; then
  cp "$SAMPLES_TSV" "$PROJECT_DIR/config/samples.tsv"
  # Process substitution (not a pipe) so the loop runs in THIS shell, not a
  # subshell -- a piped `... | while read` would silently lose RAW_READS_DIRS
  # once the loop exits.
  while read -r relpath; do
    [[ -z "$relpath" ]] && continue
    fname="$(basename "$relpath")"
    src="$(dirname "$SAMPLES_TSV")/$relpath"
    if [[ -f "$src" ]]; then
      # Both forms: cd+pwd (logical) keeps any symlink shortcut component
      # (e.g. ~/sharedscratch) as typed; pwd -P (canonical) fully resolves
      # it. reads__link_run's `readlink --canonicalize` ends up accessing
      # the file via the CANONICAL path regardless of which form --reads-dir
      # was given as, so both need to be in BIND_PATHS -- confirmed directly
      # (2026-09-28) that `cd $symlink && pwd` and `pwd -P` are genuinely
      # different strings for a real symlink on this filesystem, and a bind
      # covering only one form doesn't cover the other.
      src_dir_abs="$(cd "$(dirname "$src")" && pwd)"
      src_dir_real="$(cd "$(dirname "$src")" && pwd -P)"
      ln -sf "$src_dir_abs/$fname" "$PROJECT_DIR/reads/$fname"
      RAW_READS_DIRS+=("$src_dir_abs" "$src_dir_real")
    else
      echo "WARNING: could not locate $relpath (referenced in $SAMPLES_TSV) to symlink" >&2
    fi
  done < <(awk -F'\t' 'NR>1 && $1 !~ /^#/ {print $3; print $4}' "$SAMPLES_TSV" | sort -u)
elif [[ -n "$CLEANED_READS_DIR" ]]; then
  # Same *_R1_*/*_R2_* detection as --reads-dir below, but symlinked into
  # the pipeline's own intermediate path (with ITS naming convention,
  # {sample_id}.{library_id}_{1,2}.fq.gz -- not the original filename) so
  # reads__link_run, and for "decontaminated" also fastp + host
  # decontamination, are skipped: Snakemake only cares that an expected
  # output file already exists, not how it got there. forward_filename/
  # reverse_filename/adapter columns are left blank in samples.tsv --
  # confirmed directly (2026-10-10) that workflow/Snakefile's own parsing
  # only ever touches sample_id/library_id/assembly_ids at DAG-build time;
  # the read-path columns are only read inside reads__link_run's own input
  # functions, which this mode never invokes.
  case "$CLEANED_READS_STAGE" in
    fastp) dest_dir="$PROJECT_DIR/results/preprocess/fastp" ;;
    decontaminated) dest_dir="$PROJECT_DIR/results/preprocess/bowtie2/decontaminated_reads" ;;
  esac
  mkdir -p "$dest_dir"
  echo "Detecting already-cleaned samples in $CLEANED_READS_DIR (stage: $CLEANED_READS_STAGE, sample_id = field $SAMPLE_ID_FIELD when split on '$SAMPLE_ID_DELIM')..."
  out="$PROJECT_DIR/config/samples.tsv"
  printf "sample_id\tlibrary_id\tforward_filename\treverse_filename\tforward_adapter\treverse_adapter\tassembly_ids\n" > "$out"
  found=0
  reads_dir_abs="$(cd "$CLEANED_READS_DIR" && pwd)"
  reads_dir_real="$(cd "$CLEANED_READS_DIR" && pwd -P)"
  RAW_READS_DIRS+=("$reads_dir_abs" "$reads_dir_real")
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

    IFS="$SAMPLE_ID_DELIM" read -ra name_parts <<< "$fname"
    if (( ${#name_parts[@]} < 2 )); then
      echo "ERROR: delimiter '$SAMPLE_ID_DELIM' not found in filename '$fname' --" >&2
      echo "  sample_id would become the entire filename. Pass the correct" >&2
      echo "  --sample-id-delimiter for your lab's naming convention." >&2
      exit 1
    fi
    if (( ${#name_parts[@]} < SAMPLE_ID_FIELD )); then
      echo "ERROR: filename '$fname' has only ${#name_parts[@]} '$SAMPLE_ID_DELIM'-separated fields," >&2
      echo "  but --sample-id-field is $SAMPLE_ID_FIELD." >&2
      exit 1
    fi
    sample_id="${name_parts[$((SAMPLE_ID_FIELD - 1))]}"
    if [[ -z "$sample_id" ]]; then
      echo "ERROR: empty sample_id from '$fname' (field $SAMPLE_ID_FIELD)." >&2
      exit 1
    fi
    if [[ -n "$EXCLUDE_REGEX" && "$sample_id" =~ $EXCLUDE_REGEX ]]; then
      echo "  skipping (matches --exclude-regex): $sample_id ($fname)"
      continue
    fi
    if [[ "$sample_id" == *[._]* ]]; then
      echo "WARNING: sample_id '$sample_id' contains '.' or '_', which can make {sample}.{library} wildcards ambiguous." >&2
    fi

    assembly_id="$sample_id"
    if [[ -n "$ASSEMBLY_STRIP_REGEX" ]]; then
      assembly_id="$(sed -E "s#${ASSEMBLY_STRIP_REGEX}##" <<< "$sample_id")"
      if [[ -z "$assembly_id" ]]; then
        echo "ERROR: --assembly-strip-regex reduced '$sample_id' to an empty assembly id." >&2
        exit 1
      fi
    fi

    # library is always lib1 here -- matches the --reads-dir branch's own
    # convention, since nothing in this project's samples.tsv has told us
    # otherwise.
    ln -sf "$reads_dir_abs/$fname" "$dest_dir/${sample_id}.lib1_1.fq.gz"
    ln -sf "$reads_dir_abs/$rev_name" "$dest_dir/${sample_id}.lib1_2.fq.gz"
    printf "%s\tlib1\t\t\t\t\t%s\n" "$sample_id" "$assembly_id" >> "$out"
    echo "  found sample: $sample_id -> assembly $assembly_id ($fname), staged at $CLEANED_READS_STAGE"
  done
  if [[ "$found" -eq 0 ]]; then
    echo "ERROR: no *_R1_*.fastq.gz files found in $CLEANED_READS_DIR" >&2
    exit 1
  fi

  dups="$(tail -n +2 "$out" | cut -f1 | sort | uniq -d)"
  if [[ -n "$dups" ]]; then
    echo "ERROR: duplicate sample_id values in $out:" >&2
    echo "$dups" | head >&2
    echo "  Check --sample-id-delimiter / --sample-id-field." >&2
    exit 1
  fi
  if [[ $(tail -n +2 "$out" | wc -l) -eq 0 ]]; then
    echo "ERROR: all samples were excluded -- $out has no rows." >&2
    exit 1
  fi
else
  echo "Detecting samples in $READS_DIR (sample_id = field $SAMPLE_ID_FIELD when split on '$SAMPLE_ID_DELIM')..."
  out="$PROJECT_DIR/config/samples.tsv"
  fwd_adapter="AGATCGGAAGAGCACACGTCTGAACTCCAGTCA"
  rev_adapter="AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT"
  printf "sample_id\tlibrary_id\tforward_filename\treverse_filename\tforward_adapter\treverse_adapter\tassembly_ids\n" > "$out"
  found=0
  # Both forms recorded for the same reason as the --samples-tsv branch
  # above (see its comment): a symlink shortcut and its canonical target
  # are genuinely different strings, and reads__link_run needs the
  # canonical one bound.
  reads_dir_abs="$(cd "$READS_DIR" && pwd)"
  reads_dir_real="$(cd "$READS_DIR" && pwd -P)"
  RAW_READS_DIRS+=("$reads_dir_abs" "$reads_dir_real")
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

    # Split the filename into fields on the delimiter and pick one (fix
    # by Lucy, 2026-09-28). The old approach, ${fname%%"$DELIM"*}, always
    # took field 1, which for names like 12223_D10T1R1_S53_R1_001.fastq.gz
    # with delimiter '_' gave the same sample_id (the shared project
    # number) for every sample. It also returned the whole filename
    # unchanged if the delimiter never matched at all.
    IFS="$SAMPLE_ID_DELIM" read -ra name_parts <<< "$fname"
    if (( ${#name_parts[@]} < 2 )); then
      echo "ERROR: delimiter '$SAMPLE_ID_DELIM' not found in filename '$fname' --" >&2
      echo "  sample_id would become the entire filename. Pass the correct" >&2
      echo "  --sample-id-delimiter for your lab's naming convention." >&2
      exit 1
    fi
    if (( ${#name_parts[@]} < SAMPLE_ID_FIELD )); then
      echo "ERROR: filename '$fname' has only ${#name_parts[@]} '$SAMPLE_ID_DELIM'-separated fields," >&2
      echo "  but --sample-id-field is $SAMPLE_ID_FIELD." >&2
      exit 1
    fi
    sample_id="${name_parts[$((SAMPLE_ID_FIELD - 1))]}"
    if [[ -z "$sample_id" ]]; then
      echo "ERROR: empty sample_id from '$fname' (field $SAMPLE_ID_FIELD)." >&2
      exit 1
    fi
    if [[ -n "$EXCLUDE_REGEX" && "$sample_id" =~ $EXCLUDE_REGEX ]]; then
      echo "  skipping (matches --exclude-regex): $sample_id ($fname)"
      continue
    fi
    if [[ "$sample_id" == *[._]* ]]; then
      echo "WARNING: sample_id '$sample_id' contains '.' or '_', which can make {sample}.{library} wildcards ambiguous." >&2
    fi

    # assembly_id: same as sample_id unless --assembly-strip-regex is
    # given, in which case samples that reduce to the same string are
    # co-assembled (e.g. stripping a trailing replicate marker so
    # D10T1R1/D10T1R2 share assembly D10T1 while keeping separate
    # sample_id rows).
    assembly_id="$sample_id"
    if [[ -n "$ASSEMBLY_STRIP_REGEX" ]]; then
      assembly_id="$(sed -E "s#${ASSEMBLY_STRIP_REGEX}##" <<< "$sample_id")"
      if [[ -z "$assembly_id" ]]; then
        echo "ERROR: --assembly-strip-regex reduced '$sample_id' to an empty assembly id." >&2
        exit 1
      fi
    fi

    ln -sf "$reads_dir_abs/$fname" "$PROJECT_DIR/reads/$fname"
    ln -sf "$reads_dir_abs/$rev_name" "$PROJECT_DIR/reads/$rev_name"
    printf "%s\tlib1\treads/%s\treads/%s\t%s\t%s\t%s\n" \
      "$sample_id" "$fname" "$rev_name" "$fwd_adapter" "$rev_adapter" "$assembly_id" >> "$out"
    echo "  found sample: $sample_id -> assembly $assembly_id ($fname)"
  done
  if [[ "$found" -eq 0 ]]; then
    echo "ERROR: no *_R1_*.fastq.gz files found in $READS_DIR" >&2
    exit 1
  fi

  # Every row uses library lib1, so sample_id must be unique. Duplicates
  # mean the delimiter/field choice is wrong -- this is exactly the
  # failure mode that motivated --sample-id-field: every sample silently
  # collapsing into one shared sample_id.
  dups="$(tail -n +2 "$out" | cut -f1 | sort | uniq -d)"
  if [[ -n "$dups" ]]; then
    echo "ERROR: duplicate sample_id values in $out:" >&2
    echo "$dups" | head >&2
    echo "  Check --sample-id-delimiter / --sample-id-field." >&2
    exit 1
  fi
  if [[ $(tail -n +2 "$out" | wc -l) -eq 0 ]]; then
    echo "ERROR: all samples were excluded -- $out has no rows." >&2
    exit 1
  fi
fi

# --provided-assembly / --provided-alignments: layered on top of whichever
# read source was used above, since they're about assembly/alignments, not
# reads -- a project can combine, say, --cleaned-reads-dir with
# --provided-assembly if it has both. Both read the assembly_ids this
# project's samples.tsv now has (comma-separated, matching
# workflow/Snakefile's own `assembly_ids.str.split(",")` parsing exactly).
if [[ -n "$PROVIDED_ASSEMBLY_DIR" ]]; then
  mapfile -t ASSEMBLY_IDS < <(
    tail -n +2 "$PROJECT_DIR/config/samples.tsv" | cut -f7 | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sort -u
  )
  if [[ "${#ASSEMBLY_IDS[@]}" -eq 0 ]]; then
    echo "ERROR: --provided-assembly given but samples.tsv has no assembly_ids to match against." >&2
    exit 1
  fi

  echo "Wiring in provided assembly from $PROVIDED_ASSEMBLY_DIR (${#ASSEMBLY_IDS[@]} assembly id(s))..."
  sed -i 's|^assembler:.*|assembler: "provided"  # set by bootstrap_project.sh --provided-assembly|' "$PROJECT_DIR/config/config.yaml"
  provided_dir_abs="$(cd "$PROVIDED_ASSEMBLY_DIR" && pwd)"
  provided_dir_real="$(cd "$PROVIDED_ASSEMBLY_DIR" && pwd -P)"
  RAW_READS_DIRS+=("$provided_dir_abs" "$provided_dir_real")
  mkdir -p "$PROJECT_DIR/results/assemble/provided"

  missing_assemblies=()
  for assembly_id in "${ASSEMBLY_IDS[@]}"; do
    src="$provided_dir_abs/${assembly_id}.fa.gz"
    if [[ ! -f "$src" ]]; then
      missing_assemblies+=("$assembly_id")
      continue
    fi
    # Real gzip magic bytes (1f 8b) -- catches a plain, uncompressed FASTA
    # handed in by mistake before it reaches bowtie2-build/concoct deep in
    # a real SLURM job instead.
    magic="$(head -c2 "$src" | od -An -tx1 | tr -d ' \n')"
    if [[ "$magic" != "1f8b" ]]; then
      echo "ERROR: $src does not look gzip-compressed (expected .fa.gz)." >&2
      exit 1
    fi
    ln -sf "$src" "$PROJECT_DIR/results/assemble/provided/${assembly_id}.fa.gz"
    echo "  wired assembly: $assembly_id"
  done
  if [[ "${#missing_assemblies[@]}" -gt 0 ]]; then
    echo "ERROR: missing <assembly_id>.fa.gz for assembly id(s) referenced in samples.tsv:" >&2
    printf '  %s\n' "${missing_assemblies[@]}" >&2
    echo "  Expected at: $provided_dir_abs/<assembly_id>.fa.gz" >&2
    exit 1
  fi
fi

if [[ -n "$PROVIDED_ALIGNMENTS_DIR" ]]; then
  # ALIGN_EXT is a pipeline-wide constant derived from this one params.yaml
  # value (workflow/rules/assemble/bowtie2.smk: SAMTOOLS_OUTTYPE), not
  # overridable per-rule -- so --provided-alignments-format is validated
  # against it, not just defaulted from it. Real bug found testing this
  # directly (2026-10-10): an earlier version of this script only read
  # params.yaml when --provided-alignments-format was omitted, so an
  # explicit --provided-alignments-format bam against a project whose
  # params.yaml still said out_type: cram silently wired in .bam files
  # that assemble__bowtie2__map's rule (which expects .cram) could never
  # see -- Snakemake just reported the "real" .cram as missing and
  # redid bowtie2__build_run + bowtie2__map from scratch anyway.
  configured_ext="$(grep -E '^[[:space:]]*out_type:' "$PROJECT_DIR/config/params.yaml" | sed -E 's/^[^:]+:[[:space:]]*//; s/[[:space:]]*#.*$//' | tr -d '"' | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$PROVIDED_ALIGNMENTS_FORMAT" ]]; then
    align_ext="$configured_ext"
  else
    align_ext="$PROVIDED_ALIGNMENTS_FORMAT"
    if [[ "$align_ext" != "$configured_ext" ]]; then
      echo "ERROR: --provided-alignments-format $align_ext conflicts with" >&2
      echo "  config/params.yaml's assemble: samtools: out_type: $configured_ext." >&2
      echo "  This is a pipeline-wide constant (workflow/rules/assemble/bowtie2.smk) --" >&2
      echo "  either convert your alignments to $configured_ext, or change out_type in" >&2
      echo "  $PROJECT_DIR/config/params.yaml to $align_ext before bootstrapping." >&2
      exit 1
    fi
  fi
  if [[ "$align_ext" != "bam" && "$align_ext" != "cram" ]]; then
    echo "ERROR: could not determine alignment format (got '$align_ext' from params.yaml's assemble: samtools: out_type)." >&2
    echo "  Pass --provided-alignments-format bam|cram explicitly." >&2
    exit 1
  fi

  echo "Wiring in provided alignments from $PROVIDED_ALIGNMENTS_DIR (format: $align_ext)..."
  align_dir_abs="$(cd "$PROVIDED_ALIGNMENTS_DIR" && pwd)"
  align_dir_real="$(cd "$PROVIDED_ALIGNMENTS_DIR" && pwd -P)"
  RAW_READS_DIRS+=("$align_dir_abs" "$align_dir_real")
  mkdir -p "$PROJECT_DIR/results/assemble/bowtie2" "$PROJECT_DIR/results/assemble/index"

  # assemble__bowtie2__map declares this empty touchfile (its own build
  # step's real output: touch(ASSEMBLE_INDEX / "{assembly_id}")) as a
  # required input -- Snakemake needs it to exist to confirm the provided
  # alignment is up to date, or it schedules bowtie2__build_run (and then
  # bowtie2__map too, even though its real output already exists) to
  # produce it. Real bug caught testing this directly (2026-10-10): without
  # this, a dry run against a provided alignment still proposed re-running
  # the whole build+map chain, defeating the entire point of providing the
  # alignment. --provided-assembly already validated every assembly id in
  # ASSEMBLY_IDS exists, so it's safe to touch one per id here.
  for assembly_id in "${ASSEMBLY_IDS[@]}"; do
    touch "$PROJECT_DIR/results/assemble/index/${assembly_id}"
  done

  have_samtools=0
  if command -v samtools >/dev/null 2>&1; then
    have_samtools=1
  else
    echo "WARNING: samtools not on PATH -- skipping alignment validation and" >&2
    echo "  cannot build a missing .bai/.crai index. Build it yourself before" >&2
    echo "  submitting real jobs if any index is missing (reported below)." >&2
  fi

  missing_alignments=()
  while IFS=$'\t' read -r sample_id library_id assembly_ids_field; do
    [[ -z "$sample_id" ]] && continue
    IFS=',' read -ra row_assemblies <<< "$assembly_ids_field"
    for raw_assembly_id in "${row_assemblies[@]}"; do
      assembly_id="$(sed 's/^ *//;s/ *$//' <<< "$raw_assembly_id")"
      [[ -z "$assembly_id" ]] && continue
      src="$align_dir_abs/${assembly_id}.${sample_id}.${library_id}.${align_ext}"
      if [[ ! -f "$src" ]]; then
        missing_alignments+=("${assembly_id}.${sample_id}.${library_id}.${align_ext}")
        continue
      fi
      dst="$PROJECT_DIR/results/assemble/bowtie2/${assembly_id}.${sample_id}.${library_id}.${align_ext}"
      ln -sf "$src" "$dst"
      if [[ "$have_samtools" -eq 1 ]]; then
        if ! samtools quickcheck "$src" 2>/dev/null; then
          echo "ERROR: samtools quickcheck failed on $src -- looks corrupt or truncated." >&2
          exit 1
        fi
        index_ext=".bai"; [[ "$align_ext" == "cram" ]] && index_ext=".crai"
        if [[ ! -f "${src}${index_ext}" ]]; then
          echo "  building missing index: $(basename "$src")${index_ext}"
          samtools index "$dst"
        else
          ln -sf "${src}${index_ext}" "${dst}${index_ext}"
        fi
      fi
      echo "  wired alignment: ${assembly_id}.${sample_id}.${library_id}.${align_ext}"
    done
  done < <(tail -n +2 "$PROJECT_DIR/config/samples.tsv" | cut -f1,2,7)

  if [[ "${#missing_alignments[@]}" -gt 0 ]]; then
    echo "ERROR: missing alignment file(s) for (assembly, sample, library) triplet(s) in samples.tsv:" >&2
    printf '  %s\n' "${missing_alignments[@]}" >&2
    echo "  Expected at: $align_dir_abs/<assembly_id>.<sample_id>.<library_id>.$align_ext" >&2
    exit 1
  fi
fi

# Record the real reads directory/directories in config.yaml so
# run_Kelvin.sh can bind-mount them automatically (see raw_reads_dirs:'s
# own comment in config/config.yaml for why this is needed at all).
if [[ "${#RAW_READS_DIRS[@]}" -gt 0 ]]; then
  raw_reads_dirs_joined="$(printf "%s\n" "${RAW_READS_DIRS[@]}" | sort -u | paste -sd, -)"
  sed -i "s|^raw_reads_dirs:.*|raw_reads_dirs: \"$raw_reads_dirs_joined\"|" "$PROJECT_DIR/config/config.yaml"
fi

# Central resources store (read-only reference genomes + tool databases,
# shared across every project).
ln -s "$RESOURCES_PATH" "$PROJECT_DIR/resources"

# Run wrapper, generated from this fork's own validated run_Kelvin.sh
# (same Apptainer bind-mount list, same Kelvin profile wiring). Only
# projectFolder needs patching -- run_Kelvin.sh reads pipelineFolder at
# runtime from the project's own config.yaml (pipeline_folder:, patched
# above), not from a static line in this script, so it stays correct even
# if the generated run_Kelvin.sh is later copied or moved elsewhere.
sed \
  -e "s|^projectFolder=.*|projectFolder=\"$PROJECT_DIR\"|" \
  "$PIPELINE_FOLDER/run_Kelvin.sh" > "$PROJECT_DIR/run_Kelvin.sh"
chmod +x "$PROJECT_DIR/run_Kelvin.sh"

# Progress-checking companion (see workflow/scripts/check_progress_kelvin.sh)
# -- same templating approach as run_Kelvin.sh, so `bash check_progress_kelvin.sh`
# works with no arguments from inside the project directory.
sed \
  -e "s|^projectFolder=.*|projectFolder=\"$PROJECT_DIR\"|" \
  "$PIPELINE_FOLDER/workflow/scripts/check_progress_kelvin.sh" > "$PROJECT_DIR/check_progress_kelvin.sh"
chmod +x "$PROJECT_DIR/check_progress_kelvin.sh"

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

# Target just one real, near-term output, not the default "all" -- "all"
# needs every module's final output (assemble, mag_annotate,
# read_annotate...), which no fresh project has data for yet and would fail
# for reasons unrelated to whether THIS project's config/samples.tsv is
# actually valid (confirmed directly this session: an unscoped -n dry run
# tries to resolve unrelated branches like read_annotate's sylph database).
# Which target makes sense depends on which entry point was used -- the
# default (raw reads) target, reads__link_run's own output, means nothing
# once reads/preprocess are being skipped.
first_sample="$(awk -F'\t' 'NR==2{print $1"."$2; exit}' config/samples.tsv)"
if [[ -z "$first_sample" ]]; then
  echo "ERROR: could not read a sample from config/samples.tsv for the self-check" >&2
  exit 1
fi
first_assembly="$(tail -n +2 config/samples.tsv | cut -f7 | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | head -1 || true)"

self_check_target=""
self_check_skip_reason=""
if [[ -n "$PROVIDED_ASSEMBLY_DIR" ]]; then
  if [[ -n "$PROVIDED_ALIGNMENTS_DIR" ]]; then
    # Both assembly and alignments provided -- concoct_run needs only
    # those two (confirmed by reading its own input: block), no external
    # reference database, so it's a real exercise of both drop-ins without
    # dragging in GTDB-Tk/DRAM-scale dependencies a fresh project may not
    # have configured yet.
    self_check_target="results/assemble/concoct/${first_assembly}"
  else
    # Assembly only -- bowtie2-build's own mock output, the cheapest real
    # check that the provided FASTA parses correctly.
    self_check_target="results/assemble/index/${first_assembly}"
  fi
elif [[ -n "$CLEANED_READS_DIR" && "$CLEANED_READS_STAGE" == "decontaminated" ]]; then
  # nonpareil__run needs only the decontaminated forward read (confirmed
  # by reading its input: block) -- no external database, unlike every
  # other decontaminated-reads consumer.
  self_check_target="results/read_annotate/nonpareil/${first_sample}.npa"
elif [[ -n "$CLEANED_READS_DIR" && "$CLEANED_READS_STAGE" == "fastp" ]]; then
  # kraken2 is the only fastp-stage consumer, and it needs a real database
  # configured in features.yaml -- check one actually exists rather than
  # assume, since a fresh project may not have features.yaml's kraken2:
  # block populated yet.
  first_kraken_db="$(grep -A20 '^  kraken2:' config/features.yaml | tail -n +2 | grep -E '^\s{4}[a-zA-Z0-9_]+:' | grep -v '^\s*#' | head -1 | sed -E 's/^\s*([a-zA-Z0-9_]+):.*/\1/' || true)"
  if [[ -n "$first_kraken_db" ]]; then
    self_check_target="results/read_annotate/kraken2/${first_kraken_db}/${first_sample}.report"
  else
    self_check_skip_reason="no kraken2 database configured in config/features.yaml yet (databases: kraken2: block is empty) -- can't self-check the fastp-stage drop-in without one"
  fi
else
  self_check_target="results/reads/${first_sample}_1.fq.gz"
fi

if [[ -n "$self_check_skip_reason" ]]; then
  echo "WARNING: skipping self-check -- $self_check_skip_reason" >&2
  echo "Project scaffolded; dry-run manually once that's sorted:" >&2
  echo "  cd $PROJECT_DIR && snakemake -n -s $PIPELINE_FOLDER/workflow/Snakefile --configfile config/config.yaml --profile config/profiles/Kelvin <target>" >&2
  echo "Ready. Submit with: cd $PROJECT_DIR && ./run_Kelvin.sh <target>"
  exit 0
fi

if "$SNAKEMAKE_BIN" -n \
    -s "$PIPELINE_FOLDER/workflow/Snakefile" \
    --configfile config/config.yaml \
    --profile config/profiles/Kelvin \
    "$self_check_target" \
    > self_check.log 2>&1; then
  echo "Self-check passed: project DAG resolves cleanly."
else
  echo "ERROR: dry-run self-check failed. See $PROJECT_DIR/self_check.log" >&2
  tail -30 self_check.log >&2
  exit 1
fi

# --verify: submit the same target for real (not a dry run) and wait for
# it. A dry run only confirms the DAG resolves and referenced files are
# stat-able -- it never invokes Apptainer, never checks a file's actual
# read permission (stat-able and readable aren't the same thing), and
# never calls sbatch. This is the only way to actually exercise the
# container + bind-mount path and real filesystem write access, both real,
# confirmed failure classes this fork has hit in practice. Opt-in because
# it costs a real queue-wait -- fine once for a new project, an annoyance
# on every bootstrap for someone doing this routinely.
if [[ "$VERIFY" -eq 1 ]]; then
  echo "Verifying with a real job (--verify): submitting $self_check_target..."
  # concoct's own output is directory(...), not a plain file (see
  # assemble/concoct.smk) -- rm -f/-f-test don't apply to it, so check
  # existence with -e (file or directory) and remove with rm -rf.
  rm -rf "$self_check_target"
  ./run_Kelvin.sh "$self_check_target"

  verify_timeout=300  # generous for a trivial rule tiered onto k2-sandbox
                       # (see config/escalation.yaml) -- real queue-wait
                       # there is normally seconds, not minutes. The
                       # provided-assembly/-alignments targets above run
                       # real bowtie2-build/concoct, not a sandbox-tier
                       # rule, so this is less generous for those -- expect
                       # to wait longer, or re-run with a longer manual
                       # check via check_progress_kelvin.sh if it times out.
  waited=0
  while [[ ! -e "$self_check_target" && "$waited" -lt "$verify_timeout" ]]; do
    sleep 5
    waited=$((waited + 5))
  done

  if [[ -e "$self_check_target" ]]; then
    echo "Verify passed: $self_check_target created for real."
  else
    echo "ERROR: verify failed -- $self_check_target was not created within ${verify_timeout}s." >&2
    echo "Check what happened with:" >&2
    echo "  cd $PROJECT_DIR && bash check_progress_kelvin.sh" >&2
    exit 1
  fi
fi

echo "Ready. Submit with: cd $PROJECT_DIR && ./run_Kelvin.sh <target>"
