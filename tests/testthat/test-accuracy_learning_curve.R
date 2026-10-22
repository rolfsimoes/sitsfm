# Runs analysis/sbsr2027/accuracy_learning_curve.R on the MODIS samples of sits
# (1218 samples, 4 classes), one round, MLP on the raw time series.
# Oracle: per-class counts computed by hand with floor(), the rounding of
# sits_sample(); set properties checked with base R; results of one worker
# compared with results of two; torch threads inside the training traced
# in torch_manual_seed(), which sits calls once per training.
# It cannot see the encoders, the GPU or the run time of the real data,
# nor the AlphaEarth and encoder inputs of the 2018 validation points.
# Without a GPU every task gets the same threads; the share among the
# processes on a GPU (nvidia-smi) is checked only as training = task value.
# Model reuse needs the sitsfm commit, read from the .git of this checkout;
# a changed commit is not tested, only a changed sits_md5.
script <- normalizePath(testthat::test_path("..", "..", "analysis", "sbsr2027", "accuracy_learning_curve.R"))
modis <- tempfile("modis_", fileext = ".rds")
saveRDS(sits::samples_modis_ndvi, modis)
new_dir <- function() {
    d <- tempfile("lc_")
    dir.create(file.path(d, "data", "results", "sbsr2027", "split-70-30"), recursive = TRUE)
    d
}
run <- function(dir, fractions = "0.1,0.5,1", methods = "ts_mlp", workers = "1", rounds = "1",
                folder = NULL, env = character(), val2018 = NULL) {
    old <- setwd(dir)
    on.exit(setwd(old))
    suppressWarnings(system2(
        "Rscript", c(script, rounds, fractions, methods, modis, workers, folder, val2018),
        stdout = TRUE, stderr = TRUE, env = env
    ))
}
# profile of the child R processes, workers included: each training logs
# the torch threads it runs with
trace_profile <- tempfile("trace_", fileext = ".R")
writeLines(c(
    'if (file.exists("~/.Rprofile")) source("~/.Rprofile")',
    'setHook(packageEvent("torch", "onLoad"), function(...) suppressMessages(trace(',
    '    "torch_manual_seed", where = asNamespace("torch"), print = FALSE,',
    '    tracer = quote(message("worker ", Sys.getpid(), ": training threads ",',
    '        torch::torch_get_num_threads())))))'
), trace_profile)
# threads per worker pid, in log order, from lines that end in
# "<n> threads, worker <pid>" or "worker <pid>: training threads <n>"
threads_by_worker <- function(log, training) {
    if (training) {
        m <- regmatches(log, regexec("^worker ([0-9]+): training threads ([0-9]+)$", log))
        m <- m[lengths(m) == 3]
        pid <- vapply(m, `[[`, "", 2)
        n <- vapply(m, `[[`, "", 3)
    } else {
        m <- regmatches(log, regexec(": accuracy .*, ([0-9]+) threads, worker ([0-9]+)$", log))
        m <- m[lengths(m) == 3]
        pid <- vapply(m, `[[`, "", 3)
        n <- vapply(m, `[[`, "", 2)
    }
    lapply(split(as.integer(n), pid), unname)
}
# the last lines of a run's log, shown when the run fails
tail_of <- function(log) paste(utils::tail(log, 30), collapse = "\n")
# the default experiment folder and the files of round 1 in it
results <- function(dir) file.path(dir, "data", "results", "sbsr2027", "split-70-30")
round1 <- function(dir) file.path(results(dir), "round-01")
split_path <- function(dir) file.path(round1(dir), "round_01_split.rds")
task_file <- function(dir, method, frac, round = 1) {
    file.path(results(dir), sprintf("round-%02d", round), "split-70-30",
              sprintf("round_%02d_%s_f%03d.csv", round, method, round(frac * 100)))
}
no_seconds <- function(file) {
    d <- read.csv(file)
    d[d$metric != "seconds", ]
}
work <- new_dir()
log <- run(work)
labels <- sits::samples_modis_ndvi[["label"]]
count <- function(ids) as.vector(table(factor(labels[ids], levels = sort(unique(labels)))))

test_that("the script ends and writes the split and one table per fraction", {
    expect_null(attr(log, "status"), info = tail_of(log))
    expect_true(file.exists(split_path(work)))
    for (f in c(0.1, 0.5, 1)) expect_true(file.exists(task_file(work, "ts_mlp", f)))
})

split <- readRDS(split_path(work))

