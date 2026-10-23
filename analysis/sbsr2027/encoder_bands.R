# Bands of the regional encoders (btwins, vicreg, lejepa): one line per
# encoder. Exits 1 if an encoder is not cached or its bands are not the
# 6 reflectance bands of ts_mlp6 and ts_tempcnn6.
# Reads only the cached encoders that accuracy_learning_curve.R reads
# (data/embeddings/embeddings/MODEL/encoder/MODEL.rds); it downloads nothing.
#   Rscript analysis/sbsr2027/encoder_bands.R
suppressPackageStartupMessages(library(sits))
library(glue)

# bands6 is defined once, in the curve script; read that line, not a copy
script_file <- sub("^--file=", "", grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE))
curve_lines <- readLines(fs::path(fs::path_dir(script_file), "accuracy_learning_curve.R"))
eval(parse(text = grep("^bands6 <- ", curve_lines, value = TRUE)))
stopifnot(length(bands6) == 6)

failed <- FALSE
for (model in c("btwins", "vicreg", "lejepa")) {
  model_file <- glue("data/embeddings/embeddings/{model}/encoder/{model}.rds")
  if (!fs::file_exists(model_file)) {
    cat(glue("{model}: not cached at {model_file}"), "\n", sep = "")
    failed <- TRUE
    next
  }
  # the bands of the samples the encoder was trained on; sits_encode() selects them
  bands <- sits:::.ml_bands(readRDS(model_file))
  ok <- length(bands) == 6 && setequal(bands, bands6)
  failed <- failed || !ok
  cat(glue("{model}: {toString(bands)}{if (ok) '' else ' (not the 6 bands)'}"), "\n", sep = "")
}
if (failed) {
  quit(status = 1)
}
