def get_bracken_kmer_distrib(wildcards):
    """Look up the bracken-build kmer distribution file for this rule's
    {kraken_db} wildcard, at the read length configured in params.yaml
    (read_annotate: bracken: read_length).

    Raises a clear error (wrapped by Snakemake into InputFunctionException,
    with the offending wildcards attached) rather than a bare KeyError, if
    either the database or the specific read length isn't listed in
    config/features.yaml's databases: bracken_kmer_distrib: block -- real
    requirement, not a hypothetical: a missing kmer_distrib file is a silent
    correctness problem (wrong read length picked, or Bracken erroring deep
    inside its own C code) if not caught here, at DAG-build time, instead.
    """
    db_name = wildcards.kraken_db
    read_length = params["read_annotate"]["bracken"]["read_length"]
    distribs = features["databases"].get("bracken_kmer_distrib", {})

    if db_name not in distribs:
        raise ValueError(
            f"read_annotate__bracken__assign: no bracken_kmer_distrib entry for "
            f"kraken2 database '{db_name}' in config/features.yaml (databases: "
            f"bracken_kmer_distrib: {db_name}: ...). Run bracken-build against "
            f"this database first, then add the resulting kmer_distrib path(s)."
        )
    if read_length not in distribs[db_name]:
        raise ValueError(
            f"read_annotate__bracken__assign: no kmer_distrib file for read "
            f"length {read_length} (config/params.yaml: read_annotate: bracken: "
            f"read_length) against kraken2 database '{db_name}'. Available "
            f"lengths for this database: {sorted(distribs[db_name].keys())}. "
            f"Run bracken-build for this read length, or correct the "
            f"configured read_length."
        )
    return distribs[db_name][read_length]


rule read_annotate__bracken__assign:
    """
    Run Bracken on one sample's Kraken2 report for corrected abundance
    estimates -- Kraken2's own raw report over-represents higher taxonomic
    ranks, standard practice is to correct it with Bracken alongside it.
    """
    input:
        report=KRAKEN2 / "{kraken_db}" / "{sample_id}.{library_id}.report",
        kmer_distrib=get_bracken_kmer_distrib,
    output:
        abundance=BRACKEN / "{kraken_db}" / "{sample_id}.{library_id}.bracken",
        report=BRACKEN / "{kraken_db}" / "{sample_id}.{library_id}.bracken_report",
    log:
        BRACKEN / "{kraken_db}_{sample_id}.{library_id}.log",
    benchmark:
        BRACKEN / "benchmark/{kraken_db}_{sample_id}.{library_id}.tsv",
    threads: esc("cpus", "read_annotate__bracken__assign")
    resources:
        runtime=esc("runtime", "read_annotate__bracken__assign"),
        mem_mb=esc("mem_mb", "read_annotate__bracken__assign"),
        cpus_per_task=esc("cpus", "read_annotate__bracken__assign"),
        slurm_partition=esc("partition", "read_annotate__bracken__assign"),
        gres=lambda wc, attempt: f"{get_resources(wc, attempt, 'read_annotate__bracken__assign')['nvme']}",
        attempt=get_attempt,
    retries: len(get_escalation_order("read_annotate__bracken__assign"))
    container:
        # Reuses the same image kraken2__assign already runs in (no new
        # container pull) -- Bracken itself isn't installed in it (checked
        # directly, 2026-10-06: `which bracken bracken-build
        # est_abundance.py` inside docker://fischuu/hrp_preprocess:0.8
        # returns nothing), but this rule doesn't call Bracken's own
        # binaries -- see workflow/scripts/bracken_est_abundance.py's own
        # header for why, and params.script below.
        docker["preprocess"],
    params:
        read_length=params["read_annotate"]["bracken"]["read_length"],
        folder=config["pipeline_folder"],
        # Self-contained on purpose (changed 2026-10-06, was: call the
        # already-installed-but-externally-owned conda env
        # bracken-2.6.1-py39hc16433a_3 directly by absolute path). That env
        # is real and works, but it's a shared resource this fork has no
        # control over and no guarantee survives being updated or deleted
        # out from under it. est_abundance.py -- the actual estimation
        # script Bracken's own `bracken` wrapper just shells out to -- is
        # pure Python stdlib (confirmed by reading its imports: os, sys,
        # argparse, operator, time) with no compiled/C dependency, so it's
        # vendored verbatim into this repo instead (GPLv3, redistribution
        # permitted -- see the vendored file's own provenance note) and run
        # with this container's own python3, matching the existing
        # pipeline_folder/workflow/scripts convention used elsewhere in this
        # fork (e.g. read_annotate__ncyc__run, assemble__drep__separate_bins).
        # Verified directly: the vendored copy, run with a plain system
        # python3 (not the conda env), produces byte-identical output to the
        # original. Calls est_abundance.py directly rather than through
        # Bracken's own `bracken` wrapper script for an unrelated reason:
        # that wrapper demands its -d argument be a directory containing a
        # file literally named database<READ_LEN>mers.kmer_distrib, which
        # would mean reproducing that naming convention per database;
        # est_abundance.py takes the kmer_distrib file directly as -k,
        # matching config/features.yaml's per-database-per-length path
        # layout exactly, with nothing to rename.
        script="workflow/scripts/bracken_est_abundance.py",
    shell:
        """
        python3 {params.folder}/{params.script} \
            --input {input.report} \
            --kmer_distr {input.kmer_distrib} \
            --output {output.abundance} \
            --out-report {output.report} \
            --level S \
        2> {log} 1>&2
        """


rule read_annotate__bracken:
    """Run Bracken over every sample's Kraken2 report, for every configured kraken2 database."""
    input:
        [
            BRACKEN / kraken_db / f"{sample_id}.{library_id}.bracken"
            for sample_id, library_id in SAMPLE_LIBRARY
            for kraken_db in features["databases"]["kraken2"]
        ],
