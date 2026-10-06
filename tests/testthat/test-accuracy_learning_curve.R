# Runs analysis/accuracy_learning_curve.R on the MODIS samples of sits
# (1218 samples, 4 classes), one round, MLP on the raw time series.
# Oracle: per-class counts computed by hand with floor(), the rounding of
# sits_sample(); set properties checked with base R.
# It cannot see the encoders, the GPU or the run time of the real data.
script <- normalizePath(testthat::test_path("..", "..", "analysis", "accuracy_learning_curve.R"))
work <- tempfile("lc_")
dir.create(work)
saveRDS(sits::samples_modis_ndvi, file.path(work, "modis.rds"))
run <- function(fractions = "0.1,0.5,1", dir = work) {
    file.copy(file.path(work, "modis.rds"), dir)
    withr::with_dir(dir, suppressWarnings(system2(
        "Rscript", c(script, "1", fractions, "ts_mlp", "modis.rds"),
        stdout = TRUE, stderr = TRUE
    )))
}
log <- run()
out <- file.path(work, "data", "results", "learning_curve")
labels <- sits::samples_modis_ndvi[["label"]]
count <- function(ids) as.vector(table(factor(labels[ids], levels = sort(unique(labels)))))

test_that("the script ends and writes the split and the accuracy table", {
    expect_null(attr(log, "status"))
    expect_true(file.exists(file.path(out, "round_01_split.rds")))
    expect_true(file.exists(file.path(out, "round_01_ts_mlp.csv")))
})

split <- readRDS(file.path(out, "round_01_split.rds"))

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

test_that("the table holds accuracy, kappa and one F1 per class for each fraction", {
    acc <- read.csv(file.path(out, "round_01_ts_mlp.csv"))
    for (f in c(0.1, 0.5, 1)) {
        a <- acc[acc$fraction == f, ]
        expect_equal(sum(a$metric == "accuracy"), 1)
        expect_equal(sum(a$metric == "kappa"), 1)
        expect_setequal(a$class[a$metric == "f1"], sort(unique(labels)))
        # an MLP on 84 samples gets few gradient steps and can stay below
        # chance, so the test checks the range, not the quality
        expect_true(all(a$value[a$metric == "accuracy"] >= 0 & a$value[a$metric == "accuracy"] <= 1))
        expect_equal(unique(a$n_valid), 368)
    }
})

test_that("a second run skips the round that is done", {
    expect_true(any(grepl("done, skipped", run())))
})

test_that("a fraction gives the same samples and accuracy without the other fractions", {
    # streams per round and substreams per fraction: the result of (round,
    # fraction) must not depend on which other fractions ran
    work2 <- tempfile("lc_")
    dir.create(work2)
    log2 <- run("0.5,1", work2)
    expect_null(attr(log2, "status"))
    out2 <- file.path(work2, "data", "results", "learning_curve")
    split2 <- readRDS(file.path(out2, "round_01_split.rds"))
    expect_identical(split2$valid, split$valid)
    expect_identical(split2$train[["0.5"]], split$train[["0.5"]])
    keep <- function(d) d[d$fraction %in% c(0.5, 1) & d$metric != "seconds", ]
    a1 <- keep(read.csv(file.path(out, "round_01_ts_mlp.csv")))
    a2 <- keep(read.csv(file.path(out2, "round_01_ts_mlp.csv")))
    rownames(a1) <- rownames(a2) <- NULL
    expect_equal(a2, a1)
})

test_that("a fraction that is not a multiple of 0.01 is refused", {
    work3 <- tempfile("lc_")
    dir.create(work3)
    expect_false(is.null(attr(run("0.125,1", work3), "status")))
})

test_that("encoded samples are read from disk once per run, not per round", {
    # stand-in for an encoder: the MODIS samples saved as encoded_btwins.rds
    work4 <- tempfile("lc_")
    out4 <- file.path(work4, "data", "results", "learning_curve")
    dir.create(out4, recursive = TRUE)
    enc <- sits::samples_modis_ndvi
    enc[["id"]] <- seq_len(nrow(enc))
    saveRDS(enc, file.path(out4, "encoded_btwins.rds"))
    file.copy(file.path(work, "modis.rds"), work4)
    log4 <- withr::with_dir(work4, suppressWarnings(system2(
        "Rscript", c(script, "2", "0.5,1", "btwins", "modis.rds"),
        stdout = TRUE, stderr = TRUE
    )))
    expect_null(attr(log4, "status"))
    expect_equal(sum(grepl("encoded btwins: read from", log4)), 1)
    expect_true(file.exists(file.path(out4, "round_02_btwins.csv")))
})
