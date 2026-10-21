# Landsat time series of the 24,000 validation points of 2018
# (data/validation/validation_data_2018.parquet), read from the monthly
# Landsat cubes of 2017 and 2018 on the server, so that every method of
# the learning curve can be evaluated on them. The series have the 24 dates
# and 10 bands of the labelled samples, which come from the same cubes.
#
# Mode "check" (the default) reads 3 labelled samples of 2018 from the
# cubes and compares them with the stored values; it writes nothing and
# exits with status 1 if a value differs. Mode "all" writes
# data/results/validation_2018/validation_series_2018.rds, rows in the
# order of the parquet file.
#
# Optional arguments: mode, cubes folder, multicores, e.g.
#   Rscript analysis/validation_series_2018.R check
#   Rscript analysis/validation_series_2018.R all ~/rascunho-gpu/biomasbr-sits/cerrado/cubes 16
library(sits)
library(glue)

args <- commandArgs(trailingOnly = TRUE)
mode <- "check"
cubes_dir <- "~/rascunho-gpu/biomasbr-sits/cerrado/cubes"
multicores <- 16
if (length(args) >= 1) mode <- args[[1]]
if (length(args) >= 2) cubes_dir <- args[[2]]
if (length(args) >= 3) multicores <- as.integer(args[[3]])
stopifnot(mode %in% c("check", "all"))

#
# 1. Cubes of 2017 and 2018 (file names LANDSAT_OLI_<tile>_<band>_<date>.tif)
#
years <- c(2017, 2018)
cubes <- purrr::map(years, function(year) {
  sits_cube(
    source = "BDC",
    collection = "LANDSAT-OLI-16D",
    data_dir = path.expand(fs::path(cubes_dir, year)),
    progress = FALSE
  )
})

# The two years are read apart and joined, one row per point in input order
get_series <- function(points) {
  per_year <- purrr::map2(cubes, years, function(cube, year) {
    points[["start_date"]] <- as.Date(glue("{year}-01-01"))
    points[["end_date"]] <- as.Date(glue("{year}-12-31"))
    values <- sits_get_data(cube, points, multicores = multicores, progress = FALSE)
    # sits_get_data does not keep the input order
    key <- function(x) paste(round(x[["longitude"]], 7), round(x[["latitude"]], 7))
    row <- match(key(points), key(values))
    if (anyNA(row)) {
      stop(glue("{sum(is.na(row))} points of {year} have no values"))
    }
    values[["time_series"]][row]
  })
  points[["start_date"]] <- as.Date(glue("{years[[1]]}-01-01"))
  points[["end_date"]] <- as.Date(glue("{years[[2]]}-12-31"))
  points[["time_series"]] <- purrr::map2(per_year[[1]], per_year[[2]], dplyr::bind_rows)
  points
}

#
# 2. Check: 3 labelled samples of 2018 against their stored values
#
if (mode == "check") {
  samples <- readRDS("data/results/learning_curve/labelled_samples.rds")
  samples <- samples[format(samples[["end_date"]], "%Y") == "2018", ]
  set.seed(7)
  samples <- samples[sample(nrow(samples), 3), ]
  extracted <- get_series(samples[, c("longitude", "latitude", "label")])
  failed <- FALSE
  for (i in seq_len(nrow(samples))) {
    stored <- samples[["time_series"]][[i]]
    read <- extracted[["time_series"]][[i]]
    bands <- setdiff(names(stored), "Index")
    same_dates <- identical(as.Date(stored[["Index"]]), as.Date(read[["Index"]]))
    diff <- if (same_dates && all(bands %in% names(read))) {
      max(abs(as.matrix(stored[, bands]) - as.matrix(read[, bands])))
    } else {
      NA
    }
    message(glue(
      "sample {i} ({samples$label[[i]]}): {nrow(stored)} dates stored, {nrow(read)} read, ",
      "same dates {same_dates}, {length(bands)} bands, max abs difference {signif(diff, 3)}"
    ))
    failed <- failed || is.na(diff) || diff > 1e-6
  }
  if (failed) {
    quit(status = 1)
  }
  quit(status = 0)
}

#
# 3. All validation points
#
points <- arrow::read_parquet("data/validation/validation_data_2018.parquet")
points <- tibble::as_tibble(points[, c("longitude", "latitude", "label")])
started <- Sys.time()
series <- get_series(points)
n_dates <- purrr::map_int(series[["time_series"]], nrow)
n_na <- sum(purrr::map_lgl(series[["time_series"]], function(ts) anyNA(ts)))
message(glue(
  "{nrow(series)} points, dates per point {paste(unique(n_dates), collapse = ',')}, ",
  "points with NA {n_na}, {round(difftime(Sys.time(), started, units = 'mins'), 1)} min"
))
out_dir <- fs::dir_create("data/results/validation_2018")
out_file <- out_dir / "validation_series_2018.rds"
saveRDS(series, glue("{out_file}.tmp"))
fs::file_move(glue("{out_file}.tmp"), out_file)
message(glue("written {out_file}"))
