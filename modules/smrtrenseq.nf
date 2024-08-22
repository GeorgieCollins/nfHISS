process TrimReads {
    container 'docker://quay.io/biocontainers/cutadapt:4.9--py312hf67a6ed_0'
    scratch true
    cpus 8
    memory { 1.GB * task.attempt }
    errorStrategy { task.exitStatus == 137 ? 'retry' : 'finish' }
    maxRetries 3
    time '4h'
    input:
    tuple val(sample), path(reads)
    val five_prime
    val three_prime
    output:
    tuple val(sample), path("${sample}_trimmed.fastq.gz")
    script:
    """
    cutadapt \
        -j $task.cpus \
        -g ^$five_prime \
        -a $three_prime\$ \
        -o ${sample}_trimmed.fastq.gz \
        $reads
    """
}

process CanuAssemble {
    container 'docker://quay.io/biocontainers/canu:2.2--ha47f30e_0'
    scratch true
    cpus 8
    memory { 36.GB * task.attempt }
    errorStrategy { task.exitStatus == 137 ? 'retry' : 'finish' }
    maxRetries 3
    time '48h'
    input:
    tuple val(sample), path(reads)
    val genome_size
    val max_input_coverage
    output:
    path "assembly/${sample}_assembly.contigs.fasta"
    path "assembly/${sample}.report"
    publishDir "results/${sample}", mode: 'copy'
    script:
    """
    canu \
        -d assembly \
        -p ${sample}_assembly \
        genomeSize=$genome_size \
        useGrid=false \
        -pacbio-hifi $reads \
        maxInputCoverage=$max_input_coverage \
        batMemory=32g
    """
}

process SeqkitStats {
    container 'docker://quay.io/biocontainers/seqfu:1.20.3--h1eb128b_2'
    scratch true
    cpus 1
    memory { 1.GB * task.attempt }
    errorStrategy { task.exitStatus == 137 ? 'retry' : 'finish' }
    maxRetries 3
    time '1h'
    input:
    path assembly
    tuple val(sample), path(reads)
    output:
    path "${sample}_statistics.txt"
    publishDir "results/${sample}", mode: 'copy'
    script:
    """
    seqkit stats -b $assembly | sed 's/_assembly\\.contigs//g' > ${sample}_statistics.txt
    """
}

process ChopSequences {
    container 'docker://quay.io/biocontainers/meme:5.5.6--pl5321h4242488_0'
    scratch true
    cpus 1
    memory { 2.GB * task.attempt }
    errorStrategy { task.exitStatus == 137 ? 'retry' : 'finish' }
    maxRetries 3
    time '2h'
    input:
    path assembly
    output:
    path 'chopped.fa'
    script:
    """
    chop_sequences.sh -i $assembly -o chopped.fa
    """
}

process NLRParser {
    container 'docker://quay.io/biocontainers/meme:5.5.6--pl5321h4242488_0'
    scratch true
    cpus 2
    memory { 4.GB * task.attempt }
    errorStrategy { task.exitStatus == 137 ? 'retry' : 'finish' }
    maxRetries 3
    time '8h'
    input:
    path chopped
    output:
    path 'parser.xml'
    script:
    """
    nlr_parser.sh -t 2 -i $chopped -o parser.xml
    """
}

process NLRAnnotator {
    container 'docker://quay.io/biocontainers/meme:5.5.6--pl5321h4242488_0'
    scratch true
    cpus 1
    memory { 2.GB * task.attempt }
    errorStrategy { task.exitStatus == 137 ? 'retry' : 'finish' }
    maxRetries 3
    time '4h'
    input:
    path assembly
    path parser_xml
    tuple val(sample), path(reads)
    val flanking
    output:
    path "${sample}_NLR_annotator.txt"
    path "${sample}_NLR_annotator.fa"
    publishDir "results/${sample}", mode: 'copy'
    script:
    """
    nlr_annotator.sh -i $parser_xml -o ${sample}_NLR_annotator.txt -f $assembly ${sample}_NLR_annotator.fa $flanking
    """
}