test_that("the split keeps floor(0.7 n) of each class for training", {
    # Cerrado 379, Forest 131, Pasture 344, Soy_Corn 364
    expect_equal(count(split$train[["1"]]), c(265, 91, 240, 254))
    expect_equal(count(split$valid), c(114, 40, 104, 110))
    expect_length(intersect(split$valid, split$train[["1"]]), 0)
    expect_setequal(c(split$valid, split$train[["1"]]), seq_along(labels))
})

test_that("fractions take floor(f n) of each class and are nested", {
    # 0.5: floor(0.5 x 265, 91, 240, 254); 0.1: floor(0.1 x 265, 91, 240, 254)
    expect_equal(count(split$train[["0.5"]]), c(132, 45, 120, 127))
    expect_equal(count(split$train[["0.1"]]), c(26, 9, 24, 25))
    expect_length(setdiff(split$train[["0.1"]], split$train[["0.5"]]), 0)
    expect_length(setdiff(split$train[["0.5"]], split$train[["1"]]), 0)
})

test_that("each table holds accuracy, kappa and one F1 per class", {
    for (f in c(0.1, 0.5, 1)) {
        a <- read.csv(task_file(work, "ts_mlp", f))
        expect_equal(unique(a$fraction), f)
        expect_equal(sum(a$metric == "accuracy"), 1)
        expect_equal(sum(a$metric == "kappa"), 1)
        expect_setequal(a$class[a$metric == "f1"], sort(unique(labels)))
        # an MLP on 84 samples gets few gradient steps and can stay below
        # chance, so the test checks the range, not the quality
        acc <- a$value[a$metric == "accuracy"]
        expect_true(acc >= 0 && acc <= 1)
        expect_equal(unique(a$n_valid), 368)
    }
})

test_that("a second run skips every task that is done", {
    log2 <- run(work)
    expect_equal(sum(grepl("done, skipped", log2)), 3)
    expect_false(any(grepl(": accuracy", log2)))
})

test_that("a fraction gives the same samples and result without the other fractions", {
    work2 <- new_dir()
    log2 <- run(work2, "0.5,1")
    expect_null(attr(log2, "status"), info = tail_of(log2))
    split2 <- readRDS(split_path(work2))
    expect_identical(split2$valid, split$valid)
    expect_identical(split2$train[["0.5"]], split$train[["0.5"]])
    for (f in c(0.5, 1)) {
        expect_equal(no_seconds(task_file(work2, "ts_mlp", f)), no_seconds(task_file(work, "ts_mlp", f)))
    }
})

test_that("two workers give the same results as one", {
    work3 <- new_dir()
    log3 <- run(work3, workers = "2", env = paste0("R_PROFILE_USER=", trace_profile))
    expect_null(attr(log3, "status"), info = tail_of(log3))
    q <- if (file.exists("/sys/fs/cgroup/cpu.max")) {
        strsplit(readLines("/sys/fs/cgroup/cpu.max", n = 1), " ")[[1]]
    } else {
        "max"
    }
    cores <- if (q[[1]] == "max") parallel::detectCores() else as.numeric(q[[1]]) %/% as.numeric(q[[2]])
    # each training runs with the threads its task chose, not the
    # whole quota that sits_train() takes by default
    task <- threads_by_worker(log3, training = FALSE)
    expect_equal(sum(lengths(task)), 3)
    expect_identical(threads_by_worker(log3, training = TRUE), task)
    if (!torch::cuda_is_available()) {
        # without a GPU each worker gets half of the CPU quota of the container
        expect_equal(sum(grepl(paste0("torch threads ", max(1, cores %/% 2), "$"), log3)), 2)
        expect_true(all(unlist(task) == max(1, cores %/% 2)))
    }
    for (f in c(0.1, 0.5, 1)) {
        expect_equal(no_seconds(task_file(work3, "ts_mlp", f)), no_seconds(task_file(work, "ts_mlp", f)))
    }
})

test_that("a table of the first layout (one per round and method) is reused", {
    # first layout: round_01_ts_mlp.csv with all fractions; a marker value
    # shows the table was split, not recomputed
    work4 <- new_dir()
    first <- do.call(rbind, lapply(c(0.5, 1), function(f) read.csv(task_file(work, "ts_mlp", f))))
    first$value[first$metric == "accuracy"] <- 0.123
    dir.create(file.path(round1(work4), "split-70-30"), recursive = TRUE)
    write.csv(first, file.path(round1(work4), "split-70-30", "round_01_ts_mlp.csv"), row.names = FALSE)
    log4 <- run(work4, "0.5,1")
    expect_equal(sum(grepl("done, skipped", log4)), 2)
    for (f in c(0.5, 1)) {
        a <- read.csv(task_file(work4, "ts_mlp", f))
        expect_equal(a$value[a$metric == "accuracy"], 0.123)
    }
})

