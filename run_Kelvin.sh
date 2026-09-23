#!/usr/bin/env bash

# Kelvin2 launch wrapper for holor-pipeline-fork.
#
# Modeled on run_Snakebite-Holoruminant-MetaG.sh (this repo's generic
# template) plus a validated Apptainer/Singularity bind-mount list carried
# over from an earlier, locally-installed Kelvin run of this pipeline --
# that bind list is hard-won knowledge -- a missing bind path surfaces as a
# misleading "filesystem latency" error, not an obvious permissions error --
# reused here rather than rediscovered.
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

# Helper: read YAML value (simple key: value, no nesting)
################################################################################
read_yaml() {
    local key="$1"
    local file="$2"
    grep -E "^[[:space:]]*${key}:" "$file" \
        | sed -E "s/^[^:]+:[[:space:]]*//" \
        | tr -d '"'
}

# Pipeline folder: read from THIS PROJECT's config.yaml (pipeline_folder:,
# already the single source of truth several rules read via
# config["pipeline_folder"] -- see workflow/rules/folders.smk and others)
# rather than derived from where this script file happens to live.
#
# Real bug fixed 2026-09-22: the old approach derived pipelineFolder from
# `dirname "${BASH_SOURCE[0]}"`, which only works if this script stays
# in the pipeline clone -- the header comment right above ("EDIT ME: point
# this at your own project directory") invites copying/hand-editing this
# file, and a colleague who copied it into their project directory (a
# reasonable reading of that comment, without going through
# bootstrap_project.sh) got a pipelineFolder pointing at their PROJECT
# directory instead of the pipeline clone -- workflow/Snakefile and every
# other $pipelineFolder/... path then didn't exist there. Reading it from
# config.yaml instead means this script can live anywhere; the only
# requirement is that projectFolder above points at a real, bootstrapped
# project whose config.yaml has a correct pipeline_folder: (bootstrap_project.sh
# already sets this correctly on every new project).
pipelineFolder="$(read_yaml pipeline_folder "$configFile")"
pipelineFolder="${pipelineFolder%/}"  # config.yaml's value has a trailing
                                       # slash (required by rules that do
                                       # config["pipeline_folder"] + "workflow/...")

if [[ -z "$pipelineFolder" ]]; then
    echo "ERROR: pipeline_folder not defined in $configFile" >&2
    exit 1
fi
if [[ ! -f "$pipelineFolder/workflow/Snakefile" ]]; then
    echo "ERROR: $pipelineFolder/workflow/Snakefile not found -- pipeline_folder in" >&2
    echo "  $configFile" >&2
    echo "  does not point at a real holor-pipeline-fork clone." >&2
    exit 1
fi

# Real bug fixed 2026-09-22, same incident as above: nothing below used to
# force the working directory to $projectFolder, so config.yaml's own
# relative-path keys (sample-file: "config/samples.tsv", etc. -- resolved
# by Snakemake against the CALLER's CWD, not against configFile's location)
# and the bare `mkdir -p slurm_out` a few lines down silently used whatever
# directory the *user* happened to be in when they ran this script. Ran
# from the pipeline clone instead of the project directory (which the
# pipelineFolder bug above made a plausible thing to end up doing), results
# and slurm_out/ landed in the clone, and Snakemake picked up the clone's
# own placeholder config/samples.tsv instead of the project's real one.
# Making this script's own location and the caller's CWD irrelevant, by
# always cd-ing into the real project directory first, removes this
# failure mode structurally rather than relying on users invoking it from
# the right place.
cd "$projectFolder" || { echo "ERROR: cannot cd into $projectFolder" >&2; exit 1; }

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
# is required alongside this, not optional (confirmed again 2026-09-22 on
# a real compute node: squashfuse present + no --userns fails immediately
# with exactly that message).
#
# Both squashfuse-on-PATH and --userns are only added below if a cheap,
# side-effect-free check confirms squashfuse is actually usable here --
# rather than assuming it always is. If it isn't (binary missing, /dev/fuse
# not present/accessible), every container call falls back to the slower
# but still-correct full-extraction path instead of a hard failure, and
# this prints a visible warning so the slowdown is diagnosable rather than
# silently costing minutes per rule.
SQUASHFUSE_BIN="/mnt/scratch2/igfs-anaconda/conda-envs/squashfuse-0.6.1-hc12fc2f_0/bin"
SINGULARITY_EXTRA_ARGS=""
if [[ -x "$SQUASHFUSE_BIN/squashfuse" && -e /dev/fuse && -r /dev/fuse && -w /dev/fuse ]]; then
    export PATH="$SQUASHFUSE_BIN:$PATH"
    SINGULARITY_EXTRA_ARGS="--userns"
else
    echo "WARNING: squashfuse ($SQUASHFUSE_BIN) or /dev/fuse not usable on this node --" >&2
    echo "  every container call will fall back to full sandbox extraction" >&2
    echo "  (correct, but several minutes slower per invocation than a squashfuse mount)." >&2
fi

