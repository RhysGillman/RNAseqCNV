#' Importing packages
#' @import shiny
#' @import tidyr
#' @import dplyr
#' @importFrom magrittr %>%
#' @import ggplot2
#' @import stringr
#' @importFrom data.table fread
#' @import ggpubr
#' @import shinyFiles

#### functions for deseq norm testing ####

# get normalized counts
get_norm_exp <- function(sample_table, sample_num, standard_samples, minReadCnt, samp_prop, weight_table, weight_samp_prop, batch, generate_weights) {

  #extract file names from sample table
  count_file <- pull(sample_table, "count_path")[sample_num]
  sample_n <- pull(sample_table, 1)[sample_num]

  #read the count table
  count_table <- fread(file = count_file)
  data.table::setnames(count_table, colnames(count_table), c("ENSG", "count"))

  #check the count file format
  if (ncol(count_table) != 2 | !is.numeric(count_table[, count])) {
    return(paste0("Incorrect count file format for the sample: ", sample_n))
  }

  # set column to join by
  data.table::setkey(count_table, ENSG)

  if(batch == TRUE) {
    for (i in 2:nrow(sample_table)) {

      #extract file names from sample table
      count_file <- pull(sample_table, "count_path")[i]
      sample_n <- pull(sample_table, 1)[i]

      #read the count table
      count_table_sample <- fread(file = count_file)
      data.table::setnames(count_table_sample, colnames(count_table_sample), c("ENSG", "count"))

      #check the count file format
      if (ncol(count_table_sample) != 2 | !is.numeric(count_table_sample[, count])) {
        return(paste0("Incorrect count file format for the sample: ", sample_n))
      }

      #bind the tables together
      data.table::setkey(count_table_sample, ENSG)
      count_table <- count_table[count_table_sample, nomatch = 0]

    }
    final_mat <- as.data.frame(count_table)
  } else {

    #inner join diploid reference and analyzed sample
    data.table::setkey(standard_samples, ENSG)
    final_mat <- as.data.frame(count_table[standard_samples, nomatch = 0])

  }

  #keep genes for determining gender for later
  gender_genes = final_mat %>% filter(ENSG %in% "ENSG00000012817")

  #filter genes based on reads count; top 1-q have read count > N, filter base on weight
  keepIdx_tmp = final_mat %>% mutate(keep_gene = apply(.[, -1], MARGIN = 1, FUN = function(x) sum(x > minReadCnt) > (length(x) * samp_prop)), id = row_number()) %>% filter(keep_gene == TRUE)

  if (generate_weights == FALSE) {
    keepIdx = keepIdx_tmp %>% inner_join(weight_table, by = "ENSG") %>% group_by(chromosome_name) %>% mutate(weight_chr_quant = quantile(weight, 1 - weight_samp_prop)) %>% filter(weight >= weight_chr_quant) %>% pull(id)
  } else {
    keepIdx = keepIdx_tmp %>% pull(id)
  }

  # filter table for normalization, get rid of genes with 0 counts and keep genes for gender estimation
  count_filt <- final_mat %>% .[c(keepIdx), ] %>% .[pull(., 2) != 0, ] %>% bind_rows(gender_genes) %>% distinct(ENSG, .keep_all = TRUE)
  ENSG <- count_filt$ENSG
  count_filt <- select(count_filt, -ENSG)

  #sample Deseq normalization
  count_col <- as.data.frame(colnames(count_filt))

  dds <- DESeq2::DESeqDataSetFromMatrix(colData = count_col, countData = count_filt, design= ~ 1)
  dds_vst <- DESeq2::varianceStabilizingTransformation(dds, blind=T, fitType='local')
  count_norm <- as.data.frame(SummarizedExperiment::assay(dds_vst))

  if (batch == TRUE) {
    colnames(count_norm) <- pull(sample_table, 1)
    print(paste0("Normalization completed"))
  } else {
    colnames(count_norm)[1] <- sample_n
    colnames(count_norm)[2:ncol(count_norm)] <- paste0("control_", 1:(ncol(count_norm)-1))
    print(paste0("Normalization for sample: ", sample_n, " completed"))
  }

  #Modify table for downstream analysis
  rownames(count_norm) <- ENSG

  return(count_norm)
}

#calculate geometric mean
gm_mean = function(a){prod(a)^(1/length(a))}

####get median expression level####
get_med <- function(count_norm, refDataExp, weight_table, generate_weights) {

  ENSG=rownames(count_norm)

  ####calculate median for all genes####
  pickGeneDFall_tmp=count_norm %>% mutate(ENSG=ENSG) %>% left_join(select(refDataExp, chr, ENSG), by = "ENSG")
    if (generate_weights == TRUE) {
      pickGeneDFall <- pickGeneDFall_tmp %>% mutate(med = apply(.[, -c(ncol(.) - 1, ncol(.))], 1, median), var = apply(.[, -c(ncol(.) - 1, ncol(.))], 1, var)) %>%
        select(ENSG, chr, med, var)
    } else {
      pickGeneDFall <- pickGeneDFall_tmp %>% mutate(med = apply(.[, -c(ncol(.) - 1, ncol(.))], 1, median)) %>%
        select(ENSG, med)
    }

  return(pickGeneDFall)
}

