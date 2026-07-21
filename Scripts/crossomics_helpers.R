# =============================================================================
# crossomics_helpers.R
# Saliva (oral) -> Urine (distal) cross-site multi-omics association analysis.
# Adapts methods from Zhang et al., Microbiome (2026) 14:147
#   "Cross-body site microbial interactions influence the human plasma metabolome"
# to the periodontitis-diabetes-kidney comorbidity cohort (GTDB annotation).
#
# Layers analysed (all in the saliva -> urine direction):
#   (1) saliva microbiome -> urine microbiome
#   (2) saliva microbiome -> urine metabolome
#   (3) saliva metabolome -> urine metabolome
# plus a 3-layer mediation chain that ties them together:
#   saliva microbiome -> urine microbiome -> urine metabolome
# =============================================================================

suppressMessages({
  library(data.table); library(vegan); library(dplyr); library(tidyr)
  library(ggplot2); library(igraph); library(ggraph); library(tibble)
  library(stringr); library(randomForest)
})

DISEASE_LEVELS <- c("N","P","PD","PC","PCD")
# ASCII-only labels for plots (CJK fonts crash the graphics device on this box)
DISEASE_LABS   <- c(N="N (healthy)", P="P (perio)", PD="PD (+diab)",
                    PC="PC (+kidney)", PCD="PCD (+diab+kidney)")
DISEASE_COLS   <- c(N="#4DBBD5", P="#00A087", PD="#E64B35", PC="#3C5488", PCD="#F39B7F")

## ---- subject id / group parsing --------------------------------------------
# sample names look like "u52_S_N" / "u7_U_PCD"; subject = leading uNN token.
subj_of  <- function(x) sub("_.*$", "", x)
group_of <- function(x) sub("^u[0-9]+_[A-Za-z]+_", "", x)   # disease code after pos

## ---- microbiome loader (GTDB table -> relative abundance at a given rank) ----
# level = "Species" (default) or "Genus".
# Combined prevalence+abundance filter: keep a feature only if its relative
# abundance exceeds `min_abund` in at least `min_prev` of samples. This retains
# rare-but-credible taxa (abundant when present) while dropping one-shot / trace
# detections that a prevalence-only filter would let through. Returns:
#   list(rel = feature x sample relative-abundance matrix [cols = subject],
#        tax = data.frame mapping feature -> Genus/Phylum lineage)
load_microbiome <- function(path, min_prev = 0.05, min_abund = 1e-4,
                            level = "Species", keep = NULL) {
  dt <- fread(path, sep = "\t", header = TRUE)
  taxcols <- c("Kingdom","Phylum","Class","Order","Family","Genus","Species")
  samp <- setdiff(names(dt), taxcols)
  # aggregate to the requested rank by summing relative abundance
  g <- dt[, lapply(.SD, sum), by = c(level), .SDcols = samp]
  M <- as.matrix(g[, ..samp]); rownames(M) <- g[[level]]
  colnames(M) <- subj_of(colnames(M))                 # key by subject
  # restrict to the analysis set FIRST so the prevalence/abundance filter is
  # computed on exactly the samples that will be analysed
  if (!is.null(keep)) M <- M[, intersect(colnames(M), keep), drop = FALSE]
  # combined filter: rel.abund > min_abund in >= min_prev of samples
  keep_feat <- rowMeans(M > min_abund) >= min_prev
  M <- M[keep_feat, , drop = FALSE]
  # renormalise to relative abundance after filtering
  M <- sweep(M, 2, colSums(M), "/")
  # lineage (deduplicated) for the kept features
  lincols <- unique(c(level, "Genus", "Phylum"))
  lin <- unique(dt[, ..lincols]); lin <- lin[!duplicated(lin[[level]])]
  list(rel = M, tax = as.data.frame(lin[get(level) %in% rownames(M)]))
}

## ---- metabolome loader (pos + neg -> log2 feature x sample) -----------------
# Returns: list(log2 = feature x subject log2 matrix, group = named disease code)
load_metabolome <- function(pos_path, neg_path, top_var = NULL, keep = NULL) {
  rd <- function(p, tag) {
    d <- fread(p); ids <- d[[1]]
    m <- as.matrix(d[, -(1:2)])                       # drop SampleID,label
    rownames(m) <- subj_of(ids)
    colnames(m) <- paste0(tag, "_", colnames(m))      # pos=P_ / neg=N_ prefix
    list(m = m, grp = setNames(group_of(ids), subj_of(ids)))
  }
  P <- rd(pos_path, "P"); N <- rd(neg_path, "N")
  stopifnot(identical(rownames(P$m), rownames(N$m)))
  X <- cbind(P$m, N$m)                                 # subject x feature
  X <- log2(X + 1)
  Xf <- t(X)                                           # feature x subject
  # subset samples before variance ranking so top_var reflects the analysis set
  if (!is.null(keep)) Xf <- Xf[, intersect(colnames(Xf), keep), drop = FALSE]
  if (!is.null(top_var)) {
    v <- apply(Xf, 1, var); Xf <- Xf[order(v, decreasing = TRUE)[seq_len(min(top_var, nrow(Xf)))], ]
  }
  list(log2 = Xf, group = P$grp)
}

## ---- align two feature x subject matrices on shared subjects ----------------
align_subjects <- function(A, B) {
  s <- intersect(colnames(A), colnames(B))
  s <- s[order(as.integer(sub("^u", "", s)))]
  list(A = A[, s, drop = FALSE], B = B[, s, drop = FALSE], subj = s)
}

## ---- CLR transform (for microbiome correlation / euclidean) -----------------
clr_mat <- function(M, pseudo = NULL) {            # M = feature x sample (rel.abund)
  if (is.null(pseudo)) pseudo <- min(M[M > 0]) / 2
  L <- log(M + pseudo)
  sweep(L, 2, colMeans(L), "-")
}

## ---- distance matrix per layer ---------------------------------------------
# microbiome: Bray-Curtis on relative abundance; metabolome: Euclidean on z(log2)
layer_dist <- function(mat, type) {
  if (type == "microbiome") {
    vegdist(t(mat), method = "bray")
  } else {
    z <- t(scale(t(mat)))                            # z-score per feature
    dist(t(z), method = "euclidean")
  }
}

