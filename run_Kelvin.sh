#!/usr/bin/env bash

# Kelvin2 launch wrapper for holor-pipeline-fork.
#
# Modeled on run_Snakebite-Holoruminant-MetaG.sh (this repo's generic
# template) plus a validated Apptainer/Singularity bind-mount list carried
# over from an earlier, locally-installed Kelvin run of this pipeline --
# that bind list is real, hard-won knowledge (see CLAUDE.md incident #4:
# a missing bind path surfaces as a misleading "filesystem latency" error, not
# an obvious permissions error), reused here rather than rediscovered.
#
# No --retries/--restart-times override here: every resource-consuming rule
# in workflow/rules/ already declares its own `retries: len(get_escalation_order(...))`,
# which takes precedence over any CLI/profile default and drives per-rule tier
# escalation (config/escalation.yaml) automatically.

# Set the project relevant paths
################################################################################
# EDIT ME: point this at your own project directory (see
# workflow/scripts/bootstrap_project.sh, which generates this file with the
# right value substituted automatically -- prefer that over editing by hand).
projectFolder="/mnt/scratch2/users/<your-username>/<your-project-name>"
configFile="${projectFolder}/config/config.yaml"
# Pipeline folder is this fork's own location -- derived automatically, no
# need to edit.
pipelineFolder="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

Profile=$projectFolder/config/profiles/Kelvin

# For use with Apptainer/Singularity, set these variables
################################################################################
export APPTAINER_TMPDIR="${projectFolder}/tmp"
export APPTAINER_CACHEDIR="${projectFolder}/tmp"
export SINGULARITY_TMPDIR="${projectFolder}/tmp"
export SINGULARITY_CACHEDIR="${projectFolder}/tmp"
mkdir -p "$APPTAINER_TMPDIR"
mkdir -p "$SINGULARITY_TMPDIR"

# Real fix, found and verified 2026-09-16 during the first successful real
# preprocess_{sample}_{library} group run: without squashfuse, Apptainer
# falls back to fully re-extracting each ~1GB container image into a fresh
# temporary sandbox on EVERY invocation ("Converting SIF file to temporary
# sandbox..."), which measured as a uniform ~2.6-3.6x slowdown across every
# single rule in that run (fastp, bowtie2, samtools alike -- the slowdown
# tracked container invocations, not any one tool). squashfuse isn't a
# Kelvin2 module; it exists only as a standalone conda env someone in the
# lab already built. Putting its bin/ on PATH lets Apptainer mount the SIF's
# squashfs directly instead of extracting it (confirmed: ~0.5s vs. many
# seconds per invocation, real containers, real bind list). Apptainer's
# setuid install refuses FUSE-mounting by default ("configuration disallows
# users from mounting SIF squashFS partition in setuid mode") -- --userns
# below is required alongside this, not optional.
export PATH="/mnt/scratch2/igfs-anaconda/conda-envs/squashfuse-0.6.1-hc12fc2f_0/bin:$PATH"

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

# Pre-flight safety gate (CLAUDE.md Section 4 incidents #2/#6): refuses to
# launch if a previous generation's SLURM jobs or orchestrator process are
# still alive for this project -- see workflow/scripts/kelvin_launch_guard.sh
# for what it actually checks and why "kill" alone isn't a safe signal.
if ! "$pipelineFolder/workflow/scripts/kelvin_launch_guard.sh" "$projectFolder"; then
    exit 1
fi

# Bind-mount list (see header comment). Points at the central reference/
# database store (Section 6 step 1) -- migrated 2026-09-15 via rsync copy
# (not mv/rename, per explicit instruction: no write access to
# My_holor_project, and the copy leaves it fully untouched regardless).
# Verified: 2.75TB / 249,400 files transferred, 0 errors, source untouched.
# If your project needs an extra host path bound in (e.g. self-provided
# assemblies living outside projectFolder), add it here -- keep this list
# to paths this pipeline itself actually needs, not other unrelated
# projects' directories.
################################################################################
BIND_PATHS="/sys:/sys,/dev/shm:/dev/shm,/run,/tmp,${projectFolder}/tmp,/mnt/scratch2/igfs-databases/HoloR-MetaG-pipeline-resources/,${pipelineFolder}/workflow/scripts,/mnt/scratch2/igfs-anaconda/conda-dbs/kraken2/k2_pluspfp_20240904"

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
          --singularity-args "--userns -B $BIND_PATHS" \
          --singularity-prefix "$SINGULARITY_PREFIX" \
          --latency-wait 60 \
          --scheduler greedy \
          --resources metaspades_slots=$metaspades_slots \
          --rerun-incomplete \
          "$@"
