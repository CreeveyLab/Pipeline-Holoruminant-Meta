rule mag_annotate__bakta:
    """Run Bakta once per dereplicated MAG, all genomes bundled into one job"""
    input:
        genomes=DREP / "dereplicated_genomes",
    output:
        out_dir=directory(BAKTA / "genomes"),
    log:
        BAKTA / "bakta.log",
    container:
        docker["mag_annotate"]
    params:
        folder=config["pipeline_folder"],
        work_dir=lambda w: Path(str(BAKTA / "genomes") + "_tmp"),
        db=features["databases"]["bakta"],
        options=params["mag_annotate"]["bakta"]["additional_options"],
        threads_per_genome=params["mag_annotate"]["bakta"]["threads_per_genome"],
    threads: esc("cpus", "mag_annotate__bakta")
    resources:
        runtime=esc("runtime", "mag_annotate__bakta"),
        mem_mb=esc("mem_mb", "mag_annotate__bakta"),
        cpus_per_task=esc("cpus", "mag_annotate__bakta"),
        slurm_partition=esc("partition", "mag_annotate__bakta"),
        gres=lambda wc, attempt: f"{get_resources(wc, attempt, 'mag_annotate__bakta')['nvme']}",
        attempt=get_attempt,
    retries: len(get_escalation_order("mag_annotate__bakta"))
    shell:
        """
        # work_dir is deliberately not wiped first: bakta_per_genome.sh skips
        # genomes a previous (timed-out) attempt already finished.
        {params.folder}/workflow/scripts/bakta_per_genome.sh \
            {params.db} \
            {input.genomes} \
            {params.work_dir} \
            {threads} \
            {params.threads_per_genome} \
            {params.options} \
        > {log} 2>&1

        mv {params.work_dir} {output.out_dir}
        """
