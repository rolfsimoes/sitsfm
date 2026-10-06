# Paired learning curve: accuracy of encoders + MLP and of MLP and TempCNN
# on the raw time series, by fraction of the training samples.
# Each round draws a new split of the labelled samples (70% train, 30%
# validation); all methods of a round use the same split and the same
# nested fractions.
#
# Optional arguments: rounds, fractions, methods, samples file, e.g.
#   Rscript analysis/accuracy_learning_curve.R 1 0.05,1 btwins,ts_mlp
library(sits)
library(glue)

args <- commandArgs(trailingOnly = TRUE)
n_runs <- 10
fractions <- c(0.05, 0.1, 0.15, 0.20, 0.25, 0.5, 0.75, 1.0)
methods <- c("btwins", "vicreg", "lejepa", "ts_mlp", "ts_tempcnn")
samples_file <- NULL
if (length(args) >= 1) n_runs <- as.integer(args[[1]])
if (length(args) >= 2) fractions <- as.numeric(strsplit(args[[2]], ",")[[1]])
if (length(args) >= 3) methods <- strsplit(args[[3]], ",")[[1]]
if (length(args) >= 4) samples_file <- args[[4]]
# each fraction has its own random substream, numbered 100 * fraction
stopifnot(abs(fractions * 100 - round(fractions * 100)) < 1e-9)

#
# Random streams: L'Ecuyer-CMRG gives streams that do not overlap.
# Round r uses stream r for its split; the training of fraction f uses
# substream 100 * f of stream r, the same for all methods. A training
# depends only on its round and fraction, not on what ran before.
#
RNGkind("L'Ecuyer-CMRG")
set.seed(1524)
base_stream <- .Random.seed
round_stream <- function(ith_run) {
  stream <- base_stream
  for (i in seq_len(ith_run)) stream <- parallel::nextRNGStream(stream)
  stream
}
fraction_stream <- function(stream, frac) {
  for (i in seq_len(round(frac * 100))) stream <- parallel::nextRNGSubStream(stream)
  stream
}

batch_size <- NULL
if (torch::cuda_is_available()) {
  batch_size <- 1000 * 1000
}
results_dir <- fs::dir_create("data/results/learning_curve")

#
# 1. Load the samples
#
if (is.null(samples_file)) {
  labelled_samples <- sits_from_hf(
    repo = "e-sensing/samples_cerrado",
    file = "labelled_samples_cerrado.parquet",
    type = "dataset"
  )
} else {
  labelled_samples <- readRDS(samples_file)
}
# Add identifier in each sample
labelled_samples[["id"]] <- seq_len(nrow(labelled_samples))

#
# 2. Encode all samples once per encoder; the encoder is frozen,
#    so each round takes the rows it needs
#
# encoded samples kept in memory, read from disk once per run
encoded_cache <- list()
encode_samples <- function(model) {
  if (!is.null(encoded_cache[[model]])) {
    return(encoded_cache[[model]])
  }
  enc_file <- results_dir / glue("encoded_{model}.rds")
  if (fs::file_exists(enc_file)) {
    message(glue("encoded {model}: read from {enc_file}"))
    encoded_cache[[model]] <<- readRDS(enc_file)
    return(encoded_cache[[model]])
  }
  model_file <- glue("data/embeddings/embeddings/{model}/encoder/{model}.rds")
  if (!fs::file_exists(model_file)) {
    fs::dir_create(fs::path_dir(model_file))
    encoder <- sits_from_hf(
      repo = "e-sensing/encoders_cerrado",
      file = glue("ssl_{model}_tcnn_model_2017_2024.rds"),
      type = "model"
    )
    saveRDS(encoder, model_file)
  }
  samples_enc <- sits_encode(
    data = labelled_samples,
    encoder = readRDS(model_file),
    multicores = 20,
    gpu_memory = 80,
    batch_size = batch_size
  )
  # the rows must match the samples, or the ids point to other samples
  stopifnot(
    nrow(samples_enc) == nrow(labelled_samples),
    identical(samples_enc[["label"]], labelled_samples[["label"]])
  )
  samples_enc[["id"]] <- labelled_samples[["id"]]
  saveRDS(samples_enc, glue("{enc_file}.tmp"))
  fs::file_move(glue("{enc_file}.tmp"), enc_file)
  encoded_cache[[model]] <<- samples_enc
  samples_enc
}

