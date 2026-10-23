# Paired learning curve: accuracy of encoders + MLP, of AlphaEarth and
# TESSERA embeddings + MLP and of MLP and TempCNN on the raw time series,
# by fraction of the training samples.
# Each round reads its split of the labelled samples (round_RR_split.rds,
# written by make_splits.R); all methods of a round use the same split and
# the same nested fractions.
#
# Each (round, method, fraction) is one task with its own result file
# (round_RR_METHOD_fFFF.csv); a task whose file is done is skipped, and
# tasks run in parallel workers.
# Each task saves its model and metadata in models/ of its round
# (round_RR_METHOD_fFFF.rds and .json); a later task reads the model if the
# metadata show the same sits files, the same sitsfm commit and the md5 of
# the .rds, and trains it again otherwise.
#
# Layout of the results (experiment) folder:
#   inputs/                 labelled samples, encoded samples, 2018 points
#   round-RR/               round_RR_split.rds (from make_splits.R)
#   round-RR/split-70-30/   task files of the internal test
#   round-RR/val-2018/      task files and predictions on the 2018 points
#   round-RR/models/        models and their metadata
#
# Optional arguments: rounds, fractions, methods, samples file ("hf": the
# labelled samples on Hugging Face), workers, results folder, 2018
# validation points ("none", "all", or a number of them for a check), e.g.
#   Rscript analysis/sbsr2027/accuracy_learning_curve.R 1 0.05,1 btwins,ts_tempcnn hf 2
# The AlphaEarth (ae_*) and TESSERA (tessera_*) methods and the 6-band
# methods (ts_mlp6, ts_tempcnn6) are not in the default methods; name them.
# With 2018 validation points, each task also classifies them and writes
# their metrics and predicted classes in val-2018/ of its round.
library(sits)
library(glue)

args <- commandArgs(trailingOnly = TRUE)
n_runs <- 10
fractions <- c(0.05, 0.1, 0.15, 0.20, 0.25, 0.5, 0.75, 1.0)
methods <- c("btwins", "vicreg", "lejepa", "ts_mlp", "ts_tempcnn")
samples_file <- "hf"
n_workers <- 1
results_folder <- "data/results/sbsr2027/split-70-30"
val2018 <- "none"
if (length(args) >= 1) n_runs <- as.integer(args[[1]])
if (length(args) >= 2) fractions <- as.numeric(strsplit(args[[2]], ",")[[1]])
if (length(args) >= 3) methods <- strsplit(args[[3]], ",")[[1]]
if (length(args) >= 4) samples_file <- args[[4]]
if (length(args) >= 5) n_workers <- as.integer(args[[5]])
if (length(args) >= 6) results_folder <- args[[6]]
if (length(args) >= 7) val2018 <- args[[7]]
stopifnot(val2018 %in% c("none", "all") || grepl("^[0-9]+$", val2018))
# each fraction has its own random substream, numbered 100 * fraction
stopifnot(abs(fractions * 100 - round(fractions * 100)) < 1e-9)

# Random streams (base_stream, round_stream, fraction_stream): the training
# of fraction f in round r uses substream 100 * f of stream r; streams.R
# sits next to this script
script_file <- sub("^--file=", "", grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE))
source(fs::path(fs::path_dir(script_file), "streams.R"))

batch_size <- NULL
if (torch::cuda_is_available()) {
  batch_size <- 1000 * 1000
}
results_dir <- fs::dir_create(results_folder)
inputs_dir <- fs::dir_create(results_dir / "inputs")
round_dir <- function(ith_run) {
  results_dir / glue("round-{sprintf('%02d', ith_run)}")
}
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
  samples_file <- inputs_dir / "labelled_samples.rds"
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
# the encoders were pre-trained on the 6 reflectance bands only, so
# ts_mlp6 and ts_tempcnn6 train the raw time series methods on the same bands
bands6 <- c("BLUE", "GREEN", "RED", "NIR08", "SWIR16", "SWIR22")
bands6_methods <- c("ts_mlp6", "ts_tempcnn6")

