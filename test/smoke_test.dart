/// Smoke test: the public barrel imports, the fakes compile, and a
/// resilient websocket round-trips frames against the fake factory.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:test/test.dart';

import 'helpers/fake_ws.dart';
import 'helpers/fakes.dart';

void main() {
  test('barrel exports usable types and fake plumbing works', () async {
    final factory = FakeWsFactory();
    final socket = factory.enqueueSocket();

    final ws = ResilientWebSocket(
      uri: Uri.parse('wss://api.deepgram.com/v1/listen'),
      config: testConfig,
      auth: DeepgramAuth(testConfig),
      wsFactory: factory,
      probe: FakeProbe(),
      options: const ResilientWebSocketOptions(
        keepAliveInterval: Duration(minutes: 30),
      ),
    );

    final states = <WsConnectionState>[];
    final sub = ws.states.listen(states.add);
    final received = <WsMessage>[];
    final msgSub = ws.messages.listen(received.add);

    // connect() resolves only when the whole session ends — subscribe to
    // states first and await the open transition (the documented pattern).
    final opened = ws.states.firstWhere(
      (WsConnectionState state) => state == WsConnectionState.open,
    );
    unawaited(ws.connect());
    await opened;
    expect(ws.isConnected, isTrue);
    expect(factory.authorizationHeaders.single, 'Token test-api-key');

    socket.emit(jsonEncode({'type': 'Metadata'}));
    socket.emit(<int>[1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(received, hasLength(2));
    expect(received.first.isText, isTrue);
    expect(received.first.text, contains('Metadata'));
    expect(received.last.isBinary, isTrue);
    expect(received.last.bytes, <int>[1, 2, 3]);

    ws.send('hello');
    expect(socket.sent, contains('hello'));

    await ws.close();
    expect(ws.state, WsConnectionState.closed);
    expect(states, containsAll(<WsConnectionState>[WsConnectionState.open]));

    await sub.cancel();
    await msgSub.cancel();
    await ws.dispose();
  });
}
