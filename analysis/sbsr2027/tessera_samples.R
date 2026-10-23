# TESSERA samples from the vectors read at the sample points (TESSERA v1.1,
# variant dclimate, 128 dimensions, the 10 m pixel that contains the point),
# one parquet per set and year in data/results/alphaearth/tessera/
# (tessera_SET_YEAR.parquet: id, longitude, latitude, year, status, T000 to
# T127). Writes sits samples (parquet) in data/results/alphaearth/tessera/samples/,
# labelled and 2018 validation points, two versions each:
#   y        the vector as read (not unit length; norms about 5 to 51)
#   unit_y   the vector divided by its L2 norm, unit length as AlphaEarth
# The image year is the label year Y.
#
# Each file has the structure of the AlphaEarth samples of
# alphaearth_samples.R: one row per sample, a time series of one date
# (1 Jan of the image year), bands T000 to T127. Rows follow the points of
# alphaearth_points.R, so the row number is the id of accuracy_learning_curve.R.
# A point with no TESSERA data has NaN values; it gets a zero vector, as a
# pixel with no data in the AlphaEarth export, and is counted.
#
# Prints a summary and the failed checks; exits with status 1 if a check
# fails. A file is renamed to its final name only if its checks pass.
#
# Optional arguments: sets, and a number of points for a check ("all", the
# default). A check takes evenly spaced points and every point with no data,
# and writes to data/results/alphaearth/tessera/samples_check/, e.g.
#   Rscript analysis/sbsr2027/tessera_samples.R
#   Rscript analysis/sbsr2027/tessera_samples.R labelled,validation2018 300
library(sits)
library(glue)

args <- commandArgs(trailingOnly = TRUE)
sets <- c("labelled", "validation2018")
limit <- "all"
if (length(args) >= 1) sets <- strsplit(args[[1]], ",")[[1]]
if (length(args) >= 2) limit <- args[[2]]
stopifnot(all(sets %in% c("labelled", "validation2018")))
stopifnot(limit == "all" || grepl("^[0-9]+$", limit))

ae_dir <- fs::path("data/results/alphaearth")
tessera_dir <- ae_dir / "tessera"
# the subset of a check never replaces the files for Hugging Face
out_dir <- fs::dir_create(tessera_dir / if (limit == "all") "samples" else "samples_check")
bands <- sprintf("T%03d", 0:127)
failed <- character(0)
check <- function(ok, what) {
  if (!isTRUE(ok)) {
    failed <<- c(failed, what)
    writeLines(glue("FAIL {what}"))
  }
  isTRUE(ok)
}

#
# 1. Source: label and coordinates of each id
#
# labelled_samples.rds of the server is not loaded here; the AlphaEarth file
# holds its labels and coordinates in its row order
source_file <- c(
  labelled = ae_dir / "samples" / "alphaearth_labelled_centre_y.parquet",
  validation2018 = fs::path("data/validation/validation_data_2018.parquet")
)
points_file <- c(labelled = "points.csv", validation2018 = "validation_points.csv")
read_source <- function(set) {
  cols <- c("sample:id", "longitude", "latitude", "label")
  as.data.frame(arrow::read_parquet(source_file[[set]], col_select = dplyr::all_of(cols)))
}

#
# 2. TESSERA vectors of one set, all years, in the order of the points
#
read_tessera <- function(set, points) {
  files <- fs::dir_ls(tessera_dir, regexp = glue("/tessera_{set}_[0-9]{{4}}[.]parquet$"))
  tbl <- dplyr::bind_rows(purrr::map(files, function(file) as.data.frame(arrow::read_parquet(file))))
  writeLines(glue("{set}: TESSERA files {length(files)}, rows {nrow(tbl)}"))
  check(identical(names(tbl), c("id", "longitude", "latitude", "year", "status", bands)), glue("{set} TESSERA columns"))
  check(!anyDuplicated(tbl$id), glue("{set} TESSERA ids unique"))
  check(setequal(tbl$id, points$id), glue("{set} TESSERA ids equal the point ids"))
  tbl <- tbl[match(points$id, tbl$id), ]
  check(identical(as.integer(tbl$year), as.integer(points$label_year)), glue("{set} TESSERA year equals the label year"))
  coord_diff <- max(abs(c(tbl$longitude - points$longitude, tbl$latitude - points$latitude)))
  check(coord_diff < 1e-9, glue("{set} TESSERA coordinates equal the points ({coord_diff})"))
  values <- as.matrix(tbl[bands])
  valid <- tbl$status == "valid"
  check(all(is.finite(values[valid, ])), glue("{set} valid rows are finite"))
  check(all(is.nan(values[!valid, ])), glue("{set} rows with no data are NaN"))
  by_status <- table(tbl$status)
  writeLines(glue("{set}: status {names(by_status)} {as.vector(by_status)}"))
  for (year in sort(unique(tbl$year))) {
    writeLines(glue("{set} {year}: rows {sum(tbl$year == year)}, not valid {sum(tbl$year == year & !valid)}"))
  }
  list(values = values, valid = valid, year = as.integer(tbl$year))
}

