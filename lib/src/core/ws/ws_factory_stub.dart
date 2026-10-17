/// Platform-independent WebSocket abstractions.
///
/// This is the stub (default) implementation; `ws_factory_io.dart` and
/// `ws_factory_web.dart` provide the platform versions selected by
/// `ws_factory.dart`'s conditional exports.
library;

import 'dart:async';

/// A connected WebSocket wrapper used by [WsFactory].
abstract class WsSocket {
  /// Stream of inbound frames (`String` for text, `List<int>` for binary).
  Stream<dynamic> get stream;

  /// Sends a text or binary frame.
  void add(Object data);

  /// Completes when the connection is established; throws on refusal.
  Future<void> get ready;

  /// Closes the socket.
  Future<void> close();

  /// Close code after the stream is done, when provided by the platform.
  int? get closeCode;

  /// Close reason after the stream is done, when provided by the platform.
  String? get closeReason;
}

/// Creates platform-appropriate WebSocket connections.
abstract class WsFactory {
  /// Establishes a connection to [uri].
  ///
  /// [authorizationHeader] is the full `Authorization` header value
  /// (`Token <key>` or `Bearer <jwt>`). VM implementations send it as a
  /// header; web implementations translate it into Deepgram's documented
  /// `Sec-WebSocket-Protocol` fallback.
  Future<WsSocket> connect(
    Uri uri, {
    required String authorizationHeader,
    required Duration connectTimeout,
  });
}

/// A [WsFactory] that always fails — replaced at compile time by the
/// conditional export.
class StubWsFactory implements WsFactory {
  @override
  Future<WsSocket> connect(
    Uri uri, {
    required String authorizationHeader,
    required Duration connectTimeout,
  }) async {
    throw UnsupportedError(
      'No WebSocket implementation is available on this platform.',
    );
  }
}

/// The factory instance exported on unsupported platforms.
final WsFactory defaultWsFactory = StubWsFactory();