####prepare snv files####
prepare_snv <- function(sample_table, centr_ref, sample_num, minDepth, snv_format = c("vcf", "custom")) {

  snv_file <- pull(sample_table, snv_path)[sample_num]
  sample_n <- pull(sample_table, 1)[sample_num]

  smpSNP=list()
  print(paste("Preparing file with snv information for:", sample_n))

  #prepare data from custom table
  if (snv_format == "custom") {
    #read the table
    snv_table_pre <- fread(snv_file)

    #check if all appropriate columns are present
    cols <- colnames(snv_table_pre)
    chr <- str_which(cols, "^#Chromosome$|#CHROM$|^CHR$|^chr$|^Chr$|^CHROM$|^chrom$|^Chrom$|^CHROMOSOME$|^chromosome$|^Chromosome$")
    start <- str_which(cols, "^START$|^start$|^Start$|^POS$|^pos$|^Pos$")
    depth <- str_which(cols, "^DEPTH$|^depth$|^Depth$|^DP$|^dp$|^Dp$")
    maf <- str_which(cols, "^MAF$|^maf$|^Maf$|^HET$|^het$|^Het$")
    to_keep <- as.numeric(c(chr, start, depth, maf))
    if (length(to_keep) != 4) {
      smpSNP[[sample_n]] <- "Incorrect column name in a custom snv file."
      return(smpSNP)
    }
    snv_table <- snv_table_pre[, to_keep, with = FALSE]
    data.table::setnames(snv_table, colnames(snv_table), c("chr", "start", "depth", "maf"))

    #Check some column parameters
    if (is.numeric(snv_table[, start]) == FALSE | is.numeric(snv_table[, depth]) == FALSE | is.numeric(snv_table[, maf]) == FALSE) {
      smpSNP[[sample_n]] <- "Incorrect type of a column in a custom file with snv information."
      return(smpSNP)
    }

  } else if (snv_format == "vcf") {
    snv_table <- vcf_to_snv(snv_file)
    if(is.character(snv_table)) {
      smpSNP[[sample_n]] <- snv_table
      return(smpSNP)
    }
  }

  smpSNP[[as.character(sample_n)]] <- snv_table %>% filter(chr %in% c(c(1:22, "X"), paste0("chr", c(1:22, "X")))) %>% mutate(chr = sub("chr", "", chr)) %>% left_join(centr_ref, by = "chr") %>%
    mutate(chr = factor(chr, levels=c(1:22, "X")), ID=paste0(chr,"-", start), sampleID=sample_n) %>% mutate(arm = ifelse(start < cstart, "p", ifelse(start > cend, "q", "centr")))

  return(smpSNP)
}


####filter SNVs of interest for samples###
filter_snv <- function(one_smpSNP, keepSNP, minDepth, mafRange) {

  smpSNPdata.tmp= one_smpSNP %>% dplyr::select(sampleID, ID, maf, chr, start, depth, arm) %>%
    filter(data.table::inrange(maf, mafRange[1], mafRange[2]), depth > minDepth) %>% filter(chr != "Y")
  if (keepSNP[1] != FALSE) {
    smpSNPdata.tmp <- smpSNPdata.tmp %>% filter(ID %in% keepSNP)
  }
  return(smpSNPdata.tmp)
}


####Calculate peak statistics for whole chromosome####
calc_chrom_lvl <- function(smpSNPdata.tmp) {
  smpSNPdata <- smpSNPdata.tmp %>% group_by(chr) %>% arrange(chr, desc(depth) ) %>%
    #mutate(snvOrd=1:n()) %>% 
    mutate(snvOrd = row_number()) %>%
    filter(snvOrd<=1000) %>%
    mutate(snvNum=n(), peak_max=densityMaxY(maf),
           peak=findPeak(maf), peakCol=ifelse(between(peak, 0.42, 0.58), 'black', 'red'), peakdist = find_peak_dist(maf)) %>%
   ungroup() %>% mutate(chr = factor(chr, levels = c(1:22, "X")))
  return(smpSNPdata)
}

####Calculate peak statistics for arms separately#s###
calc_arm_lvl <- function(smpSNPdata.tmp) {
  smpSNPdata_a=smpSNPdata.tmp %>% group_by(chr, arm) %>% arrange(chr, desc(depth) ) %>%
    mutate(snvNum=n(), peak_max=densityMaxY(maf),
           peak=findPeak(maf), peakCol=ifelse(between(peak, 0.42, 0.58), 'black', 'red'), peakdist = find_peak_dist(maf)) %>%
    ungroup() %>% mutate(chr = factor(chr, levels = c(1:22, "X")))
  return(smpSNPdata_a)
}

####normalize normalized counts (against median of expression for each gene) and join weight values####
#beta-needs cleaning
count_transform <- function(count_ns, pickGeneDFall, refDataExp, weight_table) {
  count_ns_tmp = count_ns %>% left_join(select(pickGeneDFall, ENSG, med), by = "ENSG") %>%
    mutate(count_nor_med=log2(.[, 1] / med) ) %>% filter(med != 0)
  sENSGinfor=refDataExp[match(count_ns_tmp$ENSG, refDataExp$ENSG), ] %>% select(chr, end, start)

  #keeping only the genes which have weights calculated for geom_poit and boxplot
  count_ns = cbind(sENSGinfor, count_ns_tmp) %>% inner_join(weight_table, by = "ENSG")
}

