# Runs analysis/sbsr2027/make_splits.R on the MODIS samples of sits (1218
# samples, 4 classes, 732 locations, 47 blocks of 1 degree), with the label
# years replaced by 2018, 2020, 2022 and 2024 in turn, so the same location
# recurs in several years; the later samples of a location get another
# label, so the label of a location depends on which sample is earliest.
# No training.
# Oracle for random: the split code of accuracy_learning_curve.R before it
# moved to make_splits.R (commit 10af5b0), copied below and run in this
# process. Oracles for the other geometries: locations, blocks and years
# counted here from the coordinates and dates, not by the script.
# It cannot see the real samples (110,044, 11 classes) nor the server.
make_splits <- normalizePath(testthat::test_path("..", "..", "analysis", "sbsr2027", "make_splits.R"))
experiment <- normalizePath(testthat::test_path("..", "..", "analysis", "sbsr2027", "accuracy_learning_curve.R"))
samples <- sits::samples_modis_ndvi
years <- c(2018, 2020, 2022, 2024)
samples[["end_date"]] <- as.Date(paste0(years[(seq_len(nrow(samples)) - 1) %% 4 + 1], "-08-31"))
ids <- seq_len(nrow(samples))
location <- paste(round(samples$longitude, 7), round(samples$latitude, 7))
# row of the earliest sample of each location (which.min: the first in row order)
first <- unname(unlist(tapply(ids, location, function(rows) rows[which.min(samples$end_date[rows])])))
classes <- sort(unique(samples$label))
later <- !(ids %in% first)
samples$label[later] <- classes[match(samples$label[later], classes) %% length(classes) + 1]
block <- paste(floor(samples$longitude), floor(samples$latitude))
year <- format(samples$end_date, "%Y")

work <- tempfile("splits_")
inputs <- file.path(work, "data", "results", "sbsr2027", "split-70-30", "inputs")
dir.create(inputs, recursive = TRUE)
saveRDS(samples, file.path(inputs, "labelled_samples.rds"))
run <- function(...) {
    old <- setwd(work)
    on.exit(setwd(old))
    suppressWarnings(system2("Rscript", c(make_splits, ...), stdout = TRUE, stderr = TRUE))
}
split_of <- function(geometry, ith_run) {
    folder <- if (geometry == "random") "split-70-30" else paste0("split-", geometry)
    readRDS(file.path(work, "data", "results", "sbsr2027", folder,
                      sprintf("round-%02d", ith_run), sprintf("round_%02d_split.rds", ith_run)))
}
tail_of <- function(log) paste(utils::tail(log, 30), collapse = "\n")
fractions <- c(0.05, 0.1, 0.5, 1)
fraction_arg <- paste(fractions, collapse = ",")
logs <- list(
    random = run("random", "data/results/sbsr2027/split-70-30", "2", fraction_arg),
    location = run("location", "data/results/sbsr2027/split-location", "2", fraction_arg),
    block = run("block", "data/results/sbsr2027/split-block", "2", fraction_arg),
    year = run("year", "data/results/sbsr2027/split-year", "4", fraction_arg)
)
rounds <- c(random = 2, location = 2, block = 2, year = 4)

# the split code of accuracy_learning_curve.R at commit 10af5b0
old_split <- function(labelled_samples, ith_run, fractions) {
    kind <- RNGkind()
    on.exit(RNGkind(kind[[1]], kind[[2]], kind[[3]]))
    RNGkind("L'Ecuyer-CMRG")
    set.seed(1524)
    base_stream <- .Random.seed
    round_stream <- function(ith_run) {
        stream <- base_stream
        for (i in seq_len(ith_run)) stream <- parallel::nextRNGStream(stream)
        stream
    }
    assign(".Random.seed", round_stream(ith_run), envir = globalenv())
    train_samples <- sits::sits_sample(labelled_samples, frac = 0.7, oversample = FALSE)
    validation_ids <- setdiff(labelled_samples[["id"]], train_samples[["id"]])
    train_order <- sits::sits_sample(train_samples, frac = 1.0, oversample = FALSE)
    train_ids <- purrr::map(fractions, function(frac) {
        dplyr::slice_head(dplyr::group_by(train_order, .data[["label"]]), prop = frac)[["id"]]
    })
    names(train_ids) <- as.character(fractions)
    list(valid = validation_ids, train = train_ids)
}

test_that("every geometry ends and writes its rounds", {
    for (g in names(logs)) {
        expect_null(attr(logs[[g]], "status"), info = tail_of(logs[[g]]))
        expect_equal(sum(grepl(paste0("^round [0-9]+ ", g, ": valid"), logs[[g]])), rounds[[g]])
    }
})

