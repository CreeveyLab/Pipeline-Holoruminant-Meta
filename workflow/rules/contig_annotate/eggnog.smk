from glob import glob
from os.path import join

rule contig_annotate__eggnog_find_homology:
    """
    Find homolog genes in data (EGGNOG).
    """
    input:
        folder = CONTIG_PRODIGAL / "{assembly_id}/Chunks/",
        files = CONTIG_PRODIGAL / "{assembly_id}/Chunks/prodigal.chunk.{i}"
    output:
        file=CONTIG_EGGNOG / "{assembly_id}/Chunks/prodigal.chunk.{i}.emapper.seed_orthologs"
    log:
        CONTIG_EGGNOG / "{assembly_id}/Chunks/prodigal.chunk.{i}.log"
    params:
        folder = lambda wildcards: CONTIG_EGGNOG / f"{wildcards.assembly_id}/Chunks/",
        tmp=config["nvme_storage"],
        out="prodigal.chunk.{i}",
        fa=features["databases"]["eggnog"]
    threads: esc("cpus", "contig_annotate__eggnog_find_homology")
    resources:
        runtime=esc("runtime", "contig_annotate__eggnog_find_homology"),
        mem_mb=esc("mem_mb", "contig_annotate__eggnog_find_homology"),
        cpus_per_task=esc("cpus", "contig_annotate__eggnog_find_homology"),
        slurm_partition=esc("partition", "contig_annotate__eggnog_find_homology"),
        gres=lambda wc, attempt: f"{get_resources(wc, attempt, 'contig_annotate__eggnog_find_homology')['nvme']}",
        attempt=get_attempt,
    retries: len(get_escalation_order("contig_annotate__eggnog_find_homology"))
    container:
        docker["mag_annotate"]
    shell:""" 
        DATA_DIR="{params.tmp}"

        if [ -z "$DATA_DIR" ]; then
            DATA_DIR="{params.fa}"
        else
            cp {params.fa}/eggnog* {params.tmp} &> {log};
        fi;


         emapper.py -m diamond --data_dir $DATA_DIR --override --no_annot --no_file_comments --cpu {threads} -i {input.files} --output_dir {params.folder} -o {params.out}  2>> {log} 1>&2;
    """
    
