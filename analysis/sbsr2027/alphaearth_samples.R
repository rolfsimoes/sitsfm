# AlphaEarth samples from the 3 x 3 windows exported by
# earthengine/alphaearth_extract.py in rolfsimoes/sbsr-paper.
# Writes sits samples (parquet) in data/results/alphaearth/samples/:
# labelled and 2018 validation points, centre pixel and 3 x 3 mean,
# image year Y (label year) and Y - 1, one file each.
#
# Each file has the structure of sits_get_data() on
# sits_cube(source = "GOOGLE", collection = "ALPHAEARTH") for one year:
# one row per sample, a time series of one date (1 Jan of the image year),
# bands A00 to A63. Rows follow the source file, so the row number is the
# id of accuracy_learning_curve.R.
#
# Prints a summary and the failed checks; exits with status 1 if a check
# fails. A file is renamed to its final name only if its checks pass.
#
# Optional argument: sets, e.g.
#   Rscript analysis/sbsr2027/alphaearth_samples.R validation2018
library(sits)
library(glue)

args <- commandArgs(trailingOnly = TRUE)
sets <- c("labelled", "validation2018")
if (length(args) >= 1) sets <- strsplit(args[[1]], ",")[[1]]
stopifnot(all(sets %in% c("labelled", "validation2018")))

ae_dir <- fs::path("data/results/alphaearth")
out_dir <- fs::dir_create(ae_dir / "samples")
bands <- sprintf("A%02d", 0:63)
failed <- character(0)
check <- function(ok, what) {
  if (!isTRUE(ok)) {
    failed <<- c(failed, what)
    writeLines(glue("FAIL {what}"))
  }
  isTRUE(ok)
}

#
# 1. Source samples, in the order that gives the ids
#
read_source <- function(set) {
  if (set == "labelled") {
    # the copy saved by the learning curve is the one its splits come from
    readRDS("data/results/sbsr2027/split-70-30/inputs/labelled_samples.rds")
  } else {
    sits_from_parquet("data/validation/validation_data_2018.parquet")
  }
}
points_file <- c(labelled = "points.csv", validation2018 = "validation_points.csv")
tags <- list(
  labelled = c(y = "labelled", ym1 = "labelled_ym1"),
  validation2018 = c(y = "val2018", ym1 = "val2018_ym1")
)
year_shift <- c(y = 0L, ym1 = -1L)

#
# 2. Read the windows of one export
#
# each band is a 3 x 3 array as text; read by rows, the centre is the 5th value
parse_band <- function(text) {
  values <- as.numeric(strsplit(gsub("[][ ]", "", paste(text, collapse = ",")), ",", fixed = TRUE)[[1]])
  stopifnot(length(values) == 9 * length(text), !anyNA(values))
  matrix(values, ncol = 9, byrow = TRUE)
}
read_chunk <- function(file) {
  tbl <- data.table::fread(file, colClasses = list(character = bands), showProgress = FALSE)
  n <- nrow(tbl)
  # win[i, k, b]: band b of pixel k in the window of row i
  win <- array(0, dim = c(n, 9, length(bands)))
  for (b in seq_along(bands)) win[, , b] <- parse_band(tbl[[bands[[b]]]])
  sq_norm <- rowSums(win^2, dims = 2)
  # a pixel with no data comes as a zero vector, so it is left out of the mean
  valid <- sq_norm > 0
  total <- matrix(0, n, length(bands))
  for (k in 1:9) total <- total + win[, k, ] * valid[, k]
  mean <- total / rowSums(valid)
  list(
    id = tbl[["id"]], px_lon = tbl[["px_lon"]], px_lat = tbl[["px_lat"]],
    n_valid = rowSums(valid),
    # a pixel with data should be a unit vector
    odd_pixels = sum(valid & abs(sqrt(sq_norm) - 1) > 0.05),
    centre = win[, 5, ],
    mean = mean / sqrt(rowSums(mean^2))
  )
}
read_export <- function(tag) {
  files <- fs::dir_ls(ae_dir / tag, regexp = "_c[0-9]{3}[.]csv$")
  chunks <- purrr::map(files, read_chunk)
  list(
    id = unlist(purrr::map(chunks, "id")),
    px_lon = unlist(purrr::map(chunks, "px_lon")),
    px_lat = unlist(purrr::map(chunks, "px_lat")),
    n_valid = unlist(purrr::map(chunks, "n_valid")),
    odd_pixels = sum(unlist(purrr::map(chunks, "odd_pixels"))),
    centre = do.call(rbind, purrr::map(chunks, "centre")),
    mean = do.call(rbind, purrr::map(chunks, "mean"))
  )
}