test_that("random reproduces the split code of the experiment script", {
    labelled <- samples
    labelled[["id"]] <- ids
    for (r in 1:2) {
        new <- split_of("random", r)
        expect_identical(new[c("valid", "train")], old_split(labelled, r, fractions))
        expect_equal(new$geometry, "random")
    }
    expect_false(identical(split_of("random", 1)$valid, split_of("random", 2)$valid))
})

test_that("location keeps every location on one side and tests 30% of the locations of each class", {
    # label of a location: its earliest sample
    n_loc <- table(samples$label[first])
    for (r in 1:2) {
        s <- split_of("location", r)
        expect_length(intersect(location[s$valid], location[-s$valid]), 0)
        test_first <- first[location[first] %in% location[s$valid]]
        expect_equal(as.vector(table(factor(samples$label[test_first], levels = names(n_loc)))),
                     as.vector(floor(0.3 * n_loc)))
    }
})

test_that("block keeps every block on one side and tests at least 30% of the samples", {
    for (r in 1:2) {
        s <- split_of("block", r)
        expect_length(intersect(block[s$valid], block[-s$valid]), 0)
        expect_gte(length(s$valid), 0.3 * nrow(samples))
        expect_equal(s$params$block_size, 1)
        expect_equal(unname(s$params$n_blocks[["test"]]), length(unique(block[s$valid])))
        expect_equal(sum(s$params$n_blocks), length(unique(block)))
    }
})

test_that("year tests the r-th label year and trains on the others", {
    for (r in 1:4) {
        s <- split_of("year", r)
        expect_equal(unique(year[s$valid]), as.character(years[[r]]))
        expect_setequal(year[-s$valid], as.character(years[-r]))
        expect_equal(s$params$test_year, as.character(years[[r]]))
    }
    log5 <- run("year", "data/results/sbsr2027/year-5", "5", fraction_arg)
    expect_false(is.null(attr(log5, "status")))
    expect_false(dir.exists(file.path(work, "data", "results", "sbsr2027", "year-5", "round-01")))
})

test_that("every geometry: fractions are nested, take floor(f n) of each class and never touch the test side", {
    for (g in names(rounds)) {
        for (r in seq_len(rounds[[g]])) {
            s <- split_of(g, r)
            expect_setequal(c(s$valid, s$train[["1"]]), ids)
            expect_length(intersect(s$valid, s$train[["1"]]), 0)
            n_class <- table(samples$label[s$train[["1"]]])
            for (i in seq_along(fractions)[-1]) {
                expect_length(setdiff(s$train[[i - 1]], s$train[[i]]), 0)
            }
            for (f in fractions) {
                got <- table(factor(samples$label[s$train[[as.character(f)]]], levels = names(n_class)))
                expect_equal(as.vector(got), as.vector(floor(f * n_class)))
            }
            expect_equal(unname(s$params$n_train), lengths(s$train, use.names = FALSE))
            expect_equal(s$params$n_valid, length(s$valid))
            expect_equal(sum(s$params$n_test_class), length(s$valid))
        }
    }
})

test_that("an existing split file is not overwritten", {
    file <- file.path(work, "data", "results", "sbsr2027", "split-block", "round-01", "round_01_split.rds")
    before <- tools::md5sum(file)
    log2 <- run("block", "data/results/sbsr2027/split-block", "2", fraction_arg, "3")
    expect_null(attr(log2, "status"), info = tail_of(log2))
    expect_equal(sum(grepl("exists, skipped", log2)), 2)
    expect_equal(unname(tools::md5sum(file)), unname(before))
})

test_that("an experiment folder links the inputs of split-70-30 with relative links", {
    link <- file.path(work, "data", "results", "sbsr2027", "split-location", "inputs", "labelled_samples.rds")
    target <- Sys.readlink(link)
    expect_true(nzchar(target))
    expect_false(startsWith(target, "/"))
    expect_equal(unname(tools::md5sum(link)), unname(tools::md5sum(file.path(inputs, "labelled_samples.rds"))))
    # the source folder holds no link to itself
    expect_equal(Sys.readlink(file.path(inputs, "labelled_samples.rds")), "")
})

test_that("the experiment script stops on a missing split and names make_splits.R", {
    old <- setwd(work)
    on.exit(setwd(old))
    log <- suppressWarnings(system2(
        "Rscript", c(experiment, "3", "1", "ts_mlp", file.path(inputs, "labelled_samples.rds"), "1"),
        stdout = TRUE, stderr = TRUE
    ))
    expect_false(is.null(attr(log, "status")))
    expect_true(any(grepl("round_03_split.rds is missing; write it with analysis/sbsr2027/make_splits.R", log)))
    expect_false(dir.exists(file.path(work, "data", "results", "sbsr2027", "split-70-30", "round-01", "split-70-30")))
})
