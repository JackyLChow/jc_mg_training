# CRAN
library(readr) # importing files
library(ggplot2) # general plots
library(ggrepel) # ggplot package for plot labeling
library(dplyr) # easy data manipulation

# Bioconductor
library(ComplexHeatmap) # heatmaps
library(DESeq2) # differential gene expression
library(ReactomePA) # Reactome pathway enrichment
library(clusterProfiler) # KEGG and Reactome pathway enrichments
library(org.Hs.eg.db) # gene synonym table for ReactomePA and clusterProfiler

################################################################################
#
# load data
#
################################################################################

#setwd("~/Documents/BFX_proj/jc_mg_Chow_PNAS_2020_training")
### counts ###
counts <- read_csv("_input/Chow_PNAS_rawcounts.csv") # import raw counts table
counts <- counts[!duplicated(counts$gene), ] # drop duplicated
r_counts <- as.matrix(counts[, 2:ncol(counts)]) # create counts matrix, drop gene name column
rownames(r_counts) <- counts$gene # assign gene name to counts matrix row names
#r_counts[1:3, 1:5] # check format
rm(counts) # clean up

### meta ###
meta <- data.frame(read_csv("_input/Chow_PNAS_meta.csv")) # import metadata as data.frame
rownames(meta) <- meta$sample # assign sample name to metadata rows
meta$treatment <- factor(meta$treatment, levels = c("control", "SBRT")) # factorize comparison column
#rownames(meta) == colnames(r_counts) # check that meta rows matches r_counts columns
#meta <- meta[colnames(r_counts), ] # reorder meta rows to match r_counts columns

################################################################################
#
# PCA and Heatmap
#
################################################################################

n_counts <- log2(r_counts + 1) # crude counts normalization

### PCA ###
pc_res_ <- prcomp(t(n_counts)) # calculate principle component coordinates
pc_plot <- cbind(meta, # join pca to metadata to plot
                 pc_res_$x) # PCA coordinates for samples

png("_output/pca.png", height = 500, width = 500, res = 100)
ggplot(pc_plot, aes(PC1, PC2, color = treatment)) +
  geom_point() +
  theme(aspect.ratio = 1)
dev.off()

### Heatmap ###
# choose genes to show by major, negative contributors to PC2
pc2_ev <- pc_res_$rotation[, "PC2"] # extract gene eigenvalues for PC2
pc2_ev <- pc2_ev[order(pc2_ev, decreasing = F)] # reorder by increasing eigenvalue

s_counts <- t(scale(t(n_counts))) # z-score normalized counts

png("_output/heat_pc2.png", height = 700, width = 500, res = 100)
set.seed(415); Heatmap(s_counts[names(pc2_ev)[1:50], ], # show top 50
                       name = "z-score",
                       row_names_gp = gpar(fontsize = 7),
                       show_row_dend = F,
                       use_raster = F)
dev.off()

rm(n_counts, pc_res_, pc_plot, pc2_ev, s_counts) # clean up

################################################################################
#
# DGE and GSEA
#
################################################################################

################################################################################
# DESeq2 pipeline
################################################################################
ds2_ <- DESeqDataSetFromMatrix(countData = r_counts, # call counts matrix
                               colData = meta, # call metadata table
                               design = ~ treatment)
ds2_ <- DESeq(ds2_) # run DESeq2
res <- data.frame(results(ds2_)) # extract results as data.frame
#res <- data.frame(lfcShrink(ds2_, coef = "treatment_SBRT_vs_control", type = "apeglm")) # extract fold change shrunk results as data.frame
res$symbol <- rownames(res) # add gene symbol column for plotting

### plot results as volcano plot ###
volc <- ggplot(res, aes(log2FoldChange, -log10(padj))) +
  ### label 5 most positive and most negative biological effect ###
  geom_point(data = res[res$padj > 0.05 | abs(res$log2FoldChange) < 1, ], size = 0.33, color = "grey40", alpha = 0.5) + # plot not signficant genes small
  geom_point(data = res[res$padj < 0.05 & abs(res$log2FoldChange) > 1, ], alpha = 0.5) + # plot significant  genes larger
  ### show thresholds for significance ###
  geom_vline(xintercept = c(-1, 1), color = "red") + # biological effect is double
  geom_hline(yintercept = -log10(0.05), color = "red") + # statistical significance is padj 0.05
  ### label 5 most positive and most negative biological effect and most statistically significant ###
  geom_label_repel(data = top_n(res, 5, log2FoldChange), aes(label = symbol), min.segment.length = 0) +
  geom_label_repel(data = top_n(res, 5, -log2FoldChange), aes(label = symbol), min.segment.length = 0) +
  geom_label_repel(data = top_n(res, 5, -padj), aes(label = symbol), min.segment.length = 0)
  
png("_output/volc.png", height = 500, width = 700, res = 100)
print(volc)
dev.off()

rm(ds2_) # clean up

################################################################################
# Ranked list GSEA
################################################################################
res <- res[order(res$log2FoldChange, decreasing = T), ] # reorder results table by fold change

### use gene synonym table to generate gene reference table ###
gene_ref <- AnnotationDbi::select(org.Hs.eg.db,
                                  keys = res$symbol,
                                  columns = c("ENTREZID"),
                                  keytype = "SYMBOL") # reference gene symbol with ENTREZID
gene_ref <- gene_ref[!duplicated(gene_ref$ENTREZID), ] # remove duplicated ENTREZID entries
gene_order <- left_join(gene_ref, res, by = c("SYMBOL" = "symbol")) # join res to gene_ref
gene_order <- setNames(gene_order$log2FoldChange, gene_order$ENTREZID) # convert gene_order to named number vector

### run reactomePA with base settings ###
set.seed(415); GSEAreactome <- data.frame(gsePathway(gene_order,
                                                     maxGSSize = 300,
                                                     pvalueCutoff = 0.05,
                                                     pAdjustMethod = "BH",
                                                     verbose = FALSE))

### run clusterProfiler with base settings ###
set.seed(415); GSEAkegg <- data.frame(gseKEGG(gene_order,
                                              organism = 'hsa',
                                              maxGSSize = 300,
                                              pvalueCutoff = 0.05,
                                              verbose = FALSE))

set.seed(415); GSEAgo <- data.frame(gseGO(gene_order,
                                          OrgDb = org.Hs.eg.db,
                                          maxGSSize = 300,
                                          pvalueCutoff = 0.05,
                                          verbose = FALSE))

### merge GSEA results into a single table ###
GSEAall <- rbind(GSEAreactome, GSEAkegg, GSEAgo)
GSEAall$p.adjust <- p.adjust(GSEAall$pvalue, method = "BH") # recalculate p.adjust
GSEAall$core_enrichment_symbol <- NULL # create column to replace enrichment ENTREZID with symbol

GSEAall$core_enrichment_symbol <- paste(toString(gene_ref$SYMBOL[as.character(gene_ref$ENTREZID) %in% unlist(strsplit(gene_ref$ENTREZID, "/"))]))

for(n in rownames(GSEAall)){
  ce_ <- GSEAall[n, "core_enrichment"] # get core enrichment
  GSEAall[n, "core_enrichment_symbol"] <- toString(gene_ref$SYMBOL[as.character(gene_ref$ENTREZID) %in% unlist(strsplit(ce_, "/"))]) # replace with symbol
  rm(ce_, n)
}

write.csv(GSEAall, "_output/GSEAall.csv", row.names = F)







