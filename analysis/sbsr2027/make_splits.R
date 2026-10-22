# Train/test splits of a learning-curve experiment, one file per round
# (round-RR/round_RR_split.rds), read by accuracy_learning_curve.R.
# The split of round r is drawn from stream r of streams.R, so the same
# arguments always give the same splits. An existing split file is never
# overwritten: recorded tasks used it.
#
# Geometries of the test side (the rest is the training side):
#   random    30% of the samples of each class (sits_sample keeps
#             floor(0.7 n) of each class for training); the recorded splits
#   location  30% of the locations (unique longitude and latitude, 7
#             decimals), stratified by the label of the earliest sample of
#             each location; all samples of a location are on one side
#   block     square blocks of a given size in degrees, in random order,
#             until the test side holds at least 30% of the samples
#   year      round r tests the r-th label year, and trains on the others.
#             The same locations recur in the other years, so this
#             measures transfer in time, not spatial independence.
# The training fractions are nested and drawn from the training side by
# the rule of streams.R (nested_fractions).
#
# The split file is list(valid = ids, train = list of ids named by
# fraction, geometry, params); accuracy_learning_curve.R reads only valid
# and train. Ids are row numbers of inputs/labelled_samples.rds.
# <experiment>/inputs/ gets relative links to every file of
# split-70-30/inputs/, so the experiment script runs there unchanged.
#
# Optional arguments: geometry (random, location, block, year), experiment
# folder (default data/results/sbsr2027/split-GEOMETRY, but split-70-30 for
# random), rounds (default 10; for year, at most the number of years),
# fractions, block size in degrees (default 1), e.g.
#   Rscript analysis/sbsr2027/make_splits.R
#   Rscript analysis/sbsr2027/make_splits.R block data/results/sbsr2027/split-block 10
library(sits)
library(glue)

# streams.R sits next to this script
script_file <- sub("^--file=", "", grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE))
source(fs::path(fs::path_dir(script_file), "streams.R"))

args <- commandArgs(trailingOnly = TRUE)
geometry <- "random"
if (length(args) >= 1) geometry <- args[[1]]
stopifnot(geometry %in% c("random", "location", "block", "year"))
results_folder <- glue("data/results/sbsr2027/split-{geometry}")
if (geometry == "random") results_folder <- "data/results/sbsr2027/split-70-30"
n_runs <- NA
fractions <- c(0.05, 0.1, 0.15, 0.20, 0.25, 0.5, 0.75, 1.0)
block_size <- 1
if (length(args) >= 2) results_folder <- args[[2]]
if (length(args) >= 3) n_runs <- as.integer(args[[3]])
if (length(args) >= 4) fractions <- as.numeric(strsplit(args[[4]], ",")[[1]])
if (length(args) >= 5) block_size <- as.numeric(args[[5]])
# the experiment script numbers the substream of a fraction 100 * fraction
stopifnot(abs(fractions * 100 - round(fractions * 100)) < 1e-9, fractions > 0, fractions <= 1)
stopifnot(block_size > 0)

#
# 1. Labelled samples and the inputs of the experiment
#
source_inputs <- fs::path("data/results/sbsr2027/split-70-30/inputs")
samples_file <- source_inputs / "labelled_samples.rds"
if (!fs::file_exists(samples_file)) {
  stop(glue("{samples_file} is missing; accuracy_learning_curve.R downloads it"))
}
labelled_samples <- readRDS(samples_file)
# the id of accuracy_learning_curve.R: the row number
labelled_samples[["id"]] <- seq_len(nrow(labelled_samples))
n_samples <- nrow(labelled_samples)

results_dir <- fs::dir_create(results_folder)
inputs_dir <- fs::dir_create(results_dir / "inputs")
# relative links, so the tree can move; the source folder links nothing
if (fs::path_real(inputs_dir) != fs::path_real(source_inputs)) {
  for (file in fs::dir_ls(source_inputs, regexp = "[.]tmp$", invert = TRUE)) {
    link <- inputs_dir / fs::path_file(file)
    if (fs::file_exists(link) || fs::link_exists(link)) {
      next
    }
    fs::link_create(fs::path_rel(fs::path_abs(file), fs::path_abs(inputs_dir)), link)
  }
}

