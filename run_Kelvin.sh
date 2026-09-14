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
# /mnt/scratch2/igfs-databases/Holoruminant/resources/ once the reference/
# database store migration (Section 6 step 1, on hold pending sign-off from
# whoever owns My_holor_project) actually happens.
################################################################################
BIND_PATHS="/sys:/sys,/dev/shm:/dev/shm,/run,/tmp,${projectFolder}/tmp,/mnt/scratch2/igfs-databases/Holoruminant/My_holor_project/resources/,${pipelineFolder}/workflow/scripts,/mnt/scratch2/igfs-anaconda/conda-dbs/kraken2/k2_pluspfp_20240904,/mnt/scratch2/users/3053301/infinity-seq"

snakemake -s "$pipelineFolder/workflow/Snakefile" \
          --jobs 150 \
          --use-singularity \
          --configfile "$configFile" \
          --profile "$Profile" \
          --singularity-args "-B $BIND_PATHS" \
          --singularity-prefix "$projectFolder/docker_images/" \
          --latency-wait 60 \
          --scheduler greedy \
          --resources metaspades_slots=$metaspades_slots \
          --rerun-incomplete \
          "$@"