####filter out par regions####
remove_par <- function(count_ns, par_reg) {
  #### get rid of PAR regions

  parX = filter(par_reg, chr == "X")
  parX <- as.data.frame(parX)
  count_ns = count_ns %>% filter(chr != "X" | ! data.table::inrange(start, parX[1, 1], parX[1, 2]) & ! data.table::inrange(start, parX[2, 1], parX[2, 2]) &
                                 ! data.table::inrange(end, parX[1, 1], parX[1, 2]) & !  data.table::inrange(end, parX[2, 1], parX[2, 2]))
  parY = filter(par_reg, chr == "Y")
  parY <- as.data.frame(parY)
  count_ns = count_ns %>% filter(chr != "Y" | ! data.table::inrange(start, parY[1, 1], parY[1, 2]) & ! data.table::inrange(start, parY[2, 1], parY[2, 2]) &
                             ! data.table::inrange(end, parY[1, 1], parY[1, 2]) & !  data.table::inrange(end, parY[2, 1], parY[2, 2]))
}

####Calculate weighted boxplot values####
get_box_wdt <- function(count_ns, scaleCols) {
  box_wdt <- count_ns %>% filter(chr %in% c(1:22, "X"))  %>% group_by(chr) %>% mutate(med_weig = weighted_quantile(x = count_nor_med, w = weight, probs = 0.5, na.rm = TRUE), low = weighted_quantile(x = count_nor_med, w = weight, probs = 0.25),
                                                                                   high = weighted_quantile(x = count_nor_med, w = weight, probs = 0.75), IQR = abs(high - low), max = high + IQR*1.5, min = low - IQR*1.5) %>%
    distinct(chr, .keep_all = TRUE)

  colours <- c()
  for(i in 1:nrow(box_wdt)) {
    colours[i] <- scaleCols$colour[which.min(abs(box_wdt$med_weig[i] - scaleCols$med_expr))]
  }

  box_wdt <- box_wdt %>% ungroup() %>% mutate(medianCol = colours) %>% select(chr, med_weig, low, high, min, max, medianCol) %>%
    mutate(chr = factor(x = chr, levels = c(1:22, "X")), pos = 0.5)

  return(box_wdt)
}

#### change ylim accordingly values in graph
adjust_ylim <- function(box_wdt, ylim) {
  box_wdt_noy <- filter(box_wdt, !chr %in% "Y")
  if (any(box_wdt_noy$max > ylim[2])) {
    ylim[2] <- max(box_wdt_noy$max)*1.1
  }

  if (any(box_wdt_noy$min < ylim[1])) {
    ylim[1] <- min(box_wdt_noy$min)*1.1
  }
  return(ylim)
}

####Apply limit to datapoints and normalize point position####
prep_expr <- function(count_ns, dpRatioChrEdge, ylim) {
  count_ns_final= count_ns %>% select(chr, end, count_nor_med, weight) %>%
    bind_rows(dpRatioChrEdge) %>% filter(chr %in% c(1:22, "X"), between(count_nor_med, ylim[1], ylim[2]) ) %>%
    mutate(chr=factor(chr, levels = c(1:22, "X"))) %>%
    arrange(chr, end) %>% group_by(chr) %>%
    mutate(normPos=scales::rescale(end, from = range(end, na.rm = TRUE)))
  return(count_ns_final)
}

filter_expr <- function(count_ns_final, cutoff = 0.6) {
  count_ns_final <- count_ns_final %>% filter(weight >= quantile(weight, cutoff, na.rm = TRUE))
}

####plot expression boxplot and point plot####
plot_exp <- function(count_ns_final, box_wdt, sample_name, ylim, estimate, feat_tab_alt, gender) {
  gp_expr <- ggplot() + ylim(ylim) + ylab("log2 fold change of expression") +
    scale_fill_identity()+
    geom_point(data = count_ns_final, aes(x = normPos, y = count_nor_med, size = 0.2), alpha = 0.32, show.legend = FALSE)+
    #scale_size(range = c(2, 6)) +
    #scale_alpha(range = c(0.22, 0.4)) +
    geom_boxplot(data = box_wdt, aes(ymin = min, lower = low, middle = med_weig, upper = high, ymax = max, fill=medianCol, x = pos), alpha=0.75, outlier.colour = NA, stat = "identity", show.legend = FALSE)+
    geom_hline(yintercept = 0, colour = "red")+
    labs(title = paste0(sample_name),
    subtitle = paste0("estimated gender: ", gender))
  if (estimate == TRUE) {
    gp_expr <- gp_expr +
      geom_point(data = data.frame(x = c(0.5, 0.5), y = c(ylim[2], ylim[2]), point_col = c("low", "high"), chr = factor(c(1, 1), levels = c(1:22, "X"))), mapping = aes(x = x, y = y, color = point_col), shape = 0, size = 4, stroke = 2) +
      geom_label(data = distinct(feat_tab_alt, chr, colour_chr, chr_alt), aes(x = 0.5, y = ylim[2], color = colour_chr, label = chr_alt), label.size = 2, show.legend = FALSE) +
      scale_color_manual(limits = c("low", "high"), values=c("orangered", "black")) +
      guides(color = guide_legend(
        title = "Quality"
      ))
    }

  gp_expr <- gp_expr +
    facet_grid(.~chr) +
    theme_bw() +
    theme(plot.title = element_text(hjust = 0.5, size = 18),
          plot.subtitle = element_text(hjust = 0.5, size = 12),
          axis.title.x=element_blank(),
          axis.text.x = element_blank(),
          axis.title.y = element_text(size = 15),
          axis.text.y = element_text(size = 12),
          axis.ticks = element_blank(),
          legend.justification = "top",
          legend.text = element_text(size = 15),
          legend.title = element_text(size = 17)) +
    guides(size = "none")
}