#
# 2. Encode all samples once per encoder; the encoder is frozen,
#    so each round takes the rows it needs
#
# AlphaEarth methods: embeddings at the sample points, one file per image
# year, rows in the order of the labelled samples
ae_repo <- "e-sensing/samples_cerrado_aef"
ae_files <- list(
  ae_centre_y = "alphaearth_labelled_centre_y.parquet"
)
# the same reading at the 2018 validation points, rows in the parquet order
ae_val2018_files <- list(
  ae_centre_y = "alphaearth_validation2018_centre_y.parquet"
)
# TESSERA methods, in the same layout: the vector of the label year as
# read (tessera_y) and divided by its L2 norm (tessera_unit_y)
tessera_repo <- "e-sensing/samples_cerrado_tessera"
tessera_files <- list(
  tessera_y = "tessera_labelled_y.parquet",
  tessera_unit_y = "tessera_labelled_unit_y.parquet"
)
tessera_val2018_files <- list(
  tessera_y = "tessera_validation2018_y.parquet",
  tessera_unit_y = "tessera_validation2018_unit_y.parquet"
)
# methods read from Hugging Face: their files and repository
hf_files <- c(ae_files, tessera_files)
hf_val2018_files <- c(ae_val2018_files, tessera_val2018_files)
hf_repo <- c(
  rep(list(ae_repo), length(ae_files)), rep(list(tessera_repo), length(tessera_files))
)
names(hf_repo) <- names(hf_files)
embedding_samples <- function(method) {
  files <- hf_files[[method]]
  # the Y - 1 and Y methods will list two files and join their bands
  stopifnot(length(files) == 1)
  samples <- sits_from_hf(repo = hf_repo[[method]], file = files, type = "dataset")
  # same points in the same order, so the row number is the id
  stopifnot(
    nrow(samples) == nrow(labelled_samples),
    all(samples[["longitude"]] == labelled_samples[["longitude"]]),
    all(samples[["latitude"]] == labelled_samples[["latitude"]])
  )
  samples
}
encoder_file <- function(model) {
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
  model_file
}
encode_samples <- function(model) {
  enc_file <- inputs_dir / glue("encoded_{model}.rds")
  if (fs::file_exists(enc_file)) {
    return(invisible(enc_file))
  }
  if (model %in% names(hf_files)) {
    samples_enc <- embedding_samples(model)
  } else {
    samples_enc <- sits_encode(
      data = labelled_samples,
      encoder = readRDS(encoder_file(model)),
      multicores = 20,
      gpu_memory = 80,
      batch_size = batch_size
    )
  }
  # the rows must match the samples, or the ids point to other samples;
  # unname: the saved samples have empty names on the labels
  stopifnot(
    nrow(samples_enc) == nrow(labelled_samples),
    identical(unname(samples_enc[["label"]]), unname(labelled_samples[["label"]]))
  )
  samples_enc[["id"]] <- labelled_samples[["id"]]
  saveRDS(samples_enc, glue("{enc_file}.tmp"))
  fs::file_move(glue("{enc_file}.tmp"), enc_file)
  invisible(enc_file)
}
for (method in methods[!startsWith(methods, "ts_")]) {
  encode_samples(method)
}

