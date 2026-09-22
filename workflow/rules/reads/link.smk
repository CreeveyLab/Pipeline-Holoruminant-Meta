rule reads__link_run:
    """Make a link to the original file, with a prettier name than default"""
    input:
        forward_=get_forward,
        reverse_=get_reverse,
    output:
        forward_=READS / "{sample}.{library}_1.fq.gz",
        reverse_=READS / "{sample}.{library}_2.fq.gz",
    log:
        READS / "{sample}.{library}.log"
    benchmark:
        READS / "benchmark/{sample}.{library}.tsv"
    container:
        docker["reads"]
    shell:
        # --force: this rule is the very first thing the whole pipeline
        # does, and run_Kelvin.sh always passes --rerun-incomplete. Any
        # earlier interrupted run (killed job, crash further downstream,
        # a retry) that got this far before failing leaves a real symlink
        # behind; without --force, a legitimate Snakemake retry of this
        # (correctly) incomplete job fails immediately with
        # "ln: failed to create symbolic link ...: File exists" instead of
        # just recreating the link, which is what should always happen.
        """
        ln --symbolic --force $(readlink --canonicalize {input.forward_}) {output.forward_} 2>  {log} 1>&2
        ln --symbolic --force $(readlink --canonicalize {input.reverse_}) {output.reverse_} 2>> {log} 1>&2
        """

rule reads__link:
    """Link all reads in the samples.tsv"""
    input:
        [
            READS / f"{sample}.{library}_{end}.fq.gz"
            for sample, library in SAMPLE_LIBRARY
            for end in ["1", "2"]
        ],
