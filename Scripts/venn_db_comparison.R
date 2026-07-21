#!/usr/bin/env Rscript
# Compare GTDB vs HROM species annotations for saliva (S) and urine (U) samples.
#
# Species-matching rule (user-specified):
#   * HROM species id = value of the `Species` column with the leading "s__"
#     removed and every space replaced by "_".
#   * GTDB species id = the `Taxonomy` value as-is.
#   * Two species are the SAME only if the two strings are exactly identical.
# Detection rule:
#   * A species is "present" at a body site if its abundance is > 0 in at least
#     one sample of that site.
#
# Run from the project root:  Rscript Scripts/venn_db_comparison.R

suppressPackageStartupMessages({
  library(data.table)
  library(ggvenn)
  library(ggplot2)
})

## ---- paths ----
data_dir    <- "Data"
results_dir <- "Results"
dir.create(results_dir, showWarnings = FALSE)

meta_file <- file.path(data_dir, "meta.txt")
gtdb_file <- file.path(data_dir, "Species.xls")   # GTDB annotation
hrom_file <- file.path(data_dir, "hrom.all.xls")  # HROM annotation

## ---- read ----
meta <- fread(meta_file, sep = "\t", header = TRUE)
setnames(meta, trimws(names(meta)))
meta[, name     := trimws(as.character(name))]
meta[, Position := trimws(as.character(Position))]
meta_pos <- setNames(meta$Position, meta$name)

gtdb <- fread(gtdb_file, sep = "\t", header = TRUE)
hrom <- fread(hrom_file, sep = "\t", header = TRUE)

## ---- identify sample columns and assign each to a body site ----
lineage_cols <- c("Kingdom", "Phylum", "Class", "Order", "Family", "Genus", "Species")

# Site = meta Position when the sample is in meta, otherwise the name prefix (S/U).
site_of <- function(cols) {
  s <- ifelse(cols %in% names(meta_pos), meta_pos[cols], substr(cols, 1, 1))
  unname(s)
}

gtdb_samples <- setdiff(names(gtdb), "Taxonomy")
hrom_samples <- setdiff(names(hrom), lineage_cols)

gtdb_S <- gtdb_samples[site_of(gtdb_samples) == "S"]
gtdb_U <- gtdb_samples[site_of(gtdb_samples) == "U"]
hrom_S <- hrom_samples[site_of(hrom_samples) == "S"]
hrom_U <- hrom_samples[site_of(hrom_samples) == "U"]

## ---- build species ids ----
gtdb[, sp_id := as.character(Taxonomy)]
hrom[, sp_id := gsub(" ", "_", sub("^s__", "", as.character(Species)))]

## ---- species detected at a site (abundance > 0 in >= 1 sample) ----
present_species <- function(dt, cols) {
  if (length(cols) == 0) return(character(0))
  m <- as.matrix(dt[, ..cols])
  storage.mode(m) <- "double"
  unique(dt$sp_id[rowSums(m, na.rm = TRUE) > 0])
}

gtdb_sal <- present_species(gtdb, gtdb_S)
gtdb_uri <- present_species(gtdb, gtdb_U)
hrom_sal <- present_species(hrom, hrom_S)
hrom_uri <- present_species(hrom, hrom_U)

## ---- per-site Venn figure + membership table + summary row ----
make_outputs <- function(gset, hset, site_label, file_tag) {
  shared    <- intersect(gset, hset)
  gtdb_only <- setdiff(gset, hset)
  hrom_only <- setdiff(hset, gset)

  memb <- rbind(
    data.table(species = sort(shared),    category = "shared"),
    data.table(species = sort(gtdb_only), category = "GTDB_only"),
    data.table(species = sort(hrom_only), category = "HROM_only")
  )
  fwrite(memb, file.path(results_dir, paste0("species_membership_", file_tag, ".csv")))

  venn_list <- setNames(list(gset, hset), c("GTDB", "HROM"))
  p <- ggvenn(venn_list,
              fill_color      = c("#3B9AB2", "#E1AF00"),
              fill_alpha      = 0.55,
              stroke_size     = 0.4,
              set_name_size   = 6,
              text_size       = 5,
              show_percentage = FALSE) +
    ggtitle(paste0(site_label, ": GTDB vs HROM species")) +
    theme(plot.title = element_text(hjust = 0.5, face = "bold"))
  ggsave(file.path(results_dir, paste0("venn_", file_tag, ".png")), p,
         width = 6, height = 5, dpi = 300)
  ggsave(file.path(results_dir, paste0("venn_", file_tag, ".pdf")), p,
         width = 6, height = 5)

  data.table(site       = site_label,
             GTDB_total = length(gset),
             HROM_total = length(hset),
             GTDB_only  = length(gtdb_only),
             HROM_only  = length(hrom_only),
             shared     = length(shared))
}

summary_tab <- rbind(
  make_outputs(gtdb_sal, hrom_sal, "Saliva (S)", "saliva"),
  make_outputs(gtdb_uri, hrom_uri, "Urine (U)",  "urine")
)
fwrite(summary_tab, file.path(results_dir, "venn_summary.csv"))

## ---- console report ----
cat("\n== Sample columns per site ==\n")
cat(sprintf("GTDB: %d saliva, %d urine   |   HROM: %d saliva, %d urine\n",
            length(gtdb_S), length(gtdb_U), length(hrom_S), length(hrom_U)))
cat("\n== Venn summary (species counts) ==\n")
print(summary_tab)
cat("\nOutputs written to: ", normalizePath(results_dir), "\n", sep = "")
