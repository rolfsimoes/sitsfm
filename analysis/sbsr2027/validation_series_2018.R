# Landsat time series of the 24,000 validation points of 2018
# (data/validation/validation_data_2018.parquet), read from the monthly
# Landsat cubes of 2017 and 2018 on the server, so that every method of
# the learning curve can be evaluated on them. The series have the 24 dates
# and 10 bands of the labelled samples, which come from the same cubes.
#
# Mode "check" (the default) reads 10 labelled samples of 2018, in 3
# tiles, from the cubes and compares them with the stored values; it writes nothing and
# exits with status 1 if a value differs. Mode "all" writes
# data/results/sbsr2027/val-2018/inputs/validation_series_2018.rds, rows in
# the order of the parquet file.
#
# Optional arguments: mode, cubes folder, multicores, e.g.
#   Rscript analysis/sbsr2027/validation_series_2018.R check
#   Rscript analysis/sbsr2027/validation_series_2018.R all ~/rascunho-gpu/biomasbr-sits/cerrado/cubes 16
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
# 1. Cube of 2017 and 2018 (file names LANDSAT_OLI_<tile>_<band>_<date>.tif)
#
# One cube over both years, as for the labelled samples: sits fills cloud
# gaps along the whole series, so years read apart can differ near January
load_year <- function(year, tiles) {
  sits_cube(
    source = "BDC",
    collection = "LANDSAT-OLI-16D",
    data_dir = path.expand(fs::path(cubes_dir, year)),
    tiles = tiles,
    multicores = multicores,
    progress = FALSE
  )
}

# tile of a point in the BDC_MD_V2 grid, as in the file names
point_tile <- function(lon, lat) {
  roi <- c(lon_min = lon - 1e-4, lat_min = lat - 1e-4, lon_max = lon + 1e-4, lat_max = lat + 1e-4)
  sits_roi_to_tiles(roi = roi, grid_system = "BDC_MD_V2")[["tile_id"]][[1]]
}

# Opening the cube reads every file of the tiles it covers (tiles = NULL:
# all of them)
get_series <- function(points, tiles = NULL) {
  started <- Sys.time()
  cube <- sits_merge(load_year(2017, tiles), load_year(2018, tiles))
  message(glue("cube of {length(cube$tile)} tiles opened in {round(difftime(Sys.time(), started, units = 'mins'), 1)} min"))
  points[["start_date"]] <- as.Date("2017-01-01")
  points[["end_date"]] <- as.Date("2018-12-01")
  values <- sits_get_data(cube, points, multicores = multicores, progress = FALSE)
  # sits_get_data does not keep the input order
  key <- function(x) paste(round(x[["longitude"]], 7), round(x[["latitude"]], 7))
  row <- match(key(points), key(values))
  if (anyNA(row)) {
    stop(glue("{sum(is.na(row))} points have no values"))
  }
  values[row, ]
}

#
# 2. Check: 10 labelled samples of 2018 in 3 tiles against their stored values
#
if (mode == "check") {
  samples <- readRDS("data/results/sbsr2027/split-70-30/inputs/labelled_samples.rds")
  samples <- samples[format(samples[["end_date"]], "%Y") == "2018", ]
  # 10 samples from 3 tiles: each tile opened costs its thousands of files
  set.seed(7)
  samples <- samples[sample(nrow(samples), 100), ]
  samples[["tile"]] <- purrr::map2_chr(samples[["longitude"]], samples[["latitude"]], point_tile)
  tiles <- names(sort(table(samples[["tile"]]), decreasing = TRUE))[1:3]
  samples <- samples[samples[["tile"]] %in% tiles, ]
  samples <- samples[sample(nrow(samples), min(10, nrow(samples))), ]
  extracted <- get_series(samples[, c("longitude", "latitude", "label")], tiles)
  failed <- FALSE
  for (i in seq_len(nrow(samples))) {
    stored <- samples[["time_series"]][[i]]
    read <- extracted[["time_series"]][[i]]
    bands <- setdiff(names(stored), "Index")
    same_dates <- identical(as.Date(stored[["Index"]]), as.Date(read[["Index"]]))
    if (!same_dates || !all(bands %in% names(read))) {
      message(glue("sample {i}: dates or bands differ"))
      failed <- TRUE
      next
    }
    diff <- abs(as.matrix(stored[, bands]) - as.matrix(read[, bands]))
    # dates where any band differs, to tell gap filling from a changed cube
    by_date <- apply(diff, 1, max)
    differing <- format(as.Date(stored[["Index"]])[by_date > 1e-6], "%Y-%m")
    message(glue(
      "sample {i} ({samples$label[[i]]}): max abs difference {signif(max(diff), 3)}, ",
      "identical values {round(100 * mean(diff <= 1e-6), 1)}%, ",
      "dates that differ: {if (length(differing) == 0) 'none' else toString(differing)}"
    ))
    failed <- failed || max(diff) > 1e-6
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
out_dir <- fs::dir_create("data/results/sbsr2027/val-2018/inputs")
out_file <- out_dir / "validation_series_2018.rds"
saveRDS(series, glue("{out_file}.tmp"))
fs::file_move(glue("{out_file}.tmp"), out_file)
message(glue("written {out_file}"))