####plot snv density plots####
plot_snv <- function(smpSNPdata, sample_name, estimate) {

  missedChr=c(1:22, "X")[table(smpSNPdata$chr) < 15]
  if(length(missedChr) > 0){
    tmpSNPdata=data.frame(sampleID = sample_name, ID=paste0(missedChr, "-1"), maf=0.5, chr=factor(missedChr, levels = c(1:22, "X")), start=1,
                          depth=100, snvOrd=1, snvNum=1, peak_max=0, peak=0, peakCol="red", stringsAsFactors = F)
    smpSNPdata = bind_rows(smpSNPdata, tmpSNPdata)
  }
  if(nrow(smpSNPdata)<500){
    gp.maf=ggplot()+annotate("text", x = 1, y = 1, label = "Low coverage")+theme_void()
  }else{
    snvNumDensityMaxY=smpSNPdata %>% select(chr, snvNum, peak_max, peakdist) %>% unique()
    yAxisMax=snvNumDensityMaxY %>% filter(snvNum > 100) %>% .$peak_max %>% max()
    snvNumDF = snvNumDensityMaxY %>% mutate(x=0.5, y=yAxisMax*1.05)
    peakdist_dat = snvNumDensityMaxY %>% mutate(x = 0.5, y = yAxisMax*1.1, label = round(peakdist, 3))
    gp.maf=ggplot(data=smpSNPdata) + xlab("Minor allele frequency") + ylab("Density") +
      geom_density(aes(maf, color=peakCol), show.legend = FALSE) +
      geom_vline(xintercept = c(1/3, 0.5, 2/3), alpha = 0.4, size = 0.5)+
      geom_label(data = peakdist_dat, aes(x, y, label = label), fill = "white", color = "black", vjust=0)+
      scale_color_identity(guide = guide_legend(override.aes = list(color = "white")))+
      scale_x_continuous(breaks = round(c(1/3, 2/3), 3), labels = c("1/3", "2/3"), minor_breaks = NULL, limits = c(0,1)) +
      scale_y_continuous(breaks = c(seq(from = 1, to = floor(yAxisMax)), yAxisMax*1.15), labels = c(seq(from = 1, to = floor(yAxisMax)), "peak dist."), limits = c(0, yAxisMax*1.25)) +
      facet_grid(.~chr, scales="free_y") +
      theme_bw() +
      theme(axis.text.x = element_text(angle = 40, vjust = 0.5),
            axis.ticks = element_blank(),
            strip.background = element_blank(),
            strip.text.x = element_blank(),
            axis.title.x = element_text(size = 17),
            axis.title.y = element_text(size = 15),
            axis.text.y = element_text(size = 12),
            plot.margin = unit(c(0,1,1,1), "lines")
      )
    if (estimate == TRUE) {
      #need to add identical legend as for the expression in order for the graphs to align correctly with ggarrange
      gp.maf <- gp.maf +
        geom_point(data = data.frame(x = c(0.5, 0.5), y = c(0, 0), point_col = c("white", "white"), chr = factor(c(1, 1), levels = c(1:22, "X"))), mapping = aes(x = x, y = y, color = point_col), shape = 20, size = 5, alpha = 0) +
        guides(color = guide_legend(
          title = "Quality"
        )) +
        theme(
          legend.text = element_text(color = "white", size = 15),
          legend.title = element_text(color = "white", size = 17),
          legend.key = element_blank(),
          legend.justification = "top"
        )
    }
  }
  return(gp.maf)
}

####arrange expression and snv graph####
arrange_plots <- function(gg_exp, gg_snv) {
  fig <- ggarrange(plotlist =list(expr=gg_exp, maf=gg_snv)
                , ncol = 1, nrow = 2, heights = c(3, 1), align='v')
  return(fig)
}


####arm level utilities####
#### rescale centromeric region ####
rescale_centr <- function(centr_ref, count_ns_final) {
  count_ns_range <- count_ns_final %>% group_by(chr) %>% summarise(chr_end = max(end)) %>% mutate(chr_start = 1)
  centr_res <- centr_ref  %>% filter(chr != "Y") %>% mutate(chr = factor(chr, levels = c(1:22, "X"))) %>% left_join(count_ns_range, by = "chr") %>% mutate(p_mid = cstart/2, q_mid = cend + (chr_end - cend)/2)
  rescaled <- data.frame(cstartr = c(), cendr = c(), p_midr = c(), q_midr = c())

  for (i in 1:nrow(centr_res)) {
    cstartr_chr <- scales::rescale(centr_res$cstart[i], from = c(centr_res$chr_start[i], centr_res$chr_end[i]))
    cendr_chr <- scales::rescale(centr_res$cend[i], from = c(centr_res$chr_start[i], centr_res$chr_end[i]))
    p_midr <- scales::rescale(centr_res$p_mid[i], from = c(centr_res$chr_start[i], centr_res$chr_end[i]))
    q_midr <- scales::rescale(centr_res$q_mid[i], from = c(centr_res$chr_start[i], centr_res$chr_end[i]))
    rescaled <- rbind(rescaled, c(cstartr_chr, cendr_chr, p_midr, q_midr))
  }
  colnames(rescaled) <- c("cstartr", "cendr", "p_midr", "q_midr")
  centr_res <- cbind(centr_res, rescaled) %>% select(chr, cstartr, cendr, p_midr, q_midr)

  return(centr_res)
}

