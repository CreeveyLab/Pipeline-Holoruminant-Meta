# Troubleshooting

## Starting the pipeline

*The reads-module does not even finish correctly*

1. Check the slurm output in .snakemake/slurm_logs, can you find something there?
2. Check the binding folders (-B) in run_Snakebite-Holoruminant-MetaG.sh, do they all exist?

## Targeting one rule re-runs way more than expected

*You ask for one specific output, but Snakemake wants to redo several
upstream steps too — `reads__link_run`, `fastp`, `kraken2__assign`, whatever
sits between the raw reads and your actual target — even though their
outputs already exist on disk and look fine.*

**Real cause, not hypothetical** (hit directly 2026-10-10, validating
`read_annotate__bracken__assign`): Snakemake's dependency tracking is
mtime-based by default. If a raw input file's modification time is newer
than an already-computed downstream output — even if nothing about the
data that actually matters changed — Snakemake treats the whole chain
below that input as stale and wants to redo it. In the real case that
motivated this entry, the raw FASTQ had genuinely been touched/rewritten
after the existing Kraken2 report was last computed, so retargeting
anything downstream of it (like a brand-new Bracken rule) wanted to redo
`reads__link_run` → `fastp` → `kraken2__assign` first, which is both slow
(fastp alone can run over an hour on real data) and pointless if you
already trust the existing outputs.

**Fix: `--touch`.** `run_Kelvin.sh` forwards every flag straight through to
`snakemake`, so this works with no code change:

```bash
# 1. Re-stamp the existing, still-good chain as fresh (no re-execution,
#    just timestamp updates, walked in topological order):
bash run_Kelvin.sh --touch results/read_annotate/kraken2/refseq500/37131.lib1.report

# 2. Then submit your actual target normally -- Snakemake now sees its
#    inputs as up to date and only runs what's genuinely missing:
bash run_Kelvin.sh results/read_annotate/bracken/refseq500/37131.lib1.bracken
```

Real caveats, both confirmed directly:

- **`--touch` only re-stamps files that still exist.** If an intermediate
  output was already cleaned up (e.g. a `temp()`-marked file, consumed and
  deleted after its one real downstream use), the log says so explicitly
  (`Output files not touched because they don't exist: ...`) and moves on
  — it can't retroactively "restore" something that's genuinely gone. This
  is fine as long as the specific file your real target actually needs
  (the Kraken2 report, in the example above) still exists; it doesn't need
  every intermediate file in the chain to still be present.
- **It's a trust call, not a content check.** `--touch` never inspects
  whether an existing output is still *correct* for a changed input — it
  only silences the staleness warning. Use it when you're confident the
  existing files are still good, not as a blanket workaround.
- **Scope both `--touch` and `--unlock` to a real target, not left bare.**
  Called with no target, either one defaults to building the DAG for `all`,
  which fails on this fork's own pre-existing, unrelated gaps (e.g. the
  `sylph` database — see Known Limitations in
  [00-Kelvin2-Quickstart.md](00-Kelvin2-Quickstart.md)) before it ever gets
  to touching or unlocking anything. Always pass the same real target
  you're actually working toward.
- **If a previous run was killed hard** (a `kill -9` on the orchestrator,
  not a clean exit), you'll likely also need `snakemake --unlock` (scoped
  to a real target, same as above) before `--touch` or anything else will
  run — a hard kill leaves `.snakemake/locks/` populated, and Snakemake
  refuses to touch a locked directory.

## metaSPAdes fails with an OOM-looking crash even though it had memory to spare

*`assemble__metaspades__run` dies partway through, SLURM/`sacct` shows
`OUT_OF_MEMORY` or the peak RSS landing suspiciously close to the request,
but the real memory granted should have been plenty.*

Two separate, real issues here, both already handled by this fork's own
`workflow/rules/assemble/metaspades.smk` — but worth understanding if
you're tuning `kelvin_metaspades_himem` in `config/config.yaml` yourself:

1. **SPAdes' `-m`/`--memory` flag is its own internal ceiling, separate
   from whatever SLURM actually grants the job.** It doesn't infer this
   from `--mem`/cgroups on its own — pass the wrong value (or rely on its
   default, 250GB) and SPAdes can self-terminate well under a genuinely
   larger SLURM allocation, or try to use more than SLURM actually gave
   it. This rule already sets `--memory` from `resources.mem_mb` every
   attempt (converted once, in `params.mem_gb`), so it always matches
   whatever tier/attempt is actually running — nothing to change here, but
   if you ever add a `--continue` retry path, re-derive this value fresh
   rather than trusting whatever SPAdes cached from the failed attempt.
2. **SPAdes' bundled allocator (mimalloc) can interact badly with
   transparent huge pages (THP) on the node it lands on**, producing
   exactly this failure shape — an OOM-looking crash in a consistent
   memory range regardless of how much was actually granted. Check with
   `cat /sys/kernel/mm/transparent_hugepage/enabled` on a node you suspect
   — `[always]` means THP is active cluster/node-wide. The fix
   (`export MIMALLOC_ALLOW_THP=0` before invoking `metaspades.py`) is free
   — no rebuild, no measured downside — so this rule sets it
   unconditionally rather than gating on the check; the check is still run
   and logged (to the rule's own `.log` file) purely for diagnosis.
   `config/config.yaml`'s `kelvin_metaspades_himem` comment documents a
   real, unexplained OOM-shaped failure series at 280GB that this fix was
   added in response to (2026-10-20) — the 300GB bump that followed may
   have been masking this rather than fixing it. If failures recur at
   300GB with the THP fix in place, that's real evidence it wasn't THP
   after all; if they don't, the tier may have more headroom than the
   280GB-failure evidence alone suggested.