years <- sort(unique(format(labelled_samples[["end_date"]], "%Y")))
if (geometry == "year") {
  if (is.na(n_runs)) n_runs <- min(10, length(years))
  if (n_runs > length(years)) {
    stop(glue("geometry year has {length(years)} rounds, one per label year ({toString(years)})"))
  }
}
if (is.na(n_runs)) n_runs <- 10
location <- paste(
  round(labelled_samples[["longitude"]], 7), round(labelled_samples[["latitude"]], 7)
)
block <- paste(
  floor(labelled_samples[["longitude"]] / block_size), floor(labelled_samples[["latitude"]] / block_size)
)
# one row per location: its earliest sample (order() keeps ties in row order)
first_samples <- labelled_samples[order(labelled_samples[["end_date"]]), ]
first_samples <- first_samples[!duplicated(location[first_samples[["id"]]]), ]

#
# 2. Split of each round, drawn from the stream of the round
#
round_dir <- function(ith_run) {
  results_dir / glue("round-{sprintf('%02d', ith_run)}")
}
split_file <- function(ith_run) {
  round_dir(ith_run) / glue("round_{sprintf('%02d', ith_run)}_split.rds")
}
for (ith_run in seq_len(n_runs)) {
  if (fs::file_exists(split_file(ith_run))) {
    message(glue("round {ith_run}: {split_file(ith_run)} exists, skipped"))
    next
  }
  assign(".Random.seed", round_stream(ith_run), envir = globalenv())
  test_year <- NA_character_
  n_blocks <- NA
  if (geometry == "random") {
    # oversample = FALSE: the default TRUE draws with replacement
    train_samples <- sits_sample(labelled_samples, frac = 0.7, oversample = FALSE)
    validation_ids <- setdiff(labelled_samples[["id"]], train_samples[["id"]])
  } else {
    if (geometry == "location") {
      test_first <- sits_sample(first_samples, frac = 0.3, oversample = FALSE)
      in_test <- location %in% location[test_first[["id"]]]
    } else if (geometry == "block") {
      blocks <- sample(unique(block))
      n_cum <- cumsum(as.vector(table(block)[blocks]))
      test_blocks <- blocks[seq_len(which(n_cum >= 0.3 * n_samples)[[1]])]
      in_test <- block %in% test_blocks
      n_blocks <- c(test = length(test_blocks), train = length(blocks) - length(test_blocks))
    } else {
      test_year <- years[[ith_run]]
      in_test <- format(labelled_samples[["end_date"]], "%Y") == test_year
    }
    validation_ids <- labelled_samples[["id"]][in_test]
    train_samples <- labelled_samples[!in_test, ]
  }
  train_ids <- nested_fractions(train_samples, fractions)
  n_test_class <- table(unname(labelled_samples[["label"]][validation_ids]))
  params <- list(
    block_size = if (geometry == "block") block_size else NA,
    test_year = test_year,
    n_blocks = n_blocks,
    n_test_class = setNames(as.vector(n_test_class), names(n_test_class)),
    n_valid = length(validation_ids),
    n_train = lengths(train_ids)
  )
  fs::dir_create(round_dir(ith_run))
  split <- list(valid = validation_ids, train = train_ids, geometry = geometry, params = params)
  saveRDS(split, glue("{split_file(ith_run)}.tmp"))
  fs::file_move(glue("{split_file(ith_run)}.tmp"), split_file(ith_run))
  message(glue(
    "round {ith_run} {geometry}: valid {params$n_valid} ",
    "({round(100 * params$n_valid / n_samples, 1)}%), ",
    "train {paste(params$n_train, collapse = ' ')} at fractions {paste(fractions, collapse = ' ')}",
    "{if (geometry == 'year') paste0(', test year ', test_year) else ''}",
    "{if (geometry == 'block') paste0(', blocks test ', n_blocks[['test']], ' train ', n_blocks[['train']]) else ''}"
  ))
}
