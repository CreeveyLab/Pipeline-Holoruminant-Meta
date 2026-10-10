#!/usr/bin/env bash
set -euo pipefail

# Read-only companion to run_Kelvin.sh: reports on an in-progress (or just-
# finished) Kelvin2 run for a project. Deliberately a separate script --
# folding "check status" into run_Kelvin.sh itself would mean re-running
# the same command sometimes launches a pipeline and sometimes just prints
# a report, depending on state the user can't see in advance. run_Kelvin.sh
# calls this automatically when it finds a run already active instead of
# launching a duplicate.
#
# The orchestrator itself runs directly on the login/data-mover node (see
# run_Kelvin.sh), not as its own SLURM job -- an earlier version submitted
# it as a small SLURM job specifically for unified squeue-based monitoring,
# but that added a real, avoidable queue-wait on top of whatever queue-wait
# the real work needed anyway (worse on a low-fairshare account). This
# script gives the same unified view a different way: the orchestrator
# process's own status (matched the same way kelvin_launch_guard.sh does,
# by real working directory rather than name) plus every real SLURM job it
# has submitted for this project, in one report.
#
# Usage:
#   check_progress_kelvin.sh [project_dir]     # project_dir optional if
#                                               # bootstrapped into a project
#                                               # (see below)

# EDIT ME: point this at your own project directory (see
# workflow/scripts/bootstrap_project.sh, which generates a project-local
# copy of this file with the right value substituted automatically --
# prefer that over editing by hand). Only used as a fallback when no
# argument is given.
projectFolder="/mnt/scratch2/users/<your-username>/<your-project-name>"

TARGET="${1:-$projectFolder}"
PROJECT_DIR="$(cd "$TARGET" && pwd)"

echo "=== Kelvin progress: $PROJECT_DIR ==="

# --- Orchestrator process, matched by real working directory (see
# kelvin_launch_guard.sh's ORCH_HITS for why "snakemake -s" specifically,
# not a bare "snakemake" substring, and why by-directory rather than by
# name) ---
ORCH_HITS="$(pgrep -af "snakemake -s" 2>/dev/null | grep -F "$PROJECT_DIR" || true)"

# pgrep above only sees THIS node. Kelvin2 has several login nodes behind
# round-robin DNS -- land on a different one than the orchestrator is
# actually running on, and pgrep sees nothing even though it's genuinely
# alive. The heartbeat file (see run_Kelvin.sh / kelvin_launch_guard.sh for
# the full reasoning) closes that gap: it's on shared /mnt/scratch2, so it
# reads identically from any login node.
HEARTBEAT_FILE="$PROJECT_DIR/.snakemake/orchestrator_heartbeat"
HEARTBEAT_STALE_AFTER=180
HEARTBEAT_STATUS=""
if [[ -f "$HEARTBEAT_FILE" ]]; then
    heartbeat_age=$(( $(date +%s) - $(stat -c %Y "$HEARTBEAT_FILE") ))
    if [[ "$heartbeat_age" -lt "$HEARTBEAT_STALE_AFTER" ]]; then
        HEARTBEAT_STATUS="$(cat "$HEARTBEAT_FILE") (${heartbeat_age}s old)"
    fi
fi

if [[ -n "$ORCH_HITS" ]]; then
    echo ""
    echo "Orchestrator is running (on this node):"
    echo "$ORCH_HITS" | sed 's/^/  /'
elif [[ -n "$HEARTBEAT_STATUS" ]]; then
    echo ""
    echo "Orchestrator appears to be running, but on a DIFFERENT login node than"
    echo "this one (not visible to this node's own process list) -- recent heartbeat:"
    echo "  $HEARTBEAT_STATUS"
else
    echo ""
    echo "No orchestrator currently running for this project."
fi

echo ""
echo "Real SLURM jobs currently active for this project:"
SQUEUE_HITS="$(squeue -u "$USER" -h -o "%.12i %.10T %.12M %.30j %Z" 2>/dev/null \
    | awk -v d="$PROJECT_DIR" '$5==d {print "  "$1, $2, $3, $4}' || true)"
if [[ -n "$SQUEUE_HITS" ]]; then
    echo "  JOBID        STATE          TIME  NAME"
    echo "$SQUEUE_HITS"
else
    echo "  (none)"
fi

ORCH_LOG="$PROJECT_DIR/slurm_out/kelvin_orchestrator.log"
if [[ -f "$ORCH_LOG" ]]; then
    echo ""
    echo "Recent progress (from $ORCH_LOG, [DEBUG] lines filtered out):"
    grep -v "^\[DEBUG\]" "$ORCH_LOG" 2>/dev/null | tail -30
else
    echo ""
    echo "No orchestrator log found yet at $ORCH_LOG."
fi
