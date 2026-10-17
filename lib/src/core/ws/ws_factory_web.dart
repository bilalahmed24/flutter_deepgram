/// Browser (Web) WebSocket factory built on `HtmlWebSocketChannel`.
///
/// Browsers do not allow custom headers on WebSocket upgrades, so this
/// factory authenticates using Deepgram's documented
/// `Sec-WebSocket-Protocol` approach: the client offers the subprotocols
/// `token, <API key>` (or `bearer, <JWT>`), and Deepgram accepts one of
/// them during the handshake.
///
/// See https://developers.deepgram.com/docs/using-the-sec-websocket-protocol.
library;

import 'dart:async';

import 'package:web_socket_channel/html.dart';

import 'ws_factory_stub.dart' show WsSocket, WsFactory;

// Re-export the shared types so that `import 'ws_factory.dart'` (which
// conditionally exports THIS file on web platforms) exposes the complete
// platform-independent surface, not just the web-specific declarations.
export 'ws_factory_stub.dart' show WsSocket, WsFactory;

class _WebWsSocket implements WsSocket {
  _WebWsSocket(this._channel);

  final HtmlWebSocketChannel _channel;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void add(Object data) => _channel.sink.add(data);

  @override
  Future<void> get ready => _channel.ready;

  @override
  Future<void> close() => _channel.sink.close();

  @override
  int? get closeCode => _channel.closeCode;

  @override
  String? get closeReason => _channel.closeReason;
}

/// Browser implementation of [WsFactory].
class WebWsFactory implements WsFactory {
  /// Creates a factory.
  const WebWsFactory();

  @override
  Future<WsSocket> connect(
    Uri uri, {
    required String authorizationHeader,
    required Duration connectTimeout,
  }) async {
    // Authorization header is `Token <key>` or `Bearer <jwt>`.
    final parts = authorizationHeader.split(' ');
    if (parts.length != 2) {
      throw ArgumentError.value(
        authorizationHeader,
        'authorizationHeader',
        'Expected "Token <key>" or "Bearer <jwt>".',
      );
    }
    final scheme = parts[0].toLowerCase() == 'token' ? 'token' : 'bearer';
    final credential = parts[1];
    // HtmlWebSocketChannel.connect has no connectTimeout parameter (that
    // parameter exists only on IOWebSocketChannel); the deadline is enforced
    // on the ready future below instead.
    final channel = HtmlWebSocketChannel.connect(
      uri,
      protocols: <String>[scheme, credential],
    );
    await channel.ready.timeout(connectTimeout);
    return _WebWsSocket(channel);
  }
}

/// The factory instance exported on the web.
final WsFactory defaultWsFactory = WebWsFactory();
