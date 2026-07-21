# ============================================================================
# analysis_helpers.R
# Shared logic for the HROM-based group-comparison analysis
# (periodontitis / diabetes / kidney-disease comorbidity design).
#
# Data note: HROM table is RELATIVE ABUNDANCE (each sample column sums to 1),
# NOT counts. This drives normalization choices for every method below.
# ============================================================================

suppressPackageStartupMessages({
  library(data.table); library(vegan); library(ggplot2); library(ggpubr)
  library(rstatix); library(dplyr); library(tidyr)
})

## ---- constants ----
DISEASE_LEVELS <- c("N", "P", "PD", "PC", "PCD")
GROUP_COLORS   <- c(N = "grey55", P = "#1f78b4", PD = "#e31a1c",
                    PC = "#33a02c", PCD = "#6a3d9a")
POSITION_COLORS <- c(S = "#4daf4a", U = "#984ea3")   # saliva / urine (combined plots)
# Disease-burden gradient (N -> P -> PD/PC -> PCD) for trend tests
BURDEN <- c(N = 0, P = 1, PD = 2, PC = 2, PCD = 3)
# Primary pairwise comparisons (from the design doc's "最终推荐")
PRIMARY_COMPARISONS <- list(c("N","P"), c("P","PD"), c("P","PC"),
                            c("PD","PCD"), c("PC","PCD"))

## ---- data loading -----------------------------------------------------------
load_data <- function(data_dir = "Data") {
  meta <- fread(file.path(data_dir, "meta.txt"), sep = "\t", header = TRUE)
  setnames(meta, trimws(names(meta)))
  for (cc in c("name","Group","Gender","Position")) set(meta, j = cc, value = trimws(meta[[cc]]))
  meta[, DiseaseGroup := factor(sub("^[SU]_", "", Group), levels = DISEASE_LEVELS)]
  meta[, Periodontitis := as.integer(DiseaseGroup %in% c("P","PD","PC","PCD"))]
  meta[, Diabetes      := as.integer(DiseaseGroup %in% c("PD","PCD"))]
  meta[, KidneyDisease := as.integer(DiseaseGroup %in% c("PC","PCD"))]
  meta[, Burden := BURDEN[as.character(DiseaseGroup)]]
  meta[, Sex := factor(Gender)]
  meta[, Age := as.numeric(Age)]

  hrom <- fread(file.path(data_dir, "hrom.all.xls"), sep = "\t", header = TRUE)
  lineage <- c("Kingdom","Phylum","Class","Order","Family","Genus","Species")
  hrom[, feature := Species]                       # unique per row (verified)
  list(meta = meta, hrom = hrom, lineage = lineage)
}

load_GTDB_data <- function(data_dir = "Data") {
  meta <- fread(file.path(data_dir, "meta.txt"), sep = "\t", header = TRUE)
  setnames(meta, trimws(names(meta)))
  for (cc in c("name","Group","Gender","Position")) set(meta, j = cc, value = trimws(meta[[cc]]))
  meta[, DiseaseGroup := factor(sub("^[SU]_", "", Group), levels = DISEASE_LEVELS)]
  meta[, Periodontitis := as.integer(DiseaseGroup %in% c("P","PD","PC","PCD"))]
  meta[, Diabetes      := as.integer(DiseaseGroup %in% c("PD","PCD"))]
  meta[, KidneyDisease := as.integer(DiseaseGroup %in% c("PC","PCD"))]
  meta[, Burden := BURDEN[as.character(DiseaseGroup)]]
  meta[, Sex := factor(Gender)]
  meta[, Age := as.numeric(Age)]
  
  hrom <- fread(file.path(data_dir, "Abundance.filtered.anno.xls"), sep = "\t", header = TRUE)
  lineage <- c("Kingdom","Phylum","Class","Order","Family","Genus","Species")
  hrom[, feature := Species]                       # unique per row (verified)
  list(meta = meta, hrom = hrom, lineage = lineage)
}

