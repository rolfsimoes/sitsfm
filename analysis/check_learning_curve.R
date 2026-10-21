# Server check of accuracy_learning_curve.R: reruns recorded tasks (by
# default 16: rounds 1 and 2, fractions 5% and 10%, the three encoders and
# the MLP on the raw time series, 8 workers) in a separate folder and
# compares each result with the recorded one.
#
# The check folder links (does not copy) the labelled samples, the splits
# and the encoded samples of the recorded run, so the rerun uses the same
# inputs; nothing is written in the recorded folder.
#
# Run from the repository root. Optional arguments are the number of
# rounds, the fractions, the methods and the check folder:
#   Rscript analysis/check_learning_curve.R
#   Rscript analysis/check_learning_curve.R 1 0.05,0.1 ts_tempcnn \
#     data/results/learning_curve_check_tempcnn
library(glue)

recorded_dir <- fs::path("data/results/learning_curve")
check_dir <- fs::path("data/results/learning_curve_check")
stopifnot(fs::file_exists("analysis/accuracy_learning_curve.R"))
n_rounds <- 2
fractions <- c(0.05, 0.1)
methods <- c("btwins", "vicreg", "lejepa", "ts_mlp")
n_workers <- 8
args <- commandArgs(trailingOnly = TRUE)
if (length(args) >= 1) n_rounds <- as.integer(args[[1]])
if (length(args) >= 2) fractions <- as.numeric(strsplit(args[[2]], ",")[[1]])
if (length(args) >= 3) methods <- strsplit(args[[3]], ",")[[1]]
if (length(args) >= 4) check_dir <- fs::path(args[[4]])

task_name <- function(ith_run, method, frac) {
  glue("round_{sprintf('%02d', ith_run)}_{method}_f{sprintf('%03d', round(frac * 100))}.csv")
}
tasks <- expand.grid(
  frac = fractions, method = methods, ith_run = seq_len(n_rounds),
  stringsAsFactors = FALSE
)
tasks[["file"]] <- task_name(tasks[["ith_run"]], tasks[["method"]], tasks[["frac"]])

# the learning-curve script skips tasks whose file exists, so results of
# an earlier check would be compared again instead of rerun
fs::dir_create(check_dir)
old <- intersect(c(tasks[["file"]], "comparison.csv"), fs::path_file(fs::dir_ls(check_dir)))
if (length(old) > 0) {
  stop(glue("{check_dir} holds results of an earlier check ({toString(old)}); move them away"))
}

#
# 1. Inputs of the recorded run, linked
#
inputs <- c(
  "labelled_samples.rds",
  sprintf("round_%02d_split.rds", seq_len(n_rounds)),
  glue("encoded_{setdiff(methods, c('ts_mlp', 'ts_tempcnn'))}.rds")
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
  fs::link_create(target, link)
}

#
# 2. Rerun the tasks in the check folder, as a child process
#
log_file <- check_dir / "check.log"
message(glue("running {nrow(tasks)} tasks, log in {log_file}"))
status <- system2(
  "Rscript",
  c(
    "analysis/accuracy_learning_curve.R", n_rounds, paste(fractions, collapse = ","),
    paste(methods, collapse = ","), "hf", n_workers, as.character(check_dir)
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
new_files <- check_dir / tasks[["file"]]
recorded_files <- recorded_dir / tasks[["file"]]
found <- fs::file_exists(new_files) & fs::file_exists(recorded_files)
cmp <- tasks[found, c("ith_run", "method", "frac", "file")]
names(cmp) <- c("round", "method", "fraction", "file")
cmp[["acc_recorded"]] <- vapply(recorded_files[found], metric_value, 0, "accuracy")
cmp[["acc_new"]] <- vapply(new_files[found], metric_value, 0, "accuracy")
cmp[["acc_diff"]] <- cmp[["acc_new"]] - cmp[["acc_recorded"]]
cmp[["sec_recorded"]] <- vapply(recorded_files[found], metric_value, 0, "seconds")
cmp[["sec_new"]] <- vapply(new_files[found], metric_value, 0, "seconds")
cmp[["sec_ratio"]] <- cmp[["sec_new"]] / cmp[["sec_recorded"]]
cmp_file <- check_dir / "comparison.csv"
write.csv(cmp, glue("{cmp_file}.tmp"), row.names = FALSE)
fs::file_move(glue("{cmp_file}.tmp"), cmp_file)

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
