/// VM-platform (Android, iOS, macOS, Windows, Linux) WebSocket factory
/// built on `IOWebSocketChannel`.
library;

import 'dart:async';

import 'package:web_socket_channel/io.dart';

import 'ws_factory_stub.dart' show WsSocket, WsFactory;

// Re-export the shared types so that `import 'ws_factory.dart'` (which
// conditionally exports THIS file on VM platforms) exposes the complete
// platform-independent surface, not just the VM-specific declarations.
export 'ws_factory_stub.dart' show WsSocket, WsFactory;

class _IoWsSocket implements WsSocket {
  _IoWsSocket(this._channel);

  final IOWebSocketChannel _channel;

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

/// VM implementation of [WsFactory]: sends credentials via the standard
/// `Authorization` header and enables transport-level ping/pong keepalive.
class IoWsFactory implements WsFactory {
  /// Creates a factory. [pingInterval] defaults to 30 s of transport-level
  /// keepalive, independent of any application-level KeepAlive messages.
  const IoWsFactory({this.pingInterval = const Duration(seconds: 30)});

  /// Interval for WebSocket protocol-level ping frames.
  final Duration pingInterval;

  @override
  Future<WsSocket> connect(
    Uri uri, {
    required String authorizationHeader,
    required Duration connectTimeout,
  }) async {
    final channel = IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': authorizationHeader},
      pingInterval: pingInterval,
      connectTimeout: connectTimeout,
    );
    // `ready` completes once the upgrade succeeds; a refused upgrade (4xx)
    // or a network failure throws here.
    await channel.ready.timeout(connectTimeout);
    return _IoWsSocket(channel);
  }
}

/// The factory instance exported on VM platforms.
final WsFactory defaultWsFactory = const IoWsFactory();