## ---- (1) Mantel + (2) Procrustes overall congruence ------------------------
congruence <- function(Dx, Dy, nperm = 999, seed = 1) {
  set.seed(seed)
  mt <- mantel(Dx, Dy, method = "spearman", permutations = nperm)
  ox <- cmdscale(Dx, k = 5); oy <- cmdscale(Dy, k = 5)
  pt <- protest(ox, oy, permutations = nperm)
  list(mantel = mt, protest = pt, ox = ox, oy = oy)
}

## ---- (2b) variance explained: dbRDA of Dy constrained by saliva axes -------
# saliva structure summarised by its leading PCoA axes -> explain urine distance
variance_explained <- function(Dx, Dy, k = 8, nperm = 999, seed = 1) {
  set.seed(seed)
  ax <- cmdscale(Dx, k = k); colnames(ax) <- paste0("SalAx", seq_len(k))
  df <- as.data.frame(ax)
  cap <- dbrda(Dy ~ ., data = df)
  an  <- anova(cap, permutations = nperm)
  r2  <- summary(cap)$constr.chi / summary(cap)$tot.chi
  list(cap = cap, anova = an, R2 = as.numeric(r2),
       p = an$`Pr(>F)`[1], F = an$F[1])
}

## ---- (2c) PERMANOVA: adonis2 of Dy ~ saliva leading PCoA axes ---------------
# Distance-based variance partition by permutation. Uses the SAME saliva axes as
# dbRDA on purpose: adonis2 is the omnibus permutation test of the very partition
# dbRDA computes, so R2/F/p will closely match -- a deliberate teaching point that
# PERMANOVA and dbRDA are one model, not two independent confirmations.
permanova_xy <- function(Dx, Dy, k = 8, nperm = 999, seed = 1) {
  set.seed(seed)
  ax <- cmdscale(Dx, k = k); colnames(ax) <- paste0("SalAx", seq_len(k))
  df <- as.data.frame(ax)
  ad <- adonis2(Dy ~ ., data = df, permutations = nperm, by = NULL)
  list(adonis = ad, R2 = as.numeric(ad$R2[1]),
       F = as.numeric(ad$F[1]), p = ad$`Pr(>F)`[1])
}

## ---- subject-level metadata (from Saliva_meta.txt) -------------------------
load_subject_meta <- function(path = "Data/microbiome_data/Saliva_meta.txt") {
  m <- fread(path, header = TRUE)
  setnames(m, 1, "sample")
  data.frame(
    subject      = subj_of(m$sample),
    DiseaseGroup = factor(sub("^[SU]_", "", m$Group), levels = DISEASE_LEVELS),
    Gender       = factor(m$Gender),
    Age          = as.numeric(m$Age),
    row.names    = subj_of(m$sample), stringsAsFactors = FALSE)
}

## ---- (3) feature-feature Spearman network ----------------------------------
# A,B = feature x subject (aligned). Returns both FDR-significant and the paper's
# nominal-threshold (|r|>=rmin & P<pmax) edge sets.
cross_correlation <- function(A, B, rmin = 0.3, q = 0.05, pmax = 0.05) {
  At <- t(A); Bt <- t(B)
  R  <- cor(At, Bt, method = "spearman")             # nA x nB
  n  <- nrow(At)
  tt <- R * sqrt((n - 2) / (1 - R^2))
  P  <- 2 * pt(-abs(tt), df = n - 2)
  edges <- data.frame(
    from = rep(rownames(R), times = ncol(R)),
    to   = rep(colnames(R), each  = nrow(R)),
    r    = as.vector(R), p = as.vector(P))
  edges$fdr <- p.adjust(edges$p, "BH")
  ok  <- is.finite(edges$r) & abs(edges$r) >= rmin
  sig     <- edges[ok & edges$fdr < q, ];  sig     <- sig[order(-abs(sig$r)), ]
  sig_nom <- edges[ok & edges$p   < pmax, ]; sig_nom <- sig_nom[order(-abs(sig_nom$r)), ]
  list(R = R, edges = edges, sig = sig, sig_nom = sig_nom,
       n_tested = nrow(edges))
}

## ---- procrustes plot (saliva vs urine ordination, arrows per subject) ------
plot_procrustes <- function(cg, meta, title) {
  pr <- procrustes(cg$ox, cg$oy)
  sj <- rownames(cg$ox)
  df <- data.frame(x1 = pr$X[,1], y1 = pr$X[,2],
                   x2 = pr$Yrot[,1], y2 = pr$Yrot[,2],
                   grp = meta[sj, "DiseaseGroup"])
  ggplot(df) +
    geom_segment(aes(x1, y1, xend = x2, yend = y2, colour = grp),
                 arrow = arrow(length = unit(0.12, "cm")), alpha = .6, linewidth = .4) +
    geom_point(aes(x1, y1, colour = grp), size = 1.3) +
    scale_colour_manual(values = DISEASE_COLS, name = "Group",
                        labels = DISEASE_LABS, drop = FALSE) +
    labs(title = title,
         subtitle = sprintf("Procrustes correlation = %.3f, p = %.3f (999 perm)",
                            cg$protest$t0, cg$protest$signif),
         x = "Dim 1", y = "Dim 2") +
    theme_bw(base_size = 11) + theme(legend.position = "right")
}

## ---- tidy a feature name for display (strip MS-DIAL "; CExx; INCHIKEY") ------
clean_name <- function(x) substr(sub("\\s*;.*$", "", x), 1, 30)

