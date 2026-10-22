# Server check of accuracy_learning_curve.R: reruns recorded tasks (by
# default 16: rounds 1 and 2, fractions 5% and 10%, the three encoders and
# the MLP on the raw time series, 8 workers) in a separate folder and
# compares each result with the recorded one.
#
# The check folder links (does not copy) the labelled samples, the splits
# and the encoded samples of the recorded run, so the rerun uses the same
# inputs; nothing is written in the recorded folder. The check folder has
# the layout of an experiment folder (see accuracy_learning_curve.R): links
# in inputs/ and round-RR/, the log in logs/, comparison.csv in round-RR/.
#
# Run from the repository root. Optional arguments are the number of
# rounds, the fractions, the methods, the check folder and the 2018
# validation points ("none", "all" or a number of them), which each
# rerun task also classifies (see accuracy_learning_curve.R):
#   Rscript analysis/sbsr2027/check_learning_curve.R
#   Rscript analysis/sbsr2027/check_learning_curve.R 1 0.05,0.1 ts_tempcnn \
#     data/results/sbsr2027/split-70-30/checks/tempcnn
#   Rscript analysis/sbsr2027/check_learning_curve.R 1 0.05 btwins,ae_centre_y,ts_mlp \
#     data/results/sbsr2027/val-2018/checks/check-400 400
library(glue)

recorded_dir <- fs::path("data/results/sbsr2027/split-70-30")
check_dir <- fs::path("data/results/sbsr2027/split-70-30/checks/rerun")
stopifnot(fs::file_exists("analysis/sbsr2027/accuracy_learning_curve.R"))
n_rounds <- 2
fractions <- c(0.05, 0.1)
methods <- c("btwins", "vicreg", "lejepa", "ts_mlp")
n_workers <- 8
val2018 <- "none"
args <- commandArgs(trailingOnly = TRUE)
if (length(args) >= 1) n_rounds <- as.integer(args[[1]])
if (length(args) >= 2) fractions <- as.numeric(strsplit(args[[2]], ",")[[1]])
if (length(args) >= 3) methods <- strsplit(args[[3]], ",")[[1]]
if (length(args) >= 4) check_dir <- fs::path(args[[4]])
if (length(args) >= 5) val2018 <- args[[5]]

task_name <- function(ith_run, method, frac) {
  glue("round_{sprintf('%02d', ith_run)}_{method}_f{sprintf('%03d', round(frac * 100))}.csv")
}
round_name <- function(ith_run) sprintf("round-%02d", ith_run)
tasks <- expand.grid(
  frac = fractions, method = methods, ith_run = seq_len(n_rounds),
  stringsAsFactors = FALSE
)
tasks[["file"]] <- task_name(tasks[["ith_run"]], tasks[["method"]], tasks[["frac"]])
# task file of the internal test, relative to an experiment folder
tasks[["path"]] <- fs::path(round_name(tasks[["ith_run"]]), "split-70-30", tasks[["file"]])

# the learning-curve script skips tasks whose file exists, so results of
# an earlier check would be compared again instead of rerun
fs::dir_create(check_dir)
old <- c(tasks[["path"]], fs::path(round_name(seq_len(n_rounds)), "comparison.csv"))
old <- old[fs::file_exists(check_dir / old)]
if (length(old) > 0) {
  stop(glue("{check_dir} holds results of an earlier check ({toString(old)}); move them away"))
}

#
# 1. Inputs of the recorded run, linked
#
inputs <- c(
  fs::path("inputs", "labelled_samples.rds"),
  fs::path(round_name(seq_len(n_rounds)), sprintf("round_%02d_split.rds", seq_len(n_rounds))),
  fs::path("inputs", glue("encoded_{setdiff(methods, c('ts_mlp', 'ts_tempcnn'))}.rds"))
)
for (input in inputs) {
  target <- fs::path_abs(recorded_dir / input)
  link <- check_dir / input
  if (!fs::file_exists(target)) {
    stop(glue("{target} is missing"))
  }
  # a link left by an earlier check is kept if it points to the same file
  if (fs::link_exists(link) && fs::link_path(link) == target) {
    next
  }
  fs::dir_create(fs::path_dir(link))
  fs::link_create(target, link)
}

#
# 2. Rerun the tasks in the check folder, as a child process
#
log_file <- fs::dir_create(check_dir / "logs") / "check.log"
message(glue("running {nrow(tasks)} tasks, log in {log_file}"))
status <- system2(
  "Rscript",
  c(
    "analysis/sbsr2027/accuracy_learning_curve.R", n_rounds, paste(fractions, collapse = ","),
    paste(methods, collapse = ","), "hf", n_workers, as.character(check_dir), val2018
  ),
  stdout = as.character(log_file), stderr = as.character(log_file)
)
message(glue("learning-curve script exit status {status}"))

#
# 3. Compare each new task with the recorded one
#
metric_value <- function(file, metric) {
  result <- read.csv(file)
  value <- result[["value"]][result[["metric"]] == metric]
  if (length(value) != 1) NA else value
}
new_files <- check_dir / tasks[["path"]]
recorded_files <- recorded_dir / tasks[["path"]]
found <- fs::file_exists(new_files) & fs::file_exists(recorded_files)
val_files <- check_dir / round_name(tasks[["ith_run"]]) / "val-2018" / tasks[["file"]]
if (val2018 != "none") found <- found & fs::file_exists(val_files)
cmp <- tasks[found, c("ith_run", "method", "frac", "file")]
names(cmp) <- c("round", "method", "fraction", "file")
cmp[["acc_recorded"]] <- vapply(recorded_files[found], metric_value, 0, "accuracy")
cmp[["acc_new"]] <- vapply(new_files[found], metric_value, 0, "accuracy")
cmp[["acc_diff"]] <- cmp[["acc_new"]] - cmp[["acc_recorded"]]
cmp[["sec_recorded"]] <- vapply(recorded_files[found], metric_value, 0, "seconds")
cmp[["sec_new"]] <- vapply(new_files[found], metric_value, 0, "seconds")
cmp[["sec_ratio"]] <- cmp[["sec_new"]] / cmp[["sec_recorded"]]
if (val2018 != "none") {
  cmp[["acc_val2018"]] <- vapply(val_files[found], metric_value, 0, "accuracy")
}
# one comparison.csv in each round folder, with the tasks of that round
for (ith_run in seq_len(n_rounds)) {
  cmp_file <- fs::dir_create(check_dir / round_name(ith_run)) / "comparison.csv"
  write.csv(cmp[cmp[["round"]] == ith_run, ], glue("{cmp_file}.tmp"), row.names = FALSE)
  fs::file_move(glue("{cmp_file}.tmp"), cmp_file)
}

missing <- tasks[["file"]][!found]
message(glue("tasks compared: {nrow(cmp)} of {nrow(tasks)}"))
if (nrow(cmp) > 0) {
  message(glue("max absolute accuracy difference: {signif(max(abs(cmp[['acc_diff']])), 3)}"))
  message(glue("median time ratio (new / recorded): {signif(stats::median(cmp[['sec_ratio']]), 3)}"))
}
if (length(missing) > 0) {
  message(glue("missing task: {missing}"))
  message(glue("see {log_file}"))
  quit(status = 1)
}
