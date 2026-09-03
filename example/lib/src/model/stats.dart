/// Summary statistics for a set of samples.
///
/// Reports median and the interquartile range rather than a mean: load times have a hard floor
/// and a long right tail, so one cold outlier in five moves a mean by 20-30% and it ends up
/// describing no run that actually happened. The IQR is what distinguishes two arms with equal
/// medians but very different consistency.
class Aggregate {
  /// Creates an aggregate.
  const Aggregate({
    required this.n,
    required this.median,
    required this.p25,
    required this.p75,
    required this.min,
    required this.max,
    this.p95,
  });

  /// Sample count.
  final int n;

  /// 50th percentile.
  final double median;

  /// 25th percentile.
  final double p25;

  /// 75th percentile.
  final double p75;

  /// Smallest sample.
  final int min;

  /// Largest sample.
  final int max;

  /// 95th percentile, present only when [n] is large enough for it to mean anything.
  ///
  /// Below 20 samples nearest-rank p95 is just the maximum, so reporting it under a percentile
  /// label would imply a distributional estimate that does not exist.
  final double? p95;

  /// Whether there is anything to report.
  bool get isEmpty => n == 0;

  /// Computes an aggregate over [samples], ignoring nulls.
  static Aggregate? of(Iterable<int?> samples) {
    final List<int> values = samples.whereType<int>().toList()..sort();
    if (values.isEmpty) return null;
    return Aggregate(
      n: values.length,
      median: _percentile(values, 0.50),
      p25: _percentile(values, 0.25),
      p75: _percentile(values, 0.75),
      min: values.first,
      max: values.last,
      p95: values.length >= 20 ? _percentile(values, 0.95) : null,
    );
  }

  /// Linear-interpolated percentile over a pre-sorted list.
  static double _percentile(List<int> sorted, double q) {
    if (sorted.length == 1) return sorted.first.toDouble();
    final double pos = q * (sorted.length - 1);
    final int lo = pos.floor();
    final int hi = pos.ceil();
    if (lo == hi) return sorted[lo].toDouble();
    final double frac = pos - lo;
    return sorted[lo] + (sorted[hi] - sorted[lo]) * frac;
  }
}

/// Formats microseconds as milliseconds with one decimal.
String formatMicros(int? micros) {
  if (micros == null) return '--';
  return '${(micros / 1000).toStringAsFixed(1)} ms';
}

/// Formats a microsecond aggregate as `median [p25-p75] (min-max, n=k)`.
String formatAggregate(Aggregate? a) {
  if (a == null) return '--';
  final String med = (a.median / 1000).toStringAsFixed(1);
  final String lo = (a.p25 / 1000).toStringAsFixed(1);
  final String hi = (a.p75 / 1000).toStringAsFixed(1);
  final String mn = (a.min / 1000).toStringAsFixed(1);
  final String mx = (a.max / 1000).toStringAsFixed(1);
  return '$med ms [$lo-$hi] ($mn-$mx, n=${a.n})';
}

/// Formats a byte count compactly.
String formatBytes(Object? bytes) {
  if (bytes is! num) return '--';
  final double kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  return '${(kb / 1024).toStringAsFixed(2)} MB';
}
