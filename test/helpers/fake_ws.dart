/// A scriptable in-memory [WsFactory]/[WsSocket] pair for unit tests.
///
/// Tests enqueue scripted behaviors (sockets to deliver or errors to throw)
/// and then drive the socket directly: [FakeWsSocket.emit] pushes inbound
/// frames, [FakeWsSocket.serverClose] simulates an unexpected disconnect,
/// and [FakeWsSocket.sent] records everything the SDK sent.
library;

import 'dart:async';

import 'package:flutter_deepgram/flutter_deepgram.dart';

/// An in-memory [WsSocket] the test controls.
class FakeWsSocket implements WsSocket {
  FakeWsSocket({this.connectDuration = Duration.zero});

  /// Artificial delay before [ready] completes.
  final Duration connectDuration;

  final StreamController<dynamic> _inbound =
      StreamController<dynamic>.broadcast();

  /// Frames sent by the SDK (text or binary).
  final List<Object> sent = [];

  /// Exception to throw from [add], if armed.
  Object? addError;

  final Completer<void> _readyCompleter = Completer<void>();

  Completer<void>? _closeCompleter;

  bool _closed = false;

  @override
  Stream<dynamic> get stream => _inbound.stream;

  @override
  Future<void> get ready => _readyCompleter.future;

  @override
  void add(Object data) {
    final error = addError;
    if (error != null) throw error;
    sent.add(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_inbound.isClosed) {
      await _inbound.close();
    }
    unawaited(_closeCompleter?.future);
    _closeCompleter?.complete();
  }

  @override
  int? closeCode;

  @override
  String? closeReason;

  /// Marks the connection as established.
  void markReady() {
    if (!_readyCompleter.isCompleted) _readyCompleter.complete();
  }

  /// Delivers an inbound text or binary frame to the SDK.
  void emit(Object frame) {
    if (!_inbound.isClosed) {
      _inbound.add(frame);
    }
  }

  /// Simulates the server closing the connection.
  void serverClose({int? code, String? reason}) {
    closeCode = code;
    closeReason = reason;
    unawaited(_inbound.close());
  }

  /// Completes when [close] has been called by the consumer.
  Future<void> get closedByConsumer {
    if (_closed) return Future<void>.value();
    _closeCompleter ??= Completer<void>();
    return _closeCompleter!.future;
  }
}

/// A [WsFactory] that hands out [FakeWsSocket]s or throws scripted errors.
class FakeWsFactory implements WsFactory {
  /// Errors to throw from [connect], in order.
  final List<Object> connectErrors = [];

  /// Sockets to deliver from [connect], in order (created by the test).
  final List<FakeWsSocket> queuedSockets = [];

  /// Sockets actually delivered, in delivery order.
  final List<FakeWsSocket> delivered = [];

  /// URIs seen by [connect].
  final List<Uri> uris = [];

  /// Authorization headers seen by [connect].
  final List<String> authorizationHeaders = [];

  /// Timeouts seen by [connect].
  final List<Duration> connectTimeouts = [];

  int connectCalls = 0;

  /// Queues [error] to be thrown by the next [connect].
  void enqueueError(Object error) => connectErrors.add(error);

  /// Queues a fresh socket to be delivered by the next [connect].
  FakeWsSocket enqueueSocket() {
    final socket = FakeWsSocket();
    queuedSockets.add(socket);
    return socket;
  }

  @override
  Future<WsSocket> connect(
    Uri uri, {
    required String authorizationHeader,
    required Duration connectTimeout,
  }) async {
    connectCalls++;
    uris.add(uri);
    authorizationHeaders.add(authorizationHeader);
    connectTimeouts.add(connectTimeout);
    if (connectErrors.isNotEmpty) {
      throw connectErrors.removeAt(0);
    }
    final socket =
        queuedSockets.isNotEmpty ? queuedSockets.removeAt(0) : FakeWsSocket();
    delivered.add(socket);
    return socket;
  }
}
