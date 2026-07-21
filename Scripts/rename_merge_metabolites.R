# =============================================================================
# rename_merge_metabolites.R
# Replace metabolite-ID column names in the metabolome CSVs with their
# "Metabolite name" (Sheet3 col4 of the matching PKU xlsx, keyed by Alignment ID
# = Sheet3 col1), then merge (sum) columns that share the same Metabolite name.
# Writes Data/metabolome_data/<file>_named.csv (originals are left untouched).
# =============================================================================
suppressMessages({library(readxl); library(data.table)})

DIR_XLSX <- "Data/PKU-101-微生物-代谢物数据"
DIR_CSV  <- "Data/metabolome_data"
FILES <- c(pos_saliva = "pos_saliva", neg_saliva = "neg_saliva",
           pos_urin   = "pos_urin",   neg_urin   = "neg_urin")

for (nm in names(FILES)) {
  xlsx <- file.path(DIR_XLSX, paste0(FILES[nm], ".xlsx"))
  csv  <- file.path(DIR_CSV,  paste0(nm, "_renamed.csv"))
  out  <- file.path(DIR_CSV,  paste0(nm, "_named.csv"))

  # id -> Metabolite name map (Sheet3: col1 = Alignment ID, col4 = Metabolite name)
  s3 <- suppressMessages(read_excel(xlsx, sheet = "Sheet3"))
  id2name <- setNames(trimws(as.character(s3[[4]])), as.character(s3[[1]]))

  d <- fread(csv, header = TRUE, check.names = FALSE)
  meta_cols <- names(d)[1:2]                       # SampleID, label
  idcols    <- names(d)[-(1:2)]

  miss <- setdiff(idcols, names(id2name))
  # mapped name; if an id is unmapped or its name is blank, keep the original id
  newname <- id2name[idcols]
  newname[is.na(newname) | newname == ""] <- idcols[is.na(newname) | newname == ""]

  # sum columns sharing the same metabolite name
  M <- as.matrix(d[, ..idcols]); storage.mode(M) <- "double"
  uniq <- unique(newname)
  Mg <- vapply(uniq, function(u) rowSums(M[, newname == u, drop = FALSE]),
               numeric(nrow(M)))
  if (is.null(dim(Mg))) Mg <- matrix(Mg, nrow = nrow(M),
                                     dimnames = list(NULL, uniq))
  colnames(Mg) <- uniq

  res <- cbind(d[, ..meta_cols], as.data.table(Mg))
  fwrite(res, out)
  cat(sprintf("%-11s ids %4d -> metabolites %4d (merged %4d redundant) | unmapped %d\n",
              nm, length(idcols), length(uniq), length(idcols) - length(uniq),
              length(miss)))
}
cat("done -> Data/metabolome_data/*_named.csv\n")