process SummariseNLRs {
    container 'docker://quay.io/biocontainers/python:3.12'
    scratch true
    cpus 1
    memory { 1.GB * task.attempt }
    errorStrategy { task.exitStatus == 137 ? 'retry' : 'finish' }
    maxRetries 3
    time '2h'
    input:
    path annotator_text
    tuple val(sample), path(reads)
    output:
    path "${sample}_NLR_summary.txt"
    publishDir "results/${sample}", mode: 'copy'
    script:
   """
    #!/usr/bin/env python3
    import csv

    contigs = set()
    count, pseudogenes, genes, complete, complete_pseudogenes = 0, 0, 0, 0, 0

    with open('$annotator_text') as infile:
        infile_reader = csv.reader(infile, delimiter='\t')
        for row in infile_reader:
            count += 1
            contigs.add(row[0])
            nlr_type = row[2]
            if nlr_type == "complete (pseudogene)" or nlr_type == "partial (pseudogene)":
                pseudogenes += 1
            if nlr_type == "complete" or nlr_type == "partial":
                genes += 1
            if nlr_type == "complete":
                complete += 1
            if nlr_type == "complete (pseudogene)":
                complete_pseudogenes += 1

    with open('${sample}_NLR_summary.txt', 'w') as outfile:
        outfile_writer = csv.writer(outfile, delimiter='\t')
        outfile_writer.writerow(
            [
                "NLR Contigs",
                "NLR Count",
                "Pseudogenous NLRs",
                "NLR Genes",
                "Complete NLRs",
                "Complete Pseudogenous NLRs",
            ]
        )

        outfile_writer.writerow(
            [
                len(contigs),
                count,
                pseudogenes,
                genes,
                complete,
                complete_pseudogenes,
            ]
        )
    """ 
}

process InputStatistics {
    scratch true
    cpus 1
    memory { 1.GB * task.attempt }
    errorStrategy { task.exitStatus == 137 ? 'retry' : 'finish' }
    maxRetries 3
    time '2h'
    input:
    path report
    tuple val(sample), path(reads)
    output:
    path "${sample}_input_stats.txt"
    publishDir "results/${sample}", mode: 'copy'
    script:
    """
    Reads=\$(cat $report | grep -m 1 'reads' | cut -f5 -d ' ')
    Bases=\$(cat $report | grep -m 1 'bases' | cut -f5 -d ' ')
    printf "Reads\tBases\n" > ${sample}_input_stats.txt
    printf "\$Reads\t\$Bases" >> ${sample}_input_stats.txt
    """
}

process NLR2Bed {
    container 'docker://quay.io/biocontainers/python:3.12'
    scratch true
    cpus 1
    memory { 1.GB * task.attempt }
    errorStrategy { task.exitStatus == 137 ? 'retry' : 'finish' }
    maxRetries 3
    time '2h'
    input:
    path annotator_text
    output:
    path 'NLR_Annotator.bed'
    script:
    """
    #!/usr/bin/env python3
    import csv

    with open('$annotator_text') as infile, open('NLR_Annotator.bed', 'w') as outfile:
        infile_reader = csv.reader(infile, delimiter='\t')
        outfile_writer = csv.writer(outfile, delimiter='\t')

        for row in infile_reader:
            outfile_writer.writerow([row[0], row[3], row[4], row[1], 0, row[5]])
    """
}

process SortNLRBed {
    scratch true
    cpus 1
    memory { 1.GB * task.attempt }
    errorStrategy { task.exitStatus == 137 ? 'retry' : 'finish' }
    maxRetries 3
    time '1h'
    input:
    path annotator_bed
    tuple val(sample), path(reads)
    output:
    path "${sample}_NLR_Annotator_sorted.bed"
    publishDir "results/${sample}", mode: 'copy'
    script:
    """
    sort -k1,1V -k2,2n -k3,3n $annotator_bed > ${sample}_NLR_Annotator_sorted.bed
    """
}

