/// Shared fixtures for building test configurations and clients.
library;

import 'package:flutter_deepgram/flutter_deepgram.dart';

/// A configuration with fast timings suitable for unit tests.
///
/// Retries are nearly instant and probe checks always succeed unless a test
/// overrides the probe explicitly.
const DeepgramConfig testConfig = DeepgramConfig(
  apiKey: 'test-api-key',
  requestTimeout: Duration(seconds: 2),
  maxRetries: 2,
  retryBaseDelay: Duration(milliseconds: 1),
  retryMaxDelay: Duration(milliseconds: 5),
);

/// A connectivity probe whose result the test controls.
class FakeProbe implements ConnectivityProbe {
  FakeProbe({this.result = true});

  /// Value returned by [isInternetAvailable].
  bool result;

  @override
  final String probeUrl = 'https://probe.test/';

  @override
  DateTime? lastGreenAt;

  @override
  DateTime? lastRedAt;

  @override
  Future<bool> isInternetAvailable() async {
    if (result) {
      lastGreenAt = DateTime.now().toUtc();
    } else {
      lastRedAt = DateTime.now().toUtc();
    }
    return result;
  }
}

/// A logger that records everything it is asked to log (and emits nothing).
class RecordingLogger extends DeepgramLogger {
  final List<String> debugs = [];
  final List<String> infos = [];
  final List<String> warns = [];
  final List<String> errors = [];

  @override
  void debug(String message, [Object? error]) => debugs.add(message);

  @override
  void info(String message, [Object? error]) => infos.add(message);

  @override
  void warn(String message, [Object? error]) => warns.add(message);

  @override
  void error(String message, [Object? error]) => errors.add(message);
}
