## sitsfm Package

**Scripts for testing foundational models in SITS**

This package contains scripts for running foundational models using the `sits` package. For more details, please refer to the section on embeddings in the 
[on-line book about `sits`](https://e-sensing.github.io/sitsbook/).

## Content of the scripts 

The scripts can be found in the `analysis` directory. All data necessary 
to run them in on Hugging Face. The results of each step are also available
in Hugging Face. 

1. `generate_ssl_encoders.R`: reads a set of samples and produces 
foundational models for the MAE, LeJEPA, VICReg, and Barlow Twins encoders
using self-supervised learning.

2. `generate_embeddings_cube_2018.R`: takes a two year Landsat-8 data cube
covering the Cerrado biome in Brazil from `2017-01-01` to `2018-12-31`
and generates embeddings cubes using
the MAE, LeJEPA, VICReg, and Barlow Twins encoders produced in step 1. 

3. `generate_embeddings_cube_2024.R`: takes a two year Landsat-8 data cube
covering the Cerrado biome in Brazil from `2023-01-01` to `2024-12-31`
and generates embeddings cubes using
the MAE, LeJEPA, VICReg, and Barlow Twins encoders produced in step 1.

4. `create_validation_points.R`: uses the result of classifications
produced using time series algorithms on data cubes (no embeddings)
combining agricultural classes produced by analysis using Sentinel-2 images
with natural cover classes using Landsat-8 from the period 2018 to 2024.
The resulting validation points are an approximation to a validation data
set that is used to assess the accuracy of the classification of the
embeddings cube.

5. `classify_vicreg_cube.R`: example of classification of an embeddings cube
using a set of labelled training samples and validated with the data set
produced in step 4. These data sets are independent. 

6. `accuracy_alpha_earth_2018.R`: use the validation points produced in 
step 4 to measure the accuracy of the classification of the Alpha Earth
embeddings for year 2018. This classification has been done using the
same set of labelled samples used in step 5. 

7. `accuracy_learning_curve.R`: measures which method reaches a given
accuracy with fewer training samples. It compares the LeJEPA, VICReg and
Barlow Twins encoders, frozen, each with an MLP trained on its embeddings,
against an MLP and a TempCNN trained on the raw time series. Each round
draws a new split of the labelled samples, 30% of each class for
validation and 70% for training, and trains every method on the same
nested fractions of the 70%. Each round, method and fraction is one task
with its own CSV (`round_RR_METHOD_fFFF.csv` in
`data/results/learning_curve`): overall accuracy, kappa, F1 per class and
run time. A task whose CSV is complete is skipped, so a run can be resumed,
and tasks run in parallel workers. To stop a run without losing the
tasks in progress, create `data/results/learning_curve/STOP`: the workers
skip the tasks not started; remove the file before the next run. Optional arguments are the number of
rounds, the fractions, the methods, the samples (`hf`: the labelled
samples on Hugging Face) and the number of workers; a stage run of one
round, two fractions, one encoder and the TempCNN on the raw time series,
in 4 workers:

```
Rscript analysis/accuracy_learning_curve.R 1 0.05,1 btwins,ts_tempcnn hf 4
```

8. `summary_learning_curve.R`: reads the result files of step 7 and writes,
in `data/results/learning_curve/summary`, the mean and standard deviation
over rounds of each method and fraction (overall accuracy, kappa, macro F1,
F1 per class), the paired differences of each method against the MLP on
the raw time series with their 95% interval (the TempCNN is left out of
the report), and two
figures: the learning curve and the paired differences. It works on a run
in progress; `n_rounds` says how many rounds each number uses.

```
Rscript analysis/summary_learning_curve.R
```

## Tests

The test runs the learning curve on the MODIS samples of `sits` and checks
the split, the nested fractions, the result tables, the skip of finished
tasks and that two workers give the results of one. From the repository
root, with temporary files in `tmp/`:

```
mkdir -p tmp
TMPDIR="$PWD/tmp" Rscript -e 'testthat::test_file("tests/testthat/test-accuracy_learning_curve.R")'
```
