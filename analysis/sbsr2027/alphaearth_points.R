# Points of the labelled samples for the AlphaEarth extraction.
# Writes id, longitude, latitude and label_year of each sample to
# data/results/alphaearth/points.csv, and prints a summary of the points.
#
# The id is the row number of the labelled samples, as in
# accuracy_learning_curve.R, so the AlphaEarth vectors match its splits.
# A "2017/2018" sample is labelled with its final year, 2018.
#
#   Rscript analysis/sbsr2027/alphaearth_points.R
library(sits)
library(glue)

#
# 1. Load the samples as accuracy_learning_curve.R does
#
# the copy saved by the learning curve is the one its splits come from
samples_file <- fs::path("data/results/sbsr2027/split-70-30/inputs/labelled_samples.rds")
if (!fs::file_exists(samples_file)) {
  fs::dir_create(fs::path_dir(samples_file))
  hf_samples <- sits_from_hf(
    repo = "e-sensing/samples_cerrado",
    file = "labelled_samples_cerrado.parquet",
    type = "dataset"
  )
  saveRDS(hf_samples, glue("{samples_file}.tmp"))
  fs::file_move(glue("{samples_file}.tmp"), samples_file)
}
samples <- readRDS(samples_file)
samples[["id"]] <- seq_len(nrow(samples))

#
# 2. Write the points
#
points <- data.frame(
  id = samples[["id"]],
  longitude = samples[["longitude"]],
  latitude = samples[["latitude"]],
  label_year = as.integer(format(as.Date(samples[["end_date"]]), "%Y"))
)
points_dir <- fs::dir_create("data/results/alphaearth")
points_file <- points_dir / "points.csv"
write.csv(points, glue("{points_file}.tmp"), row.names = FALSE)
fs::file_move(glue("{points_file}.tmp"), points_file)

#
# 3. Summary of the points
#
writeLines(glue("rows: {nrow(points)}"))
writeLines(glue("labels: {length(unique(samples[['label']]))}"))
writeLines(glue("NA longitude: {sum(is.na(points$longitude))}"))
writeLines(glue("NA latitude: {sum(is.na(points$latitude))}"))
writeLines(glue("NA label_year: {sum(is.na(points$label_year))}"))
lon <- range(points$longitude, na.rm = TRUE)
lat <- range(points$latitude, na.rm = TRUE)
writeLines(glue("longitude range: {lon[[1]]} {lon[[2]]}"))
writeLines(glue("latitude range: {lat[[1]]} {lat[[2]]}"))
# each sample covers two years, so the start year is label_year - 1
start_year <- as.integer(format(as.Date(samples[["start_date"]]), "%Y"))
writeLines(glue("start year not label_year - 1: {sum(start_year != points$label_year - 1, na.rm = TRUE)}"))
by_year <- table(points$label_year, useNA = "ifany")
for (year in names(by_year)) {
  writeLines(glue("label_year {year}: {by_year[[year]]}"))
}
by_label <- table(samples[["label"]], useNA = "ifany")
for (label in names(by_label)) {
  writeLines(glue("label {label}: {by_label[[label]]}"))
}

#
# 4. Points of the 2018 validation set, id = row number of the parquet
#
validation <- arrow::read_parquet("data/validation/validation_data_2018.parquet")
val_points <- data.frame(
  id = seq_len(nrow(validation)),
  longitude = validation[["longitude"]],
  latitude = validation[["latitude"]],
  label_year = as.integer(format(as.Date(validation[["end_date"]]), "%Y"))
)
val_file <- points_dir / "validation_points.csv"
write.csv(val_points, glue("{val_file}.tmp"), row.names = FALSE)
fs::file_move(glue("{val_file}.tmp"), val_file)
writeLines(glue("validation rows: {nrow(val_points)}"))
writeLines(glue("validation NA coordinates: {sum(is.na(val_points$longitude) | is.na(val_points$latitude))}"))
by_year <- table(val_points$label_year, useNA = "ifany")
for (year in names(by_year)) {
  writeLines(glue("validation label_year {year}: {by_year[[year]]}"))
}
