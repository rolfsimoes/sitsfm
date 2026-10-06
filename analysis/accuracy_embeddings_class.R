# Example of embeddings cube classification using VICReg encoder
#
library(sits)
library(glue)
set.seed(1524)
model <- "lejepa"

batch_size <- NULL
block_size <- NULL
if (torch::cuda_is_available()) {
    batch_size <- 1000*1000
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

model_dir <- fs::dir_create(glue::glue("data/embeddings/embeddings/{model}/encoder"))
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
        dest_dir <- glue::glue("data/results/{model}/{model}_2018_class_", round(frac,2))
        dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
        #
        # Build an MLP model for classification
        #
        mlp_model <- sits_train(
            samples = samples_enc,
            ml_method = sits_mlp(
                min_delta = 0.005,
                epochs = 150,
                batch_size = 128,
                verbose = TRUE
            )
        )
        dest_dir_mlp <- fs::dir_create(dest_dir, "models")
        dir.create(dest_dir_mlp, recursive = TRUE, showWarnings = FALSE)
        saveRDS(mlp_model, dest_dir_mlp / glue::glue("mlp_{model}.rds"))


        #
        # Generate a Probability cube
        #
        dest_dir_probs <- fs::dir_create(dest_dir, "probs")

        cube_probs <- slider::slide_dfr(cube_raster, function(tile) {
            sits_classify(
                data = tile,
                ml_model = mlp_model,
                roi = cerrado_limits,
                memsize    = 250,
                multicores = 20,
                gpu_memory = 80,
                batch_size = batch_size,
                block_size = block_size,
                output_dir = dest_dir_probs,
                version = paste("version", gsub("\\.", "-", as.character(round(frac,2))), tile[["tile"]], sep = "-"),
                progress = TRUE,
                verbose = TRUE
            )
        })

        #
        # Produce a smoothed cube
        #
        dest_dir_smooth <- fs::dir_create(dest_dir, "smooth")

        cube_smooth <- sits_smooth(
            cube = cube_probs,
            memsize = 200,
            multicores = 20,
            output_dir = dest_dir_smooth,
            progress = TRUE,
            verbose = TRUE,
            version = paste("version", gsub("\\.", "-", as.character(round(frac,2))), sep = "-")
        )

        #
        # Produce a classification map
        #

     
        dest_dir_class <- fs::dir_create(dest_dir, "class")

        cube_class <- sits_label_classification(
            cube_smooth,
            memsize = 200,
            multicores = 20,
            output_dir = dest_dir_class,
            progress = TRUE,
            verbose = TRUE,
            version = paste("version", gsub("\\.", "-", as.character(round(frac,2))), sep = "-")
        )
        #
        #  Measure accuracy
        #
        acc <- sits_accuracy(
            data = cube_class,
            validation = validation_data,
            method = "pixel"
        )
        acc$name <- glue::glue("{model}_{round(frac,2)}")
        
        # include accuracy in results list
        acc
    }
)

#
# 14.Save to xlsx file
#
saveRDS(results, glue::glue("data/results/{model}/acc_{model}.rds"))

sits_to_xlsx(
    results, file = glue::glue("data/benchmarks_2018/acc_{model}.xlsx")
)