## ---- bipartite correlation network -----------------------------------------
# edges: data.frame(from,to,r). from = saliva features, to = urine features.
plot_cross_network <- function(edges, from_type, to_type, max_edges = 250,
                               title = "") {
  e <- edges[order(-abs(edges$r)), ]
  if (nrow(e) > max_edges) e <- e[seq_len(max_edges), ]
  e$from <- paste0("S|", e$from); e$to <- paste0("U|", e$to)
  g <- graph_from_data_frame(e[, c("from","to","r")], directed = FALSE)
  V(g)$side <- ifelse(startsWith(V(g)$name, "S|"),
                      paste0("Saliva ", from_type), paste0("Urine ", to_type))
  V(g)$deg  <- degree(g)
  V(g)$lab  <- substr(clean_name(sub("^[SU]\\|", "", V(g)$name)), 1, 24)
  # label only the top-N hubs; crowding made every label unreadable before
  topn <- min(10, length(V(g)))
  V(g)$show <- V(g)$deg >= sort(V(g)$deg, decreasing = TRUE)[topn]
  E(g)$dir  <- ifelse(E(g)$r > 0, "positive", "negative")
  ggraph(g, layout = "stress") +
    geom_edge_link(aes(edge_colour = dir, edge_alpha = abs(r)), edge_width = .35) +
    geom_node_point(aes(colour = side, size = deg)) +
    geom_node_text(aes(label = ifelse(show, lab, "")), repel = TRUE, size = 2.5,
                   max.overlaps = Inf, box.padding = 0.7, point.padding = 0.3,
                   force = 4,
                   min.segment.length = 0, segment.size = .25,
                   segment.colour = "grey50") +
    scale_edge_colour_manual(values = c(positive = "#E64B35", negative = "#3C5488"),
                             name = "Correlation") +
    scale_edge_alpha(range = c(.15, .8), guide = "none") +
    scale_size(range = c(1, 5), name = "Degree") +
    scale_colour_manual(values = c("#00A087","#F39B7F","#8491B4","#91D1C2"),
                        name = "Node") +
    labs(title = title,
         subtitle = sprintf("%d significant pairs (|r|>=0.3, P<0.05); top %d shown",
                            nrow(edges), nrow(e))) +
    theme_graph(base_family = "") + theme(legend.position = "right")
}

## ---- heatmap data: top hub saliva features x top urine features ------------
hub_heatmap_data <- function(cc, n_from = 25, n_to = 25) {
  s <- cc$sig_nom
  if (nrow(s) == 0) return(NULL)
  top_from <- names(sort(table(s$from), decreasing = TRUE))[seq_len(min(n_from, length(unique(s$from))))]
  top_to   <- names(sort(table(s$to),   decreasing = TRUE))[seq_len(min(n_to,   length(unique(s$to))))]
  cc$R[top_from, top_to, drop = FALSE]
}

## ---- (5) mediation scan: X (saliva) -> M (urine) -> Y (urine) ---------------
# Pre-select triples whose 3 pairwise Spearman corrs are all nominally sig,
# then run mediation::mediate with covariate adjustment. Cap n triples.
mediation_scan <- function(Xmat, Mmat, Ymat, meta, ccXM, ccMY, ccXY = NULL,
                           max_triples = 120, sims = 300, seed = 1,
                           require_xy = FALSE) {
  set.seed(seed)
  sxm <- ccXM$sig_nom; smy <- ccMY$sig_nom
  if (nrow(sxm) == 0 || nrow(smy) == 0)
    return(list(res = data.frame(), n_candidate = 0))
  cand <- merge(sxm, smy, by.x = "to", by.y = "from",
                suffixes = c(".xm", ".my"))      # X - M - Y, share mediator
  if (require_xy && !is.null(ccXY)) {            # paper-strict: also need X-Y sig
    cand$key <- paste(cand$from, cand$to.my)
    cand <- cand[cand$key %in% paste(ccXY$sig_nom$from, ccXY$sig_nom$to), ]
  }
  if (nrow(cand) == 0) return(list(res = data.frame(), n_candidate = 0))
  cand$score <- abs(cand$r.xm) * abs(cand$r.my)
  cand <- cand[order(-cand$score), ]
  cand <- head(cand, max_triples)
  sj <- colnames(Xmat); Z <- meta[sj, c("Age","Gender","DiseaseGroup")]
  out <- lapply(seq_len(nrow(cand)), function(i) {
    X <- as.numeric(Xmat[cand$from[i], ]); M <- as.numeric(Mmat[cand$to[i], ])
    Y <- as.numeric(Ymat[cand$to.my[i], ])
    d <- data.frame(X, M, Y, Age = Z$Age, Gender = Z$Gender, DG = Z$DiseaseGroup)
    fm <- try(mediation::mediate(
      lm(M ~ X + Age + Gender + DG, d),
      lm(Y ~ X + M + Age + Gender + DG, d),
      treat = "X", mediator = "M", sims = sims), silent = TRUE)
    if (inherits(fm, "try-error")) return(NULL)
    data.frame(saliva_microbe = cand$from[i], urine_microbe = cand$to[i],
               urine_metab = cand$to.my[i],
               ACME = fm$d0, ACME_p = fm$d0.p, ADE = fm$z0, prop_med = fm$n0,
               total_p = fm$tau.p)
  })
  res <- do.call(rbind, out)
  if (!is.null(res)) { res$ACME_fdr <- p.adjust(res$ACME_p, "BH")
                       res <- res[order(res$ACME_p), ] }
  list(res = res, n_candidate = nrow(cand))
}

## ---- (4) random-forest predictive R^2 (paper's GBDT analog) ----------------
# Predict each of the top urine features from the full saliva feature matrix,
# k-fold CV, report out-of-fold R^2. Returns per-target R^2 vector + summary.
rf_predict_R2 <- function(Xsal, Yuri, n_target = 40, kfold = 5,
                          ntree = 120, seed = 1) {
  set.seed(seed)
  v <- apply(Yuri, 1, var)
  targ <- order(v, decreasing = TRUE)[seq_len(min(n_target, nrow(Yuri)))]
  Xpred <- t(Xsal)                                   # subject x feature
  fold  <- sample(rep_len(seq_len(kfold), ncol(Yuri)))
  r2 <- sapply(targ, function(j) {
    y <- Yuri[j, ]; pred <- numeric(length(y))
    for (k in seq_len(kfold)) {
      tr <- fold != k; te <- !tr
      fit <- randomForest(Xpred[tr, , drop = FALSE], y[tr], ntree = ntree)
      pred[te] <- predict(fit, Xpred[te, , drop = FALSE])
    }
    1 - sum((y - pred)^2) / sum((y - mean(y))^2)     # CV R^2 (can be <0)
  })
  names(r2) <- rownames(Yuri)[targ]
  list(r2 = r2, mean = mean(r2), median = median(r2),
       frac_pos5 = mean(r2 > 0.05))
}