## ---- per-site feature tables ------------------------------------------------
# Returns: meta (ordered to matrix cols), abund_all (taxa present in site),
#          abund (prevalence-filtered), tax (lineage for filtered taxa).
prep_site <- function(dat, site, min_prev = 0.10) {
  meta <- dat$meta[Position == site]
  samp <- meta$name
  M <- as.matrix(dat$hrom[, ..samp]); storage.mode(M) <- "double"
  rownames(M) <- dat$hrom$feature
  meta <- meta[match(colnames(M), meta$name)]      # align order
  M <- M[rowSums(M) > 0, , drop = FALSE]            # present in this site
  prev <- rowMeans(M > 0)
  Mf <- M[prev >= min_prev, , drop = FALSE]
  tax <- dat$hrom[match(rownames(Mf), feature), c(dat$lineage, "feature"), with = FALSE]
  list(meta = as.data.frame(meta), abund_all = M, abund = Mf, tax = as.data.frame(tax))
}

## ---- combined (both sites) feature table ------------------------------------
# All samples from both positions together; used for the body-site contrast.
prep_combined <- function(dat, min_prev = 0.10) {
  meta <- dat$meta
  samp <- meta$name
  M <- as.matrix(dat$hrom[, ..samp]); storage.mode(M) <- "double"
  rownames(M) <- dat$hrom$feature
  meta <- meta[match(colnames(M), meta$name)]
  M <- M[rowSums(M) > 0, , drop = FALSE]
  prev <- rowMeans(M > 0)
  Mf <- M[prev >= min_prev, , drop = FALSE]
  list(meta = as.data.frame(meta), abund_all = M, abund = Mf)
}

## ---- CLR transform (taxa x samples) ----------------------------------------
clr_transform <- function(M, pseudo = NULL) {
  if (is.null(pseudo)) pseudo <- min(M[M > 0]) / 2
  logX <- log(M + pseudo)
  sweep(logX, 2, colMeans(logX), "-")              # center within each sample
}

## ---- alpha diversity --------------------------------------------------------
alpha_table <- function(M, meta) {
  tM <- t(M)                                        # samples x taxa
  data.frame(
    name         = meta$name,
    DiseaseGroup = meta$DiseaseGroup,
    Position     = meta$Position,
    Burden       = meta$Burden,
    Observed     = rowSums(tM > 0),
    Shannon      = vegan::diversity(tM, "shannon"),
    Simpson      = vegan::diversity(tM, "simpson"),
    InvSimpson   = vegan::diversity(tM, "invsimpson")
  ) |> dplyr::mutate(Pielou = Shannon / log(Observed))
}

# Kruskal-Wallis across 5 groups + Dunn (BH) on primary comparisons + Spearman trend
alpha_stats <- function(adf, metric) {
  x <- adf[[metric]]; g <- adf$DiseaseGroup
  kw <- kruskal.test(x ~ g)
  dunn <- adf |> rstatix::dunn_test(as.formula(paste(metric, "~ DiseaseGroup")),
                                    p.adjust.method = "BH")
  comp_lab <- sapply(PRIMARY_COMPARISONS, paste, collapse = "_")
  dunn$pair <- paste(dunn$group1, dunn$group2, sep = "_")
  dunn$pair2 <- paste(dunn$group2, dunn$group1, sep = "_")
  dunn_primary <- dunn[dunn$pair %in% comp_lab | dunn$pair2 %in% comp_lab, ]
  sp <- suppressWarnings(cor.test(x, adf$Burden, method = "spearman"))
  list(metric = metric, kw_p = kw$p.value,
       dunn = dunn_primary, trend_rho = unname(sp$estimate), trend_p = sp$p.value)
}

plot_alpha <- function(adf, metric) {
  ggplot(adf, aes(DiseaseGroup, .data[[metric]], fill = DiseaseGroup)) +
    geom_boxplot(outlier.size = 0.6, alpha = 0.85) +
    geom_jitter(width = 0.15, size = 0.5, alpha = 0.4) +
    scale_fill_manual(values = GROUP_COLORS) +
    stat_compare_means(method = "kruskal.test", label = "p.format", size = 3) +
    labs(x = NULL, y = metric, title = metric) +
    theme_bw(base_size = 11) + theme(legend.position = "none")
}

