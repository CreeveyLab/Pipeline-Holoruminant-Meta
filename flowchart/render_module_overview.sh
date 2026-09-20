#!/usr/bin/env bash
set -euo pipefail

# Regenerates module_overview.png from module_overview.dot -- the
# high-level, major-modules-only companion to flowchart.png (which is the
# full, generated-from-real-rules DAG; see generate_rulegraph.sh in this
# same directory).
#
# Unlike flowchart.png, this one is NOT auto-derived from the Snakefile --
# Snakemake has no notion of "module" as a grouping above individual rules,
# so there's nothing to introspect directly. module_overview.dot is
# hand-written, but every edge in it was verified against real cross-module
# references in workflow/rules/ (which module's rules actually read another
# module's output path constants from workflow/rules/folders.smk), not
# guessed. If a module's real dependencies change, update the .dot file by
# hand and re-verify the same way, then re-render.
#
# Requires only graphviz's `dot` (already on PATH system-wide on Kelvin2 --
# no Snakemake or R env needed, unlike the other two generators in this
# directory).
#
# Usage: run from anywhere, no project context needed:
#   /path/to/holor-pipeline-fork/flowchart/render_module_overview.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dot -Tpng "$DIR/module_overview.dot" > "$DIR/module_overview.png"

echo "Wrote $DIR/module_overview.png"