## ---- orchestrator: full analysis of one saliva -> urine layer pairing ------
# *_dist matrices feed Bray/Euclidean distance (full features);
# *_cor matrices feed correlation + RF (reduced/standardised features).
analyze_pairing <- function(A_dist, B_dist, tA, tB, A_cor, B_cor,
                            n_target = 40, nperm = 999, seed = 1) {
  ad <- align_subjects(A_dist, B_dist)
  Dx <- layer_dist(ad$A, tA); Dy <- layer_dist(ad$B, tB)
  cg <- congruence(Dx, Dy, nperm = nperm, seed = seed)
  ve <- variance_explained(Dx, Dy, k = 8, nperm = nperm, seed = seed)
  pm <- permanova_xy(Dx, Dy, k = 8, nperm = nperm, seed = seed)
  ac <- align_subjects(A_cor, B_cor)
  cc <- cross_correlation(ac$A, ac$B)
  rf <- rf_predict_R2(ac$A, ac$B, n_target = n_target, seed = seed)
  list(cg = cg, ve = ve, pm = pm, cc = cc, rf = rf, n = length(ad$subj),
       Dx = Dx, Dy = Dy)
}

## ---- per-feature PERMANOVA (paper-style): each X feature vs Dy --------------
# For every saliva feature (predictor) run univariate adonis2(Dy ~ feature):
#   R2 = SS_feature / SS_total, pseudo-F, permutation P.
# Implemented via the McArdle-Anderson Gower-matrix quadratic form, vectorised
# over all features (one matrix product per permutation), so it matches
# vegan::adonis2 for a single continuous predictor but runs in ~1 s for thousands
# of features. Xmat = feature x subject; columns are aligned to Dy's labels.
permanova_per_feature <- function(Dy, Xmat, nperm = 199, seed = 1) {
  set.seed(seed)
  D <- as.matrix(Dy); n <- nrow(D); sj <- rownames(D)
  if (!is.null(sj)) Xmat <- Xmat[, sj, drop = FALSE]      # align subjects to Dy
  A  <- -0.5 * D^2
  rm <- rowMeans(A); gm <- mean(A)
  G  <- A - outer(rm, rep(1, n)) - outer(rep(1, n), rm) + gm   # Gower double-centre
  SST <- sum(diag(G))
  Xc  <- scale(t(Xmat), center = TRUE, scale = FALSE)     # subject x feature, centred
  den <- colSums(Xc^2)
  keep <- den > 0 & is.finite(den)                        # drop zero-variance features
  Xc <- Xc[, keep, drop = FALSE]; den <- den[keep]
  ssm  <- colSums(Xc * (G %*% Xc)) / den                  # SS explained per feature
  Fobs <- ssm / ((SST - ssm) / (n - 2))
  ge <- numeric(ncol(Xc))
  for (b in seq_len(nperm)) {
    Xp   <- Xc[sample.int(n), , drop = FALSE]
    ssmp <- colSums(Xp * (G %*% Xp)) / den
    ge   <- ge + ((ssmp / ((SST - ssmp) / (n - 2))) >= Fobs)
  }
  data.frame(feature = colnames(Xc), R2 = ssm / SST, F = Fobs,
             p = (ge + 1) / (nperm + 1), row.names = NULL)
}

## ---- histogram of significant per-feature PERMANOVA R2 ---------------------
plot_perfeature_hist <- function(pf, title, fill = "#3C5488", bins = 30) {
  sig <- pf[pf$p < 0.05 & is.finite(pf$R2), ]
  ggplot(sig, aes(R2)) +
    geom_histogram(bins = bins, fill = fill, colour = "white") +
    geom_vline(xintercept = median(sig$R2), linetype = 2, colour = "#E64B35") +
    labs(title = title,
         subtitle = sprintf("%d / %d features significant (P<0.05); median R2 = %.3f, max = %.3f",
                            nrow(sig), nrow(pf), median(sig$R2), max(sig$R2)),
         x = "per-feature PERMANOVA R2 (explained in urine distance)",
         y = "number of features") +
    theme_bw(base_size = 11)
}

## ---- joint (multivariate) PERMANOVA R2 of the significant features ----------
# The per-feature R2 summed across significant features (naive_sum) double-counts
# shared variance and can exceed 1. The TRUE joint explained variance must come
# from one multivariate model adonis2(Dy ~ X1 + ... + Xk):
#   - full model uses ALL significant features, but is DEGENERATE when p >= n-1
#     (predictors >= samples) -> R2 is forced to 1 with 0 residual df;
#   - so we also report a collinearity-free estimate: adonis2 on the leading
#     PCs of the significant-feature block (orthogonal, p_pc << n).
permanova_joint <- function(Dy, Xmat, pf, n_pc = 10, nperm = 199, seed = 1) {
  set.seed(seed)
  sj <- rownames(as.matrix(Dy))                 # align predictors to Dy subject order
  if (!is.null(sj)) Xmat <- Xmat[, sj, drop = FALSE]
  n <- ncol(Xmat)
  feats <- pf$feature[pf$p < 0.05 & is.finite(pf$R2)]
  naive <- sum(pf$R2[pf$p < 0.05 & is.finite(pf$R2)])
  if (length(feats) < 2)
    return(data.frame(n_sig = length(feats), naive_sum_R2 = round(naive, 3),
                      full_R2 = NA, full_degenerate = NA, pc_q = NA,
                      joint_R2_pca = NA, joint_p_pca = NA))
  Xs <- scale(t(Xmat[feats, , drop = FALSE]), center = TRUE, scale = FALSE)
  degen <- ncol(Xs) >= n - 1
  full_R2 <- if (degen) 1 else
    adonis2(Dy ~ ., data = as.data.frame(Xs), by = NULL, permutations = nperm)$R2[1]
  q  <- min(n_pc, ncol(Xs), n - 2)
  pc <- prcomp(Xs)$x[, seq_len(q), drop = FALSE]
  ap <- adonis2(Dy ~ ., data = as.data.frame(pc), by = NULL, permutations = nperm)
  data.frame(n_sig = ncol(Xs), naive_sum_R2 = round(naive, 3),
             full_R2 = round(full_R2, 3), full_degenerate = degen, pc_q = q,
             joint_R2_pca = round(ap$R2[1], 3), joint_p_pca = signif(ap$`Pr(>F)`[1], 2))
}