#
# 3. Loop in rounds
#
for (ith_run in seq_len(n_runs)) {
  run_stream <- round_stream(ith_run)
  assign(".Random.seed", run_stream, envir = globalenv())
  #
  # Split train and validation samples
  #
  # oversample = FALSE: the default TRUE draws with replacement
  train_samples <- sits_sample(labelled_samples, frac = 0.7, oversample = FALSE)
  validation_ids <- setdiff(labelled_samples[["id"]], train_samples[["id"]])
  #
  # Nested fractions: shuffle each class once; fraction f takes the first
  # floor(f n) samples of each class, whatever the other fractions are
  #
  train_order <- sits_sample(train_samples, frac = 1.0, oversample = FALSE)
  train_ids <- purrr::map(fractions, function(frac) {
    dplyr::slice_head(dplyr::group_by(train_order, .data[["label"]]), prop = frac)[["id"]]
  })
  names(train_ids) <- as.character(fractions)
  saveRDS(
    list(valid = validation_ids, train = train_ids),
    results_dir / glue("round_{sprintf('%02d', ith_run)}_split.rds")
  )
  #
  # Loop in methods
  #
  for (method in methods) {
    acc_file <- results_dir / glue("round_{sprintf('%02d', ith_run)}_{method}.csv")
    if (fs::file_exists(acc_file) &&
        all(fractions %in% read.csv(acc_file)[["fraction"]])) {
      message(glue("round {ith_run} {method}: done, skipped"))
      next
    }
    if (startsWith(method, "ts_")) {
      method_samples <- labelled_samples
    } else {
      method_samples <- encode_samples(method)
    }
    validation_samples <- dplyr::filter(
      method_samples, .data[["id"]] %in% validation_ids
    )
    #
    # Loop in fractions
    #
    results <- purrr::map(fractions, function(frac) {
      samples_red <- dplyr::filter(
        method_samples, .data[["id"]] %in% train_ids[[as.character(frac)]]
      )
      start_time <- Sys.time()
      # seed = NULL: sits draws the torch seed from the R stream, which
      # also draws the early stopping split
      assign(".Random.seed", fraction_stream(run_stream, frac), envir = globalenv())
      if (method == "ts_tempcnn") {
        ml_method <- sits_tempcnn()
      } else {
        ml_method <- sits_mlp(
          min_delta = 0.005,
          epochs = 150,
          batch_size = 128
        )
      }
      ml_model <- sits_train(samples = samples_red, ml_method = ml_method)
      class_pts <- sits_classify(
        data = validation_samples,
        ml_model = ml_model,
        multicores = 20,
        gpu_memory = 80,
        batch_size = batch_size,
        progress = FALSE
      )
      seconds <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
      #
      # Measure accuracy
      #
      acc <- sits_accuracy(class_pts)
      message(glue(
        "round {ith_run} {method} fraction {frac}: ",
        "accuracy {round(acc$overall[['Accuracy']], 4)}, {round(seconds)} s"
      ))
      data.frame(
        round = ith_run,
        method = method,
        fraction = frac,
        n_train = nrow(samples_red),
        n_valid = nrow(validation_samples),
        metric = c("accuracy", "kappa", rep("f1", nrow(acc$table)), "seconds"),
        class = c(NA, NA, sub("^Class: ", "", rownames(acc$byClass)), NA),
        value = c(
          acc$overall[["Accuracy"]], acc$overall[["Kappa"]],
          acc$byClass[, "F1"], seconds
        )
      )
    })
    #
    # Save the accuracy table of the round
    #
    write.csv(dplyr::bind_rows(results), glue("{acc_file}.tmp"), row.names = FALSE)
    fs::file_move(glue("{acc_file}.tmp"), acc_file)
  }
}