####draw zoomed in expression graph####
plot_exp_zoom <- function(count_ns_final, centr_res, plot_chr, estimate, feat_tab_alt) {

  #filter only for chromosome of interest

  count_ns_chr <- filter(count_ns_final, chr == plot_chr, count_nor_med < 0.5 & count_nor_med > -0.5)

  gg_expr_zoom = ggplot(data=count_ns_chr) + ylim(c(-0.5, 0.5)) + ylab("Normalized expression") +
    geom_point(aes(x = normPos, y = count_nor_med, size = weight), alpha=0.6) +
    scale_size(range = c(1,5)) +
    geom_smooth(aes(x = normPos, y = count_nor_med, weight = weight), alpha = 0.5, size = 0.5, method = "loess", formula = 'y ~ x', se = FALSE) +
    annotate("segment", x = 0, xend = 1, y = 0, yend = 0,
             colour = "red", alpha = 0.85) +
    scale_x_continuous(expand = c(0,0)) +
    geom_vline(data = filter(centr_res, chr == plot_chr), mapping = aes(xintercept = cstartr)) +
    geom_vline(data = filter(centr_res, chr == plot_chr), mapping = aes(xintercept = cendr)) +
    ggtitle(paste0("chromosome ", plot_chr)) +
    theme_bw() +
    theme(legend.position = "none",
          plot.title = element_text(hjust = 0.5, size = 20),
          axis.text = element_text(size = 16),
          axis.title = element_text(size = 17),
          axis.title.x = element_blank(),
          axis.text.x = element_blank(),
          axis.ticks = element_blank())

  if (estimate == TRUE) {

    q_alt <- feat_tab_alt %>% filter(arm == "q", chr == plot_chr)
    p_alt <- feat_tab_alt %>% filter(arm == "p", chr == plot_chr)

    gg_expr_zoom <- gg_expr_zoom +
      geom_label(data = q_alt, aes(x = centr_res$q_midr[centr_res$chr == plot_chr], y = 0.4, label = paste0(alteration, ", " , alteration_prob*100, "%"), color = colour_arm, size = 15000)) +
      scale_color_manual(limits = c("low", "high"), values=c("orangered", "black")) +
      if(nrow(p_alt) > 0) {
        geom_label(data = p_alt, aes(x = centr_res$p_midr[centr_res$chr == plot_chr], y = 0.4, label = paste0(alteration, ", " , alteration_prob*100, "%"), color = colour_arm, size = 15000))
      }
  }



  return(gg_expr_zoom)
}


####calculate per chromosome max of y axis for arm level MAF graphs
get_yAxisMax_arm <- function(smpSNPdata_arm, plot_chr) {

  smpSNP_arm_chr <- smpSNPdata_arm %>% filter(chr == plot_chr)
  yAxisMax_arm <- smpSNP_arm_chr %>% distinct(arm, peak_max) %>% summarise(y_max = max(peak_max)) %>% pull(y_max)
  return(yAxisMax_arm)

}

####draw snv graph for chromosome arm####
plot_snv_arm <- function(smpSNPdata_a, plot_arm, plot_chr, yAxisMax) {

  smpSNP_arm <- filter(smpSNPdata_a, chr == plot_chr, arm == plot_arm)

  SNP_ann <- smpSNP_arm %>% select(chr, snvNum, peak_max, peakdist) %>% unique()

  peakdist_dat = SNP_ann %>% mutate(x = 0.5, y = yAxisMax*1.15, label = round(peakdist, 3))

  if (nrow(smpSNP_arm) < 10) {
    gg_snv_arm = ggplot() + ylim(0, yAxisMax*1.2)+
      scale_x_continuous(limits = c(0,1)) +
      annotate("text", x = 0.5, y = 0.8 * yAxisMax, label = "Low coverage")+
      ggtitle(paste0(plot_arm, " arm")) +
      theme_void() +
      theme(plot.margin = unit(c(0,1,1,1), "lines"), plot.title = element_text(hjust = 0.5, size = 20))
  } else {
    gg_snv_arm <- ggplot(data=smpSNP_arm) + xlab("Mutant allele frequency") + ylab("Density") + ylim(0, yAxisMax*1.2) +
      geom_density(aes(maf, color=peakCol)) +
      geom_text(data = peakdist_dat, aes(x, y, label = paste0("peak dist. = ", label)), vjust=0, size = 6)+
      geom_vline(xintercept = c(1/3, 0.5, 2/3), alpha = 0.4, size = 0.5)+
      scale_color_identity()+
      scale_x_continuous(breaks = round(c(1/3, 0.5, 2/3), 2), minor_breaks = NULL, limits = c(0,1), labels = c("1/3", "1/2", "2/3")) +
      ggtitle(paste0(plot_arm, " arm")) +
      theme_bw() +
      theme(axis.text = element_text(size = 16), axis.ticks = element_blank(),
            strip.background = element_blank(), strip.text.x = element_blank(),
            plot.margin = unit(c(0,1,1,1), "lines"), plot.title = element_text(hjust = 0.5, size = 20),
            axis.title = element_text(size = 17)
      )
  }

  # switcht axis side and remove q arm y axis title
  if (plot_arm == "q") {
    suppressMessages(gg_snv_arm <- gg_snv_arm +
                       theme(axis.title.y.left = element_blank(),
                             axis.text.y.left = element_blank(),
                             axis.ticks.y.left = element_blank()) +
                       scale_y_continuous(position = "right") +
                       ylab("Density"))
  }

  return(gg_snv_arm)
}

