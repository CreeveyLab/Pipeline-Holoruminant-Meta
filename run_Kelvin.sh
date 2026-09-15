#!/usr/bin/env bash

# Kelvin2 launch wrapper for holor-pipeline-fork.
#
# Modeled on run_Snakebite-Holoruminant-MetaG.sh (this repo's generic
# template) plus the validated Apptainer/Singularity bind-mount list from the
# old locally-installed pipeline's Kelvin run script
# (/mnt/scratch2/users/3053301/holor_pipeline_project/run_Pipeline-Holoruminant-meta.sh)
# -- that bind list is real, hard-won knowledge (see CLAUDE.md incident #4:
# a missing bind path surfaces as a misleading "filesystem latency" error, not
# an obvious permissions error), reused here rather than rediscovered.
#
# No --retries/--restart-times override here: every resource-consuming rule
# in workflow/rules/ already declares its own `retries: len(get_escalation_order(...))`,
# which takes precedence over any CLI/profile default and drives per-rule tier
# escalation (config/escalation.yaml) automatically.

# Set the project relevant paths
################################################################################
projectFolder="/mnt/scratch2/users/3053301/holor_pipeline_project"
configFile="${projectFolder}/config/config.yaml"
pipelineFolder="/users/3053301/holor-pipeline-fork"

Profile=$projectFolder/config/profiles/Kelvin

# For use with Apptainer/Singularity, set these variables
################################################################################
export APPTAINER_TMPDIR="${projectFolder}/tmp"
export APPTAINER_CACHEDIR="${projectFolder}/tmp"
export SINGULARITY_TMPDIR="${projectFolder}/tmp"
export SINGULARITY_CACHEDIR="${projectFolder}/tmp"
mkdir -p "$APPTAINER_TMPDIR"
mkdir -p "$SINGULARITY_TMPDIR"

# Helper: read YAML value (simple key: value, no nesting)
################################################################################
read_yaml() {
    local key="$1"
    local file="$2"
    grep -E "^[[:space:]]*${key}:" "$file" \
        | sed -E "s/^[^:]+:[[:space:]]*//" \
        | tr -d '"'
}

metaspades_slots="$(read_yaml metaspades_slots "$configFile")"

if [[ -z "$metaspades_slots" ]]; then
    echo "ERROR: metaspades_slots not defined in $configFile" >&2
    exit 1
fi

echo "config file      : ${configFile}"
echo "Project folder   : ${projectFolder}"
echo "Pipeline folder   : ${pipelineFolder}"

mkdir -p slurm_out
mkdir -p "$projectFolder/tmp"

# Bind-mount list (see header comment). NOTE: still points at
# My_holor_project/resources -- update to
# /mnt/scratch2/igfs-databases/HoloR-MetaG-pipeline-resources/ once the
# reference/database store migration (Section 6 step 1, copy in progress at
# time of writing) is complete and verified.
################################################################################
BIND_PATHS="/sys:/sys,/dev/shm:/dev/shm,/run,/tmp,${projectFolder}/tmp,/mnt/scratch2/igfs-databases/Holoruminant/My_holor_project/resources/,${pipelineFolder}/workflow/scripts,/mnt/scratch2/igfs-anaconda/conda-dbs/kraken2/k2_pluspfp_20240904,/mnt/scratch2/users/3053301/infinity-seq"

# Shared, group-writable Apptainer/Singularity image cache (config/.docker.yml's
# ~23 containers), not a per-project docker_images/ folder. Snakemake's own
# image cache filename is md5(container URL).simg (snakemake/deployment/
# singularity.py) -- purely a function of the image URI, confirmed both in
# source and empirically (identical hash/bytes seen in two unrelated
# projects) -- so every project pointed at the same prefix transparently
# shares pulls: whoever touches a given container first triggers the pull,
# everyone else just reuses the file. Pre-pulled once for 22 of the 23
# images in .docker.yml (2026-09-14), specifically to avoid a first-pull
# race between concurrent users; hrp_vamb:0.1 failed to pull (Docker Hub
# access denied -- image is private or gone) but isn't actually referenced
# by any rule (only a commented-out note in workflow/rules/folders.smk),
# so this doesn't block anything. A still-missing image would only be
# pulled fresh if .docker.yml adds a new one later, or if hrp_vamb ever
# becomes real and gets wired into a rule.
SINGULARITY_PREFIX="/mnt/scratch2/igfs-databases/HoloR-MetaG-pipeline-containers/"

snakemake -s "$pipelineFolder/workflow/Snakefile" \
          --jobs 150 \
          --use-singularity \
          --configfile "$configFile" \
          --profile "$Profile" \
          --singularity-args "-B $BIND_PATHS" \
          --singularity-prefix "$SINGULARITY_PREFIX" \
          --latency-wait 60 \
          --scheduler greedy \
          --resources metaspades_slots=$metaspades_slots \
          --rerun-incomplete \
          "$@"