## ---- paper-style cumulative variance explained + bootstrap CI --------------
# Mirrors Zhang et al. (Microbiome 2026, Fig 2a): (1) univariate adonis2 screen
# per saliva feature, keep P<0.05; (2) ONE joint adonis2(Dy ~ all sig features)
# -> cumulative R2 (shared variance counted once, bounded in [0,1] when k<n,
# NOT a sum of univariate R2); (3) bootstrap subjects for a 95% CI. When the
# significant set is too large (k >= n-1) the joint model is degenerate (p>=n),
# so we substitute the leading PCs of that block and flag the method.
# NOTE on CI method: classic with-replacement bootstrap of a distance matrix
# duplicates samples -> zero-distance pairs that inflate R2 (CI ends up above the
# point estimate). We instead use SUBSAMPLING without replacement (f*n subjects),
# which avoids the artifact. Predictors are the leading PCs of the significant
# block (orthogonal, p_pc << n) so the model stays well-posed at our small n
# (the paper's n=435 allowed using all significant genera directly).
permanova_cumulative <- function(Dy, Xmat, pf, n_pc = 10, B = 300, f = 0.85,
                                 nperm = 999, seed = 1) {
  set.seed(seed)
  Dm <- as.matrix(Dy); n <- nrow(Dm); sj <- rownames(Dm)
  Xa <- if (!is.null(sj)) Xmat[, sj, drop = FALSE] else Xmat
  feats <- pf$feature[pf$p < 0.05 & is.finite(pf$R2)]
  if (length(feats) < 2)
    return(data.frame(n_sig = length(feats), pc_q = NA, R2 = NA,
                      ci_lo = NA, ci_hi = NA, p = NA))
  Xs <- scale(t(Xa[feats, , drop = FALSE]), center = TRUE, scale = FALSE)
  q  <- min(n_pc, ncol(Xs), n - 2)
  P  <- prcomp(Xs)$x[, seq_len(q), drop = FALSE]
  pt <- adonis2(Dy ~ ., data = as.data.frame(P), by = NULL, permutations = nperm)
  m  <- round(f * n); r2b <- numeric(B)
  for (b in seq_len(B)) {
    idx <- sample(n, size = m, replace = FALSE)          # no duplicates
    Pb  <- as.data.frame(P[idx, , drop = FALSE])
    r2b[b] <- adonis2(as.dist(Dm[idx, idx]) ~ ., data = Pb,
                      by = NULL, permutations = 1)$R2[1]
  }
  ci <- quantile(r2b, c(.025, .975), names = FALSE)
  data.frame(n_sig = length(feats), pc_q = q,
             R2 = round(as.numeric(pt$R2[1]), 4),
             ci_lo = round(ci[1], 4), ci_hi = round(ci[2], 4),
             p = signif(pt$`Pr(>F)`[1], 2))
}

## ---- forest plot of cumulative R2 + 95% CI across pairings ------------------
plot_cumulative_R2 <- function(df, title = "") {
  df$pairing <- factor(df$pairing, levels = rev(df$pairing))
  ggplot(df, aes(R2, pairing)) +
    geom_errorbarh(aes(xmin = ci_lo, xmax = ci_hi), height = .18, colour = "#3C5488") +
    geom_point(aes(colour = pairing), size = 3.4) +
    geom_text(aes(label = sprintf("%.1f%% [%.1f–%.1f]", 100*R2, 100*ci_lo, 100*ci_hi)),
              vjust = -1.1, size = 3.2) +
    scale_x_continuous(labels = function(x) paste0(round(100*x), "%"),
                       limits = c(0, max(df$ci_hi) * 1.15)) +
    scale_colour_manual(values = c("#2E6F95","#D9A441","#1B998B"), guide = "none") +
    labs(title = title, x = "cumulative variance of urine layer explained (R2, 95% CI)",
         y = NULL) + theme_bw(base_size = 11)
}

## ---- shared cross-site, disease-differential metabolites -------------------
# Metabolites measurable in BOTH fluids (same ionisation mode + same name) that
# also separate healthy (N) from disease (P/PD/PC/PCD). Wilcoxon per fluid,
# BH-FDR within fluid; log2FC = median(disease) - median(healthy).
shared_disease_test <- function(Smet, Umet, meta) {
  sj <- intersect(colnames(Smet), colnames(Umet))
  sj <- sj[order(as.integer(sub("^u", "", sj)))]
  ill <- meta[sj, "DiseaseGroup"] != "N"
  sh  <- intersect(rownames(Smet), rownames(Umet))
  tst <- function(M) {
    M <- M[sh, sj, drop = FALSE]
    list(p  = apply(M, 1, function(x)
           tryCatch(wilcox.test(x[ill], x[!ill])$p.value, error = function(e) NA)),
         fc = apply(M, 1, function(x) median(x[ill]) - median(x[!ill])))
  }
  S <- tst(Smet); U <- tst(Umet)
  data.frame(feature = sh, name = clean_name(sh),
             saliva_log2FC = S$fc, saliva_p = S$p, saliva_fdr = p.adjust(S$p, "BH"),
             urine_log2FC  = U$fc, urine_p  = U$p, urine_fdr  = p.adjust(U$p, "BH"),
             same_dir = sign(S$fc) == sign(U$fc),
             n_healthy = sum(!ill), n_disease = sum(ill), row.names = NULL)
}

