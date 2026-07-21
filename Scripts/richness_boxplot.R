#!/usr/bin/env Rscript
# Richness (observed species, abundance > 0) per sample for two databases
# GTDB  -> Data/Species.xls
# HROM  -> Data/hrom.all.xls
# Compared between Saliva (S) and Urine (U) samples.

suppressPackageStartupMessages({
  library(ggplot2)
  library(ggpubr)
})

## ---- paths ----
proj    <- "/Users/zhangyf/Projects/baiyunyang"
data_dir <- file.path(proj, "Data")
res_dir  <- file.path(proj, "Results")
dir.create(res_dir, showWarnings = FALSE, recursive = TRUE)

## ---- metadata: name -> Position (U/S) ----
meta <- read.delim(file.path(data_dir, "meta.txt"),
                   header = TRUE, check.names = FALSE,
                   stringsAsFactors = FALSE)
pos_map <- setNames(meta$Position, meta$name)

## ---- richness helper: count features with abundance > 0 per sample ----
richness_df <- function(abund, dbname) {
  abund <- as.data.frame(lapply(abund, function(x) as.numeric(as.character(x))))
  rich  <- colSums(abund > 0, na.rm = TRUE)
  data.frame(
    Sample   = names(rich),
    Richness = as.integer(rich),
    Position = unname(pos_map[names(rich)]),
    Database = dbname,
    stringsAsFactors = FALSE
  )
}

## ---- GTDB: col1 = Taxonomy, rest = samples ----
sp <- read.delim(file.path(data_dir, "Species.xls"),
                 header = TRUE, check.names = FALSE, row.names = 1,
                 stringsAsFactors = FALSE)
gtdb <- richness_df(sp, "GTDB")

## ---- HROM: cols 1-7 = taxonomy levels, rest = samples ----
hr <- read.delim(file.path(data_dir, "hrom.all.xls"),
                 header = TRUE, check.names = FALSE,
                 stringsAsFactors = FALSE)
tax_cols <- c("Kingdom", "Phylum", "Class", "Order", "Family", "Genus", "Species")
hr_abund <- hr[, !(colnames(hr) %in% tax_cols), drop = FALSE]
hrom <- richness_df(hr_abund, "HROM")

## ---- combine ----
df <- rbind(gtdb, hrom)
df$Position <- factor(ifelse(df$Position == "S", "Saliva", "Urine"),
                      levels = c("Saliva", "Urine"))
df$Database <- factor(df$Database, levels = c("GTDB", "HROM"))

## ---- save per-sample richness table ----
write.table(df, file.path(res_dir, "richness_per_sample.tsv"),
            sep = "\t", quote = FALSE, row.names = FALSE)

## ---- summary stats (median/mean/n + Wilcoxon Saliva vs Urine per database) ----
summ <- do.call(rbind, lapply(split(df, list(df$Database, df$Position)), function(d) {
  data.frame(Database = d$Database[1], Position = d$Position[1],
             n = nrow(d), mean = round(mean(d$Richness), 1),
             median = median(d$Richness),
             min = min(d$Richness), max = max(d$Richness))
}))
rownames(summ) <- NULL
# Paired comparison: same samples annotated by both databases -> GTDB vs HROM per site
wilcox_tbl <- do.call(rbind, lapply(levels(df$Position), function(ps) {
  d <- df[df$Position == ps, ]
  w <- reshape(d[, c("Sample", "Database", "Richness")],
               idvar = "Sample", timevar = "Database", direction = "wide")
  g <- w[["Richness.GTDB"]]; h <- w[["Richness.HROM"]]
  p <- wilcox.test(g, h, paired = TRUE)$p.value
  data.frame(Position = ps, comparison = "GTDB vs HROM (paired)",
             n_pairs = nrow(w),
             median_GTDB = median(g), median_HROM = median(h),
             wilcox_p = signif(p, 4))
}))
write.table(summ, file.path(res_dir, "richness_summary.tsv"),
            sep = "\t", quote = FALSE, row.names = FALSE)
write.table(wilcox_tbl, file.path(res_dir, "richness_wilcoxon.tsv"),
            sep = "\t", quote = FALSE, row.names = FALSE)

cat("== Summary ==\n"); print(summ)
cat("\n== Paired Wilcoxon (GTDB vs HROM, per site) ==\n"); print(wilcox_tbl)

## ---- boxplot: GTDB vs HROM within each site, faceted by site, shared y-axis ----
fmt_p <- function(p) ifelse(p < 2.2e-16, "p < 2.2e-16", paste0("p = ", signif(p, 3)))
ymax <- max(df$Richness)
# brackets placed just above each site's own data (still on the shared axis)
stat.test <- data.frame(
  Position   = factor(wilcox_tbl$Position, levels = c("Saliva", "Urine")),
  group1     = "GTDB", group2 = "HROM",
  label      = fmt_p(wilcox_tbl$wilcox_p),
  y.position = sapply(as.character(wilcox_tbl$Position),
                      function(ps) max(df$Richness[df$Position == ps]) * 1.06)
)

pal <- c(GTDB = "#3C6E9B", HROM = "#C0504D")
p <- ggplot(df, aes(x = Database, y = Richness, fill = Database)) +
  geom_boxplot(width = 0.6, outlier.shape = NA, alpha = 0.85) +
  geom_jitter(width = 0.15, size = 0.9, alpha = 0.45, colour = "grey25") +
  facet_wrap(~ Position) +                                   # scales = "fixed" -> shared y-axis
  ggpubr::stat_pvalue_manual(stat.test, label = "label", tip.length = 0.01) +
  scale_fill_manual(values = pal) +
  scale_y_continuous(limits = c(0, ymax * 1.15)) +           # unified y-axis range
  labs(x = NULL, y = "Richness (observed species)",
       title = "Microbial richness: GTDB vs HROM within each site",
       subtitle = "Paired Wilcoxon signed-rank test (same samples, two databases)") +
  theme_bw(base_size = 13) +
  theme(legend.position = "none",
        strip.background = element_rect(fill = "grey92"),
        strip.text = element_text(face = "bold"),
        plot.title = element_text(face = "bold", size = 12),
        plot.subtitle = element_text(size = 9, colour = "grey30"))

ggsave(file.path(res_dir, "richness_boxplot.pdf"), p, width = 7, height = 4.5)
ggsave(file.path(res_dir, "richness_boxplot.png"), p, width = 7, height = 4.5, dpi = 300)

cat("\nOutputs written to:", res_dir, "\n")
cat("  - richness_per_sample.tsv\n  - richness_summary.tsv\n  - richness_wilcoxon.tsv\n  - richness_boxplot.pdf / .png\n")