#
# 3. One row per id: a point in two overlapping tiles has two rows;
#    keep the complete window, then the centre nearest to the point
#
select_rows <- function(export, points) {
  pt <- match(export$id, points$id)
  # distance in metres, enough to rank two pixels of one point
  dx <- (export$px_lon - points$longitude[pt]) * cos(points$latitude[pt] * pi / 180) * 111320
  dy <- (export$px_lat - points$latitude[pt]) * 110540
  dist <- sqrt(dx^2 + dy^2)
  ord <- order(export$id, export$n_valid < 9, dist)
  keep <- ord[!duplicated(export$id[ord])]
  # row of each point, in the order of the points
  list(
    rows = keep[match(points$id, export$id[keep])],
    repeated = sum(duplicated(export$id)),
    unknown = sum(is.na(pt))
  )
}

#
# 4. sits samples as sits_get_data() returns them
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
    cube = "ALPHAEARTH",
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
# 5. Build, check and write the files of each set
#
# the 1,000 pilot points of 2018, read with another parser
pilot <- read.csv(ae_dir / "alphaearth_pilot_2018.csv", colClasses = "character")
pilot_centre <- sapply(bands, function(b) {
  jsonlite::fromJSON(paste0("[", paste(pilot[[b]], collapse = ","), "]"))[, 2, 2]
})
pilot_id <- as.integer(pilot[["id"]])

for (set in sets) {
  source <- read_source(set)
  points <- read.csv(ae_dir / points_file[[set]])
  writeLines(glue("{set}: source rows {nrow(source)}, points {nrow(points)}"))
  check(identical(points$id, seq_len(nrow(source))), glue("{set} point ids are the source row numbers"))
  coord_diff <- max(abs(c(points$longitude - source$longitude, points$latitude - source$latitude)))
  check(coord_diff < 1e-9, glue("{set} point coordinates equal the source ({coord_diff})"))
  label_year <- as.integer(format(as.Date(source[["end_date"]]), "%Y"))
  for (shift in names(tags[[set]])) {
    tag <- tags[[set]][[shift]]
    export <- read_export(tag)
    sel <- select_rows(export, points)
    rows <- sel$rows
    missing <- sum(is.na(rows))
    incomplete <- sum(export$n_valid[rows] < 9, na.rm = TRUE)
    writeLines(glue("{tag}: export rows {length(export$id)}, repeated {sel$repeated}, unknown ids {sel$unknown}, missing ids {missing}"))
    writeLines(glue("{tag}: incomplete windows used in the mean {incomplete}, pixels with data whose norm is not near 1: {export$odd_pixels}"))
    check(sel$unknown == 0, glue("{tag} no unknown id"))
    check(missing == 0, glue("{tag} no missing id"))
    if (missing > 0) next
    for (reading in c("centre", "mean")) {
      values <- export[[reading]][rows, , drop = FALSE]
      norm <- sqrt(rowSums(values^2))
      writeLines(glue("{tag} {reading}: norm min {sprintf('%.6f', min(norm))} max {sprintf('%.6f', max(norm))}"))
      if (reading == "centre") {
        check(all(norm >= 0.99 & norm <= 1.01), glue("{tag} centre norms in [0.99, 1.01]"))
      } else {
        check(all(abs(norm - 1) <= 1e-9), glue("{tag} mean norms equal 1"))
      }
      if (set == "labelled" && shift == "y" && reading == "centre") {
        pilot_diff <- max(abs(values[pilot_id, ] - pilot_centre))
        writeLines(glue("{tag} centre: max abs difference to the pilot {pilot_diff}"))
        check(pilot_diff == 0, glue("{tag} centre equals the pilot centre"))
      }
      samples <- as_samples(source, values, label_year + year_shift[[shift]])
      check(nrow(samples) == nrow(source), glue("{tag} {reading} rows equal source rows"))
      file <- out_dir / glue("alphaearth_{set}_{reading}_{shift}.parquet")
      if (write_samples(samples, file)) {
        writeLines(glue("{fs::path_file(file)}: {nrow(samples)} rows, {format(fs::file_size(file))}"))
      }
    }
  }
}
writeLines(glue("checks failed: {length(failed)}"))
if (length(failed) > 0) quit(status = 1)