####arrange arm graphs####
chr_plot <- function(p_snv, q_snv, arm_expr) {
  chr_arm_level <- ggarrange(plotlist = list(p_snv, arm_expr, q_snv), ncol = 3, widths = c(1.2, 4, 1.2), align = "h")
  return(chr_arm_level)
}

####modify decimals####
specify_decimal <- function(x, k) {
  trimws(format(round(x, k), nsmall=k))
}

####find peak in a vector####
findPeak <- function(vec){
  vec=vec[between(vec, 0.1, 0.9)]
  len=length(vec)
  if(len < 10){
    return(0)
  }else{
    d=density(vec)
    maxVec=max(d$y)
    maxPos=d$x[d$y == maxVec]
    # peak=d$x[which(d$y==max(d$y[which(diff(sign(diff(d$y) ))==-2)]))]
    return(maxPos[1])
  }
}

####find peak distance####
find_peak_dist <- function(vec) {
  len=length(vec)
  if(len < 10){
    return(0)
  }else{
    d=density(vec)
    #Choose the two highest peaks from the MAF density curve
    peaks_max = d$x[which(d$y %in% sort(d$y[which(diff(sign(diff(d$y) ))==-2)], decreasing = TRUE)[1:2])]
    #making sure the distance is measured between symetric peaks
    #symmetry treshold set at 1.2
    if (length(na.omit(peaks_max)) > 1 & data.table::inrange(max(peaks_max - 0.5), 0.42 - min(peaks_max), 0.58 - min(peaks_max))) {
      dist_peak <- abs(peaks_max[1] - peaks_max[2])
      return(dist_peak)
    } else {
      return(0)
    }
  }
}

####find max on y axis from density vector of allele frequency####
densityMaxY <- function(vec){
  len=length(vec)
  if(len < 10){
    return(0)
  }else{
    d=density(vec)
    return(max(d$y))
  }
}

######height of density curve on 0.5 on x axis
find_y_0.5 <- function(vec) {
  vec=vec[between(vec, 0.1, 0.9)]
  len=length(vec)
  if(len < 10){
    return(0)
  }else{
    d=density(vec)
    peak_0.5=d$y[which.min(abs(d$x - 0.5))]
    return(peak_0.5)
  }
}

####adjust for diploid level based on diploid chromosomes####
adjust_dipl <- function(feat_tab_alt, count_ns) {

  if (sum(feat_tab_alt$chr_status == "dipl", na.rm = TRUE) < 1) {
    print("Unable to adjust expression level")
    return(count_ns)
  }

  baseline_shift = median(feat_tab_alt$arm_med[feat_tab_alt$chr_status == "dipl"], na.rm = TRUE)
  count_ns$count_nor_med <- count_ns$count_nor_med - baseline_shift
  return(count_ns)
}

####get arm metrics####
get_arm_metr <- function(count_ns, smpSNPdata, sample_name, centr_ref) {

  #calculate weighted median for every chromosome and use only 1:22
  summ_arm <- count_ns %>% filter(!is.infinite(count_nor_med)) %>% filter(chr %in% c(1:22, "X")) %>% left_join(centr_ref, by = "chr") %>% mutate(chr = factor(chr, levels = c(1:22, "X"))) %>%
    mutate(arm = ifelse(end < cstart, "p", ifelse(end > cend, "q", "centr"))) %>% filter(arm != "centr") %>% group_by(chr, arm) %>%

    # get rid of 21 p arm
    filter(!(chr == 21 & arm == "p")) %>%

    mutate(arm_med = weighted_quantile(x = count_nor_med,w = weight, probs = 0.5, na.rm = TRUE),
           up_quart = weighted_quantile(x = count_nor_med, w = weight, probs = 0.75, na.rm = TRUE),
           low_quart = weighted_quantile(x = count_nor_med, w = weight, probs = 0.25, na.rm = TRUE)) %>%

    ungroup() %>% distinct(chr, arm, arm_med, up_quart, low_quart) %>%
    left_join(distinct(.data = smpSNPdata, chr, arm, peakdist, peak_m_dist, peak_max, y_0.5), by = c("chr", "arm")) %>% mutate(chr = factor(chr, levels = c(1:22, "X")), sd = sd(arm_med), mean_all = mean(arm_med)) %>% ungroup() %>%

    mutate(sds_median = (arm_med - mean_all)/sd, sds_025 = (low_quart - mean_all)/sd, sds_075 = (up_quart-mean_all)/sd,
           n_02_04 = sum(data.table::inrange(peakdist, 0.2, 0.4) & peak_m_dist > 0.08), n_04 = sum(data.table::inrange(peakdist, 0.4, 0.9) & peak_m_dist > 0.08)) %>%

    arrange(chr) %>%

    select(chr, arm, arm_med, up_quart, low_quart, peak_max, peak_m_dist, peakdist, y_0.5, sd, sds_median, sds_025, sds_075, n_02_04, n_04)
  return(summ_arm)

}

