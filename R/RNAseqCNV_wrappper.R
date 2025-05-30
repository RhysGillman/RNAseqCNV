#' RNAseqCNV_wrapper
#'
#' Wrapper for generating figures and tables for CNV estimation from RNA-seq
#'
#' @param config path to R script assigning paths to needed directories into variables: 1. count_dir - path to a directory with count files, 2. snv_dir - path to a directory with files with snv information
#' (either vcf or custom tabular data), out_dir - path to an output directory. More detailed description can be found in the package README file.
#' @param metadata path to a metadata table with three columns. First colum: sample names, second column: file names of count files, third column: file names of snv files. There should be no header.
#'  More information is included in the package README file.
#' @param snv_format character string, either "vcf" or "custom". "vcf" argument should be used when vcf files with snv information are generated with GATK. Otherwise "custom" arguments can be used when input
#' with snv iformation has 4 required columns: chromosome, locus of the snv, overall sequencing depth of the locus and MAF. MAF is the proportion of alternative allele sequencing depth to overall sequencing depth of the locus.
#' @param adjust logical value, If TRUE, expression is centered according to the random forest estimated diploid chromosomes. Default = TRUE.
#' @param arm_lvl logical value, If TRUE, arm_lvl figures will be printed (increases run-time significantly). Defaul = TRUE.
#' @param estimate_lab logical value, If TRUE, CNV estimation labels will be included in the final figure.
#' @param genome_version character string, either "hg19" or "hg38" (default). The gene annotation, kept SNPs, pseudoautosomal regions, centromeric regions and standard samples will be
#' selected accordingly to the the chosen version. If the information is supplied by the user by any of these arguments - referData, keptSNP, par_region, centr_refer,
#' the internal data will be overwritten.
#' @param gene_annotation table, reference data for gene annotation with ensamble ids
#' @param SNP_to_keep vector of realiable SNPs to keep for the MAF graphs
#' @param par_regions table with pseudoautosomal regions. These regions will be filtered out.
#' @param centromeric_regions table with chromosomal centromeric locations.
#' @param weight_tab table with per-gene weight for calculating weighted quantiles for the boxplots in the main figure.
#' @param generate_weights logical value, if TRUE, weights for calculating weighted quantiles will be contructed from variance and depth of the analyzed cohort of samples. If batch is TRUE, the weights will be analyzed
#' from the batch of input samples, if FALSE the weight will be generate from joined diploid standard and analyzed sample.
#' @param model_gend random forest model for estimating gender based on the expression of certain genes on chromosome Y.
#' @param model_dip random forest model for estimating whether chromosome arm is diploid.
#' @param model_alter random forest model for estimating the CNVs on chromosome arm.
#' @param model_alter_noSNV random forest model for estimating CNVs on chromosome arm level in case not enough SNV information is available to conctruct MAF density curve.
#' @param batch logical value, if TRUE, the samples will be normalized together as a batch, also gene expression median will be calculated from these samples
#' @param standard_samples character vector with sample names of samples which should be used as a standard for vst and log2 fold centering. The samples names must be included in the metadata table and batch analysis cannot be TRUE. If NULL (default), in-build standard samples will be used.
#' @param CNV_matrix logical value, if TRUE, additional matrix of called CNVs for all analyzed samples will be output
#' @param scale_cols colour scaling for box plots according to the median of a boxplot.
#' @param dpRationChromEdge table with chromosome start and end base positions.
#' @param minDepth minimal depth of of SNV to be kept (default 20).
#' @param mafRange numeric value, two numerical values specifying the range of MAFs of SNVs to be kept (default c(0.05, 0.9))
#' @param minReadCnt numeric value value used for filtering genes with low expression according to to formula: at least samp_prop*100 percent of samples have more reads than minReadCnt. (default 3)
#' @param samp_prop sample proportion which is required to have at least minReadCnt reads for a gene. The samples inlcude the diploid reference (from standard_samples parameter) and analyzed sample. (default 0.8)
#' @param weight_samp_prop proportion of samples with highest weight to be kept. default (1)
#' @export RNAseqCNV_wrapper
RNAseqCNV_wrapper <- function(config, metadata, snv_format, adjust = TRUE, arm_lvl = TRUE, estimate_lab = TRUE, genome_version = "hg38", gene_annotation = NULL, SNP_to_keep = NULL, par_regions = NULL, centromeric_regions = NULL, weight_tab = weight_table, generate_weights = FALSE, model_gend = model_gender, model_dip = model_dipl, model_alter = model_alt,
                              model_alter_noSNV = model_noSNV, batch = FALSE, standard_samples = NULL, CNV_matrix = FALSE, scale_cols = scaleCols, dpRatioChromEdge = dpRatioChrEdge, minDepth = 20, mafRange = c(0.1, 0.9), minReadCnt = 3, samp_prop = 0.8, weight_samp_prop = 1) {

  print("Analysis initiated")
  #Check the config file
  out_dir <- NULL
  count_dir <- NULL
  snv_dir <- NULL

  #check whether a snv_format was selected
  if (is.null(snv_format) | !snv_format %in% c("vcf", "custom")) {
    stop("snv_format parameter has to be either 'vcf' or 'custom'")
  }

  #config file chekcing
  source(config, local = TRUE)
  if (is.null(count_dir) | is.null(snv_dir)) {
    stop("Incorrect config file format")
  }

  if (is.null(out_dir)) {
    out_dir <- file.path(getwd(), "RNAseqCNV_output")
    warning(paste0("The output directory from config file is missing. The results will be saved in:", out_dir))
    dir.create(out_dir)
  } else if (!dir.exists(out_dir)) {
    out_dir_new <- file.path(getwd(), "RNAseqCNV_output")
    warning(paste0("The output directory:", out_dir, " does not exist. The results will be saved in:", out_dir_new))
    out_dir <- out_dir_new
    dir.create(out_dir)
  }
  if (!dir.exists(snv_dir)) {
    stop(paste0("Incorrect information in config file. Directory:", snv_dir, " does not exist"))
  }
  if (!dir.exists(count_dir)) {
    stop(paste0("Incorrect information in config file. Directory:", count_dir, " does not exist"))
  }

  #check metadata file
  metadata_tab = fread(metadata, header = FALSE)
  if (ncol(metadata_tab) != 3) {
    stop("The number of columns in metadata table should be 3")
  }

  #Assign reference data
  if (genome_version == "hg38") {
    referData = gene_annot_hg38
    keptSNP = dbSNP_hg38
    par_region = pseudoautosomal_regions_hg38
    centr_ref = centromeres_hg38
    diploid_standard = diploid_standard_hg38
  } else if (genome_version == "hg19") {
    referData = gene_annot_hg19
    keptSNP = dbSNP_hg19
    par_region = pseudoautosomal_regions_hg19
    centr_ref = centromeres_hg19
    diploid_standard = diploid_standard_hg19
  }

  #If user provided data, use those instead
  if (!is.null(gene_annotation)) {
    referData = gene_annotation
  }
  if (!is.null(SNP_to_keep)) {
    keptSNP = SNP_to_keep
  }
  if(!is.null(par_regions)) {
    par_reg = par_regions
  }
  if(!is.null(centromeric_regions)) {
    centr_ref = centromeric_regions
  }

  #Create sample table
  sample_table = metadata_tab %>% mutate(count_path = file.path(count_dir, pull(metadata_tab, 2)), snv_path = file.path(snv_dir, pull(metadata_tab, 3)))

  #check whether any of the files is missing
  count_check <- file.exists(sample_table$count_path)
  snv_check <- file.exists(sample_table$snv_path)

  if (any(!c(count_check, snv_check))) {
    count_miss <- sample_table$count_path[!count_check]
    snv_miss <- sample_table$snv_path[!snv_check]

    files_miss <- paste0(c(count_miss, snv_miss), collapse = ", ")

    stop(paste0("File/s: ", files_miss, " not found"))
  }

  if (!is.null(standard_samples)) {

    #Check whether both standard samples and batch analysis were not selected together
    if (batch == TRUE & !is.null(standard_samples)) {
      stop("Both batch analysis and single sample analysis with selected standard samples cannot be performed together. Either select batch as FALSE or do not input standard samples")
    }
    #Check whether the samples are present in the sample table
    if (all(standard_samples %in% pull(sample_table, 1)) == FALSE) {
      stop("The input standard samples are not in metadata table.")
    }
    #Create standard sample table
    standard_samples <- create_standard(standard_samples = standard_samples, sample_table = sample_table)

  } else {
    # select first twenty samples from the standard only for the sake of faster of the vst calculation
    cols_ind <- c(1:20, ncol(diploid_standard))
    standard_samples <- diploid_standard[, ..cols_ind]
  }

  #Create estimation table
  est_table <- data.frame(sample = character(),
                          gender = factor(levels = c("female", "male")),
                          chrom_n = integer(),
                          alterations = character(), stringsAsFactors = FALSE)

  #If batch analysis was selected normalize the input samples together
  if(batch == TRUE) {

    print("Normalizing gene expression and applying variance stabilizing transformation...")

    #calculate normalized count values with DESeq2 normalization method for batch of samples from the input
    count_norm <- get_norm_exp(sample_table = sample_table, sample_num = 1, standard_samples = standard_samples, minReadCnt = minReadCnt, samp_prop = samp_prop, weight_table = weight_tab, weight_samp_prop = weight_samp_prop, batch = TRUE, generate_weights)

    #calculate median gene expression across diploid reference and analyzed sample for batch of samples from the input
    pickGeneDFall <- get_med(count_norm = count_norm, refDataExp = referData, generate_weights = generate_weights)

    if (generate_weights == TRUE) {
      #create weights based on variance of gene expression and expression depth of the batch of samples
      weight_tab <- create_weights(pickGeneDFall)
    }
  }



  #Run the analysis for every sample in the table
  for(i in 1:nrow(sample_table)) {

    sample_name <- as.character(sample_table[i, 1])

    #normalize the samples with in-build standard or standard from the input and calculate gene medians
    if(batch == FALSE) {

      #calculate normalized count values with DESeq2 normalization method
      count_norm <- get_norm_exp(sample_table = sample_table, sample_num = i, standard_samples = standard_samples, minReadCnt = minReadCnt, samp_prop = samp_prop, weight_table = weight_tab, weight_samp_prop = weight_samp_prop, batch, generate_weights)

      #calculate median gene expression across diploid reference and analyzed sample
      pickGeneDFall <- get_med(count_norm = count_norm, refDataExp = referData, generate_weights = generate_weights)

      if (generate_weights == TRUE) {
        #create weights based on variance of gene expression and expression depth of the batch of samples
        weight_tab <- create_weights(pickGeneDFall)
      }
    }

    # if count file format was incorrect print out a message and skip this sample
    if (is.character(count_norm)) {
      message(count_norm)
      next()
    }

    #load SNP data
    smpSNP <- prepare_snv(sample_table = sample_table, sample_num = i, centr_ref = centr_ref, snv_format = snv_format, minDepth = minDepth)

    # if SNV data format was incorrect print out a message and skip this sample
    if (is.character(smpSNP[[1]])) {
      message(smpSNP[[1]])
      next()
    }

    #filter SNP data base on dpSNP database
    smpSNPdata.tmp <- filter_snv(smpSNP[[1]], keepSNP = keptSNP, minDepth = minDepth, mafRange = mafRange)

    #analyze chromosome-level metrics (out-dated)
    smpSNPdata <- calc_chrom_lvl(smpSNPdata.tmp)
    #arm-level metrics
    smpSNPdata_a_2 <- calc_arm(smpSNPdata.tmp)

    #select sample
    # count_norm_samp <- count_norm %>% select(!!quo(tidyselect::all_of(sample_name))) %>% mutate(ENSG = rownames(.))
    count_norm_samp <- count_norm %>% select(!!quo(tidyselect::all_of(sample_name))) %>% mutate(ENSG = rownames(.))

    #join reference data and weight data
    count_ns <- count_transform(count_ns = count_norm_samp, pickGeneDFall, refDataExp = referData, weight_table = weight_tab)

    #remove PAR regions
    count_ns <- remove_par(count_ns = count_ns, par_reg = par_region)

    #Calculate metrics for chromosome arms
    feat_tab <- get_arm_metr(count_ns = count_ns, smpSNPdata = smpSNPdata_a_2, sample_name = sample_names, centr_ref = centr_ref)

    #Export the per-arm median of log2 fold change of expression
    log2fold_arm_s <- select(feat_tab, chr, arm, arm_med) %>% mutate(arm_med = round(arm_med, 3))
    colnames(log2fold_arm_s)[3] <- sample_name
    if (i == 1) {
      log2fold_arm <- log2fold_arm_s
    } else {
      log2fold_arm <- merge(log2fold_arm, log2fold_arm_s, by = c('chr', 'arm'))
    }

    #estimate gender
    # count_ns_gend <- count_norm_samp %>% filter(ENSG %in% "ENSG00000012817") %>%  select(ENSG, !!quo(tidyselect::all_of(sample_name))) %>% spread(key = ENSG, value = !!quo(tidyselect::all_of(sample_name)))
    count_ns_gend <- count_norm_samp %>% filter(ENSG %in% "ENSG00000012817") %>%  select(ENSG, !!quo(sample_name)) %>% spread(key = ENSG, value = !!quo(sample_name))
    gender <- ifelse(predict(model_gend, newdata = count_ns_gend, type = "response") > 0.5, "male", "female")

    #preprocess data for karyotype estimation and diploid level adjustement
    # model diploid level
    feat_tab$chr_status <- randomForest:::predict.randomForest(model_dip, feat_tab, type = "class")
    #exclude non-informative regions  and
    #if the model was not able to call changes
    #(mainly due problematic density graphs on chromosome X) change the value to unknown
    feat_tab_dipl <- feat_tab %>%
      filter(arm != "p" | !chr %in% c(13, 14, 15, 21)) %>% mutate(chr_status = ifelse(is.na(chr_status), "unknown", as.character(chr_status))) %>%
      metr_dipl()

    #model alteration on chromosome arms an in case of problematic SNV graph, use model without this information included
    print(paste0("Estimating chromosome arm CNV",": ", sample_name))
    feat_tab_alt <- feat_tab_dipl %>% filter(chr_status != "unknown") %>% mutate(alteration = as.character(randomForest:::predict.randomForest(model_alter, ., type = "class")),
                                            alteration_prob = apply(randomForest:::predict.randomForest(model_alter, ., type = "prob"), 1, max))
    if (any(feat_tab_dipl$chr_status == "unknown")) {
      feat_tab_alt <- feat_tab_dipl %>% filter(chr_status == "unknown") %>% mutate(alteration = as.character(randomForest:::predict.randomForest(model_alter_noSNV, ., type = "class")),
                                                                               alteration_prob = apply(randomForest:::predict.randomForest(model_alter_noSNV, ., type = "prob"), 1, max)) %>%
        bind_rows(feat_tab_alt)
    }

    if (CNV_matrix == TRUE) {
      if (i == 1) {
        alt_matrix <- feat_tab_alt %>% mutate(sample = sample_name, chr_arm = paste0(chr, arm)) %>% select(sample, chr_arm, alteration) %>% pivot_wider(names_from = chr_arm, values_from = alteration)
      } else {
        sample_alt <- feat_tab_alt %>% mutate(sample = sample_name, chr_arm = paste0(chr, arm)) %>% select(sample, chr_arm, alteration) %>% pivot_wider(names_from = chr_arm, values_from = alteration)
        alt_matrix <- bind_rows(alt_matrix, sample_alt)
      }
    }

    feat_tab_alt <- colour_code(feat_tab_alt, conf_tresh = 0.85) %>% group_by(chr) %>%
      mutate(alteration = as.character(alteration), chr_alt = as.character(ifelse(length(unique(alteration)) == 1, unique(alteration), "ab")))

    #estimate karyotype
    kar_list <- gen_kar_list(feat_tab_alt = feat_tab_alt, sample_name = sample_name, gender = gender)
    est_table <- rbind(est_table, kar_list)
    write.table(x = est_table, file = file.path(out_dir, "estimation_table.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)
    write.table(x = cbind(est_table , status = "not checked", comments = "none"), file = file.path(out_dir, "manual_an_table.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)


    #adjust the gene expression according to the estimation of which chromosomes are diploid
    if (adjust == TRUE) {
      count_ns <-  adjust_dipl(feat_tab_alt, count_ns)
    }

    #calculate box plots
    box_wdt <- get_box_wdt(count_ns = count_ns, scaleCols = scale_cols)

    #adjust y axis limits
    ylim <- adjust_ylim(box_wdt = box_wdt, ylim = c(-0.4, 0.4))

    count_ns_final <- prep_expr(count_ns = count_ns, dpRatioChrEdge = dpRatioChromEdge, ylim = ylim)

    # filter low weighted genes for clearer visualization
    #count_ns_final <- filter_expr(count_ns_final = count_ns_final, cutoff = 0.6)

    #Create per-sample folder for figures
    chr_dir = file.path(out_dir, sample_name)
    dir.create(path = chr_dir)

    # Create and plot the main figure
    gg_exp <- plot_exp(count_ns_final = count_ns_final, box_wdt = box_wdt, sample_name = sample_name, ylim = ylim, estimate = estimate_lab, feat_tab_alt = feat_tab_alt, gender = gender)

    gg_snv <- plot_snv(smpSNPdata, sample_name = sample_name, estimate = estimate_lab)

    fig <- arrange_plots(gg_exp = gg_exp, gg_snv = gg_snv)

    print(paste0("Plotting main figure: ", sample_name))

    ggsave(plot = fig, filename = file.path(chr_dir, paste0(sample_name, "_CNV_main_fig.png")), device = 'png', width = 16, height = 10, dpi = 200)


      #plot arm-level figures
      if(arm_lvl == TRUE) {

        chr_to_plot <- c(1:22, "X")

        centr_res <- rescale_centr(centr_ref, count_ns_final)

        print(paste0("Plotting arm-level figures: ", sample_name))

        #plot every chromosome
        for (i in chr_to_plot) {

          print(paste0("Plotting chr ", i, " arm-level figure"))

          gg_exp_zoom <- plot_exp_zoom(count_ns_final = count_ns_final, centr_res = centr_res, plot_chr = i,  estimate = estimate_lab, feat_tab_alt = feat_tab_alt)

          yAxisMax_arm = get_yAxisMax_arm(smpSNPdata = smpSNPdata_a_2, plot_chr = i)

          gg_snv_arm_p <- plot_snv_arm(smpSNPdata_a = smpSNPdata_a_2, plot_arm = "p", plot_chr = i, yAxisMax = yAxisMax_arm)

          gg_snv_arm_q <- plot_snv_arm(smpSNPdata_a = smpSNPdata_a_2, plot_arm = "q", plot_chr = i, yAxisMax = yAxisMax_arm)

          gg_arm <- chr_plot(p_snv = gg_snv_arm_p, q_snv = gg_snv_arm_q, arm_expr = gg_exp_zoom)

          ggsave(filename = file.path(chr_dir, paste0("chromosome_", i, ".png")), plot = gg_arm, device = "png", width = 20, height = 10, dpi = 100)

        }

      }

      print(paste0("Analysis for sample: ", sample_name, " finished"))
  }

  #Order the per-arm median of log2 fold change table and write it into a file
  log2fold_arm <- log2fold_arm %>% mutate(arm = factor(arm, levels = c('p', 'q'))) %>% arrange(chr, arm)
  write.table(log2fold_arm, file = file.path(out_dir, "log2_fold_change_per_arm.tsv"), sep = "\t", row.names = FALSE)

  #Write an estimated matrix into a file
  if (CNV_matrix == TRUE) {
    write.table(alt_matrix, file = file.path(out_dir, "alteration_matrix.tsv"), sep = "\t", row.names = FALSE)
  }
}
