#!/usr/bin/env bash
set -euo pipefail

# Pre-flight safety gate for (re)launching Snakemake against a Kelvin2
# project directory. Addresses two confirmed incidents from running this
# pipeline for real:
#
#   - SIGTERM does not reliably stop a Snakemake orchestrator process --
#     confirmed 3 separate times, once with two stale survivors alive
#     simultaneously, one surviving 5+ days undetected. A human trusting
#     that `kill` worked is not a safe signal.
#   - Relaunching into a still-active previous generation caused two jobs
#     to race writing the same output path via shell `>` redirection --
#     real, confirmed file corruption, not a theoretical risk.
#
# This script checks two independent, objective signals before allowing a
# launch: (1) squeue, correlated to this project by real working directory
# (not by job name, which isn't project-tagged) -- any pending/running job
# whose WorkDir matches this project blocks the launch; (2) a local
# pgrep sweep for any snakemake process whose command line still
# references this project -- catches a "killed" orchestrator that didn't
# actually die. Only once BOTH are clear does it report a leftover
# Snakemake lock (if any) as advisory -- safe to `--unlock`, but that
# decision is left to the human, not automated here.
#
# Usage:
#   kelvin_launch_guard.sh <project_dir>            # hard gate: exit 1 if unsafe
#   kelvin_launch_guard.sh <project_dir> --status    # read-only report, always exit 0

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <project_dir> [--status]" >&2
    exit 1
fi

PROJECT_DIR="$(cd "$1" && pwd)"
MODE="${2:-gate}"

echo "=== Kelvin launch guard: $PROJECT_DIR ==="

# --- 1. Any SLURM jobs (pending or running) whose real WorkDir matches this project ---
SQUEUE_HITS="$(squeue -u "$USER" -h -o "%.12i %.10T %Z" 2>/dev/null | awk -v d="$PROJECT_DIR" '$3==d' || true)"

# --- 2. Any live local snakemake process still referencing this project ---
# Match on "snakemake -s" specifically (the actual invocation shape every
# real orchestrator uses, e.g. `snakemake -s .../Snakefile ...`), not a
# bare "snakemake" substring -- that broader pattern produces real false
# positives (confirmed directly: it matched an unrelated shell command that
# merely mentioned "module load snakemake/9.9.0" and this project's path
# as substrings, with no actual snakemake process running at all).
ORCH_HITS="$(pgrep -af "snakemake -s" 2>/dev/null | grep -F "$PROJECT_DIR" || true)"

BLOCKED=0

if [[ -n "$SQUEUE_HITS" ]]; then
    BLOCKED=1
    echo ""
    echo "BLOCKED: SLURM job(s) still queued/running with this project's working directory:"
    echo "  JOBID        STATE      WORK_DIR"
    echo "$SQUEUE_HITS" | sed 's/^/  /'
fi

if [[ -n "$ORCH_HITS" ]]; then
    BLOCKED=1
    echo ""
    echo "BLOCKED: a live snakemake process still references this project:"
    echo "$ORCH_HITS" | sed 's/^/  /'
    echo ""
    echo "  NOTE: plain 'kill <pid>' (SIGTERM) has been confirmed unreliable for"
    echo "  stopping this orchestrator before -- use 'kill -9 <pid>', wait a few"
    echo "  seconds, then re-run this check before relaunching."
fi

if [[ "$BLOCKED" -eq 1 ]]; then
    if [[ "$MODE" == "--status" ]]; then
        exit 0
    fi
    echo ""
    echo "Refusing to launch: clear the above before relaunching Snakemake for this project."
    exit 1
fi

echo "No in-flight SLURM jobs or live orchestrator process found for this project."

if [[ -d "$PROJECT_DIR/.snakemake/locks" ]] && [[ -n "$(ls -A "$PROJECT_DIR/.snakemake/locks" 2>/dev/null)" ]]; then
    echo ""
    echo "NOTE: a Snakemake lock exists at $PROJECT_DIR/.snakemake/locks, but nothing"
    echo "found above appears to still be using it -- this looks like a leftover from"
    echo "an interrupted run, not an active one. If you agree, clear it yourself with:"
    echo "  snakemake --unlock -s <Snakefile> --configfile $PROJECT_DIR/config/config.yaml"
fi

echo "Safe to launch."
exit 0
