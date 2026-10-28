## sitsfm Package

**Scripts for testing foundational models in SITS**

This package contains scripts for running foundational models using the `sits` package. For more details, please refer to the section on embeddings in the 
[on-line book about `sits`](https://e-sensing.github.io/sitsbook/).

## Content of the scripts 

The scripts can be found in the `analysis` directory. All data necessary 
to run them in on Hugging Face. The results of each step are also available
in Hugging Face. The scripts of the SBSR 2027 experiments (steps 7 to 12
and the AlphaEarth scripts) are in `analysis/sbsr2027` and write their
results in `data/results/sbsr2027` (see "Results of the SBSR 2027
experiments" below).

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

7. `sbsr2027/make_splits.R`: draws the train/test split of each round of
an experiment and the nested training fractions, and writes them to
`round-RR/round_RR_split.rds` in the experiment folder; step 8 reads them
and draws nothing. The split of round r comes from random stream r (seed
1524), so the same arguments give the same splits, and an existing split
file is never overwritten. The geometry decides what may not be on both
sides:

   - `random`: 30% of the samples of each class for test, 70% for
     training; these are the recorded splits of `split-70-30`;
   - `location`: 30% of the locations (unique coordinates), stratified by
     the label of the earliest sample of each location; all samples of a
     location are on one side;
   - `block`: square blocks of a given size in degrees, in random order,
     until the test side holds at least 30% of the samples;
   - `year`: round r tests the r-th label year (2018, 2020, 2022, 2024)
     and trains on the other years. The same locations recur in the other
     years, so this measures transfer in time, not spatial independence.

   The training fractions are nested: each class of the training side is
shuffled once, and fraction f takes the first floor(f n) of each class.
Besides the ids, the split file holds the geometry and its counts (test
year, blocks on each side, test samples per class, test and training
sizes); the script prints them, one line per round. It reads the labelled
samples from `data/results/sbsr2027/split-70-30/inputs/` and links every
file of that folder, with relative links, into `inputs/` of the
experiment folder, so step 8 runs there with the same samples and
encoded samples. Optional arguments are the geometry (default `random`),
the experiment folder (default `data/results/sbsr2027/split-GEOMETRY`,
but `split-70-30` for `random`), the number of rounds (default 10; for
`year` at most the number of years), the fractions and the block size
(default 1 degree):

```
Rscript analysis/sbsr2027/make_splits.R
Rscript analysis/sbsr2027/make_splits.R block data/results/sbsr2027/split-block 10
```

8. `sbsr2027/accuracy_learning_curve.R`: measures which method reaches a given
accuracy with fewer training samples. It compares the LeJEPA, VICReg and
Barlow Twins encoders, frozen, each with an MLP trained on its embeddings,
against an MLP and a TempCNN trained on the raw time series. The method
`ae_centre_y` trains the same MLP on AlphaEarth embeddings: the vector of
the 10 m pixel that contains each sample, in the label year, read from the
Hugging Face dataset named by `ae_repo` in the script. The methods
`tessera_y` and `tessera_unit_y` train it on TESSERA embeddings (step 12)
of the label year, read from the dataset named by `tessera_repo`: the
vector as read, and the vector divided by its L2 norm. The methods
`ts_mlp6` and `ts_tempcnn6` are `ts_mlp` and `ts_tempcnn` trained on the
6 reflectance bands (BLUE, GREEN, RED, NIR08, SWIR16, SWIR22) instead of
the 10 bands of the labelled samples: the encoders were pre-trained on
these 6 bands, and `sits_encode()` selects them. The same 6 bands are
selected in the test samples and the 2018 points. These methods are
not in the default methods, so they run only when named. Each round
reads its split from step 7 (`round_RR_split.rds`) and trains every
method on the same nested fractions of the training side; the run stops
if a split file is missing or lacks a fraction asked for. Each round, method and fraction is one task
with its own CSV (`round-RR/split-70-30/round_RR_METHOD_fFFF.csv` in the
results folder): overall accuracy, kappa, F1 per class and
run time. A task whose CSV is complete is skipped, so a run can be resumed,
and tasks run in parallel workers. Each task saves its trained model in
`models/` of its round (`round-RR/models/round_RR_METHOD_fFFF.rds`) with its
metadata (`.json`: task, training seconds, date, sitsfm commit, sits and
torch versions, md5 of the sits files and of the model); a later task reads
the model instead of training if the md5 of the sits files, the sitsfm
commit and the md5 of the model match, and trains it again otherwise, with
the training seconds of the metadata in its run time. To stop a run without losing the
tasks in progress, create `STOP` in the results folder: the workers
skip the tasks not started; remove the file before the next run. Optional arguments are the number of
rounds, the fractions, the methods, the samples (`hf`: the labelled
samples on Hugging Face), the number of workers and the results folder
(default `data/results/sbsr2027/split-70-30`; the samples, splits, encoded
samples, task CSVs, models and STOP file are all there), and the
2018 validation points of step 11 (`none`, the default; `all`; or a number
of evenly spaced points, for a check). With 2018 validation points, each
task also classifies them and writes their metrics in the same format to
`round-RR/val-2018/` in the results folder: overall accuracy (not weighted; the
points are not allocated in proportion to area), kappa, F1 of the 8 classes
of the points, and run time. Predictions of the 3 classes absent from the
points (Mangrove, Nat_NonVeg, Water) count as errors. The predicted class
of each point goes to `round-RR/val-2018/round_RR_METHOD_fFFF_pred.csv` (`row` in
`validation_data_2018.parquet`, `label`, `predicted`). The points in the
input of each method are saved once in `inputs/` of the results folder
(`val2018_series.rds`, `val2018_encoded_METHOD.rds`). A stage run of one
round, two fractions, one encoder and the TempCNN on the raw time series,
in 4 workers:

```
Rscript analysis/sbsr2027/accuracy_learning_curve.R 1 0.05,1 btwins,ts_tempcnn hf 4
```

The runs on the server are scripts for `tether start`, one per job.
Each runs its Rscript calls one after another, with one OpenBLAS thread
per R process; the GPU runners run the learning curve in 8 workers, and
every run skips the tasks already done. Its `tether-progress` line counts the tasks of the current
Rscript call; that of `run_summary.sh` counts the summaries.
The GPU jobs are started one script after the other, each after the
job before it ends; `run_tessera.sh` and `run_split_block_cpu.sh` run
on the CPU, beside them:

1. `run_bands_check.sh`: runs first, because it decides whether the
   comparison of the encoders with the raw time series is fair. It
   prints the bands of the three cached encoders
   (`encoder_bands.R`, which downloads nothing and exits 1 unless each
   has the 6 reflectance bands), then runs `ts_mlp6` and `ts_tempcnn6`
   on round 1 of `split-70-30` at 5% and 100% (internal test only, 4
   tasks), beside the tasks already there. Its accuracies, against
   those of `ts_mlp` and `ts_tempcnn` in the same round and fractions,
   decide whether the raw time series methods of every experiment must
   run again on the 6 bands.
2. `run_split_year.sh`: the held-out label years (`split-year`, 4
   rounds), the six methods before TESSERA.
3. `run_bands_full.sh`: `ts_mlp6` and `ts_tempcnn6` in every folder:
   `split-70-30` (10 rounds, internal test only; the 4 tasks of the
   check are skipped), then `val-2018` (round 1), `split-year` (4
   rounds), `split-location` and `split-block` (round 1), scored also on
   the 2018 points (268 tasks). Its accuracies replace those of `ts_mlp`
   and `ts_tempcnn` in the table and figure of the paper, so the raw time
   series and the encoders are compared on the same 6 bands.
4. `run_tessera.sh`: the TESSERA queue, `tessera_y` then
   `tessera_unit_y` in each folder: `split-70-30` (10 rounds, internal
   test only), then `val-2018` (round 1), `split-year` (4 rounds),
   `split-location` and `split-block` (round 1), scored also on the 2018
   points. After `split-70-30` it runs step 7 on the other folders, which
   keeps their splits and only links the new encoded samples. It hides
   the GPU (`CUDA_VISIBLE_DEVICES` empty), so sits trains and classifies
   on the CPU. Its budget beside a GPU job of up to 80 GiB is 150 GiB of RAM
   (the cgroup has 316 GiB, and tether stops the jobs at 95%). The
   argument is the number of workers (default 2).
5. `run_split_block_cpu.sh`: rounds 1 to 10 of `split-block` for the
   seven MLP methods (all but `ts_tempcnn6`), scored also on the 2018
   points, so that `run_split_block.sh` later skips them and trains
   only the TempCNN. It hides the GPU as `run_tessera.sh` does and runs
   beside the GPU job:
   `tether start --needs cpu analysis/sbsr2027/run_split_block_cpu.sh 2`
   (the argument is the number of workers, default 2). It must end or
   be stopped before the GPU queue reaches `split-block`, because two
   jobs on one folder may run the same task twice. Measured on 24 Oct,
   the GPU job plus 2 CPU workers peaked at 222 GiB of 316.
6. `run_val2018.sh`: rounds 1 to 10 of `val-2018`, all eight methods,
   the raw time series as `ts_mlp6` and `ts_tempcnn6`; round 1 of
   `ts_mlp` and `ts_tempcnn` stays and is not extended.
7. `run_split_location.sh` and `run_split_block.sh`: rounds 1 to 10 of
   `split-location` and `split-block`, the same eight methods, scored
   also on the 2018 points.
8. `run_summary.sh`: step 9 on every experiment folder and evaluation
   set, with `ts_mlp6` as the baseline of the paired differences.

Start `run_tessera.sh` with 2 workers. When the first tasks end, the RAM
line of the job card (`tether status`) gives the cost per worker; stop
the job and start it again with the number of workers that stays within
150 GiB. Done tasks are skipped.

```
tether start --needs cpu analysis/sbsr2027/run_tessera.sh 2
```

On the GPU an MLP task takes from about 80 s (5% of the labels) to
about 2,000 s (100%), so the CPU rate is compared by fraction. When the
first tasks of `tessera_y` end, read their seconds in the job log
(`tether log ID --grep 'tessera_y fraction .*: accuracy'`) and compare
them with the `seconds` metric of `ae_centre_y` at the same round and
fraction, in `round_01_ae_centre_y_fFFF.csv` of
`data/results/sbsr2027/split-70-30/round-01/split-70-30/`. If the CPU
is more than 3 times slower, stop the job (`tether stop ID`): finished
tasks are kept, and the queue runs on the GPU when it is free.

9. `sbsr2027/summary_learning_curve.R`: reads the result files of step 8
for one evaluation set (`round-RR/split-70-30/`, the internal test, or
`round-RR/val-2018/`, the 2018 points) of an experiment folder (default
`data/results/sbsr2027/split-70-30`) and writes, in its
`summary/EVALUATION/`, the mean and standard deviation
over rounds of each method and fraction (overall accuracy, kappa, macro F1,
F1 per class), the paired differences of each method against a baseline,
the MLP on the raw time series (`ts_mlp`, or `ts_mlp6` on the 6 bands),
with their 95% interval, plain (`ci_low`, `ci_high`)
and corrected for the shared samples of the rounds as in Nadeau and Bengio
(2003) (`nb_low`, `nb_high`), and two figures: the learning curve and the
paired differences. It works on a run
in progress; `n_rounds` says how many rounds each number uses. With one
round the standard deviation and the interval are NA, and the figures have
no band and no bars. The optional arguments are the experiment folder,
the evaluation set (`split-70-30`, the default, or `val-2018`) and the
baseline (`ts_mlp`, the default, or `ts_mlp6`); it stops if the folder
has no task files of the baseline:

```
Rscript analysis/sbsr2027/summary_learning_curve.R
Rscript analysis/sbsr2027/summary_learning_curve.R data/results/sbsr2027/val-2018 val-2018 ts_mlp6
```

10. `sbsr2027/check_learning_curve.R`: reruns 16 recorded tasks of step 8 (rounds
1 and 2, fractions 5% and 10%, the three encoders and the MLP on the raw
time series, 8 workers) in `data/results/sbsr2027/split-70-30/checks/rerun`,
an experiment folder that links the labelled samples and encoded samples
(`inputs/`) and the splits (`round-RR/`) of
`data/results/sbsr2027/split-70-30`. It writes the log of the run
(`logs/check.log`) and one `comparison.csv` in each round folder (accuracy
and seconds, recorded and new) and prints the number of tasks compared, the largest accuracy
difference and the median time ratio; it exits with status 1 if a task
is missing. It writes nothing in the recorded folder and
refuses to run while results of an earlier check are in its folder.
Optional arguments are the number of rounds, the fractions, the methods,
the check folder and the 2018 validation points of step 8; the second line
reruns the two recorded TempCNN tasks of round 1 at 5% and 10%:

```
Rscript analysis/sbsr2027/check_learning_curve.R
Rscript analysis/sbsr2027/check_learning_curve.R 1 0.05,0.1 ts_tempcnn data/results/sbsr2027/split-70-30/checks/tempcnn
```

With 2018 validation points, `comparison.csv` also holds their accuracy
(`acc_val2018`). The evaluation of round 1 on the 2018 validation points
has a check stage on 400 points, one fraction and one method of each input
(encoder, AlphaEarth, time series), then the run of all fractions and
methods on all points. Start them detached from the repository root, with
one OpenBLAS thread per R process (otherwise OpenBLAS opens one idle thread
per core in each process; the workers inherit the environment):

```
mkdir -p data/results/sbsr2027/val-2018/logs
setsid nohup env OPENBLAS_NUM_THREADS=1 Rscript analysis/sbsr2027/check_learning_curve.R 1 0.05 btwins,ae_centre_y,ts_mlp data/results/sbsr2027/val-2018/checks/check-400 400 > data/results/sbsr2027/val-2018/logs/check_stage.log 2>&1 < /dev/null &
setsid nohup env OPENBLAS_NUM_THREADS=1 Rscript analysis/sbsr2027/check_learning_curve.R 1 0.05,0.1,0.15,0.2,0.25,0.5,0.75,1 btwins,vicreg,lejepa,ts_mlp,ts_tempcnn,ae_centre_y data/results/sbsr2027/val-2018 all > data/results/sbsr2027/val-2018/logs/run.log 2>&1 < /dev/null &
```

11. `sbsr2027/validation_series_2018.R`: reads the Landsat time series of the 24,000
validation points of 2018 from the monthly Landsat cubes of 2017 and 2018
on the server (the cubes of the labelled samples), with their 24 dates and
10 bands, into `data/results/sbsr2027/val-2018/inputs/validation_series_2018.rds`.
Mode `check`, the default, first compares 10 labelled samples of 2018, in 3 tiles, read
from the cubes with their stored values, writes nothing and exits with
status 1 if a value differs. Optional arguments are the mode, the cubes
folder and the number of cores:

```
Rscript analysis/sbsr2027/validation_series_2018.R check
Rscript analysis/sbsr2027/validation_series_2018.R all ~/rascunho-gpu/biomasbr-sits/cerrado/cubes 16
```

12. `sbsr2027/tessera_samples.R`: turns the TESSERA vectors (version 1.1,
variant dclimate, 128 dimensions, the 10 m pixel that contains the point)
read at the labelled samples and at the 2018 validation points
(`data/results/alphaearth/tessera/tessera_SET_YEAR.parquet`: id,
longitude, latitude, year, status, `T000` to `T127`) into sits samples
in `data/results/alphaearth/tessera/samples/`, two versions of each set:
`tessera_SET_y.parquet`, the vector as read (not unit length), and
`tessera_SET_unit_y.parquet`, the vector divided by its L2 norm. Each
sample has one date (1 January of the label year) and the bands `T000`
to `T127`; row `i` is sample `i` of the points of
`analysis/sbsr2027/alphaearth_points.R`, so the ids match the splits.
A point with no TESSERA data gets a zero vector and is counted. The
labels and coordinates come from the AlphaEarth labelled samples and
from `validation_data_2018.parquet`, so the labelled samples are not
loaded. The script prints a summary and the failed checks, and exits
with status 1 if a check fails. These files are the Hugging Face dataset
that step 8 reads. Optional arguments are the sets and a number of points
for a check, which takes evenly spaced points and every point with no
data and writes to `samples_check/` instead:

```
Rscript analysis/sbsr2027/tessera_samples.R labelled,validation2018 300
Rscript analysis/sbsr2027/tessera_samples.R
```

## Results of the SBSR 2027 experiments

Each experiment has its own folder in `data/results/sbsr2027`, and each
round folder has the same structure in every experiment:

```
split-70-30/                 the 10-round experiment
  inputs/                    labelled_samples.rds, encoded_METHOD.rds
  round-01/ ... round-10/
    round_RR_split.rds
    split-70-30/             round_RR_METHOD_fFFF.csv (internal test)
    models/                  round_RR_METHOD_fFFF.rds and .json
  summary/split-70-30/       summary tables and figures of the internal test
  checks/                    reproduction checks of this experiment
  cpu-trained/               CPU-trained tasks moved aside, any experiment
                             (run_gpu_retrain.sh)
  logs/
val-2018/                    round 1 also scored on the 24,000 points of 2018
  inputs/                    labelled_samples.rds, encoded_METHOD.rds,
                             validation_series_2018.rds, val2018_series.rds,
                             val2018_encoded_METHOD.rds
  round-01/
    round_01_split.rds
    split-70-30/             internal-test CSVs (kept as a reproduction check)
    val-2018/                round_01_METHOD_fFFF.csv and *_pred.csv
    models/                  model .rds and .json
    comparison.csv
  summary/split-70-30/       summary of the internal test of round 1
  summary/val-2018/          summary on the 2018 points
  checks/
  logs/
split-GEOMETRY/              location, block or year splits (step 7)
  inputs/                    links to the files of split-70-30/inputs/
  round-RR/                  as in split-70-30
  summary/
  logs/
repro-check/                 retrained tasks (run_repro_check.sh)
  cpu/EXPERIMENT/            experiment folders of links and new task files
  gpu/EXPERIMENT/
  comparison.csv
  repro_sample_tasks/        the same for a task list (--tasks)
    gpu/EXPERIMENT/
    comparison.csv
```

A round folder has `val-2018/` only where the evaluation on the 2018
points ran, and `models/` only where models were saved. A check folder in `checks/` has
the layout of an experiment folder.

`analysis/sbsr2027/organize_results.sh` moves the results written before
this layout (`data/results/learning_curve`, `data/results/validation_2018`,
the check folders and logs) into it. Without `--apply` it prints the plan:
the moves, the symbolic links, the links it will re-point because their
target also moves, the files it does not recognise, which stay where they
are, and the errors. With `--apply` it writes a sha256 manifest in
`data/results/sbsr2027`, moves with `mv`, checks every hash at the new
path, re-points those links as relative links, and prints only failures
and links that still point to nothing. It never deletes or overwrites a
regular file. Run
it from the repository root:

```
analysis/sbsr2027/organize_results.sh > tmp/organize_plan.txt
analysis/sbsr2027/organize_results.sh --apply
```

`analysis/sbsr2027/pack_results.sh` packs every `*.csv` under
`data/results/sbsr2027` (task files, `_pred.csv` and summaries, with their
relative paths; no `.rds`, models or logs) into
`data/results/sbsr2027/export/sbsr2027_csv.tar.gz`, so that one
`tether fetch` brings them to the local machine. Next to it it writes
`sbsr2027_csv.sha256`, the sha256 of each packed file (check with
`sha256sum -c` in the extracted folder). Both are written under a temporary
name and renamed at the end. With `--no-pred` it leaves out the `_pred.csv`
files, the largest ones, and writes `sbsr2027_csv_nopred.*`. Start it as a
job:

```
tether start analysis/sbsr2027/pack_results.sh
```

`analysis/sbsr2027/run_repro_check.sh` retrains 11 recorded tasks, one
after another, on the CPU (`CUDA_VISIBLE_DEVICES` empty) or on the GPU,
and compares each new task file with the recorded one: TESSERA
(`tessera_y`, round 2 of split-70-30, 5%) on both devices, three
split-block tasks recorded on the CPU on both devices, and three tasks
of unknown device, written before the tether jobs, on the GPU. The
script header lists the tasks and why they were chosen. A rerun on the
device of the recorded run must equal the recorded file in every metric
row; a rerun on the other device is expected to differ. Each device and
experiment has a scratch experiment folder in
`data/results/sbsr2027/repro-check/` with links to the inputs, the
splits and the recorded task files of the earlier rounds, so the
learning-curve script trains the asked round only and writes nothing in
a recorded folder. It writes `repro-check/comparison.csv` (task, device,
recorded_device, metric, class, recorded, rerun, equal) and prints one
line per comparison; `pack_results.sh` packs the new task files and
`comparison.csv`, not the links. `--dry-run` checks every input, split,
recorded file and device and prints the 11 trainings without training;
start it first:

```
tether start analysis/sbsr2027/run_repro_check.sh --dry-run
tether start analysis/sbsr2027/run_repro_check.sh
```

`analysis/sbsr2027/run_gpu_retrain.sh` replaces every CPU-trained task by a GPU-trained one, because a CPU task does not reproduce, even on the CPU: on 27 Oct 2026 `run_repro_check.sh` gave 5 of 5 GPU tasks equal in every row and 5 of 5 CPU tasks different by 0.4 to 1.8 pp. The tasks are listed in `analysis/sbsr2027/cpu_trained_tasks.csv` (experiment, round, method, percent, action), derived from the device inventory of the sbsr-paper repository (`tmp/device-inventory.csv`, 27 Oct 2026; the rows with device `cpu`): 380 tasks. For each task the script moves the task CSV, the CSV and predictions on the 2018 points and the saved model and its `.json` into `EXPERIMENT/cpu-trained/` under the same relative path, so nothing is deleted and the learning-curve script neither skips the task nor reads its CPU model; it refuses to move a file whose task is not on the list. The 144 tasks with action `copy` (TESSERA in split-70-30, rounds 2 to 10) take the GPU-trained task CSV of `val-2018/round-RR/split-70-30/`, after a check that both experiments have the same split ids in that round. The other 236 tasks are trained again with the GPU visible, with the arguments of the runner that wrote each experiment and 8 workers (the script header lists them); `tether-progress` counts these 236 tasks. Before any move it checks the listed files, the inputs, the splits, the CUDA device, and that no task outside the list would train. A rerun after an interruption resumes. `--dry-run` runs the checks and prints the files to move and copy and the tasks to train, and writes nothing; start it first:

```
tether start analysis/sbsr2027/run_gpu_retrain.sh --dry-run
tether start analysis/sbsr2027/run_gpu_retrain.sh
```

TempCNN does not reproduce on the GPU with the same seed and split, probably because the order of the parallel sums of the convolutions changes between runs; the MLP methods reproduce exactly. The 80 `ts_tempcnn6` tasks of split-70-30 were trained a second time in val-2018 (same splits, same internal test): 77 differ, by a mean absolute difference in accuracy of 0.06 pp (sd 0.05, at most 0.23). This is smaller than the standard deviation over rounds (0.09 to 0.18 pp), which already includes it.

`run_repro_check.sh --tasks FILE` tests the final results, after `run_gpu_retrain.sh`, on a random sample of tasks listed in `FILE` (experiment, round, method, percent). `analysis/sbsr2027/repro_sample_tasks.csv` holds one task per experiment and MLP-family method: 35 tasks, from 5 experiments and 7 methods (every method except `ts_tempcnn` and `ts_tempcnn6`, which do not reproduce on the GPU, and `ts_mlp`, the 10 bands the paper does not use). `analysis/sbsr2027/repro_sample.R` drew it once with seed 1524: for each pair, a round and a fraction among the recorded tasks whose files of the earlier rounds also exist, because the rerun links them. Run again, the R script compares its draw with the file and stops if they differ; it never overwrites the file. Each task is trained on the GPU, one after another with one worker, in a scratch folder of links as above, `repro-check/repro_sample_tasks/gpu/EXPERIMENT/`, so the 11 trainings and their `comparison.csv` stay as they are. In split-70-30 it compares the internal-test file; in the other four experiments it also scores the 2018 points, as their runners did, and compares that file too. A rerun must equal its recorded file in every row except `seconds`. The script writes `repro-check/repro_sample_tasks/comparison.csv` (recorded device `final`) and prints how many tasks are equal in every row. If all 35 are equal, the share of tasks that do not reproduce is below 3/35 = 8.6% with 95% confidence (rule of three). The recorded seconds of the 35 tasks add up to 41,571 s; 7 GPU reruns with one worker took 0.26 to 0.80 of their recorded seconds (median 0.34), so the run should take about 4 h (3 to 9 h). Check the draw against the results on the server, then start the dry run first:

```
Rscript analysis/sbsr2027/repro_sample.R
tether start analysis/sbsr2027/run_repro_check.sh --dry-run --tasks analysis/sbsr2027/repro_sample_tasks.csv
tether start analysis/sbsr2027/run_repro_check.sh --tasks analysis/sbsr2027/repro_sample_tasks.csv
```

## Server tools

`server/` holds tools for the server where the learning curve runs; they
are not part of the package. `server/memstat.sh` runs next to a
learning-curve run: every 5 s it samples RAM (`anon` of the cgroup), GPU
memory and use, CPU cores and read rate of the run's processes, and
appends the min, max and mean of each 5 min window, with the count of
finished tasks (files under a folder whose path matches a pattern), as
one line to a log. It exits when the run ends. Start it
detached from the repository root, after the run:

```
setsid nohup server/memstat.sh --tasks data/results/sbsr2027/split-70-30 \
  'split-70-30/round-[0-9]+/split-70-30/[^/]*ts_tempcnn_f[0-9]{3}[.]csv$' \
  data/results/sbsr2027/split-70-30/logs/memstat.log \
  > /dev/null 2>&1 < /dev/null &
```

To read the last window as a key-value card, with an end estimate from
the task rate when the number of tasks of the run is given:

```
server/memstat.sh --card --total 80 data/results/sbsr2027/split-70-30/logs/memstat.log
```

`server/memstat.sh --help` lists the options.

## Tests

`test-make_splits.R` draws the splits of every geometry on the MODIS
samples of `sits`, with four label years, and checks that `random` gives
the splits of the code it replaced, that no location, block or year is on
both sides, that the fractions are nested and never touch the test side,
that an existing split is kept, and that the experiment script stops
without its split. It trains nothing. `test-accuracy_learning_curve.R`
makes the `random` splits, then runs the learning curve on the MODIS
samples of `sits`, and checks
the split, the nested fractions, the result tables, the skip of finished
tasks, that two workers give the results of one and train with the torch
threads of their task, that a saved split is read and not rewritten, that
a saved model is read when its metadata match and trained again when not, and
that the results folder argument moves every file. From the repository
root, with temporary files in `tmp/`:

```
mkdir -p tmp
TMPDIR="$PWD/tmp" Rscript -e 'testthat::test_file("tests/testthat/test-make_splits.R")'
TMPDIR="$PWD/tmp" Rscript -e 'testthat::test_file("tests/testthat/test-accuracy_learning_curve.R")'
```
