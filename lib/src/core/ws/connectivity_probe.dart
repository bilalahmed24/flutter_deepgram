/// Connectivity probe used to corroborate WebSocket failures.
///
/// When a WebSocket connection attempt fails, the failure alone is ambiguous
/// on a flaky mobile network: it could be Deepgram refusing the upgrade, or
/// the internet being down. This probe performs a cheap HTTPS request so
/// callers can distinguish the two cases before deciding whether to discard
/// buffered data.
library;

import 'package:http/http.dart' as http;

/// Probes general internet reachability.
class ConnectivityProbe {
  /// Creates a probe that checks [probeUrl] (a fast, highly-available HTTPS
  /// endpoint).
  ///
  /// [client] is injectable for testing; production callers omit it and the
  /// ambient `package:http` client is used.
  ConnectivityProbe({required this.probeUrl, http.Client? client})
      : _client = client;

  /// The URL probed to establish that the internet is reachable.
  final String probeUrl;

  final http.Client? _client;

  DateTime? _lastGreenAt;
  DateTime? _lastRedAt;

  /// Wall clock of the last successful probe (UTC), if any.
  DateTime? get lastGreenAt => _lastGreenAt;

  /// Wall clock of the last failed probe (UTC), if any.
  DateTime? get lastRedAt => _lastRedAt;

  /// Performs a probe. Returns `true` when the internet appears up.
  ///
  /// Never throws: an exception during probing counts as "internet suspect".
  Future<bool> isInternetAvailable() async {
    try {
      final uri = Uri.parse(probeUrl);
      final Future<http.Response> pending =
          _client != null ? _client.head(uri) : http.head(uri);
      final response = await pending.timeout(const Duration(seconds: 5));
      final up = response.statusCode > 0;
      if (up) {
        _lastGreenAt = DateTime.now().toUtc();
      } else {
        _lastRedAt = DateTime.now().toUtc();
      }
      return up;
    } catch (_) {
      _lastRedAt = DateTime.now().toUtc();
      return false;
    }
  }
}