metaspades_slots="$(read_yaml metaspades_slots "$configFile")"

if [[ -z "$metaspades_slots" ]]; then
    echo "ERROR: metaspades_slots not defined in $configFile" >&2
    exit 1
fi

echo "config file      : ${configFile}"
echo "Project folder   : ${projectFolder}"
echo "Pipeline folder   : ${pipelineFolder}"

mkdir -p "$projectFolder/slurm_out"
mkdir -p "$projectFolder/tmp"

# Dry runs (-n / --dry-run) are fast, read-only, and safe to run even
# alongside an already-active real run for this project -- skip the launch
# guard and the orchestrator-submission machinery below entirely, and just
# run directly in the foreground so the output appears immediately.
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        -n|--dry-run) DRY_RUN=1 ;;
    esac
done

if [[ "$DRY_RUN" -eq 0 ]]; then
    # Pre-flight safety gate: refuses to launch if a previous generation's
    # SLURM jobs or orchestrator process are still alive for this project --
    # see workflow/scripts/kelvin_launch_guard.sh for what it actually checks
    # and why "kill" alone isn't a safe signal.
    if ! "$pipelineFolder/workflow/scripts/kelvin_launch_guard.sh" "$projectFolder"; then
        echo ""
        echo "Not launching a second orchestrator -- checking the active run's status instead:"
        echo ""
        "$pipelineFolder/workflow/scripts/check_progress_kelvin.sh" "$projectFolder"
        exit 1
    fi
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

# Real bug fixed 2026-09-23: reads/ in the project only holds SYMLINKS to
# your real raw reads -- reads__link_run runs inside a container and needs
# the real directory bound to actually read through them, or it fails.
# Every new user was hitting this on their very first run, since raw reads
# essentially never live under a path already bound above. bootstrap_project.sh
# now records the real directory/directories in config.yaml's
# raw_reads_dirs: automatically; appended here so it doesn't need to be
# added by hand. (A hardcoded personal path used to sit in this list as a
# one-off workaround for exactly this -- removed in favor of this generic
# mechanism, since it silently applied to every project, not just its
# author's own.)
RAW_READS_DIRS="$(read_yaml raw_reads_dirs "$configFile")"
if [[ -n "$RAW_READS_DIRS" ]]; then
    BIND_PATHS="$BIND_PATHS,$RAW_READS_DIRS"
fi

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

SNAKEMAKE_INVOCATION() {
    snakemake -s "$pipelineFolder/workflow/Snakefile" \
              --jobs 150 \
              --use-singularity \
              --configfile "$configFile" \
              --profile "$Profile" \
              --singularity-args "$SINGULARITY_EXTRA_ARGS -B $BIND_PATHS" \
              --singularity-prefix "$SINGULARITY_PREFIX" \
              --latency-wait 60 \
              --scheduler greedy \
              --resources metaspades_slots=$metaspades_slots \
              --rerun-incomplete \
              "$@"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
    SNAKEMAKE_INVOCATION "$@"
    exit $?
fi

# Real launch: run the orchestrator directly on this (login/data-mover)
# node, backgrounded and detached automatically, rather than submitting it
# as a SLURM job itself.
#
# An earlier version of this script submitted the orchestrator as its own
# small SLURM job on k2-bioinf,k2-lowpri, specifically so it would show up
# in `squeue` for unified monitoring. Reverted after finding a real problem
# with that (2026-09-20): the orchestrator job's own queue-wait is additive
# to whatever queue-wait the real work needs anyway -- on an account with
# reduced fairshare priority (e.g. from genuinely heavy recent real usage),
# a tiny 1-CPU/2GB wrapper job can sit queued for a long time before it even
# starts submitting the real work, which can cost *more* total wall-clock
# than just running the orchestrator directly ever would have. The
# monitoring benefit doesn't actually require the orchestrator to be a
# SLURM job -- check_progress_kelvin.sh gives the same unified view (this
# process's status + every real job it has submitted) without that cost.
#
# Ignoring SIGHUP (what nohup normally does) plus disown here -- rather
# than requiring the user to remember tmux/screen/nohup themselves -- is
# what makes this survive a logout: the trap stops the subshell from
# dying when the shell exits and sends it SIGHUP, and disown removes it
# from this shell's job table so the shell exiting doesn't affect it
# either. A subshell with its own trap (rather than piping through an
# external `nohup ... &` command) also means "$@" gets passed straight
# through as real, already-correctly-split arguments -- no need to
# flatten them into a re-quoted string first.
ORCH_LOG="$projectFolder/slurm_out/kelvin_orchestrator.log"

(
    trap '' HUP
    SNAKEMAKE_INVOCATION "$@" > "$ORCH_LOG" 2>&1
) &
disown
ORCH_PID=$!

echo ""
echo "Orchestrator running as PID $ORCH_PID on $(hostname)."
echo "Log: $ORCH_LOG"
echo ""
echo "Check progress any time with:"
echo "  $pipelineFolder/workflow/scripts/check_progress_kelvin.sh $projectFolder"
