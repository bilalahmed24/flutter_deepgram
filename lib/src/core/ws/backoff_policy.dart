/// Exponential backoff with jitter for reconnection scheduling.
library;

import 'dart:math' as math;

/// Computes reconnect delays.
///
/// Delay grows exponentially from [baseDelay], capped at [maxDelay], with
/// uniform random jitter of up to ±25% of the delay so that fleets of
/// clients don't reconnect in lockstep (thundering herd).
class BackoffPolicy {
  /// Creates a policy with the given bounds.
  ///
  /// [random] seeds the jitter generator; inject a seeded [math.Random] in
  /// tests to make delays deterministic.
  BackoffPolicy({
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.multiplier = 2.0,
    this.jitterFraction = 0.25,
    math.Random? random,
  }) : _random = random ?? math.Random();

  /// Delay before the first retry.
  final Duration baseDelay;

  /// Upper bound on any single delay.
  final Duration maxDelay;

  /// Growth factor between consecutive attempts.
  final double multiplier;

  /// Jitter as a fraction of the computed delay (0.25 → ±25%).
  final double jitterFraction;

  final math.Random _random;

  /// Returns the delay to wait before reconnection attempt [attempt]
  /// (1-based). Does not mutate any state, so it is safe to call repeatedly.
  Duration delayFor(int attempt) {
    final effectiveAttempt = math.max(1, attempt);
    final growth = math.pow(multiplier, effectiveAttempt - 1).toDouble();
    final rawMs = baseDelay.inMilliseconds * growth;
    final cappedMs = math.min(rawMs, maxDelay.inMilliseconds);
    final jitterSpan = cappedMs * jitterFraction;
    final jitter = (_random.nextDouble() * 2 - 1) * jitterSpan;
    final finalMs = math.max(0, (cappedMs + jitter).round());
    return Duration(milliseconds: finalMs);
  }
}