# combined view: alpha by sampling position (saliva vs urine), Wilcoxon
plot_alpha_position <- function(adf, metric) {
  ggplot(adf, aes(Position, .data[[metric]], fill = Position)) +
    geom_boxplot(outlier.size = 0.6, alpha = 0.85) +
    geom_jitter(width = 0.15, size = 0.4, alpha = 0.3) +
    scale_fill_manual(values = POSITION_COLORS) +
    stat_compare_means(method = "wilcox.test", label = "p.format", size = 3) +
    labs(x = NULL, y = metric, title = metric) +
    theme_bw(base_size = 11) + theme(legend.position = "none")
}

## ---- beta diversity + PERMANOVA --------------------------------------------
# dist_method: "bray" (Bray-Curtis) or "robust.aitchison" (rPCA: rclr + Euclidean).
# perm_terms : PERMANOVA marginal terms (combined run adds "Position").
# interaction: fit Diabetes*KidneyDisease within periodontitis+ subset (per-site).
beta_analysis <- function(M, meta, dist_method = "bray",
                          perm_terms = c("Periodontitis","Diabetes","KidneyDisease"),
                          interaction = TRUE, seed = 1) {
  d <- vegan::vegdist(t(M), method = dist_method)
  pc <- cmdscale(d, k = 2, eig = TRUE, add = TRUE)
  pe <- pc$eig[pc$eig > 0]; ve <- round(100 * pc$eig[1:2] / sum(pe), 1)
  ord <- data.frame(PCo1 = pc$points[,1], PCo2 = pc$points[,2],
                    DiseaseGroup = meta$DiseaseGroup, Position = meta$Position,
                    name = meta$name)
  set.seed(seed)
  fml <- stats::as.formula(paste("d ~", paste(perm_terms, collapse = " + ")),
                           env = environment())
  perm <- adonis2(fml, data = meta, by = "margin", permutations = 999)
  perm_int <- NULL
  if (interaction) {
    sub <- meta$Periodontitis == 1
    if (sum(sub) > 10) {
      ds <- as.dist(as.matrix(d)[sub, sub]); ms <- meta[sub, ]
      set.seed(seed)
      perm_int <- adonis2(ds ~ Diabetes * KidneyDisease, data = ms,
                          by = "terms", permutations = 999)
    }
  }
  list(dist = d, ord = ord, var_expl = ve, permanova = perm, permanova_int = perm_int)
}

## ---- tidy an adonis2 result into a kable-ready data.frame -------------------
tidy_permanova <- function(aov) {
  df <- as.data.frame(aov); df$Term <- rownames(df)
  df[df$Term != "Total", c("Term","Df","R2","F","Pr(>F)")]
}

pairwise_permanova <- function(d, meta, comps = PRIMARY_COMPARISONS, seed = 1) {
  m <- as.matrix(d)
  out <- lapply(comps, function(cc) {
    idx <- which(meta$DiseaseGroup %in% cc)
    di  <- as.dist(m[idx, idx]); md <- droplevels(meta[idx, ])
    set.seed(seed)
    a <- adonis2(di ~ DiseaseGroup, data = md, permutations = 999)
    data.frame(comparison = paste(cc, collapse = " vs "),
               n = length(idx), R2 = a$R2[1], F = a$F[1], p = a$`Pr(>F)`[1])
  })
  out <- do.call(rbind, out); out$padj <- p.adjust(out$p, "BH"); out
}

plot_pcoa <- function(beta, title = "", color_by = "DiseaseGroup",
                      shape_by = NULL, palette = GROUP_COLORS) {
  p <- ggplot(beta$ord, aes(PCo1, PCo2, color = .data[[color_by]])) +
    stat_ellipse(type = "norm", linewidth = 0.4) +
    labs(title = title, color = color_by, shape = shape_by,
         x = sprintf("PCo1 (%.1f%%)", beta$var_expl[1]),
         y = sprintf("PCo2 (%.1f%%)", beta$var_expl[2])) +
    theme_bw(base_size = 11)
  if (!is.null(palette)) p <- p + scale_color_manual(values = palette)
  if (is.null(shape_by)) p + geom_point(size = 2, alpha = 0.85)
  else p + geom_point(aes(shape = .data[[shape_by]]), size = 2, alpha = 0.85)
}

