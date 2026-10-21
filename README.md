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
against an MLP and a TempCNN trained on the raw time series. The method
`ae_centre_y` trains the same MLP on AlphaEarth embeddings: the vector of
the 10 m pixel that contains each sample, in the label year, read from the
Hugging Face dataset named by `ae_repo` in the script. It is not in the
default methods, so it runs only when named. Each round
draws a new split of the labelled samples, 30% of each class for
validation and 70% for training, and trains every method on the same
nested fractions of the 70%. The split of each round is saved
(`round_RR_split.rds`); a later run reads it and does not draw it again,
and stops if it lacks a fraction asked for. Each round, method and fraction is one task
with its own CSV (`round_RR_METHOD_fFFF.csv` in
`data/results/learning_curve`): overall accuracy, kappa, F1 per class and
run time. A task whose CSV is complete is skipped, so a run can be resumed,
and tasks run in parallel workers. To stop a run without losing the
tasks in progress, create `data/results/learning_curve/STOP`: the workers
skip the tasks not started; remove the file before the next run. Optional arguments are the number of
rounds, the fractions, the methods, the samples (`hf`: the labelled
samples on Hugging Face), the number of workers and the results folder
(default `data/results/learning_curve`; the samples, splits, encoded
samples, task CSVs and STOP file are all read and written there). Each
task trains with its share of the CPU quota as torch threads, divided
among the processes on the GPU. A stage run of one
round, two fractions, one encoder and the TempCNN on the raw time series,
in 4 workers:

```
Rscript analysis/accuracy_learning_curve.R 1 0.05,1 btwins,ts_tempcnn hf 4
```

8. `summary_learning_curve.R`: reads the result files of step 7 and writes,
in `data/results/learning_curve/summary`, the mean and standard deviation
over rounds of each method and fraction (overall accuracy, kappa, macro F1,
F1 per class), the paired differences of each method against the MLP on
the raw time series with their 95% interval, and two
figures: the learning curve and the paired differences. It works on a run
in progress; `n_rounds` says how many rounds each number uses.

```
Rscript analysis/summary_learning_curve.R
```

9. `check_learning_curve.R`: reruns 16 recorded tasks of step 7 (rounds
1 and 2, fractions 5% and 10%, the three encoders and the MLP on the raw
time series, 8 workers) in `data/results/learning_curve_check`, which
links the labelled samples, splits and encoded samples of
`data/results/learning_curve`. It writes the log of the run
(`check.log`) and `comparison.csv` there (accuracy and seconds, recorded
and new) and prints the number of tasks compared, the largest accuracy
difference and the median time ratio; it exits with status 1 if a task
is missing. It writes nothing in `data/results/learning_curve` and
refuses to run while results of an earlier check are in its folder.
Optional arguments are the number of rounds, the fractions, the methods
and the check folder; the second line reruns the two recorded TempCNN
tasks of round 1 at 5% and 10%:

```
Rscript analysis/check_learning_curve.R
Rscript analysis/check_learning_curve.R 1 0.05,0.1 ts_tempcnn data/results/learning_curve_check_tempcnn
```

## Server tools

`server/` holds tools for the server where the learning curve runs; they
are not part of the package. `server/memstat.sh` runs next to a
learning-curve run: every 5 s it samples RAM (`anon` of the cgroup), GPU
memory and use, CPU cores and read rate of the run's processes, and
appends the min, max and mean of each 5 min window, with the count of
finished tasks, as one line to a log. It exits when the run ends. Start it
detached from the repository root, after the run:

```
setsid nohup server/memstat.sh --tasks data/results/learning_curve \
  'ts_tempcnn_f[0-9]{3}[.]csv$' data/results/learning_curve/memstat.log \
  > /dev/null 2>&1 < /dev/null &
```

To read the last window as a key-value card, with an end estimate from
the task rate when the number of tasks of the run is given:

```
server/memstat.sh --card --total 80 data/results/learning_curve/memstat.log
```

`server/memstat.sh --help` lists the options.

## Tests

The test runs the learning curve on the MODIS samples of `sits` and checks
the split, the nested fractions, the result tables, the skip of finished
tasks, that two workers give the results of one and train with the torch
threads of their task, that a saved split is read and not rewritten, and
that the results folder argument moves every file. From the repository
root, with temporary files in `tmp/`:

```
mkdir -p tmp
TMPDIR="$PWD/tmp" Rscript -e 'testthat::test_file("tests/testthat/test-accuracy_learning_curve.R")'
```
