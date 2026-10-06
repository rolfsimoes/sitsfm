# Paired learning curve: accuracy of encoders + MLP and of MLP and TempCNN
# on the raw time series, by fraction of the training samples.
# Each round draws a new split of the labelled samples (70% train, 30%
# validation); all methods of a round use the same split and the same
# nested fractions.
#
# Each (round, method, fraction) is one task with its own result file
# (round_RR_METHOD_fFFF.csv); a task whose file is done is skipped, and
# tasks run in parallel workers.
#
# Optional arguments: rounds, fractions, methods, samples file ("hf": the
# labelled samples on Hugging Face), workers, e.g.
#   Rscript analysis/accuracy_learning_curve.R 1 0.05,1 btwins,ts_tempcnn hf 2
library(sits)
library(glue)

args <- commandArgs(trailingOnly = TRUE)
n_runs <- 10
fractions <- c(0.05, 0.1, 0.15, 0.20, 0.25, 0.5, 0.75, 1.0)
methods <- c("btwins", "vicreg", "lejepa", "ts_mlp", "ts_tempcnn")
samples_file <- "hf"
n_workers <- 1
if (length(args) >= 1) n_runs <- as.integer(args[[1]])
if (length(args) >= 2) fractions <- as.numeric(strsplit(args[[2]], ",")[[1]])
if (length(args) >= 3) methods <- strsplit(args[[3]], ",")[[1]]
if (length(args) >= 4) samples_file <- args[[4]]
if (length(args) >= 5) n_workers <- as.integer(args[[5]])
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
# a STOP file in results_dir makes the workers skip the tasks not started;
# the tasks in progress end and write their files
stop_file <- results_dir / "STOP"
if (fs::file_exists(stop_file)) {
  stop(glue("{stop_file} exists; remove it to run"))
}

#
# 1. Load the samples
#
# workers read the samples from disk, so the download is saved once
if (samples_file == "hf") {
  samples_file <- results_dir / "labelled_samples.rds"
  if (!fs::file_exists(samples_file)) {
    hf_samples <- sits_from_hf(
      repo = "e-sensing/samples_cerrado",
      file = "labelled_samples_cerrado.parquet",
      type = "dataset"
    )
    saveRDS(hf_samples, glue("{samples_file}.tmp"))
    fs::file_move(glue("{samples_file}.tmp"), samples_file)
  }
}
read_samples <- function() {
  samples <- readRDS(samples_file)
  # Add identifier in each sample
  samples[["id"]] <- seq_len(nrow(samples))
  samples
}
labelled_samples <- read_samples()