## ---- saliva vs urine log2FC scatter (shared metabolites) -------------------
plot_shared_fc <- function(df, title = "") {
  df <- df[is.finite(df$saliva_p) & is.finite(df$urine_p) &
           is.finite(df$saliva_log2FC) & is.finite(df$urine_log2FC), ]
  df$grp <- with(df, ifelse(saliva_p < .05 & urine_p < .05 & same_dir,
                            "both sites sig, same direction",
                     ifelse(saliva_p < .05 | urine_p < .05, "one site sig", "ns")))
  df$grp <- factor(df$grp, levels = c("both sites sig, same direction",
                                      "one site sig", "ns"))
  df <- df[order(df$grp, decreasing = TRUE), ]           # candidates drawn on top
  lab <- df[df$grp == "both sites sig, same direction", ]
  # zoom to the informative core: extreme sparse-feature fold changes otherwise
  # squash everything; keep all labelled candidates inside the window
  qs  <- quantile(c(df$saliva_log2FC, df$urine_log2FC), c(.01, .99), na.rm = TRUE)
  rng <- max(abs(qs), abs(c(lab$saliva_log2FC, lab$urine_log2FC)), na.rm = TRUE) * 1.18
  n_out <- sum(abs(df$saliva_log2FC) > rng | abs(df$urine_log2FC) > rng)
  ggplot(df, aes(saliva_log2FC, urine_log2FC)) +
    geom_hline(yintercept = 0, colour = "grey70") +
    geom_vline(xintercept = 0, colour = "grey70") +
    geom_abline(slope = 1, intercept = 0, linetype = 3, colour = "grey80") +
    geom_point(aes(colour = grp, size = grp), alpha = .8) +
    ggrepel::geom_text_repel(data = lab,
                             aes(label = wrap_chem(sub("\\s*;.*$", "", name),
                                                   width = 19, max_lines = 3)),
                             size = 2.8, lineheight = 0.85, max.overlaps = Inf,
                             min.segment.length = 0, box.padding = .6,
                             segment.colour = "grey45", segment.size = .3) +
    scale_colour_manual(values = c("both sites sig, same direction" = "#E64B35",
                                   "one site sig" = "#F39B7F", "ns" = "grey80"),
                        name = NULL, drop = FALSE) +
    scale_size_manual(values = c("both sites sig, same direction" = 2.8,
                                 "one site sig" = 1.5, "ns" = 0.9), guide = "none") +
    coord_cartesian(xlim = c(-rng, rng), ylim = c(-rng, rng)) +
    labs(title = title,
         subtitle = sprintf("%d testable shared metabolites | %d candidates | %d off-scale hidden",
                            nrow(df), nrow(lab), n_out),
         x = "Saliva log2FC (disease - healthy)",
         y = "Urine log2FC (disease - healthy)") +
    theme_bw(base_size = 11) + theme(legend.position = "top")
}

## ---- per-metabolite biological note (curated; matched on cleaned name) -----
# Keyword -> short note. Used to auto-annotate whatever candidates come out, so
# the write-up never lags behind the candidate list (e.g. after dropping PD).
metabolite_note <- function(names) {
  db <- list(
    "Propionic acid"        = "短链脂肪酸(SCFA),微生物发酵产物,GPR43/HDAC 抗炎;标准品易得",
    "Hydroxyphenylacetic"   = "微生物来源芳香族(苯丙氨酸/酪氨酸)代谢物;内源、可购",
    "lauroylethanolamine"   = "N-酰基乙醇胺类脂质介质(类 PEA),PPARα 抗炎;内源、可购",
    "Harman"                = "β-咔啉生物碱;内源兼膳食来源(咖啡/烘焙),易受饮食混杂,慎用",
    "Dimethyltetradecylamine"= "脂肪叔胺,常见于表面活性剂;有外源污染嫌疑,需确证",
    "isobutylphosphate"     = "磷酸三异丁酯=工业增塑剂/阻燃剂;非内源,疑暴露/耗材污染,不建议",
    "butylphosphate"        = "磷酸酯类工业添加剂;非内源,不建议",
    "quinazolin"            = "谱库匹配的含氮杂环,未确证;须标准品+MS/MS",
    "pyrazolo"              = "谱库匹配的吡唑并嘧啶类,未确证;须标准品+MS/MS",
    "6aR,8aS"               = "长链甾体/萜类骨架,log2FC 极端疑零值伪影;须确证",
    "6aR"                   = "长链多环骨架,谱库匹配,未确证;须标准品+MS/MS")
  vapply(clean_name(names), function(nm) {
    hit <- names(db)[vapply(names(db), function(k) grepl(k, nm, ignore.case = TRUE), logical(1))]
    if (length(hit)) db[[hit[1]]] else "谱库匹配名,未经标准品确证;须先做 MS/MS 比对"
  }, character(1), USE.NAMES = FALSE)
}

## ---- candidate triage: priority / unconfirmed / exclude --------------------
# Curated call (biology, not statistics): endogenous + purchasable + mechanism
# known = priority; known industrial contaminant = exclude; spectral-library-only
# IUPAC names = unconfirmed (need standard + MS/MS before any purchase).
classify_candidates <- function(features) {
  n <- clean_name(features)
  hit <- function(pats) Reduce(`|`, lapply(pats, grepl, x = n, ignore.case = TRUE))
  tier <- rep(2L, length(n))                                   # default: unconfirmed
  tier[hit(c("Propionic acid", "Hydroxyphenylacetic", "lauroylethanolamine"))] <- 1L
  tier[hit(c("isobutylphosphate", "butylphosphate"))] <- 3L    # plasticiser/flame retardant
  factor(c("priority", "unconfirmed", "exclude")[tier],
         levels = c("priority", "unconfirmed", "exclude"))
}

# order candidates: priority tier first, then by saliva significance within tier
order_candidates <- function(cand) {
  cand$tier <- classify_candidates(cand$feature)
  cand[order(as.integer(cand$tier), cand$saliva_p), ]
}

# wrap a chemical name onto several lines: prefer breaking after -_(),. or space,
# hard-break only if a token runs far past the target width
# max_lines caps absurd IUPAC names (e.g. the 10-line tetradecahydro-naphtho...)
# so one facet cannot squash the whole panel; short names are unaffected.
wrap_chem <- function(x, width = 16, max_lines = 4) {
  vapply(x, function(s) {
    s <- as.character(s)
    if (nchar(s) <= width) return(s)
    lines <- character(0); cur <- ""
    for (ch in strsplit(s, "")[[1]]) {
      cur <- paste0(cur, ch)
      if (nchar(cur) >= width && grepl("[-_(),. ]$", cur)) { lines <- c(lines, cur); cur <- "" }
      else if (nchar(cur) >= width + 6) { lines <- c(lines, cur); cur <- "" }
    }
    if (nzchar(cur)) lines <- c(lines, cur)
    lines <- trimws(lines)
    # avoid orphans: if the last line is a tiny fragment (<=4 chars), merge it up
    nl <- length(lines)
    if (nl >= 2 && nchar(lines[nl]) <= 4) {
      lines[nl - 1] <- paste0(lines[nl - 1], lines[nl]); lines <- lines[-nl]
    }
    if (length(lines) > max_lines)
      lines <- c(lines[seq_len(max_lines)], "...")
    paste(lines, collapse = "\n")
  }, character(1), USE.NAMES = FALSE)
}