## ---- DS-FDR (Jiang et al. 2017, mSystems): permutation FDR for pairwise -------
# Discrete FDR exploits the discreteness of sparse microbiome data (zeros -> ties)
# to gain power over BH (which is conservative for discrete test statistics).
# Per-taxon two-sided Mann-Whitney rank-sum statistic |sum(rank_g1) - E0| on
# RELATIVE ABUNDANCE (keeps the zero-ties); pooled permutation null over B label
# shuffles; Li-Tibshirani q-values. Returns data.frame(feature, stat, qval).
.row_ranks <- function(X) {
  if (requireNamespace("matrixStats", quietly = TRUE))
    matrixStats::rowRanks(X, ties.method = "average")
  else t(apply(X, 1, rank))                                  # base fallback (slower)
}
dsfdr_pair <- function(X, grp, B = 1000, seed = 1) {
  grp <- factor(grp); stopifnot(nlevels(grp) == 2)
  N <- ncol(X); n1 <- sum(grp == levels(grp)[1]); center <- n1 * (N + 1) / 2
  R  <- .row_ranks(X)                                        # m x N (fixed under perm)
  g1 <- as.numeric(grp == levels(grp)[1])
  Tobs <- abs(as.vector(R %*% g1) - center)                 # observed |statistic|
  set.seed(seed)
  P <- matrix(0, N, B); for (b in seq_len(B)) P[sample.int(N, n1), b] <- 1
  Tnull <- abs(R %*% P - center)                            # m x B permutation null
  m <- length(Tobs)
  alln <- sort(as.vector(Tnull)); obss <- sort(Tobs); ut <- sort(unique(Tobs))
  ge_null <- length(alln) - findInterval(ut - 1e-9, alln)   # # null >= C
  Rhat    <- m          - findInterval(ut - 1e-9, obss)     # # obs  >= C
  fdr  <- pmin((ge_null + Rhat) / (B + 1) / Rhat, 1)
  qut  <- cummin(fdr)                                        # min FDR over cut-points C <= ut
  data.frame(feature = rownames(X), stat = Tobs,
             qval = qut[match(Tobs, ut)], row.names = NULL)
}

## ---- differential abundance: pairwise (Mann-Whitney + DS-FDR) ----------------
# Effect size = generalized log-ratio (crossRanger::BetweenGroup.test "generalized_logfc",
# a robust between-group log-fold-change; negated so >0 == higher in g2, the latter
# group). Raw p from Mann-Whitney on relative abundance; multiple-testing via DS-FDR
# (column `padj` = DS-FDR q-value). `glr` replaces the former `clr_diff`.
da_pair_dsfdr <- function(abund, clrM, meta, g1, g2, B = 1000) {
  i1 <- which(meta$DiseaseGroup == g1); i2 <- which(meta$DiseaseGroup == g2)
  grp <- factor(rep(c(g1, g2), c(length(i1), length(i2))), levels = c(g1, g2))
  pw <- apply(abund, 1, function(x)
    tryCatch(wilcox.test(x[i1], x[i2], exact = FALSE)$p.value, error = function(e) NA_real_))
  A <- abund[, c(i1, i2), drop = FALSE]
  glr <- tryCatch({
    invisible(utils::capture.output(suppressWarnings(suppressMessages(
      bgt <- crossRanger::BetweenGroup.test(t(A), grp)))))
    -bgt[match(rownames(abund), rownames(bgt)), "generalized_logfc"]
  }, error = function(e)
    apply(clrM, 1, function(x) median(x[i2]) - median(x[i1])))     # fallback: CLR median diff
  ds <- dsfdr_pair(A, grp, B = B)
  df <- data.frame(feature = rownames(abund), glr = glr, p = pw,
                   padj = ds$qval[match(rownames(abund), ds$feature)], row.names = NULL)
  df[order(df$padj, df$p), ]
}