#
# 2b. Optional: the 2018 validation points in the input of each method;
#     the raw time series methods share one file
#
val2018_file <- function(method) {
  if (startsWith(method, "ts_")) {
    return(inputs_dir / "val2018_series.rds")
  }
  inputs_dir / glue("val2018_encoded_{method}.rds")
}
val2018_task_file <- function(ith_run, method, frac) {
  round_dir(ith_run) / "val-2018" / fs::path_file(task_file(ith_run, method, frac))
}
encode_val2018 <- function(method) {
  file <- val2018_file(method)
  if (fs::file_exists(file)) {
    # a file left by a run on other points must not be used
    if (nrow(readRDS(file)) != nrow(val_series)) {
      stop(glue("{file} has other points than asked for; remove it"))
    }
    return(invisible(file))
  }
  started <- Sys.time()
  if (startsWith(method, "ts_")) {
    val_enc <- val_series
  } else if (method %in% names(hf_val2018_files)) {
    val_enc <- sits_from_hf(repo = hf_repo[[method]], file = hf_val2018_files[[method]], type = "dataset")
    val_enc <- val_enc[val_rows, ]
    # both files follow the parquet order; coordinates read by two routes
    stopifnot(
      max(abs(val_enc[["longitude"]] - val_series[["longitude"]])) < 1e-6,
      max(abs(val_enc[["latitude"]] - val_series[["latitude"]])) < 1e-6
    )
  } else {
    val_enc <- sits_encode(
      data = val_series,
      encoder = readRDS(encoder_file(method)),
      multicores = 20,
      gpu_memory = 80,
      batch_size = batch_size
    )
  }
  stopifnot(
    nrow(val_enc) == nrow(val_series),
    identical(unname(val_enc[["label"]]), unname(val_series[["label"]]))
  )
  saveRDS(val_enc, glue("{file}.tmp"))
  fs::file_move(glue("{file}.tmp"), file)
  message(glue(
    "2018 validation points, {method}: {nrow(val_enc)} rows in ",
    "{round(difftime(Sys.time(), started, units = 'mins'), 1)} min"
  ))
  invisible(file)
}
val_rows <- NULL
if (val2018 != "none") {
  # series of analysis/sbsr2027/validation_series_2018.R, rows in the parquet order
  val_series <- readRDS("data/results/sbsr2027/val-2018/inputs/validation_series_2018.rds")
  val_rows <- seq_len(nrow(val_series))
  if (val2018 != "all") {
    # evenly spaced rows: the file is sorted by class, so every class enters
    val_rows <- unique(round(seq(1, nrow(val_series), length.out = as.integer(val2018))))
  }
  val_series <- val_series[val_rows, ]
  for (method in methods) {
    encode_val2018(method)
  }
}

#
# 3. Split of each round, written by make_splits.R
#
split_file <- function(ith_run) {
  round_dir(ith_run) / glue("round_{sprintf('%02d', ith_run)}_split.rds")
}
for (ith_run in seq_len(n_runs)) {
  if (!fs::file_exists(split_file(ith_run))) {
    stop(glue("{split_file(ith_run)} is missing; write it with analysis/sbsr2027/make_splits.R"))
  }
}

#
# 4. Tasks: one per round, method and fraction
#
task_file <- function(ith_run, method, frac) {
  round_dir(ith_run) / "split-70-30" /
    glue("round_{sprintf('%02d', ith_run)}_{method}_f{sprintf('%03d', round(frac * 100))}.csv")
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
  file <- task_file(task$ith_run, task$method, task$frac)
  first_file <- fs::path(fs::path_dir(file), glue("round_{sprintf('%02d', task$ith_run)}_{task$method}.csv"))
  if (fs::file_exists(first_file) && !fs::file_exists(file)) {
    first <- read.csv(first_file)
    if (any(first[["fraction"]] == task$frac)) {
      write.csv(first[first[["fraction"]] == task$frac, ], file, row.names = FALSE)
    }
  }
}
# every task file of the run, for the progress line tether reads
progress_files <- purrr::map_chr(tasks, function(task) {
  as.character(task_file(task$ith_run, task$method, task$frac))
})
done <- purrr::map_lgl(tasks, function(task) {
  task_done(task_file(task$ith_run, task$method, task$frac), task$frac) &&
    (val2018 == "none" || task_done(val2018_task_file(task$ith_run, task$method, task$frac), task$frac))
})
for (task in tasks[done]) {
  message(glue("round {task$ith_run} {task$method} fraction {task$frac}: done, skipped"))
}
tasks <- tasks[!done]
# a split holds only the fractions make_splits.R was given
for (ith_run in unique(purrr::map_int(tasks, "ith_run"))) {
  run_fracs <- purrr::map_dbl(purrr::keep(tasks, function(task) task$ith_run == ith_run), "frac")
  missing <- setdiff(as.character(run_fracs), names(readRDS(split_file(ith_run))$train))
  if (length(missing) > 0) {
    stop(glue("{split_file(ith_run)} has no fraction {toString(missing)}; see make_splits.R"))
  }
}

