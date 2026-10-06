# Example of embeddings cube classification using VICReg encoder
#
library(sits)
library(glue)
set.seed(1524)
model <- "btwins"

batch_size <- NULL
block_size <- NULL
if (torch::cuda_is_available()) {
  batch_size <- 1000 * 1000
  block_size <- c(nrows = 512, ncols = 2048)
}

#
#  1. Load the embeddings cube
#
cube_raster_dir <- glue::glue("data/embeddings/embeddings/{model}/emb_2018")
dir.create(cube_raster_dir, recursive = TRUE, showWarnings = FALSE)

cube_raster <- sits_from_hf(
  repo = glue::glue("e-sensing/cerrado_emb_ssl_{model}_tcnn_2018"),
  type = "dataset",
  output_dir = cube_raster_dir,
  multicores = 20
)

#
# 2. Get encoder
#

model_dir <- fs::dir_create(glue::glue(
  "data/embeddings/embeddings/{model}/encoder"
))
model_file <- model_dir / glue::glue("{model}.rds")

if (!fs::file_exists(model_file)) {
  encoder <- sits_from_hf(
    repo = "e-sensing/encoders_cerrado",
    file = glue::glue("ssl_{model}_tcnn_model_2017_2024.rds"),
    type = "model"
  )

  saveRDS(encoder, model_file)
}

encoder <- readRDS(model_file)

#
# 3. Load the samples
#
labelled_samples <- sits_from_hf(
  repo = "e-sensing/samples_cerrado",
  file = "labelled_samples_cerrado.parquet",
  type = "dataset"
)
#
# 4. Recover the cerrado limits
#
cerrado_limits <- "inst/extdata/cerrado_limits/cerrado_limits.gpkg"
cerrado_limits <- sf::st_read(cerrado_limits)

#
#  5. Recover validation data
#
validation_data <- sits_from_hf(
  repo = "e-sensing/samples_cerrado",
  file = "validation_data_2018.parquet",
  type = "dataset"
)
validation_data[["start_date"]] <- as.Date("2017-01-01")

#
# Extract embeddings vlaues
#
embedding_values <- sits_get_data(
    cube_raster,
    validation_data,
    multicores = 20
)

#
#  6. Loop in fraction of samples
#
fractions <- c(0.05, 0.1, 0.15, 0.20, 0.25, 0.5, 0.75, 1.0)

results <- purrr::map(fractions, function(frac) {
  labelled_samples_red <- sits_sample(labelled_samples, frac = frac)

  #
  # Encode the samples
  #
  samples_enc <- sits_encode(
    data = labelled_samples_red,
    encoder = encoder,
    multicores = 20,
    gpu_memory = 80,
    batch_size = batch_size,
    verbose = TRUE
  )

  #
  # Create a directory to store results
  #
  dest_dir <- glue::glue(
    "data/results/{model}/{model}_2018_class_",
    round(frac, 2)
  )
  dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
  #
  # Build an MLP model for classification
  #
  dest_dir_mlp <- fs::dir_create(dest_dir, "models")
  dir.create(dest_dir_mlp, recursive = TRUE, showWarnings = FALSE)
  model_file <- dest_dir_mlp / glue::glue("mlp_{model}.rds")
  if (!fs::file_exists(model_file)) {
    mlp_model <- sits_train(
      samples = samples_enc,
      ml_method = sits_mlp(
        min_delta = 0.005,
        epochs = 150,
        batch_size = 128,
        verbose = TRUE
      )
    )
    saveRDS(mlp_model, dest_dir_mlp / glue::glue("mlp_{model}.rds"))
  } else {
    mlp_model <- readRDS(model_file)
  }

  #
  # Generate points probabilities
  #
  probs_pts <- sits_classify(
    data = embedding_values,
    ml_model = mlp_model,
    memsize = 250,
    multicores = 20,
    gpu_memory = 80,
    batch_size = batch_size,
    block_size = block_size,
    progress = TRUE,
    verbose = TRUE
  )

  #
  #  Measure accuracy
  #
  acc <- sits_accuracy(
    data = probs_pts,
    validation = embedding_values,
    method = "pixel"
  )
  acc$name <- glue::glue("{model}_{round(frac,2)}")

  # include accuracy in results list
  acc
})

#
# 14.Save to xlsx file
#
saveRDS(results, glue::glue("data/results/{model}/acc_pts_{model}.rds"))

sits_to_xlsx(
  results,
  file = glue::glue("data/benchmarks_2018/acc_pts_{model}.xlsx")
)
