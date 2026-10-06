rule read_annotate__kraken2__assign:
    """
    Run kraken2 over all samples at once using the /dev/shm/ trick.
    NOTE: /dev/shm may be not empty after the job is done.
    """
    input:
        forwards=[
            FASTP / f"{sample_id}.{library_id}_1.fq.gz"
            for sample_id, library_id in SAMPLE_LIBRARY
        ],
        reverses=[
            FASTP / f"{sample_id}.{library_id}_2.fq.gz"
            for sample_id, library_id in SAMPLE_LIBRARY
        ],
        database=lambda w: features["databases"]["kraken2"][w.kraken_db],
    output:
        out_gzs=[
            KRAKEN2 / "{kraken_db}" / f"{sample_id}.{library_id}.out.gz"
            for sample_id, library_id in SAMPLE_LIBRARY
        ],
        reports=[
            KRAKEN2 / "{kraken_db}" / f"{sample_id}.{library_id}.report"
            for sample_id, library_id in SAMPLE_LIBRARY
        ],
    log:
        KRAKEN2 / "{kraken_db}.log",
    benchmark:
        KRAKEN2 / "benchmark/{kraken_db}.tsv",
    threads: esc("cpus", "read_annotate__kraken2__assign"),
    resources:
        runtime=esc("runtime", "read_annotate__kraken2__assign"),
        mem_mb=esc("mem_mb", "read_annotate__kraken2__assign"),
        cpus_per_task=esc("cpus", "read_annotate__kraken2__assign"),
        slurm_partition=esc("partition", "read_annotate__kraken2__assign"),
        gres=lambda wc, attempt: f"{get_resources(wc, attempt, 'read_annotate__kraken2__assign')['nvme']}",
        attempt=get_attempt,
    retries: len(get_escalation_order("read_annotate__kraken2__assign")),
    params:
        retries=len(get_escalation_order("read_annotate__kraken2__assign")),
        nvme=esc_val("nvme", "read_annotate__kraken2__assign"),
        in_folder=FASTP,
        out_folder=lambda w: KRAKEN2 / w.kraken_db,
        run_in_shm=config["kraken2_shm"],
        copy_dbs=config["copy_dbs"],
        kraken2_shm=KRAKEN2SHM,
        kraken2_nvme=KRAKEN2NVME,
        kraken2_db=lambda w: w.kraken_db,
        kraken_db_shm=lambda w: os.path.join(KRAKEN2SHM, w.kraken_db),
        kraken_db_nvme=lambda w: os.path.join(KRAKEN2NVME, w.kraken_db),
    container:
        docker["preprocess"],
    shell: """
        set +u
        echo "Starting Kraken2 rule attempt {resources.attempt}" > {log}.{resources.attempt} 1>&2

        mkdir --parents {params.out_folder} 2>> {log}.{resources.attempt} 1>&2

        DB_SRC="{input.database}"
        SHM="{params.kraken2_shm}"
        NVME="{params.kraken2_nvme}"
        DB_SHM="{params.kraken_db_shm}"
        DB_NVME="{params.kraken_db_nvme}"
        COPY_DBS="{params.copy_dbs}"

        # Disable /dev/shm if config says so
        if [ "{params.run_in_shm}" != "True" ]; then
            echo "Config disables /dev/shm use for this rule" 2>> {log}.{resources.attempt} 1>&2
            SHM=""
            DB_SHM=""
        fi
        
        : "${{DB_SRC:=}}"
        : "${{SHM:=}}"
        : "${{NVME:=}}"
        : "${{DB_SHM:=}}"
        : "${{DB_NVME:=}}"

        echo "DB_SRC: $DB_SRC, COPY_DBS: $COPY_DBS" 2>> {log}.{resources.attempt} 1>&2
        
        echo "SHM: $SHM, NVME: $NVME" 2>> {log}.{resources.attempt} 1>&2
        
        echo "DB_SHM: $DB_SHM, DB_NVME: $DB_NVME" 2>> {log}.{resources.attempt} 1>&2

        if [ {params.copy_dbs} = "True" ]; then
        
            DB_SIZE=$(du -sb "$DB_SRC" | cut -f1)
            SHM_AVAIL=$(timeout 100s df --output=avail -B1 "$SHM" 2>/dev/null | tail -1 || echo 0)
            NVME_AVAIL=$(timeout 100s df --output=avail -B1 "$NVME" 2>/dev/null | tail -1 || echo 0)
        
            echo "DB_SIZE: $DB_SIZE, SHM_AVAIL: $SHM_AVAIL, NVME_AVAIL: $NVME_AVAIL" 2>> {log}.{resources.attempt} 1>&2

            if [ "$DB_SIZE" -lt "$SHM_AVAIL" ]; then
                DB_DST="$DB_SHM"
                echo "Set DB_DST to $DB_DST (SHM)" 2>> {log}.{resources.attempt} 1>&2
            elif [ "$DB_SIZE" -lt "$NVME_AVAIL" ]; then
                DB_DST="$DB_NVME"
                echo "Set DB_DST to $DB_DST (NVME)" 2>> {log}.{resources.attempt} 1>&2
            else
                if [ {resources.attempt} -eq {params.retries} ]; then
                    DB_DST="$DB_SRC"
                    echo "Not enough space, use DB_SRC" 2>> {log}.{resources.attempt} 1>&2
                else
                    echo "DB too large for available storage, aborting attempt {resources.attempt}" 2>> {log}.{resources.attempt} 1>&2
                    exit 1
                fi
            fi

            if [ "$DB_DST" != "$DB_SRC" ]; then
                echo "Copy input database to $DB_DST" 2>> {log}.{resources.attempt} 1>&2
                mkdir -p "$DB_DST"
                rsync --recursive --times "$DB_SRC"/*.k2d "$DB_DST" 2>> {log}.{resources.attempt}
            fi
        else
            echo "Skipping DB copy — using database in place" 2>> {log}.{resources.attempt} 1>&2
            DB_DST="$DB_SRC"
        fi
        
        echo "Running Kraken2 using DB_DST=$DB_DST" 2>> {log}.{resources.attempt} 1>&2

        # --memory-mapping (-M) is only fast when DB_DST is actually sitting
        # on something RAM-backed (a successful /dev/shm or NVMe copy above).
        # When no copy happened -- DB_DST fell back to DB_SRC, the database's
        # original location on shared/networked storage -- mmap turns every
        # hash-table lookup during classification into a random-access page
        # fault out to that shared disk. Real, confirmed symptom (2026-10-05,
        # against a ~1.2TB database too big for this node's /dev/shm, itself
        # capped at ~50% of physical RAM by Linux, not 100%): the classify
        # process sat at ~11GB RSS, ~2% CPU, with its output not growing
        # across repeated checks minutes apart -- alive, but making no real
        # progress, for 19.5+ hours. Without -M, kraken2 instead does one
        # real bulk sequential read of the database into the job's own
        # process heap (sized by this rule's mem_mb, not /dev/shm's ceiling)
        # as a one-time cost, which is also far cheaper than mmap's scattered
        # access pattern when reading from Lustre/shared disk. Note this
        # means the no-copy fallback path needs mem_mb to cover the FULL
        # database as real process RSS, not just the smaller "+10% over
        # documented DB size" margin above that assumed mmap/shm access --
        # already correctly sized for the database configured here, but
        # worth re-checking before pointing this rule at a much larger one.
        MMAP_FLAG="--memory-mapping"
        if [ "$DB_DST" = "$DB_SRC" ]; then
            echo "DB not copied to fast storage -- dropping --memory-mapping, will bulk-load into process memory instead" 2>> {log}.{resources.attempt} 1>&2
            MMAP_FLAG=""
        fi

        for file in {input.forwards}; do
            sample_id=$(basename "$file" _1.fq.gz)
            forward={params.in_folder}/${{sample_id}}_1.fq.gz
            reverse={params.in_folder}/${{sample_id}}_2.fq.gz
            output={params.out_folder}/${{sample_id}}.out.gz
            report={params.out_folder}/${{sample_id}}.report
            log_file={params.out_folder}/${{sample_id}}.log

            echo "Processing $sample_id" 2>> {log}.{resources.attempt} 1>&2

            kraken2 \
                --db "$DB_DST" \
                --threads {threads} \
                --gzip-compressed \
                --paired \
                --output >(pigz --processes {threads} > "$output.tmp") \
                --report "$report.tmp" \
                $MMAP_FLAG \
                "$forward" "$reverse" \
            2> "$log_file" 1>&2

            mv "$report.tmp" "$report"
            mv "$output.tmp" "$output"
        done

        if [ "{params.run_in_shm}" = "True" ] && [ "$DB_DST" = "$DB_SHM" ]; then
            rm -rfv "$DB_DST" 2>> {log}.{resources.attempt}
        fi

        mv {log}.{resources.attempt} {log}
    """


rule read_annotate__kraken2:
    """Run kraken2 over all samples at once using the /dev/shm/ trick."""
    input:
        [
            KRAKEN2 / kraken_db / f"{sample_id}.{library_id}.report"
            for sample_id, library_id in SAMPLE_LIBRARY
            for kraken_db in features["databases"]["kraken2"]
        ],
