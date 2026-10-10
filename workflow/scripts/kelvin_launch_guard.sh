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
# This script checks three independent, objective signals before allowing a
# launch: (1) squeue, correlated to this project by real working directory
# (not by job name, which isn't project-tagged) -- any pending/running job
# whose WorkDir matches this project blocks the launch; (2) a local
# pgrep sweep for any snakemake process whose command line still
# references this project -- catches a "killed" orchestrator that didn't
# actually die; (3) a heartbeat file the orchestrator itself keeps fresh
# while alive (run_Kelvin.sh, see its own comment there for the full
# reasoning) -- added 2026-10-13 because (1) and (2) both have a real gap
# on a multi-login-node cluster. Kelvin2 has several login nodes behind
# round-robin DNS (confirmed: kelvin2.qub.ac.uk resolves to 4 different
# IPs); the orchestrator is a plain background process on whichever node
# you launched from, with no cluster-wide tracking of its own. squeue only
# sees it indirectly, via whatever SLURM job it's currently waiting on --
# blind during the real pause between one job finishing and the next being
# submitted. pgrep is worse: it only sees processes on the CURRENT node, so
# logging back in and landing on a different node makes it blind entirely,
# not just during a brief gap. The heartbeat file lives in the project
# directory on shared /mnt/scratch2, so it reads identically from any login
# node -- closing the gap without needing to reach any specific node.
# Only once all three are clear does it report a leftover Snakemake lock
# (if any) as advisory -- safe to `--unlock`, but that decision is left to
# the human, not automated here.
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

# --- 3. A heartbeat file the orchestrator keeps fresh while alive, read
# identically from any login node (see this script's own header comment
# and run_Kelvin.sh's for the full reasoning). mtime compared against
# "now" -- both read from THIS node, right now, so no cross-node clock
# skew question even arises. 180s = 6x the 30s write interval: generous
# margin over real scheduling jitter, confirmed from this fork's own
# orchestrator logs to normally be seconds, not minutes, between jobs.
HEARTBEAT_FILE="$PROJECT_DIR/.snakemake/orchestrator_heartbeat"
HEARTBEAT_STALE_AFTER=180
HEARTBEAT_HITS=""
if [[ -f "$HEARTBEAT_FILE" ]]; then
    heartbeat_age=$(( $(date +%s) - $(stat -c %Y "$HEARTBEAT_FILE") ))
    if [[ "$heartbeat_age" -lt "$HEARTBEAT_STALE_AFTER" ]]; then
        HEARTBEAT_HITS="$(cat "$HEARTBEAT_FILE") (${heartbeat_age}s old)"
    fi
fi

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

if [[ -n "$HEARTBEAT_HITS" ]]; then
    BLOCKED=1
    echo ""
    echo "BLOCKED: a recent orchestrator heartbeat says this project is still active:"
    echo "  $HEARTBEAT_HITS"
    echo ""
    echo "  NOTE: this is the cross-login-node check -- squeue and the local pgrep"
    echo "  sweep above can both miss a real orchestrator running on a DIFFERENT"
    echo "  login node than this one (Kelvin2 has several, behind round-robin DNS)."
    echo "  Trust this signal even if the other two came back clear. If you're sure"
    echo "  it's genuinely dead (e.g. the node it was on rebooted), wait ${HEARTBEAT_STALE_AFTER}s"
    echo "  from the heartbeat's own timestamp above and re-run this check."
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