#
# 3. sits samples, as alphaearth_samples.R writes them
#
as_samples <- function(source, values, image_year) {
  date <- as.Date(glue("{image_year}-01-01"))
  n <- nrow(source)
  colnames(values) <- bands
  flat <- tibble::tibble(
    row = seq_len(n),
    longitude = source[["longitude"]],
    latitude = source[["latitude"]],
    start_date = date,
    end_date = date,
    label = unname(source[["label"]]),
    cube = "TESSERA",
    Index = date
  )
  flat <- dplyr::bind_cols(flat, tibble::as_tibble(values))
  # the row column keeps samples with equal metadata apart
  samples <- tidyr::nest(flat, time_series = dplyr::all_of(c("Index", bands)))
  samples[["row"]] <- NULL
  class(samples) <- c("sits", "tbl_df", "tbl", "data.frame")
  samples
}
same_samples <- function(a, b) {
  identical(class(a), class(b)) &&
    identical(names(a), names(b)) &&
    identical(as.data.frame(a[names(a) != "time_series"]), as.data.frame(b[names(b) != "time_series"])) &&
    identical(as.data.frame(dplyr::bind_rows(unname(a$time_series))), as.data.frame(dplyr::bind_rows(unname(b$time_series))))
}
write_samples <- function(samples, file) {
  tmp_file <- sub("[.]parquet$", ".tmp.parquet", file)
  if (fs::file_exists(tmp_file)) fs::file_delete(tmp_file)
  sits_to_parquet(samples, tmp_file)
  ok <- check(same_samples(samples, sits_from_parquet(tmp_file)), glue("{fs::path_file(file)} read back equals written"))
  if (ok) fs::file_move(tmp_file, file)
  ok
}

#
# 4. Build, check and write the two versions of each set
#
for (set in sets) {
  source <- read_source(set)
  points <- read.csv(ae_dir / points_file[[set]])
  writeLines(glue("{set}: source rows {nrow(source)}, points {nrow(points)}"))
  check(identical(as.integer(source[["sample:id"]]), seq_len(nrow(source))), glue("{set} source rows in id order"))
  check(identical(points$id, seq_len(nrow(source))), glue("{set} point ids are the source row numbers"))
  coord_diff <- max(abs(c(points$longitude - source$longitude, points$latitude - source$latitude)))
  check(coord_diff < 1e-9, glue("{set} point coordinates equal the source ({coord_diff})"))
  tessera <- read_tessera(set, points)
  rows <- seq_len(nrow(source))
  if (limit != "all") {
    rows <- sort(union(round(seq(1, nrow(source), length.out = as.integer(limit))), which(!tessera$valid)))
    writeLines(glue("{set}: check on {length(rows)} rows, {sum(!tessera$valid[rows])} with no data"))
  }
  valid <- tessera$valid[rows]
  raw <- tessera$values[rows, , drop = FALSE]
  raw[!valid, ] <- 0
  norm <- sqrt(rowSums(raw^2))
  unit <- raw / ifelse(valid, norm, 1)
  writeLines(glue("{set} y: norm min {sprintf('%.3f', min(norm[valid]))} max {sprintf('%.3f', max(norm[valid]))}, zero vectors {sum(!valid)}"))
  check(identical(raw[valid, ], tessera$values[rows, , drop = FALSE][valid, ]), glue("{set} y equals the TESSERA values"))
  unit_norm <- sqrt(rowSums(unit^2))
  check(all(abs(unit_norm[valid] - 1) <= 1e-9), glue("{set} unit_y norms equal 1"))
  check(all(unit[!valid, ] == 0), glue("{set} unit_y rows with no data are zero"))
  for (version in c("y", "unit_y")) {
    values <- if (version == "y") raw else unit
    check(!anyNA(values), glue("{set} {version} has no NA"))
    samples <- as_samples(source[rows, ], values, tessera$year[rows])
    check(nrow(samples) == length(rows), glue("{set} {version} rows equal source rows"))
    check(identical(unname(samples$label), unname(source$label[rows])), glue("{set} {version} labels equal the source"))
    file <- out_dir / glue("tessera_{set}_{version}.parquet")
    if (write_samples(samples, file)) {
      writeLines(glue("{fs::path_file(file)}: {nrow(samples)} rows, {format(fs::file_size(file))}"))
    }
  }
}
writeLines(glue("checks failed: {length(failed)}"))
if (length(failed) > 0) quit(status = 1)