## ---- heatmap of pairwise generalized log-ratios across the 5 primary comparisons --
# wl: NAMED list of da_pair_dsfdr() results (cols: feature, glr, padj), one per
# comparison (names = row labels). Rows = comparisons; columns = selected taxa;
# fill = glr (generalized log-ratio, >0 = higher in the 2nd group); "*" where padj<sig_th.
# Column set = taxa significant (padj<sig_th) in >=1 comparison, ranked by significance
# and capped at max_cols; if too few, padded with the next most-significant taxa.
# Small cells + larger labels. All plotted text is ASCII (CJK segfaults the device).
plot_pairwise_heatmap <- function(wl, sig_th = 0.20, max_cols = 45, min_cols = 12,
                                  title = "") {
  comp_lab <- names(wl)
  long <- do.call(rbind, lapply(comp_lab, function(nm) {
    d <- wl[[nm]]
    data.frame(comparison = nm, feature = d$feature,
               glr = d$glr, padj = d$padj, stringsAsFactors = FALSE)
  }))
  sel <- long %>% dplyr::group_by(feature) %>%
    dplyr::summarise(min_padj = min(padj, na.rm = TRUE),
                     n_sig    = sum(padj < sig_th, na.rm = TRUE),
                     max_abs  = max(abs(glr), na.rm = TRUE), .groups = "drop") %>%
    dplyr::arrange(min_padj, dplyr::desc(max_abs))
  feats <- sel$feature[sel$n_sig >= 1]
  if (length(feats) > max_cols) feats <- feats[seq_len(max_cols)]
  if (length(feats) < min_cols)
    feats <- union(feats, sel$feature[seq_len(min(min_cols, nrow(sel)))])
  long <- long[long$feature %in% feats, ]
  # order columns by clustering on the glr pattern (fallback: significance order)
  W  <- tidyr::pivot_wider(long[, c("feature","comparison","glr")],
                           names_from = comparison, values_from = glr)
  Wm <- as.matrix(W[, -1]); rownames(Wm) <- W$feature
  ord <- tryCatch(rownames(Wm)[hclust(dist(Wm))$order], error = function(e) feats)
  short <- function(f) substr(sub("^[a-z]__", "", f), 1, 30)
  long$lab        <- factor(short(long$feature), levels = short(ord))
  long$comparison <- factor(long$comparison, levels = comp_lab)
  long$star       <- ifelse(!is.na(long$padj) & long$padj < sig_th, "*", "")
  lim <- max(abs(long$glr), na.rm = TRUE)
  attr_n <- length(feats)
  p <- ggplot(long, aes(lab, comparison, fill = glr)) +
    geom_tile(color = "grey92", linewidth = 0.12) +
    geom_text(aes(label = star), size = 7, vjust = 0.78, color = "black") +
    scale_fill_gradient2(low = "#2166AC", mid = "white", high = "#B2182B",
                         midpoint = 0, limits = c(-lim, lim),
                         name = "gen. log-ratio\n(>0: higher\nin 2nd grp)") +
    scale_y_discrete(limits = rev(comp_lab)) +
    scale_x_discrete(position = "top") +
    labs(title = title, x = NULL, y = NULL) +
    theme_minimal(base_size = 12) +
    theme(axis.text.x = element_text(angle = 90, hjust = 0, vjust = 0.5, size = 8),
          axis.text.y = element_text(size = 13),
          panel.grid = element_blank(),
          plot.title = element_text(size = 14, face = "bold"),
          legend.title = element_text(size = 10),
          legend.text = element_text(size = 9),
          legend.key.height = grid::unit(0.8, "cm"))
  attr(p, "ncol") <- attr_n
  p
}

## ---- differential abundance: Maaslin2 (multivariable adjusted) --------------
run_maaslin2 <- function(Mf, meta, outdir, correction = "BH") {
  feat <- as.data.frame(t(Mf))                      # samples x features
  # Maaslin2 runs make.names() on feature names, mangling Species with spaces
  # (e.g. "s__Actinomyces dentalis" -> "...dentalis"), which then fail to join
  # back to the lineage table (NA genus). Give Maaslin2 safe IDs, restore after.
  fmap <- data.frame(id = paste0("F", seq_len(ncol(feat))),
                     feature = colnames(feat), stringsAsFactors = FALSE)
  colnames(feat) <- fmap$id
  md <- as.data.frame(meta); rownames(md) <- md$name; md <- md[rownames(feat), ]
  invisible(utils::capture.output(suppressMessages(
    fit <- Maaslin2::Maaslin2(
      input_data = feat, input_metadata = md, output = outdir,
      fixed_effects = c("Periodontitis","Diabetes","KidneyDisease","Age","Sex"),
      reference = c("Sex,F"),
      normalization = "NONE", transform = "LOG", analysis_method = "LM",
      correction = correction,
      min_prevalence = 0, max_significance = 0.25,
      plot_heatmap = FALSE, plot_scatter = FALSE, standardize = FALSE)
  )))
  res <- fit$results
  res$feature <- fmap$feature[match(res$feature, fmap$id)]   # restore original Species names
  res
}

