# Runs analysis/accuracy_learning_curve.R on the MODIS samples of sits
# (1218 samples, 4 classes), one round, MLP on the raw time series.
# Oracle: per-class counts computed by hand with floor(), the rounding of
# sits_sample(); set properties checked with base R; results of one worker
# compared with results of two.
# It cannot see the encoders, the GPU or the run time of the real data.
script <- normalizePath(testthat::test_path("..", "..", "analysis", "accuracy_learning_curve.R"))
modis <- tempfile("modis_", fileext = ".rds")
saveRDS(sits::samples_modis_ndvi, modis)
new_dir <- function() {
    d <- tempfile("lc_")
    dir.create(file.path(d, "data", "results", "learning_curve"), recursive = TRUE)
    d
}
run <- function(dir, fractions = "0.1,0.5,1", methods = "ts_mlp", workers = "1", rounds = "1") {
    old <- setwd(dir)
    on.exit(setwd(old))
    suppressWarnings(system2(
        "Rscript", c(script, rounds, fractions, methods, modis, workers),
        stdout = TRUE, stderr = TRUE
    ))
}
results <- function(dir) file.path(dir, "data", "results", "learning_curve")
task_file <- function(dir, method, frac, round = 1) {
    file.path(results(dir), sprintf("round_%02d_%s_f%03d.csv", round, method, round(frac * 100)))
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
    expect_null(attr(log, "status"))
    expect_true(file.exists(file.path(results(work), "round_01_split.rds")))
    for (f in c(0.1, 0.5, 1)) expect_true(file.exists(task_file(work, "ts_mlp", f)))
})

split <- readRDS(file.path(results(work), "round_01_split.rds"))

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
    expect_null(attr(run(work2, "0.5,1"), "status"))
    split2 <- readRDS(file.path(results(work2), "round_01_split.rds"))
    expect_identical(split2$valid, split$valid)
    expect_identical(split2$train[["0.5"]], split$train[["0.5"]])
    for (f in c(0.5, 1)) {
        expect_equal(no_seconds(task_file(work2, "ts_mlp", f)), no_seconds(task_file(work, "ts_mlp", f)))
    }
})

test_that("two workers give the same results as one", {
    work3 <- new_dir()
    expect_null(attr(run(work3, workers = "2"), "status"))
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
    write.csv(first, file.path(results(work4), "round_01_ts_mlp.csv"), row.names = FALSE)
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
    saveRDS(enc, file.path(results(work5), "encoded_btwins.rds"))
    log5 <- run(work5, "0.5,1", "btwins", rounds = "2")
    expect_null(attr(log5, "status"))
    expect_equal(sum(grepl("encoded btwins: read from", log5)), 1)
    expect_true(file.exists(task_file(work5, "btwins", 1, round = 2)))
})