#
# 5. Run one task: train, classify the validation samples, measure
#
# facts that decide the reuse of saved models, computed once here
sits_files <- c("R/sits.rdb", "libs/sits.so")
sits_md5 <- as.list(unname(tools::md5sum(file.path(system.file(package = "sits"), sits_files))))
names(sits_md5) <- sits_files
# commit of the sitsfm checkout that holds this script, read from .git
# without git; NA if not found
git_commit <- function() {
  script <- sub("^--file=", "", grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE))
  if (length(script) != 1) {
    return(NA_character_)
  }
  # the script is in analysis/sbsr2027/ of the checkout
  git_dir <- fs::path(fs::path_dir(fs::path_dir(fs::path_dir(fs::path_abs(script)))), ".git")
  if (!fs::file_exists(git_dir / "HEAD")) {
    return(NA_character_)
  }
  head <- readLines(git_dir / "HEAD", n = 1)
  # a detached HEAD holds the commit itself
  if (!startsWith(head, "ref: ")) {
    return(head)
  }
  ref <- sub("^ref: ", "", head)
  if (fs::file_exists(git_dir / ref)) {
    return(readLines(git_dir / ref, n = 1))
  }
  if (fs::file_exists(git_dir / "packed-refs")) {
    packed <- readLines(git_dir / "packed-refs")
    line <- packed[endsWith(packed, paste0(" ", ref))]
    if (length(line) == 1) {
      return(sub(" .*", "", line))
    }
  }
  NA_character_
}
sitsfm_commit <- git_commit()
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
  if (method %in% bands6_methods) {
    method_samples <- cached("samples6", function() sits_select(read_samples(), bands = bands6))
  } else if (startsWith(method, "ts_")) {
    method_samples <- cached("samples", read_samples)
  } else {
    method_samples <- cached(method, function() {
      enc_file <- inputs_dir / glue("encoded_{method}.rds")
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
  task_name <- fs::path_ext_remove(fs::path_file(task_file(ith_run, method, frac)))
  models_dir <- fs::dir_create(round_dir(ith_run) / "models")
  model_file <- models_dir / glue("{task_name}.rds")
  meta_file <- models_dir / glue("{task_name}.json")
  # a saved model is read only if made by these sits files and sitsfm commit
  reuse <- FALSE
  stale <- character(0)
  if (fs::file_exists(model_file) && fs::file_exists(meta_file)) {
    meta <- jsonlite::read_json(meta_file)
    differs <- c(
      "sits_md5 differs" = !identical(unlist(meta$sits_md5), unlist(sits_md5)),
      "sitsfm_commit differs or is unknown" =
        is.na(sitsfm_commit) || !identical(meta$sitsfm_commit, sitsfm_commit),
      "model_md5 differs" = !identical(meta$model_md5, unname(tools::md5sum(model_file)))
    )
    stale <- names(differs)[differs]
    reuse <- length(stale) == 0
  } else if (fs::file_exists(model_file) || fs::file_exists(meta_file)) {
    stale <- "its .rds or .json is missing"
  }
  if (length(stale) > 0) {
    message(glue(
      "round {ith_run} {method} fraction {frac}: saved model not used ",
      "({toString(stale)}), trained again"
    ))
  }
  start_time <- Sys.time()
  # seed = NULL: sits draws the torch seed from the R stream, which
  # also draws the early stopping split
  assign(".Random.seed", fraction_stream(round_stream(ith_run), frac), envir = globalenv())
  if (method %in% c("ts_tempcnn", "ts_tempcnn6")) {
    ml_method <- sits_tempcnn()
  } else {
    ml_method <- sits_mlp(
      min_delta = 0.005,
      epochs = 150,
      batch_size = 128
    )
  }
  # threads of this task: the CPU quota shared with the processes training
  # on the GPU now, other runs included
  threads <- task_threads()
  # sits_train() sets its threads only during the training (whole quota
  # by default); the classification runs on the CPU with the worker's
  set_threads(threads, quiet = TRUE)
  # reading a model draws nothing; each task sets its own seed above
  if (reuse) {
    ml_model <- readRDS(model_file)
    train_seconds <- meta$train_seconds
    message(glue("round {ith_run} {method} fraction {frac}: model read from {model_file}"))
  } else {
    ml_model <- sits_train(samples = samples_red, ml_method = ml_method, threads = threads)
    train_seconds <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
    saveRDS(ml_model, glue("{model_file}.tmp"))
    meta <- list(
      round = ith_run,
      method = method,
      fraction = frac,
      n_train = nrow(samples_red),
      train_seconds = train_seconds,
      trained_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      sitsfm_commit = sitsfm_commit,
      sits_version = as.character(utils::packageVersion("sits")),
      sits_md5 = sits_md5,
      torch_version = as.character(utils::packageVersion("torch")),
      r_version = as.character(getRversion()),
      model_md5 = unname(tools::md5sum(glue("{model_file}.tmp")))
    )
    jsonlite::write_json(
      meta, glue("{meta_file}.tmp"),
      auto_unbox = TRUE, pretty = TRUE, digits = NA, na = "null"
    )
    # an .rds renamed without its new .json fails the model_md5 check
    fs::file_move(glue("{model_file}.tmp"), model_file)
    fs::file_move(glue("{meta_file}.tmp"), meta_file)
  }
  if (torch::cuda_is_available()) {
    assign("on_gpu", TRUE, envir = worker_cache)
  }
  class_start <- Sys.time()
  class_pts <- sits_classify(
    data = validation_samples,
    ml_model = ml_model,
    multicores = 20,
    gpu_memory = 80,
    batch_size = batch_size,
    progress = FALSE
  )
  # seconds: training (from the metadata of a read model) and classification
  seconds <- train_seconds + as.numeric(difftime(Sys.time(), class_start, units = "secs"))
  #
  # Measure accuracy
  #
  acc <- sits_accuracy(class_pts)
  message(glue(
    "round {ith_run} {method} fraction {frac}: ",
    "accuracy {round(acc$overall[['Accuracy']], 4)}, {round(seconds)} s, ",
    "{threads} threads, worker {Sys.getpid()}"
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
  if (val2018 != "none") {
    val_start <- Sys.time()
    val_samples <- cached(as.character(val2018_file(method)), function() readRDS(val2018_file(method)))
    # the 6-band models classify the same series reduced to their bands
    if (method %in% bands6_methods) {
      val_samples <- sits_select(val_samples, bands = bands6)
    }
    class_val <- sits_classify(
      data = val_samples,
      ml_model = ml_model,
      multicores = 20,
      gpu_memory = 80,
      batch_size = batch_size,
      progress = FALSE
    )
    # seconds: training and classification, as for the internal test
    val_seconds <- train_seconds + as.numeric(difftime(Sys.time(), val_start, units = "secs"))
    # sits_accuracy() drops predictions of classes absent from the reference
    # (Mangrove, Nat_NonVeg, Water); here they count as errors
    pred <- purrr::map_chr(class_val[["predicted"]], function(p) p[["class"]])
    ref <- unname(class_val[["label"]])
    classes <- union(sort(unique(ref)), sort(unique(pred)))
    acc_val <- caret::confusionMatrix(factor(pred, levels = classes), factor(ref, levels = classes))
    # F1 only of the classes in the reference; the overall accuracy is not
    # weighted, and the class allocation of the points is not proportional to area
    f1_val <- acc_val$byClass[paste0("Class: ", sort(unique(ref))), "F1"]
    message(glue(
      "round {ith_run} {method} fraction {frac}: ",
      "2018 validation accuracy {round(acc_val$overall[['Accuracy']], 4)}"
    ))
    val_result <- data.frame(
      round = ith_run,
      method = method,
      fraction = frac,
      n_train = nrow(samples_red),
      n_valid = nrow(val_samples),
      metric = c("accuracy", "kappa", rep("f1", length(f1_val)), "seconds"),
      class = c(NA, NA, sort(unique(ref)), NA),
      value = c(acc_val$overall[["Accuracy"]], acc_val$overall[["Kappa"]], f1_val, val_seconds)
    )
    # predicted class of each point; row: its row in validation_data_2018.parquet
    val_file <- val2018_task_file(ith_run, method, frac)
    fs::dir_create(fs::path_dir(val_file))
    pred_file <- fs::path(fs::path_dir(val_file), glue("{task_name}_pred.csv"))
    pred_table <- data.frame(row = val_rows, label = ref, predicted = pred)
    write.csv(pred_table, glue("{pred_file}.tmp"), row.names = FALSE)
    fs::file_move(glue("{pred_file}.tmp"), pred_file)
    write.csv(val_result, glue("{val_file}.tmp"), row.names = FALSE)
    fs::file_move(glue("{val_file}.tmp"), val_file)
  }
  file <- task_file(ith_run, method, frac)
  fs::dir_create(fs::path_dir(file))
  write.csv(result, glue("{file}.tmp"), row.names = FALSE)
  fs::file_move(glue("{file}.tmp"), file)
  message(glue("tether-progress: {sum(fs::file_exists(progress_files))}/{length(progress_files)}"))
  invisible(file)
}

#
# 6. Run the tasks, in parallel when there is more than one worker
#
# torch opens one thread per visible core (248 on the server), more than
# the CPU quota of the container (112). The sum of the torch threads of all
# processes training on the GPU must stay within the quota, other runs
# included: before each task, the quota is divided by those processes.
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
cpu_quota <- cpu_cores()
# processes with a CUDA context; 0 without nvidia-smi or GPU
gpu_processes <- function() {
  pids <- tryCatch(
    suppressWarnings(system2(
      "nvidia-smi", c("--query-compute-apps=pid", "--format=csv,noheader"),
      stdout = TRUE, stderr = FALSE
    )),
    error = function(e) character(0)
  )
  if (!is.null(attr(pids, "status"))) {
    return(0)
  }
  sum(nzchar(trimws(pids)))
}
task_threads <- function() {
  n_gpu <- gpu_processes()
  if (n_gpu == 0) {
    return(max(1, cpu_quota %/% n_workers))
  }
  # this worker counts once, before and after its first CUDA context
  own <- if (exists("on_gpu", envir = worker_cache)) 0 else 1
  max(1, cpu_quota %/% (n_gpu + own))
}
set_threads <- function(n_threads, quiet = FALSE) {
  if (quiet && torch::torch_get_num_threads() == n_threads) {
    return(invisible(n_threads))
  }
  torch::torch_set_num_threads(n_threads)
  message(glue("worker {Sys.getpid()}: torch threads {torch::torch_get_num_threads()}"))
}
n_threads <- max(1, cpu_quota %/% n_workers)
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
    "results_dir", "inputs_dir", "round_dir", "stop_file", "samples_file", "read_samples",
    "base_stream", "round_stream", "fraction_stream", "split_file", "task_file",
    "worker_cache", "cached", "run_task", "cpu_quota", "n_workers",
    "gpu_processes", "task_threads", "set_threads", "val2018", "val2018_file",
    "val2018_task_file", "val_rows", "sits_md5", "sitsfm_commit", "progress_files",
    "bands6", "bands6_methods"
  ))
  invisible(parallel::parLapplyLB(cl, tasks, run_task))
  parallel::stopCluster(cl)
}
