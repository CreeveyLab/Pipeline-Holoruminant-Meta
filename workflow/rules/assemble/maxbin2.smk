rule assemble__maxbin2__run:
    """Run MaxBin2 over a single assembly"""
    input:
        assembly=lambda wildcards: (
            MEGAHIT / f"{wildcards.assembly_id}.fa.gz" if config["assembler"] == "megahit" else 
            METASPADES / f"{wildcards.assembly_id}.fa.gz"if config["assembler"] == "metaspades" else 
            PROVIDED / f"{wildcards.assembly_id}.fa.gz"
        ),
        alignments=get_alignments_from_assembly_id,
    output:
        workdir=directory(MAXBIN2 / "{assembly_id}"),
    log:
        MAXBIN2 / "{assembly_id}.log",
    container:
        docker["assemble"]
    threads: esc("cpus", "assemble__maxbin2__run")
    resources:
        runtime=esc("runtime", "assemble__maxbin2__run"),
        mem_mb=esc("mem_mb", "assemble__maxbin2__run"),
        cpus_per_task=esc("cpus", "assemble__maxbin2__run"),
        slurm_partition=esc("partition", "assemble__maxbin2__run"),
        gres=lambda wc, attempt: f"{get_resources(wc, attempt, 'assemble__maxbin2__run')['nvme']}",
        attempt=get_attempt,
    retries: len(get_escalation_order("assemble__maxbin2__run"))
    params:
        seed=1,
        workdir=lambda w: Path(str(MAXBIN2 / w.assembly_id) + "_tmp"),
        abund_list=lambda w: Path(str(MAXBIN2 / w.assembly_id) + "_tmp") / "maxbin2.abund_list.txt",
        align_ext=ALIGN_EXT,
        minLen=params["assemble"]["maxbin"]["min_contig_len"],
    shell:
        """
        rm --recursive --force {params.workdir}
        mkdir --parents {params.workdir}

        # One abundance file per sample (contig, meandepth = column 7), fed to
        # MaxBin2 via -abund_list. A single `samtools coverage` over all
        # alignments pools them into one row per contig, losing the
        # between-sample differential coverage MaxBin2 bins on.
        : > {params.abund_list}
        for aln in {input.alignments}; do
            cov={params.workdir}/$(basename "$aln" .{params.align_ext}).coverage
            ( samtools coverage "$aln" \
              | awk '{{print $1"\t"$7}}' \
              | grep -v '^#' \
              ) > "$cov" \
              2>> {log}
            echo "$cov" >> {params.abund_list}
        done

        run_MaxBin.pl \
            -thread {threads} \
            -contig {input.assembly} \
            -out {params.workdir}/maxbin2 \
            -abund_list {params.abund_list} \
            -min_contig_length {params.minLen} \
        2>> {log} 1>&2

        rename \
            's/\\.fasta$/.fa/' \
            {params.workdir}/*.fasta \
        2>> {log}
        


        fa_files=$(find {params.workdir} -name "*.fa")
        for fa in $fa_files; do
            pigz --best --verbose "$fa"
        done 2>> {log} 1>&2

        rm \
            --recursive \
            --force \
            {params.workdir}/maxbin.{{coverage,log,marker,noclass,summary,tooshort}} \
            {params.workdir}/maxbin2.marker_of_each_bin.tar.gz \
            {params.workdir}/*.coverage \
            {params.abund_list} \
        2>> {log} 1>&2

        mv {params.workdir} {output.workdir}
        """


rule assemble__maxbin2:
    """Run MaxBin2 over all assemblies"""
    input:
        [MAXBIN2 / assembly_id for assembly_id in ASSEMBLIES],