test_that("a fraction that is not a multiple of 0.01 is refused", {
    expect_false(is.null(attr(run(new_dir(), "0.125,1"), "status")))
})

test_that("encoded samples are read from disk once per worker, not per round", {
    # stand-in for an encoder: the MODIS samples saved as encoded_btwins.rds
    work5 <- new_dir()
    enc <- sits::samples_modis_ndvi
    enc[["id"]] <- seq_len(nrow(enc))
    dir.create(file.path(results(work5), "inputs"))
    saveRDS(enc, file.path(results(work5), "inputs", "encoded_btwins.rds"))
    log5 <- run(work5, "0.5,1", "btwins", rounds = "2")
    expect_null(attr(log5, "status"), info = tail_of(log5))
    expect_equal(sum(grepl("encoded btwins: read from", log5)), 1)
    expect_true(file.exists(task_file(work5, "btwins", 1, round = 2)))
})

test_that("a saved split is read, not drawn again, and not rewritten", {
    # marker split: every other training sample at fraction 1, 425 of 850,
    # a size no draw gives (a draw keeps floor(0.7 n) of each class)
    work6 <- new_dir()
    marker <- list(valid = split$valid, train = list("1" = split$train[["1"]][c(TRUE, FALSE)]))
    file <- split_path(work6)
    dir.create(round1(work6))
    saveRDS(marker, file)
    before <- tools::md5sum(file)
    log6 <- run(work6, "1")
    expect_null(attr(log6, "status"), info = tail_of(log6))
    expect_equal(unname(tools::md5sum(file)), unname(before))
    a <- read.csv(task_file(work6, "ts_mlp", 1))
    expect_equal(unique(a$n_train), 425)
    expect_equal(unique(a$n_valid), 368)
})

test_that("a saved split without a fraction asked for stops the run", {
    work7 <- new_dir()
    file <- split_path(work7)
    dir.create(round1(work7))
    saveRDS(list(valid = split$valid, train = list("1" = split$train[["1"]])), file)
    before <- tools::md5sum(file)
    log7 <- run(work7, "0.5,1")
    expect_false(is.null(attr(log7, "status")))
    expect_true(any(grepl("has no fraction 0.5", log7)))
    expect_equal(unname(tools::md5sum(file)), unname(before))
    expect_false(file.exists(task_file(work7, "ts_mlp", 1)))
})

test_that("a saved model is read when its metadata match the run, and trained again when not", {
    # the split and models of the first run, without its CSVs; the model of
    # fraction 1 marked as made by other sits files
    work11 <- new_dir()
    dir.create(round1(work11))
    file.copy(file.path(round1(work), c("round_01_split.rds", "models")), round1(work11), recursive = TRUE)
    meta_file <- file.path(round1(work11), "models", "round_01_ts_mlp_f100.json")
    meta <- jsonlite::read_json(meta_file)
    expect_setequal(names(meta), c(
        "round", "method", "fraction", "n_train", "train_seconds", "trained_at", "sitsfm_commit",
        "sits_version", "sits_md5", "torch_version", "r_version", "model_md5"
    ))
    expect_equal(meta$model_md5, unname(tools::md5sum(sub("json$", "rds", meta_file))))
    meta$sits_md5[[1]] <- "0"
    jsonlite::write_json(meta, meta_file, auto_unbox = TRUE, pretty = TRUE, digits = NA)
    log11 <- run(work11, "0.5,1")
    expect_null(attr(log11, "status"), info = tail_of(log11))
    expect_equal(sum(grepl("fraction 0.5: model read from", log11)), 1)
    expect_equal(sum(grepl("fraction 1: saved model not used \\(sits_md5 differs\\)", log11)), 1)
    expect_false(any(grepl("fraction 1: model read from", log11)))
    # the read model and the model trained again on the same stream give
    # the metrics of the first run
    for (f in c(0.5, 1)) {
        expect_equal(no_seconds(task_file(work11, "ts_mlp", f)), no_seconds(task_file(work, "ts_mlp", f)))
    }
    first_meta <- jsonlite::read_json(file.path(round1(work), "models", "round_01_ts_mlp_f100.json"))
    expect_equal(jsonlite::read_json(meta_file)$sits_md5, first_meta$sits_md5)
})