#### calculate chromosomal statistics ####
# calc arm extended
calc_arm <- function(smpSNPdata.tmp) {

  smpSNPdata <- smpSNPdata.tmp %>% group_by(chr, arm) %>% arrange(chr, desc(depth) ) %>%
    #mutate(snvOrd=1:n()) %>%
    mutate(snvOrd = row_number()) %>%
    mutate(snvNum=n(), peak_max=densityMaxY(maf),
           peak=findPeak(maf), peak_m_dist = abs(peak - 0.5), y_0.5 = find_y_0.5(maf), peakdist = find_peak_dist(maf), peakCol=ifelse(between(peak, 0.42, 0.58), 'black', 'red')) %>%
    ungroup() %>% filter(chr %in% c(1:22, "X")) %>% mutate(chr = factor(chr, levels = c(1:22, "X")))
  return(smpSNPdata)
}

#### calculate statistics with diploid knowldedge ####
metr_dipl <- function(data) {

  if (sum(data$chr_status == "dipl") > 3) {
    sd_chr = "dipl"
  } else {
    sd_chr = "no_dipl"
  }

  sd_dipl <- data %>% filter(chr_status == sd_chr) %>% mutate(sd_dipl = sd(arm_med)) %>% pull(sd_dipl) %>% unique()
  mean_dipl <- data %>% filter(chr_status == "dipl") %>% mutate(mean_dipl = mean(arm_med)) %>% pull(mean_dipl) %>% unique()

  data_mod <- data %>% mutate(sd_dipl = sd_dipl, mean_dipl = mean_dipl, sds_median_dipl = (arm_med - mean_dipl)/sd_dipl, sds_025_dipl = (low_quart - mean_dipl)/sd_dipl, sds_075_dipl = (up_quart-mean_dipl)/sd_dipl)

  return(data_mod)
}

### Create colour coding for estimation values ####
colour_code <- function(data, conf_tresh) {
  data_col <- data %>% mutate(colour_arm = factor(ifelse(alteration_prob < conf_tresh, "low", "high"), levels = c("low", "high"))) %>% group_by(chr) %>% mutate(min_prob = min(alteration_prob)) %>% ungroup() %>% mutate(colour_chr = factor(ifelse(min_prob < conf_tresh, "low", "high"), levels = c("low", "high"), ordered = TRUE)) %>%
    select(-min_prob)
  return(data_col)
}

### Generate report for sample ###
gen_kar_list <- function(feat_tab_alt, sample_name, gender) {

  ##extract only the chromosomes which have only one call and have high quality
  tab_mod <- feat_tab_alt %>% select(chr, arm, alteration, colour_arm) %>% group_by(chr) %>% mutate(alt_types = length(unique(alteration)), qual_types = length(unique(colour_arm))) %>% ungroup()

  # whole chromosome changes
  alt_chr_whole <- tab_mod %>% filter(alt_types == 1 & qual_types == 1 & (colour_arm != "high" | alteration != 0)) %>%
    mutate(alt_sign = ifelse(alteration %in% c(1, 2), "+", ifelse(alteration == -1, "-", "")), qual_sign = ifelse(colour_arm == "high", "", "?"), alt_str = paste0(qual_sign, chr, alt_sign)) %>%
    distinct(chr, alt_str, alteration)
  double_chr_whole <- alt_chr_whole %>% filter(alteration == 2)
  alt_chr_whole_fin <- alt_chr_whole %>% bind_rows(double_chr_whole) %>% arrange(chr)

  # arm only changes
  alt_arm <- tab_mod %>% filter((alt_types == 2 | qual_types == 2) & (colour_arm != "high" | alteration != 0)) %>%
    mutate(alt_sign = ifelse(alteration %in% c(1, 2), "+", ifelse(alteration == -1, "-", "")), qual_sign = ifelse(colour_arm == "high", "", "?"), alt_str = paste0(qual_sign, chr, arm, alt_sign)) %>%
    distinct(chr, alt_str, alteration, arm)
  double_arm <- alt_arm %>% filter(alteration == 2)
  alt_arm_fin <- alt_arm %>% bind_rows(double_arm) %>% arrange(chr, arm) %>% select(-arm)

  #fuse the tables
  alterations <- bind_rows(alt_chr_whole_fin, alt_arm_fin) %>% arrange(chr) %>% pull(alt_str) %>% paste0(collapse = ", ")

  #chromosome number
  chrom_diff <- tab_mod %>% filter(alt_types == 1, qual_types == 1, colour_arm == "high") %>% distinct(chr, alteration) %>% pull(alteration) %>% as.numeric(.) %>% sum(.)
  chrom_n = 46 + chrom_diff

  #fill in empty alteration vector
  if (alterations == "") {
    alterations <- "none"
  }


  kar_table <- data.frame(sample = sample_name,
                          gender = factor(gender, levels = c("female", "male")),
                          chrom_n = chrom_n,
                          alterations = alterations, stringsAsFactors = FALSE)

  return(kar_table)
}

