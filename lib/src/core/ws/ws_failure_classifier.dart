/// Classification of failed WebSocket connection attempts.
///
/// The ONLY definitive signal that Deepgram (not the internet) refused us is
/// a WebSocket upgrade failure carrying an HTTP status — the request
/// completed a full round trip to Deepgram's edge, so the network path is
/// exonerated. Every network-level failure (TLS / TCP / DNS / timeout) is
/// ambiguous from a single observation on a flaky mobile network, so those
/// are corroborated with a connectivity probe before deciding — and while in
/// doubt, buffered data is never discarded (losing RAM is cheap, losing
/// transcripts is not).
library;

/// Classification of a failed WebSocket connection attempt.
enum WsFailureClassification {
  /// Server answered HTTP and refused the WS upgrade — Deepgram definitive.
  deepgramDefinitive,

  /// A peer responded (TLS / refused / reset) — could be Deepgram or a
  /// middlebox. Corroborate with a fresh probe before deciding.
  ambiguous,

  /// Path appears broken (unreachable / timeout / DNS) — unstable internet
  /// is a live suspect. Corroborate; while in doubt, keep buffering.
  internetSuspect,
}

/// Classifies raw WebSocket connect errors.
class WsFailureClassifier {
  /// Classifies [error] thrown from a WebSocket connect attempt.
  WsFailureClassification classify(Object error) {
    final text = error.toString().toLowerCase();
    if (_isWebSocketUpgradeRefusal(error, text)) {
      return WsFailureClassification.deepgramDefinitive;
    }
    if (_isPathBroken(text)) {
      return WsFailureClassification.internetSuspect;
    }
    return WsFailureClassification.ambiguous;
  }

  /// A WebSocketException means the HTTP upgrade was refused by a server
  /// that ANSWERED — the full network path worked.
  bool _isWebSocketUpgradeRefusal(Object error, String text) {
    final typeName = error.runtimeType.toString();
    if (typeName.contains('WebSocketException') ||
        typeName.contains('WebSocketChannelException')) {
      return true;
    }
    if (text.contains('was not upgraded to websocket')) return true;
    if (text.contains('upgrade') && text.contains('refused')) return true;
    if (text.contains('invalid status code')) return true;
    return false;
  }

  /// Network path-level failures: unreachable, DNS, timeouts.
  bool _isPathBroken(String text) {
    return text.contains('network unreachable') ||
        text.contains('network is unreachable') ||
        text.contains('timed out') ||
        text.contains('timeout') ||
        text.contains('failed host lookup') ||
        text.contains('no address associated with hostname');
  }
}