test_that("the results folder argument moves every file the script reads and writes", {
    work8 <- new_dir()
    folder <- file.path(work8, "elsewhere")
    dir.create(folder)
    # the encoded samples and a STOP file are read from the given folder
    enc <- sits::samples_modis_ndvi
    enc[["id"]] <- seq_len(nrow(enc))
    dir.create(file.path(folder, "inputs"))
    saveRDS(enc, file.path(folder, "inputs", "encoded_btwins.rds"))
    file.create(file.path(folder, "STOP"))
    expect_false(is.null(attr(run(work8, "1", "btwins", folder = folder), "status")))
    file.remove(file.path(folder, "STOP"))
    log8 <- run(work8, "1", "btwins", folder = folder)
    expect_null(attr(log8, "status"), info = tail_of(log8))
    expect_equal(sum(grepl("encoded btwins: read from", log8)), 1)
    expect_true(file.exists(file.path(folder, "round-01", "round_01_split.rds")))
    expect_true(file.exists(file.path(folder, "round-01", "split-70-30", "round_01_btwins_f100.csv")))
    expect_true(file.exists(file.path(folder, "round-01", "models", "round_01_btwins_f100.rds")))
    # the default folder stays empty
    expect_length(list.files(results(work8), all.files = TRUE, no.. = TRUE), 0)
})

# stand-in for the 2018 validation points: samples of the internal test of
# round 1, saved where the script reads the 2018 series
val2018_dir <- function(split_from, points) {
    d <- new_dir()
    dir.create(round1(d))
    file.copy(split_path(split_from), round1(d))
    val_inputs <- file.path(d, "data", "results", "sbsr2027", "val-2018", "inputs")
    dir.create(val_inputs, recursive = TRUE)
    saveRDS(points, file.path(val_inputs, "validation_series_2018.rds"))
    d
}
val_file <- function(dir, method, frac) {
    file.path(round1(dir), "val-2018", basename(task_file(dir, method, frac)))
}

test_that("2018 points equal to the internal test give its metrics, and the internal test is unchanged", {
    # oracle: the internal metrics, computed by sits_accuracy() on the same samples
    work9 <- val2018_dir(work, sits::samples_modis_ndvi[split$valid, ])
    log9 <- run(work9, "0.5,1", folder = "data/results/sbsr2027/split-70-30", val2018 = "all")
    expect_null(attr(log9, "status"), info = tail_of(log9))
    for (f in c(0.5, 1)) {
        internal <- no_seconds(task_file(work9, "ts_mlp", f))
        expect_equal(internal, no_seconds(task_file(work, "ts_mlp", f)))
        v <- no_seconds(val_file(work9, "ts_mlp", f))
        expect_equal(unique(v$n_valid), length(split$valid))
        for (m in c("accuracy", "kappa")) {
            expect_equal(v$value[v$metric == m], internal$value[internal$metric == m])
        }
        f1 <- internal$value[internal$metric == "f1"]
        names(f1) <- internal$class[internal$metric == "f1"]
        expect_equal(v$value[v$metric == "f1"], unname(f1[v$class[v$metric == "f1"]]))
    }
    # a second run skips the tasks whose two files are done
    log9b <- run(work9, "0.5,1", folder = "data/results/sbsr2027/split-70-30", val2018 = "all")
    expect_equal(sum(grepl("done, skipped", log9b)), 2)
})

test_that("2018 metrics hold only the classes of the reference, on the points asked for", {
    # stand-in without Forest: the model still predicts Forest, which the
    # metrics count as errors
    points <- sits::samples_modis_ndvi[split$valid, ]
    points <- points[points$label != "Forest", ]
    work10 <- val2018_dir(work, points)
    log10 <- run(work10, "1", folder = "data/results/sbsr2027/split-70-30", val2018 = "40")
    expect_null(attr(log10, "status"), info = tail_of(log10))
    v <- read.csv(val_file(work10, "ts_mlp", 1))
    expect_equal(unique(v$n_valid), 40)
    expect_setequal(v$class[v$metric == "f1"], c("Cerrado", "Pasture", "Soy_Corn"))
    acc <- v$value[v$metric == "accuracy"]
    expect_true(acc >= 0 && acc <= 1)
    # oracle: the evenly spaced rows of the script, and the share of
    # predictions equal to the label, Forest included
    p <- read.csv(file.path(round1(work10), "val-2018", "round_01_ts_mlp_f100_pred.csv"))
    expect_equal(p$row, unique(round(seq(1, nrow(points), length.out = 40))))
    expect_equal(p$label, unname(points$label[p$row]))
    expect_equal(acc, mean(p$predicted == p$label))
})