rule contig_annotate__eggnog_orthology_chunk:
    """
    Annotate eggnog hits table per chunk (EGGNOG) using /dev/shm for speed,
    with usage counter to ensure DB is only deleted once all jobs are finished.
    """
    input:
        seed=CONTIG_EGGNOG / "{assembly_id}/Chunks/prodigal.chunk.{i}.emapper.seed_orthologs"
    output:
        annotation=CONTIG_EGGNOG / "{assembly_id}/Chunks/prodigal.chunk.{i}.emapper.annotations",
        done = CONTIG_EGGNOG / "{assembly_id}/Chunks/prodigal.chunk.{i}.emapper.annotations.done"
    log:
        CONTIG_EGGNOG / "{assembly_id}/Chunks/prodigal.chunk.{i}.emapper.annotations.log"
    threads: esc("cpus", "contig_annotate__eggnog_orthology_chunk")
    resources:
        runtime=esc("runtime", "contig_annotate__eggnog_orthology_chunk"),
        mem_mb=esc("mem_mb", "contig_annotate__eggnog_orthology_chunk"),
        cpus_per_task=esc("cpus", "contig_annotate__eggnog_orthology_chunk"),
        slurm_partition=esc("partition", "contig_annotate__eggnog_orthology_chunk"),
        gres=lambda wc, attempt: f"{get_resources(wc, attempt, 'contig_annotate__eggnog_orthology_chunk')['nvme']}",
        attempt=get_attempt,
    retries: len(get_escalation_order("contig_annotate__eggnog_orthology_chunk"))    
    container:
        docker["mag_annotate"]
    params:
        fa = features["databases"]["eggnog"],
        out = lambda wc: f"prodigal.chunk.{wc.i}",
        outdir = lambda wc: CONTIG_EGGNOG / f"{wc.assembly_id}/Chunks",
        run_in_shm=config["eggnog_shm"],
        copy_dbs=config["copy_dbs"],
        shm=config["shm_storage"],
        nvme=config["nvme_storage"],
    shell: """
     
      # check if dbs should be copied, otherwise use the original location
        if [ {params.copy_dbs} = "True" ]; then
        
          # check first which destination to use (shm or nvme)
            if [ "{params.run_in_shm}" = "True" ]; then
              echo "Config allowed /dev/shm use for this rule" 2>> {log} 1>&2
              DATA_DIR="{params.shm}/eggnog_data"
            else
              echo "Config disallowed /dev/shm use for this rule, using nvme space instead" 2>> {log} 1>&2
              DATA_DIR="{params.nvme}/eggnog_data"
            fi          
            
          # Initiate the copy and chunk running
            LOCK_FILE="$DATA_DIR/.lock"
            DONE_FILE="$DATA_DIR/.done"
            COUNTER_FILE="$DATA_DIR/.counter"
    
            mkdir -p $DATA_DIR
    
            # === Increment counter safely ===
            (
                flock -x 200
                COUNT=0
                if [ -f "$COUNTER_FILE" ]; then
                    COUNT=$(cat "$COUNTER_FILE")
                fi
                COUNT=$((COUNT + 1))
                echo $COUNT > "$COUNTER_FILE"
                echo "Incremented counter: $COUNT jobs using DB" >> {log}
            ) 200>"$COUNTER_FILE.lock"
    
            # === Copy DB if not already done ===
            # Loops around the acquire attempt (rather than a single
            # try/else) so a stale lock can be detected and broken on any
            # iteration, not just the first.
            if [ ! -f "$DONE_FILE" ]; then
                while true; do
                    if mkdir "$LOCK_FILE" 2>/dev/null; then
                        # Re-check DONE_FILE now that we hold the lock: the
                        # previous holder touches DONE_FILE, THEN removes
                        # LOCK_FILE, so by the time our mkdir succeeds
                        # (retried each loop iteration, unlike the original
                        # single-attempt version) the real work may already
                        # be done -- avoid a needless duplicate copy.
                        if [ -f "$DONE_FILE" ]; then
                            rmdir "$LOCK_FILE"
                            break
                        fi
                        echo "This job has the lock, copying DB..." >> {log}
                        cp -r {params.fa}/* $DATA_DIR/ >> {log} 2>&1
                        touch "$DONE_FILE"
                        rmdir "$LOCK_FILE"
                        break
                    fi
                    if [ -f "$DONE_FILE" ]; then
                        break
                    fi
                    # Stale-lock recovery: if the job that created $LOCK_FILE
                    # died mid-copy (OOM/time-limit/node failure -- normal on
                    # a shared cluster) before reaching `rmdir`, every other
                    # job needing this DB -- including any later retry --
                    # would otherwise sleep here forever, since nothing ever
                    # creates $DONE_FILE. Real, confirmed failure mode
                    # (2026-09-22), not hypothetical. If the lock is older
                    # than 60 minutes (generous margin over a real DB copy)
                    # and DONE_FILE still hasn't appeared, treat it as
                    # abandoned and break it so the next loop iteration can
                    # take over -- mkdir's own atomicity still means only one
                    # concurrently-waiting job actually wins the retry.
                    if [ -z "$(find "$LOCK_FILE" -maxdepth 0 -mmin -60 2>/dev/null)" ]; then
                        echo "Lock $LOCK_FILE is >60min old with no DONE_FILE -- treating as abandoned, breaking it" >> {log}
                        rmdir "$LOCK_FILE" 2>/dev/null || true
                        continue
                    fi
                    echo "Another job is copying the DB, waiting..." >> {log}
                    sleep 30
                done
            fi
      # If db copy is not requested, use the original location
        else 
            DATA_DIR={params.fa}
        fi

        # === Run emapper ===
        mkdir -p {params.outdir}
        emapper.py --data_dir $DATA_DIR \
                   --annotate_hits_table {input.seed} \
                   --no_file_comments \
                   -o {params.out} \
                   --output_dir {params.outdir} \
                   --override \
                   --cpu {threads} >> {log} 2>&1

        # === Decrement counter and cleanup if last job ===
        # Residual known risk, not fully solved here: if a job dies between
        # its own increment (above) and this decrement -- i.e. anywhere
        # during emapper.py's run -- that increment is never balanced, so
        # the counter can never legitimately reach zero again and $DATA_DIR
        # is never cleaned up (a leak, not a crash). Properly fixing that
        # needs real per-job tracking (e.g. one marker file per job, removed
        # on clean exit, counted instead of a mutable integer) rather than a
        # shared counter file -- a bigger change than this pass covers. The
        # guard below only prevents a DIFFERENT, more acute problem: this
        # block crashing outright (and losing an otherwise-successful
        # emapper.py run) if $COUNTER_FILE was already removed by whichever
        # sibling job legitimately finished last and cleaned up first.
        (
            flock -x 200
            COUNT=0
            if [ -f "$COUNTER_FILE" ]; then
                COUNT=$(cat "$COUNTER_FILE")
            fi
            COUNT=$((COUNT - 1))
            if [ $COUNT -le 0 ]; then
                echo 0 > "$COUNTER_FILE"
                echo "No more jobs using DB, cleaning $DATA_DIR" >> {log}
                rm -rf "$DATA_DIR"
                rm -f "$DONE_FILE"
            else
                echo $COUNT > "$COUNTER_FILE"
                echo "Remaining jobs using DB: $COUNT" >> {log}
            fi
        ) 200>"$COUNTER_FILE.lock"

        touch {output.done}
    """

    
rule contig_annotate__eggnog_merge_annotations:
    input:
        contig_annotate_aggregate_annotations_eggnog_search,
    output:
        CONTIG_EGGNOG / "{assembly_id}/eggnog_output.emapper.annotations"
    log:
        CONTIG_EGGNOG / "{assembly_id}/eggnog_output.emapper.annotations.log"
    shell:"""
       cat {input} > {output}.tmp 2> {log}
       mv {output}.tmp {output}
    """


rule contig_annotate__eggnog:
    """Run eggnog on all assemblies"""
    input:
        [CONTIG_EGGNOG / f"{assembly_id}/eggnog_output.emapper.annotations" for assembly_id in ASSEMBLIES],