#
# 2. Encode all samples once per encoder; the encoder is frozen,
#    so each round takes the rows it needs
#
encode_samples <- function(model) {
  enc_file <- results_dir / glue("encoded_{model}.rds")
  if (fs::file_exists(enc_file)) {
    return(invisible(enc_file))
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
  invisible(enc_file)
}
for (method in setdiff(methods, c("ts_mlp", "ts_tempcnn"))) {
  encode_samples(method)
}

#
# 3. Split of each round, drawn from the stream of the round
#
split_file <- function(ith_run) {
  results_dir / glue("round_{sprintf('%02d', ith_run)}_split.rds")
}
for (ith_run in seq_len(n_runs)) {
  assign(".Random.seed", round_stream(ith_run), envir = globalenv())
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
  saveRDS(list(valid = validation_ids, train = train_ids), glue("{split_file(ith_run)}.tmp"))
  fs::file_move(glue("{split_file(ith_run)}.tmp"), split_file(ith_run))
}

#
# 4. Tasks: one per round, method and fraction
#
task_file <- function(ith_run, method, frac) {
  results_dir / glue("round_{sprintf('%02d', ith_run)}_{method}_f{sprintf('%03d', round(frac * 100))}.csv")
}
# a truncated file is not done: the task runs again
task_done <- function(file, frac) {
  if (!fs::file_exists(file)) {
    return(FALSE)
  }
  result <- tryCatch(read.csv(file), error = function(e) NULL)
  !is.null(result) &&
    any(result[["metric"]] == "accuracy" & result[["fraction"]] == frac)
}
tasks <- expand.grid(
  frac = fractions, method = methods, ith_run = seq_len(n_runs),
  stringsAsFactors = FALSE
)
tasks <- purrr::pmap(tasks, list)
# tables of the first layout (one per round and method) are split into
# one table per fraction, so their tasks are not computed again
for (task in tasks) {
  first_file <- results_dir / glue("round_{sprintf('%02d', task$ith_run)}_{task$method}.csv")
  file <- task_file(task$ith_run, task$method, task$frac)
  if (fs::file_exists(first_file) && !fs::file_exists(file)) {
    first <- read.csv(first_file)
    if (any(first[["fraction"]] == task$frac)) {
      write.csv(first[first[["fraction"]] == task$frac, ], file, row.names = FALSE)
    }
  }
}
done <- purrr::map_lgl(tasks, function(task) {
  task_done(task_file(task$ith_run, task$method, task$frac), task$frac)
})
for (task in tasks[done]) {
  message(glue("round {task$ith_run} {task$method} fraction {task$frac}: done, skipped"))
}
tasks <- tasks[!done]
# longest tasks first (TempCNN, then the larger fractions), so no worker
# is left with a long task at the end
method_cost <- c(ts_tempcnn = 3, ts_mlp = 2)
task_cost <- purrr::map_dbl(tasks, function(task) {
  cost <- method_cost[task$method]
  (if (is.na(cost)) 1 else cost) * 10 + task$frac
})
tasks <- tasks[order(task_cost, decreasing = TRUE)]

#
# 5. Run one task: train, classify the validation samples, measure
#
# data read from disk once per worker
worker_cache <- new.env()
cached <- function(key, read) {
  if (!exists(key, envir = worker_cache)) {
    assign(key, read(), envir = worker_cache)
  }
  get(key, envir = worker_cache)
}
run_task <- function(task) {
  ith_run <- task$ith_run
  method <- task$method
  frac <- task$frac
  if (fs::file_exists(stop_file)) {
    message(glue("round {ith_run} {method} fraction {frac}: stop file, skipped"))
    return(invisible(NULL))
  }
  if (startsWith(method, "ts_")) {
    method_samples <- cached("samples", read_samples)
  } else {
    method_samples <- cached(method, function() {
      enc_file <- results_dir / glue("encoded_{method}.rds")
      message(glue("encoded {method}: read from {enc_file}"))
      readRDS(enc_file)
    })
  }
  split <- cached(glue("split_{ith_run}"), function() readRDS(split_file(ith_run)))
  validation_samples <- dplyr::filter(method_samples, .data[["id"]] %in% split$valid)
  samples_red <- dplyr::filter(
    method_samples, .data[["id"]] %in% split$train[[as.character(frac)]]
  )
  batch_size <- NULL
  if (torch::cuda_is_available()) {
    batch_size <- 1000 * 1000
  }
  start_time <- Sys.time()
  # seed = NULL: sits draws the torch seed from the R stream, which
  # also draws the early stopping split
  assign(".Random.seed", fraction_stream(round_stream(ith_run), frac), envir = globalenv())
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
  result <- data.frame(
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
  file <- task_file(ith_run, method, frac)
  write.csv(result, glue("{file}.tmp"), row.names = FALSE)
  fs::file_move(glue("{file}.tmp"), file)
  invisible(file)
}

#
# 6. Run the tasks, in parallel when there is more than one worker
#
# torch opens one thread per visible core (248 on the server), more than
# the CPU quota of the container (112); each worker gets quota / workers
cpu_cores <- function() {
  cpu_max <- "/sys/fs/cgroup/cpu.max"
  if (file.exists(cpu_max)) {
    quota <- strsplit(readLines(cpu_max, n = 1), " ")[[1]]
    if (quota[[1]] != "max") {
      return(as.numeric(quota[[1]]) %/% as.numeric(quota[[2]]))
    }
  }
  parallel::detectCores()
}
set_threads <- function(n_threads) {
  torch::torch_set_num_threads(n_threads)
  message(glue("worker {Sys.getpid()}: torch threads {torch::torch_get_num_threads()}"))
}
n_threads <- max(1, cpu_cores() %/% n_workers)
if (n_workers <= 1) {
  set_threads(n_threads)
  invisible(lapply(tasks, run_task))
} else if (length(tasks) > 0) {
  # outfile = "": the messages of the workers go to this log
  cl <- parallel::makePSOCKcluster(min(n_workers, length(tasks)), outfile = "")
  # fs gives the `/` of the paths; sits does not load it
  parallel::clusterEvalQ(cl, {
    library(sits)
    library(glue)
    loadNamespace("fs")
  })
  parallel::clusterCall(cl, set_threads, n_threads)
  parallel::clusterExport(cl, c(
    "results_dir", "stop_file", "samples_file", "read_samples", "base_stream",
    "round_stream", "fraction_stream", "split_file", "task_file",
    "worker_cache", "cached", "run_task"
  ))
  # chunk.size = 1: one task at a time per worker; the default sends
  # blocks of about 20 tasks and leaves some workers idle at the end
  invisible(parallel::parLapplyLB(cl, tasks, run_task, chunk.size = 1))
  parallel::stopCluster(cl)
}