#' Fucnction that converts vcf files to tabular input for CNV analysis
vcf_to_snv <- function(vcf_file, maf_tresh = 0.01, depth_tresh = 5) {

  #read the vcf files
  message("Reading in vcf file..")
  vcf_data <- fread(vcf_file, skip = "#CHROM", header = TRUE)
  #check whether the input is in correct format
  if (dim(vcf_data)[2] < 10) {
    vcf_final <- "Incorrect vcf file format. Incorrect number of columns"
    return(vcf_final)
  }
  if (!identical(colnames(vcf_data)[1:9], c("#CHROM", "POS", "ID", "REF", "ALT", "QUAL", "FILTER", "INFO", "FORMAT"))) {
    vcf_final <- "Incorrect vcf file format."
    return(vcf_final)
  }
  if (str_detect(vcf_data[1, INFO], "DP=[0-9]+") != TRUE & str_detect(string = str_split(vcf_data[1, FORMAT], pattern = ":")[[1]][3], pattern = "DP") != TRUE) {
    vcf_final <- "Incorrect vcf file format. No depth information in the INFO column and missing information in the FORMAT column"
    return(vcf_final)
  }
  if (str_detect(vcf_data[1, 9], "AD") != TRUE) {
    vcf_final <- "Incorrect vcf file format. No allele depth (AD) in FORMAT column"
    return(vcf_final)
  }


  vcf_data <- vcf_data[, 1:10]
  data.table::setnames(x = vcf_data, old = colnames(vcf_data), new = c("chr", "start", "ID", "ref", "var", "qual", "FILTER", "INFO", "FORMAT", "INFO2"))

  # Getting depth out of the INFO column
  message("Extracting depth..")
  if (str_detect(vcf_data[1, INFO], "DP=[0-9]+") == TRUE) {
    vcf_data[, depth := as.numeric(sub("DP=", "", str_extract(INFO, "DP=[0-9]+")))]
  } else {
    vcf_data[, depth := as.numeric(sapply(str_split(INFO2, ":"), function(x) x[3]))]
  }
  #reference allele and alternative allele depths
  message("Extracting reference allele and alternative allele depths..")
  vcf_data[, REF_ALT_num := sapply(str_split(INFO2, ":"), function(x) x[2])]
  #extract count for alternative allele
  vcf_data[, varDp := as.numeric(sapply(str_split(REF_ALT_num, ","), function(x) x[2]))]
  #mutant allele frequency
  vcf_data[, maf := varDp/depth]

  message("Needed information from vcf extracted")

  #return needed columns
  vcf_final <- vcf_data[, c("chr", "start", 'depth', "maf")]

  message("Finished reading vcf")
  return(vcf_final)
}

#create weight table
create_weights <- function(pickGeneDFall) {
  #weight_table = pickGeneDFall %>% mutate(weight = scales::rescale(med^2, to = c(1, 100))*scales::rescale(1/var, to = c(1, 100)), chromosome_name = chr) %>% select(ENSG, chromosome_name, weight)
  weight_table = pickGeneDFall %>% mutate(weight = scales::rescale(1/var, to = c(1, 100)), chromosome_name = chr) %>% select(ENSG, chromosome_name, weight)
}

#create standard table from input file names
create_standard <- function(standard_samples, sample_table) {

  dipl_samples <- match(standard_samples, pull(sample_table, 1))

  for (i in dipl_samples) {

    #extract file names from sample table
    count_file <- pull(sample_table, "count_path")[i]
    sample_n <- pull(sample_table, 1)[i]

    #read the count table
    count_table_sample <- fread(file = count_file)
    data.table::setnames(count_table_sample, colnames(count_table_sample), c("ENSG", "count"))

    #check the count file format
    if (ncol(count_table_sample) != 2 | !is.numeric(count_table_sample[, count])) {
      stop(paste0("Incorrect count file format for the sample: ", sample_n, ", which is also a standard sample."))
    }

    #bind the tables together
    data.table::setnames(count_table_sample, colnames(count_table_sample), c("ENSG", sample_n))
    data.table::setkey(count_table_sample, ENSG)
    if (which(i == dipl_samples) == 1) {
      count_table <- count_table_sample
    } else {
      count_table <- count_table[count_table_sample, nomatch = 0]
    }

  }
  return(count_table)
}

#' Function for calculating weighted quantiles
#'
#' The code is taken from package spatstat, version 1.63.3. The function is no longer part of spatstat package
#' @param x vector of numerical values
#' @param w vector of numerical weights, need to be larger than one
#' @param probs the quantile to be calculated
#' @param na.rm logical; remove NA values
weighted_quantile <- function (x, w, probs = seq(0, 1, 0.25), na.rm = TRUE) {
  x <- as.numeric(as.vector(x))
  w <- as.numeric(as.vector(w))
  if (anyNA(x) || anyNA(w)) {
    ok <- !(is.na(x) | is.na(w))
    x <- x[ok]
    w <- w[ok]
  }
  stopifnot(all(w >= 0))
  if (all(w == 0))
    stop("All weights are zero", call. = FALSE)
  oo <- order(x)
  x <- x[oo]
  w <- w[oo]
  Fx <- cumsum(w)/sum(w)
  result <- numeric(length(probs))
  for (i in seq_along(result)) {
    p <- probs[i]
    lefties <- which(Fx <= p)
    if (length(lefties) == 0) {
      result[i] <- x[1]
    }
    else {
      left <- max(lefties)
      result[i] <- x[left]
      if (Fx[left] < p && left < length(x)) {
        right <- left + 1
        y <- x[left] + (x[right] - x[left]) * (p - Fx[left])/(Fx[right] -
                                                                Fx[left])
        if (is.finite(y))
          result[i] <- y
      }
    }
  }
  names(result) <- paste0(format(100 * probs, trim = TRUE),
                          "%")
  return(result)
}