## ---- differential abundance: ANCOM-BC (multivariable) -----------------------
# NOTE: input is relative abundance scaled to pseudo-counts (no true counts).
run_ancombc <- function(Mf, meta) {
  suppressPackageStartupMessages({library(phyloseq); library(ANCOMBC)})
  cnt <- round(sweep(Mf, 2, colSums(Mf), "/") * 1e6)
  sd <- data.frame(meta, row.names = meta$name)
  ps <- phyloseq(otu_table(cnt, taxa_are_rows = TRUE), sample_data(sd))
  out <- ANCOMBC::ancombc(
    phyloseq = ps,
    formula = "Periodontitis + Diabetes + KidneyDisease + Age + Sex",
    p_adj_method = "BH", prv_cut = 0.10, lib_cut = 0,
    group = NULL, struc_zero = FALSE, neg_lb = FALSE, conserve = TRUE,
    verbose = FALSE)
  out$res
}

## ---- differential abundance: LEfSe (pairwise) -------------------------------
run_lefser_pair <- function(Mf, meta, g1, g2, lda = 2) {
  suppressPackageStartupMessages({library(SummarizedExperiment); library(lefser)})
  idx <- which(meta$DiseaseGroup %in% c(g1, g2))
  sub <- Mf[, idx, drop = FALSE]; sub <- sub[rowSums(sub) > 0, , drop = FALSE]
  rel <- sweep(sub, 2, colSums(sub), "/") * 1e6     # relative ab. scaled to 1e6
  cd  <- S4Vectors::DataFrame(GROUP = factor(meta$DiseaseGroup[idx], levels = c(g1, g2)))
  se  <- SummarizedExperiment(assays = list(counts = rel), colData = cd)
  res <- tryCatch(
    lefser(se, groupCol = "GROUP", lda.threshold = lda, checkAbundances = FALSE),
    error = function(e) { message("lefser [", g1, " vs ", g2, "]: ", conditionMessage(e)); NULL })
  res
}

## ---- trend along disease-burden gradient (per taxon, CLR ~ Burden) ----------
trend_taxa <- function(clrM, meta) {
  b <- meta$Burden
  st <- t(apply(clrM, 1, function(x) {
    ct <- suppressWarnings(cor.test(x, b, method = "spearman"))
    c(rho = unname(ct$estimate), p = ct$p.value)
  }))
  df <- data.frame(feature = rownames(clrM), rho = st[, "rho"], p = st[, "p"])
  df$padj <- p.adjust(df$p, "BH"); df[order(df$padj, df$p), ]
}

## ---- comorbidity synergy contrast: PCD - PD - PC + P (per taxon) ------------
interaction_contrast <- function(clrM, meta) {
  sub <- meta$Periodontitis == 1
  D <- meta$Diabetes[sub]; K <- meta$KidneyDisease[sub]; X <- clrM[, sub, drop = FALSE]
  st <- t(apply(X, 1, function(y) {
    co <- tryCatch(summary(lm(y ~ D * K))$coefficients, error = function(e) NULL)
    if (is.null(co) || !"D:K" %in% rownames(co)) return(c(synergy = NA, p = NA))
    c(synergy = co["D:K", 1], p = co["D:K", 4])
  }))
  df <- data.frame(feature = rownames(clrM), synergy = st[, "synergy"], p = st[, "p"])
  df$padj <- p.adjust(df$p, "BH"); df[order(df$padj, df$p), ]
}
