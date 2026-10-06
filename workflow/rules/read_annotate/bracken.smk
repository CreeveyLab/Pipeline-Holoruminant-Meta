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
    params:
        read_length=params["read_annotate"]["bracken"]["read_length"],
        # No container: directive on purpose. Confirmed directly (2026-10-06)
        # Bracken isn't in any existing hrp_* image (checked inside
        # docker://fischuu/hrp_preprocess:0.8, where kraken2__assign runs --
        # `which bracken bracken-build est_abundance.py` returns nothing).
        # Doesn't warrant a new dedicated image either: Bracken is a tiny,
        # single-threaded Python+C tool (no -t/--threads option at all,
        # confirmed via its own usage text) with no heavy runtime
        # dependencies, and it's already installed centrally as a conda env
        # -- bracken-2.6.1-py39hc16433a_3, confirmed real and working.
        # Called directly via that env's own est_abundance.py rather than the
        # top-level `bracken` wrapper script: the wrapper demands its -d
        # argument be a directory containing a file literally named
        # database<READ_LEN>mers.kmer_distrib, which would mean reproducing
        # that naming convention (via a symlink or copy) for every database
        # this rule might ever point at; est_abundance.py itself (which the
        # wrapper just shells out to) takes the kmer_distrib file directly as
        # -k, matching config/features.yaml's per-database-per-length path
        # layout exactly, with nothing to rename.
        # --use-singularity only containerizes rules that declare a
        # container: -- real, existing precedent for a containerless rule
        # already in this fork (see contig_annotate__eggnog_merge_annotations),
        # so mixing this in is safe.
        est_abundance_bin="/mnt/scratch2/igfs-anaconda/conda-envs/bracken-2.6.1-py39hc16433a_3/bin/est_abundance.py",
    shell:
        """
        {params.est_abundance_bin} \
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