# ASCII facet labels: line 1 = rank + tier tag, line 2+ = FULL metabolite name
# (wrapped, never truncated). CJK would crash the graphics device, so ASCII only.
candidate_labels <- function(cand, width = 20, max_lines = 4) {
  tag <- c(priority = "[OK]", unconfirmed = "[?]", exclude = "[X]")[as.character(cand$tier)]
  nm  <- sub("\\s*;.*$", "", cand$feature)      # drop MS-DIAL suffix, keep full name
  setNames(sprintf("%d %s\n%s", seq_len(nrow(cand)), tag, wrap_chem(nm, width, max_lines)),
           cand$feature)
}

## ---- boxplots of candidate metabolites in both fluids ----------------------
# One panel per metabolite (facet_wrap -> ncol per row); inside each panel the
# four boxes are Saliva/Urine x Healthy/Disease. This wraps the candidates onto
# several rows so long names get room, instead of one very wide single row.
plot_candidate_box <- function(Smet, Umet, meta, feats, title = "", labels = NULL,
                               ncol = 5) {
  sj <- intersect(colnames(Smet), colnames(Umet))
  sj <- sj[order(as.integer(sub("^u", "", sj)))]
  grp <- ifelse(meta[sj, "DiseaseGroup"] == "N", "Healthy", "Disease")
  mk <- function(M, site) {
    d <- as.data.frame(t(M[feats, sj, drop = FALSE]))
    d$Group <- grp; d$Site <- site
    tidyr::pivot_longer(d, -c(Group, Site), names_to = "feature", values_to = "log2")
  }
  L <- rbind(mk(Smet, "Saliva"), mk(Umet, "Urine"))
  if (is.null(labels)) labels <- setNames(substr(clean_name(feats), 1, 22), feats)
  L$feature <- factor(labels[L$feature], levels = unname(labels[feats]))  # keep given order
  L$Group <- factor(L$Group, levels = c("Healthy", "Disease"))
  L$Site  <- factor(L$Site,  levels = c("Saliva", "Urine"))
  ggplot(L, aes(Site, log2, fill = Group)) +
    geom_boxplot(outlier.size = .4, width = .7, linewidth = .3,
                 position = position_dodge(preserve = "single")) +
    facet_wrap(~ feature, ncol = ncol, scales = "free_y") +
    scale_fill_manual(values = c(Healthy = "#4DBBD5", Disease = "#E64B35")) +
    labs(title = title,
         subtitle = "priority order left->right, top->bottom;  each panel: Saliva & Urine x Healthy/Disease.  [OK] endogenous&purchasable  [?] needs MS/MS  [X] contaminant",
         x = NULL, y = "log2 intensity", fill = NULL) +
    theme_bw(base_size = 9.5) +
    theme(strip.text = element_text(size = 7, lineheight = 0.92,
                                    margin = ggplot2::margin(2,1,2,1)),
          legend.position = "top", panel.spacing = unit(0.5, "lines"))
}

## ---- per-disease-subgroup screen (P / PD / PC / PCD vs healthy N) ----------
subgroup_screen <- function(Smet, Umet, meta, feats) {
  sj <- intersect(colnames(Smet), colnames(Umet))
  sj <- sj[order(as.integer(sub("^u", "", sj)))]
  g  <- as.character(meta[sj, "DiseaseGroup"])
  res <- list()
  for (site in c("Saliva", "Urine")) {
    M <- (if (site == "Saliva") Smet else Umet)[feats, sj, drop = FALSE]
    for (sg in intersect(c("P", "PD", "PC", "PCD"), unique(g))) {
      d <- g == sg; h <- g == "N"
      for (f in feats) {
        x <- as.numeric(M[f, ])
        res[[length(res) + 1]] <- data.frame(
          feature = f, site = site, subgroup = sg, n_case = sum(d),
          log2FC = median(x[d]) - median(x[h]),
          p = tryCatch(wilcox.test(x[d], x[h])$p.value, error = function(e) NA))
      }
    }
  }
  do.call(rbind, res)
}

## ---- clinical flags derived from disease group -----------------------------
# The cohort's group code maps 1:1 onto the clinical indicators (verified against
# metadata代谢+微生物.xlsx): N=none, P=perio, PD=perio+diabetes,
# PC=perio+kidney, PCD=perio+diabetic-kidney. NOTE: no eGFR/creatinine exists in
# this dataset, so the kidney axis is an ORDERED SEVERITY GRADE, not true eGFR.
add_clinical_flags <- function(meta) {
  g <- as.character(meta$DiseaseGroup)
  meta$Periodontitis  <- as.integer(g %in% c("P","PD","PC","PCD"))
  meta$Diabetes       <- as.integer(g %in% c("PD","PCD"))
  meta$Kidney         <- as.integer(g %in% c("PC","PCD"))
  meta$KidneySeverity <- ifelse(g == "PC", 1L, ifelse(g == "PCD", 2L, 0L))
  meta
}

## ---- kidney-gradient trend + independence from perio/diabetes --------------
# Three complementary tests per metabolite per fluid:
#  (1) Jonckheere-Terpstra ordered trend across 0 -> 1 -> 2 kidney severity
#  (2) within-periodontitis contrast (P+PD vs PC+PCD): removes perio as driver
#  (3) linear model adjusting for perio + diabetes + age + sex
kidney_trend_test <- function(Smet, Umet, meta, feats) {
  sj <- intersect(colnames(Smet), colnames(Umet))
  sj <- sj[order(as.integer(sub("^u", "", sj)))]
  m  <- add_clinical_flags(meta[sj, , drop = FALSE])
  out <- list()
  for (site in c("Saliva", "Urine")) {
    M <- (if (site == "Saliva") Smet else Umet)[feats, sj, drop = FALSE]
    for (f in feats) {
      x  <- as.numeric(M[f, ])
      jt <- tryCatch(DescTools::JonckheereTerpstraTest(
              x, factor(m$KidneySeverity, ordered = TRUE))$p.value,
              error = function(e) NA_real_)
      rho <- suppressWarnings(cor(x, m$KidneySeverity, method = "spearman"))
      pp  <- m$Periodontitis == 1                      # all have periodontitis
      wp  <- tryCatch(wilcox.test(x[pp & m$Kidney == 1],
                                  x[pp & m$Kidney == 0])$p.value,
                      error = function(e) NA_real_)
      wfc <- median(x[pp & m$Kidney == 1]) - median(x[pp & m$Kidney == 0])
      fit <- try(lm(x ~ m$Kidney + m$Periodontitis + m$Diabetes + m$Age + m$Gender),
                 silent = TRUE)
      ke <- kp <- NA_real_
      if (!inherits(fit, "try-error")) {
        cf <- summary(fit)$coefficients
        i  <- grep("Kidney", rownames(cf))[1]
        if (!is.na(i)) { ke <- cf[i, 1]; kp <- cf[i, 4] }
      }
      out[[length(out) + 1]] <- data.frame(
        feature = f, site = site, JT_p = jt, spearman_rho = rho,
        perioOnly_log2FC = wfc, perioOnly_p = wp,
        adj_kidney_beta = ke, adj_kidney_p = kp)
    }
  }
  do.call(rbind, out)
}