process MapHiFi {
    container 'https://depot.galaxyproject.org/singularity/minimap2:2.28--he4a0461_0'
    scratch true
    cpus 8
    memory { 8.GB * task.attempt }
    errorStrategy { task.exitStatus == 137 ? 'retry' : 'finish' }
    maxRetries 3
    time '12h'
    input:
    tuple val(sample), path(reads)
    path assembly
    output:
    path 'aligned.sam'
    script:
    """
    minimap2 -x map-hifi -t $task.cpus -a -o aligned.sam $assembly $reads
    """
}

process ParseAlignment {
    container 'https://depot.galaxyproject.org/singularity/samtools:1.20--h50ea8bc_0'
    scratch true
    cpus 2
    memory { 2.GB * task.attempt }
    errorStrategy { task.exitStatus == 137 ? 'retry' : 'finish' }
    maxRetries 3
    time '4h'
    input:
    path sam
    output:
    path 'aligned.bam'
    path 'aligned.bam.bai'
    script:
    """
    samtools view -F 256 $sam -b -o convert.bam -@ $task.cpus
    samtools sort convert.bam -@ $task.cpus > aligned.bam
    samtools index aligned.bam -@ $task.cpus
    """
}

process CalculateCoverage {
    container 'https://depot.galaxyproject.org/singularity/samtools:1.20--h50ea8bc_0'
    scratch true
    cpus 1
    memory { 2.GB * task.attempt }
    errorStrategy { task.exitStatus == 137 ? 'retry' : 'finish' }
    maxRetries 3
    time '2h'
    input:
    path bam
    path nlr_bed
    path index
    output:
    path 'nlr_coverage.txt'
    script:
    """
    samtools bedcov $nlr_bed $bam > nlr_coverage.txt
    """
}

process ParseCoverage {
    container 'docker://quay.io/biocontainers/python:3.12'
    scratch true
    cpus 1
    memory { 1.GB * task.attempt }
    errorStrategy { task.exitStatus == 137 ? 'retry' : 'finish' }
    maxRetries 3
    time '2h'
    input:
    path coverage_text
    tuple val(sample), path(reads)
    output:
    path "${sample}_coverage_parsed.txt"
    publishDir "results/${sample}", mode: 'copy'
    script:
    """
    #!/usr/bin/env python3
    import csv

    coverage = {}
    with open('$coverage_text') as infile:
        infile_reader = csv.reader(infile, delimiter='\t')
        for row in infile_reader:
            average_coverage = float(row[6]) / (float(row[2]) - float(row[1]) + 1)
            coverage[row[3]] = average_coverage
    
    with open('${sample}_coverage_parsed.txt', 'w') as outfile:
        outfile_writer = csv.writer(outfile, delimiter='\t')
        for key, value in coverage.items():
            outfile_writer.writerow([key, value])
    """
}

workflow smrtrenseq {
    reads = Channel.fromPath(params.reads).splitCsv(header: true, sep: "\t").map { row -> tuple(row.sample, file(row.reads)) }
    
    trimmed_reads = TrimReads(reads, params.five_prime, params.three_prime)

    (assembly, report) = CanuAssemble(trimmed_reads, params.genome_size, params.max_input_coverage)

    stats = SeqkitStats(assembly, reads)

    chopped = ChopSequences(assembly)

    parser_xml = NLRParser(chopped)

    (annotator_text, annotator_fa) = NLRAnnotator(assembly, parser_xml, reads, params.flanking)

    nlr_summary = SummariseNLRs(annotator_text, reads)

    input_stats = InputStatistics(report, reads)

    nlr_bed = NLR2Bed(annotator_text)

    sorted_bed = SortNLRBed(nlr_bed, reads)

    sam = MapHiFi(reads, assembly)

    (bam, bai) = ParseAlignment(sam)

    coverage = CalculateCoverage(bam, sorted_bed, bai)

    parsed_coverage = ParseCoverage(coverage, reads)
}
