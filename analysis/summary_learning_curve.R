# Summary of the learning curve (analysis/accuracy_learning_curve.R):
# mean and standard deviation over rounds of each method and fraction, paired
# differences against the MLP on the raw time series, and two figures. The
# TempCNN is left out of the report (decided 2026-10-06). Reads the task
# files in data/results/learning_curve and writes to
# data/results/learning_curve/summary. Works on a run in progress:
# n_rounds says how many rounds each number is computed on.
#
#   Rscript analysis/summary_learning_curve.R
library(glue)
library(ggplot2)

results_dir <- "data/results/learning_curve"
summary_dir <- fs::dir_create(fs::path(results_dir, "summary"))

method_names <- c(
  btwins = "Barlow Twins + MLP",
  vicreg = "VICReg + MLP",
  lejepa = "LeJEPA + MLP",
  ts_mlp = "MLP, time series"
)
# fixed categorical order (dataviz reference palette, slots 1 to 4)
method_colors <- c("#2a78d6", "#eb6834", "#1baf7a", "#eda100")
names(method_colors) <- method_names
method_shapes <- c(16, 17, 15, 18)
names(method_shapes) <- method_names

#
# 1. Read the task files
#
task_files <- fs::dir_ls(results_dir, regexp = "round_[0-9]+_.*_f[0-9]{3}\\.csv$")
results <- dplyr::bind_rows(purrr::map(task_files, read.csv))
results <- dplyr::filter(results, .data[["method"]] %in% names(method_names))
message(glue("{length(task_files)} task files, rounds {paste(sort(unique(results$round)), collapse = ', ')}"))

overall <- dplyr::filter(results, .data[["metric"]] %in% c("accuracy", "kappa", "seconds"))
overall <- tidyr::pivot_wider(
  overall[, c("round", "method", "fraction", "n_train", "metric", "value")],
  names_from = "metric", values_from = "value"
)
macro_f1 <- dplyr::summarise(
  dplyr::group_by(dplyr::filter(results, .data[["metric"]] == "f1"), round, method, fraction),
  # a class never predicted has no F1; it counts as 0
  macro_f1 = mean(dplyr::coalesce(value, 0)),
  .groups = "drop"
)
overall <- dplyr::left_join(overall, macro_f1, by = c("round", "method", "fraction"))

#
# 2. Mean and standard deviation over rounds
#
summary_acc <- dplyr::summarise(
  dplyr::group_by(overall, method, fraction),
  n_rounds = dplyr::n(),
  n_train = mean(n_train),
  accuracy_mean = mean(accuracy),
  accuracy_sd = sd(accuracy),
  kappa_mean = mean(kappa),
  kappa_sd = sd(kappa),
  macro_f1_mean = mean(macro_f1),
  macro_f1_sd = sd(macro_f1),
  seconds_mean = mean(seconds),
  .groups = "drop"
)
write.csv(summary_acc, fs::path(summary_dir, "summary_accuracy.csv"), row.names = FALSE)

summary_f1 <- dplyr::summarise(
  dplyr::group_by(dplyr::filter(results, .data[["metric"]] == "f1"), method, fraction, class),
  n_rounds = dplyr::n(),
  f1_mean = mean(value, na.rm = TRUE),
  f1_sd = sd(value, na.rm = TRUE),
  .groups = "drop"
)
write.csv(summary_f1, fs::path(summary_dir, "summary_f1_class.csv"), row.names = FALSE)

#
# 3. Paired differences: method minus baseline, inside each round
#
paired <- purrr::map_dfr(c("ts_mlp"), function(base) {
  base_acc <- dplyr::select(
    dplyr::filter(overall, method == base),
    round, fraction, base_accuracy = accuracy
  )
  d <- dplyr::inner_join(
    dplyr::filter(overall, method != base), base_acc,
    by = c("round", "fraction")
  )
  dplyr::summarise(
    dplyr::group_by(d, method, fraction),
    baseline = base,
    n_rounds = dplyr::n(),
    diff_mean = mean(accuracy - base_accuracy),
    diff_sd = sd(accuracy - base_accuracy),
    # 95% interval of the mean difference (t, n_rounds - 1 degrees of freedom)
    ci_low = diff_mean - qt(0.975, pmax(n_rounds - 1, 1)) * diff_sd / sqrt(n_rounds),
    ci_high = diff_mean + qt(0.975, pmax(n_rounds - 1, 1)) * diff_sd / sqrt(n_rounds),
    .groups = "drop"
  )
})
write.csv(paired, fs::path(summary_dir, "paired_differences.csv"), row.names = FALSE)

#
# 4. Figures
#
# slides: 16:9 at 13.33 x 7.5 inches, text readable when projected
slide_width <- 13.33
slide_height <- 7.5
theme_curve <- theme_minimal(base_size = 20) +
  theme(
    legend.position = "top",
    legend.title = element_blank(),
    panel.grid.minor = element_blank(),
    plot.background = element_rect(fill = "white", colour = NA)
  )

plot_acc <- dplyr::mutate(summary_acc, method = factor(method_names[method], levels = method_names))
curve <- ggplot(plot_acc, aes(fraction, accuracy_mean, colour = method, fill = method, shape = method)) +
  geom_ribbon(
    aes(ymin = accuracy_mean - accuracy_sd, ymax = accuracy_mean + accuracy_sd),
    alpha = 0.15, colour = NA
  ) +
  geom_line(linewidth = 1) +
  geom_point(size = 3.5) +
  # one tick per fraction of the run; log scale spreads the small fractions
  scale_x_log10(
    breaks = sort(unique(plot_acc$fraction)),
    labels = scales::label_percent(accuracy = 1)
  ) +
  scale_y_continuous(labels = scales::label_percent(accuracy = 1)) +
  scale_colour_manual(values = method_colors) +
  scale_fill_manual(values = method_colors) +
  scale_shape_manual(values = method_shapes) +
  labs(
    x = "Fraction of the training samples (log scale)",
    y = "Overall accuracy",
    caption = "Mean over rounds; band: one standard deviation."
  ) +
  theme_curve
ggsave(fs::path(summary_dir, "learning_curve_accuracy.png"), curve,
       width = slide_width, height = slide_height, dpi = 150)

plot_diff <- dplyr::mutate(
  paired,
  method = factor(method_names[method], levels = method_names)
)
diff_plot <- ggplot(plot_diff, aes(fraction, diff_mean, colour = method, shape = method)) +
  geom_hline(yintercept = 0, colour = "grey50", linewidth = 0.4) +
  # dodge in log10 units, so the methods sit side by side at every fraction
  geom_errorbar(aes(ymin = ci_low, ymax = ci_high), width = 0, linewidth = 1,
                position = position_dodge(width = 0.06)) +
  geom_point(size = 3.5, position = position_dodge(width = 0.06)) +
  scale_x_log10(
    breaks = sort(unique(plot_diff$fraction)),
    labels = scales::label_percent(accuracy = 1)
  ) +
  scale_y_continuous(labels = scales::label_number(accuracy = 0.1, scale = 100, suffix = " pp")) +
  scale_colour_manual(values = method_colors) +
  scale_shape_manual(values = method_shapes) +
  labs(
    x = "Fraction of the training samples (log scale)",
    y = "Accuracy minus MLP, time series",
    caption = "Paired by round; bars: 95% interval of the mean difference."
  ) +
  theme_curve
ggsave(fs::path(summary_dir, "paired_differences.png"), diff_plot,
       width = slide_width, height = slide_height, dpi = 150)

message(glue("summary written to {summary_dir}"))