## ---- metabolite level across the ordered kidney-severity grade -------------
plot_kidney_gradient <- function(Smet, Umet, meta, feats, labels = NULL, title = "") {
  sj <- intersect(colnames(Smet), colnames(Umet))
  sj <- sj[order(as.integer(sub("^u", "", sj)))]
  m  <- add_clinical_flags(meta[sj, , drop = FALSE])
  lv0 <- paste(intersect(c("N","P","PD"), as.character(unique(m$DiseaseGroup))), collapse = "/")
  sev <- factor(m$KidneySeverity, levels = 0:2,
                labels = c(sprintf("0 no kidney\n(%s)", lv0), "1 kidney\n(PC)",
                           "2 diabetic kidney\n(PCD)"))
  mk <- function(M, site) {
    d <- as.data.frame(t(M[feats, sj, drop = FALSE]))
    d$Severity <- sev; d$Site <- site
    tidyr::pivot_longer(d, -c(Severity, Site), names_to = "feature", values_to = "log2")
  }
  L <- rbind(mk(Smet, "Saliva"), mk(Umet, "Urine"))
  if (is.null(labels)) labels <- setNames(substr(clean_name(feats), 1, 22), feats)
  L$feature <- factor(labels[L$feature], levels = unname(labels[feats]))
  ggplot(L, aes(Severity, log2, fill = Severity)) +
    geom_boxplot(outlier.size = .5, width = .62) +
    facet_grid(Site ~ feature, scales = "free_y") +
    scale_fill_manual(values = c("#4DBBD5", "#F39B7F", "#E64B35"), guide = "none") +
    labs(title = title,
         subtitle = "ordered kidney-severity grade (no eGFR available in this cohort)",
         x = NULL, y = "log2 intensity") +
    theme_bw(base_size = 9.5)
}

## ---- heatmap of subgroup-specific effects ----------------------------------
plot_subgroup_heat <- function(df, labels, title = "") {
  df$lab <- factor(labels[df$feature], levels = rev(unname(labels)))
  df$subgroup <- factor(df$subgroup, levels = intersect(c("P","PD","PC","PCD"), unique(df$subgroup)))
  df$star <- ifelse(is.na(df$p), "", ifelse(df$p < .01, "**", ifelse(df$p < .05, "*", "")))
  lim <- max(abs(df$log2FC), na.rm = TRUE)
  ggplot(df, aes(subgroup, lab, fill = log2FC)) +
    geom_tile(colour = "white", linewidth = .5) +
    geom_text(aes(label = star), size = 4.2, vjust = .78) +
    facet_wrap(~ site) +
    scale_fill_gradient2(low = "#3C5488", mid = "white", high = "#E64B35",
                         midpoint = 0, limits = c(-lim, lim), name = "log2FC") +
    labs(title = title,
         subtitle = local({
           cnt <- tapply(df$n_case, df$subgroup, function(z) z[1])
           cnt <- cnt[!is.na(cnt)]
           sprintf("vs healthy (N);  * P<0.05  ** P<0.01   [%s]",
                   paste(sprintf("%s n=%d", names(cnt), cnt), collapse = ", "))
         }),
         x = "disease subgroup", y = NULL) +
    theme_bw(base_size = 10)
}

## ---- four-method comparison table for one pairing (display helper) ----------
four_method_table <- function(res) {
  mt <- res$cg$mantel; pt <- res$cg$protest
  data.frame(
    方法 = c("Mantel test", "Procrustes (protest)",
             "PERMANOVA (adonis2)", "dbRDA"),
    问题 = c("两个距离矩阵是否相关？(对称)",
             "两个排序构型能否重合？(对称)",
             "X 能解释 Y 多少方差？(Y~X)",
             "X 约束下 Y 的方差比例？(Y~X)"),
    统计量 = c(sprintf("r = %.3f", mt$statistic),
               sprintf("r = %.3f, m² = %.3f", pt$t0, pt$ss),
               sprintf("pseudo-F = %.2f", res$pm$F),
               sprintf("F = %.2f", res$ve$F)),
    `解释比例R²` = c("—", "—",
               sprintf("%.3f", res$pm$R2), sprintf("%.3f", res$ve$R2)),
    P = c(signif(mt$signif, 2), signif(pt$signif, 2),
          signif(res$pm$p, 2), signif(res$ve$p, 2)),
    check.names = FALSE)
}

# one-row summary for the cross-pairing synthesis table
pairing_summary <- function(res, label) {
  data.frame(
    pairing      = label,
    n            = res$n,
    mantel_r     = round(res$cg$mantel$statistic, 3),
    mantel_p     = signif(res$cg$mantel$signif, 2),
    procrustes_r = round(res$cg$protest$t0, 3),
    procrustes_p = signif(res$cg$protest$signif, 2),
    permanova_R2 = round(res$pm$R2, 3),
    permanova_p  = signif(res$pm$p, 2),
    dbRDA_R2     = round(res$ve$R2, 3),
    dbRDA_p      = signif(res$ve$p, 2),
    sig_pairs    = nrow(res$cc$sig_nom),
    sig_pairs_fdr= nrow(res$cc$sig),
    RF_meanR2    = round(res$rf$mean, 3),
    RF_frac_R2gt5= round(res$rf$frac_pos5, 2),
    check.names  = FALSE)
}

cat("crossomics_helpers.R loaded\n")
