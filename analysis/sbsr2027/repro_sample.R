# Random sample of recorded tasks for the reproduction test of
# run_repro_check.sh --sample: one task per experiment and MLP-family
# method, with round and fraction drawn at random.
# TempCNN (ts_tempcnn, ts_tempcnn6) is left out: it does not reproduce on
# the GPU with the same seed and split (README, "Results of the SBSR 2027
# experiments"). ts_mlp is left out too: the paper uses the 6 bands (ts_mlp6).
#
# Candidates: the task files in round-RR/split-70-30/ of each experiment
# folder (cpu-trained/ and checks/ are not read) and, in the experiments
# that score the 2018 points, also in round-RR/val-2018/. The runner
# trains round R by linking the recorded files of rounds 1 to R-1, so a
# (round, fraction) is a candidate only if those files exist too.
# Draw: experiments in the order below, methods in alphabetical order,
# candidates sorted by round and fraction, one index per pair from
# set.seed(1524) with the sample kind "Rejection" (R >= 3.6).
#
# The sample is written once, as a CSV (experiment, round, method,
# percent). If the file exists, the new draw is compared with it and the
# script stops when they differ; the file is never overwritten.
# It prints the sample with the recorded seconds of each task file.
#
# Optional arguments: results folder (default data/results/sbsr2027),
# sample file (default analysis/sbsr2027/repro_sample_tasks.csv), e.g.
#   Rscript analysis/sbsr2027/repro_sample.R
library(glue)

args <- commandArgs(trailingOnly = TRUE)
results_folder <- "data/results/sbsr2027"
sample_file <- "analysis/sbsr2027/repro_sample_tasks.csv"
if (length(args) >= 1) results_folder <- args[[1]]
if (length(args) >= 2) sample_file <- args[[2]]
# experiment and whether its runner scored the 2018 points (as in
# run_gpu_retrain.sh)
experiments <- c(
  "split-70-30" = FALSE, "val-2018" = TRUE, "split-year" = TRUE,
  "split-location" = TRUE, "split-block" = TRUE
)
excluded <- c("ts_tempcnn", "ts_tempcnn6", "ts_mlp")
pattern <- "^round_([0-9]{2})_(.+)_f([0-9]{3})\\.csv$"

task_path <- function(exp, round, method, percent, eval_set) {
  rr <- sprintf("%02d", round)
  fs::path(
    results_folder, exp, glue("round-{rr}"), eval_set,
    glue("round_{rr}_{method}_f{sprintf('%03d', percent)}.csv")
  )
}
# value of metric `seconds` in a task file
task_seconds <- function(file) {
  x <- read.csv(file)
  x[["value"]][x[["metric"]] == "seconds"]
}

# 1. Candidate tasks of each experiment
candidates <- purrr::map_dfr(names(experiments), function(exp) {
  files <- basename(Sys.glob(fs::path(results_folder, exp, "round-[0-9][0-9]", "split-70-30", "round_*.csv")))
  files <- files[grepl(pattern, files)]
  tasks <- data.frame(
    experiment = exp,
    round = as.integer(sub(pattern, "\\1", files)),
    method = sub(pattern, "\\2", files),
    percent = as.integer(sub(pattern, "\\3", files))
  )
  tasks <- tasks[!tasks[["method"]] %in% excluded, ]
  eval_sets <- if (experiments[[exp]]) c("split-70-30", "val-2018") else "split-70-30"
  # every file of rounds 1 to R must exist, in each evaluation set
  ok <- purrr::pmap_lgl(tasks, function(experiment, round, method, percent) {
    all(purrr::map_lgl(seq_len(round), function(r) {
      all(fs::file_exists(task_path(experiment, r, method, percent, eval_sets)))
    }))
  })
  tasks[ok, ]
})
stopifnot(nrow(candidates) > 0)

# 2. One task per (experiment, method)
set.seed(1524, kind = "Mersenne-Twister", normal.kind = "Inversion", sample.kind = "Rejection")
pairs <- unique(candidates[, c("experiment", "method")])
pairs <- pairs[order(match(pairs[["experiment"]], names(experiments)), pairs[["method"]]), ]
drawn <- purrr::map_dfr(seq_len(nrow(pairs)), function(i) {
  pool <- candidates[
    candidates[["experiment"]] == pairs[["experiment"]][[i]] &
      candidates[["method"]] == pairs[["method"]][[i]],
  ]
  pool <- pool[order(pool[["round"]], pool[["percent"]]), ]
  pool[sample.int(nrow(pool), 1), ]
})
rownames(drawn) <- NULL

# 3. Compare with the recorded sample, or write it
if (fs::file_exists(sample_file)) {
  recorded <- read.csv(sample_file, stringsAsFactors = FALSE)
  if (!isTRUE(all.equal(recorded, drawn, check.attributes = FALSE))) {
    stop(glue("{sample_file} differs from this draw; it is not overwritten"))
  }
  message(glue("{sample_file}: same as this draw"))
} else {
  write.csv(drawn, glue("{sample_file}.tmp"), row.names = FALSE, quote = FALSE)
  fs::file_move(glue("{sample_file}.tmp"), sample_file)
  message(glue("{sample_file}: written"))
}

# 4. Recorded seconds of the sampled task files
drawn[["seconds"]] <- purrr::pmap_dbl(drawn, function(experiment, round, method, percent) {
  task_seconds(task_path(experiment, round, method, percent, "split-70-30"))
})
drawn[["val_seconds"]] <- purrr::pmap_dbl(drawn[, 1:4], function(experiment, round, method, percent) {
  if (!experiments[[experiment]]) {
    return(NA_real_)
  }
  task_seconds(task_path(experiment, round, method, percent, "val-2018"))
})
print(drawn, row.names = FALSE)
message(glue(
  "{nrow(drawn)} tasks from {nrow(candidates)} candidates; ",
  "recorded seconds: {round(sum(drawn$seconds))} (internal test), ",
  "{round(sum(drawn$val_seconds, na.rm = TRUE))} (2018 points)"
))
