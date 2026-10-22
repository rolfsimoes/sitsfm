# Random streams and nested fractions shared by make_splits.R (which draws
# the splits) and accuracy_learning_curve.R (which trains on them).
#
# L'Ecuyer-CMRG gives streams that do not overlap. Round r uses stream r
# for its split; the training of fraction f uses substream 100 * f of
# stream r, the same for all methods. A training depends only on its round
# and fraction, not on what ran before.
RNGkind("L'Ecuyer-CMRG")
set.seed(1524)
base_stream <- .Random.seed
round_stream <- function(ith_run) {
  stream <- base_stream
  for (i in seq_len(ith_run)) stream <- parallel::nextRNGStream(stream)
  stream
}
fraction_stream <- function(stream, frac) {
  for (i in seq_len(round(frac * 100))) stream <- parallel::nextRNGSubStream(stream)
  stream
}

# Nested fractions: shuffle each class once; fraction f takes the first
# floor(f n) samples of each class, whatever the other fractions are.
# Draws from the current stream; returns ids named by fraction.
nested_fractions <- function(train_samples, fractions) {
  train_order <- sits::sits_sample(train_samples, frac = 1.0, oversample = FALSE)
  train_ids <- purrr::map(fractions, function(frac) {
    dplyr::slice_head(dplyr::group_by(train_order, .data[["label"]]), prop = frac)[["id"]]
  })
  names(train_ids) <- as.character(fractions)
  train_ids
}
