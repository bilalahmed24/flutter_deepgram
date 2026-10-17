/// Supplementary tests for hardening fixes applied after the module suites
/// were written: `host:port` base URLs, injectable probes, grant error
/// mapping, and the compile-time stub factory.
library;

import 'dart:async';

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:flutter_deepgram/src/core/ws/ws_factory_stub.dart'
    as stub; // ignore: implementation_imports
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'helpers/fake_http.dart';
import 'helpers/fakes.dart';

void main() {
  group('DeepgramConfig baseUrl with explicit port', () {
    test('restUri and wsUri honor host:port', () {
      const config = DeepgramConfig(apiKey: 'k', baseUrl: '127.0.0.1:8080');
      expect(
        config.restUri('/v1/listen').toString(),
        'https://127.0.0.1:8080/v1/listen',
      );
      expect(
        config.wsUri('/v1/listen').toString(),
        'wss://127.0.0.1:8080/v1/listen',
      );
    });

    test('IPv6 bracket form with port parses', () {
      const config = DeepgramConfig(apiKey: 'k', baseUrl: '[::1]:9000');
      final uri = config.restUri('/v1/listen');
      expect(uri.host, '::1');
      expect(uri.port, 9000);
    });

    test('a host with no port is untouched', () {
      const config = DeepgramConfig(apiKey: 'k', baseUrl: 'api.deepgram.com');
      expect(config.restUri('/v1/listen').port, 443);
      expect(config.restUri('/v1/listen').host, 'api.deepgram.com');
    });

    test('a non-numeric suffix after the colon is invalid host input and '
        'throws FormatException from Uri', () {
      // `host:notaport` is neither a valid host nor a port; the builder
      // passes it through and Uri rejects it loudly (caller error).
      const config = DeepgramConfig(apiKey: 'k', baseUrl: 'localhost:notaport');
      expect(() => config.restUri('/v1/listen'), throwsFormatException);
    });

    test('query parameters survive alongside a port', () {
      const config = DeepgramConfig(apiKey: 'k', baseUrl: 'proxy.local:8443');
      final uri = config.wsUri('/v1/listen', {'model': 'nova-3'});
      expect(uri.toString(), 'wss://proxy.local:8443/v1/listen?model=nova-3');
    });

    test('agent URIs honor the agent host port', () {
      const config = DeepgramConfig(
        apiKey: 'k',
        agentBaseUrl: 'agent.local:9443',
      );
      expect(
        config.agentWsUri('/v1/agent/converse').toString(),
        'wss://agent.local:9443/v1/agent/converse',
      );
    });
  });

  group('ConnectivityProbe with injected client', () {
    test('non-positive status code marks the probe red', () async {
      final queue = QueueHttpClient();
      queue.enqueueRaw((request) => http.Response('nope', 0, request: request));
      final probe = ConnectivityProbe(
        probeUrl: 'https://probe.test/',
        client: queue,
      );
      expect(await probe.isInternetAvailable(), isFalse);
      expect(probe.lastRedAt, isNotNull);
      expect(probe.lastGreenAt, isNull);
    });

    test('a throwing client marks the probe red without throwing', () async {
      final queue = QueueHttpClient();
      queue.enqueueError(http.ClientException('boom'));
      final probe = ConnectivityProbe(
        probeUrl: 'https://probe.test/',
        client: queue,
      );
      expect(await probe.isInternetAvailable(), isFalse);
      expect(probe.lastRedAt, isNotNull);
    });

    test('a green response marks the probe green', () async {
      final queue = QueueHttpClient();
      queue.enqueueRaw((request) => http.Response('', 204, request: request));
      final probe = ConnectivityProbe(
        probeUrl: 'https://probe.test/',
        client: queue,
      );
      expect(await probe.isInternetAvailable(), isTrue);
      expect(probe.lastGreenAt, isNotNull);
    });

    test('a hanging client times out to red', () async {
      final probe = ConnectivityProbe(
        probeUrl: 'https://probe.test/',
        client: _HangingClient(),
      );
      final watch = Stopwatch()..start();
      expect(await probe.isInternetAvailable(), isFalse);
      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 5)));
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  group('DeepgramAuth.grantTemporaryToken error hardening', () {
    test('a non-JSON 200 body becomes DeepgramServerException', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson('<html>gateway error</html>');
      final auth = DeepgramAuth(testConfig);
      await http.runWithClient(() async {
        await expectLater(
          auth.grantTemporaryToken(),
          throwsA(isA<DeepgramServerException>()),
        );
      }, () => queue);
    });
  });

  group('StubWsFactory (unsupported platforms)', () {
    test('connect throws UnsupportedError', () {
      expect(
        stub.defaultWsFactory.connect(
          Uri.parse('wss://api.deepgram.com/v1/listen'),
          authorizationHeader: 'Token k',
          connectTimeout: const Duration(seconds: 5),
        ),
        throwsUnsupportedError,
      );
    });
  });
}

/// An [http.Client] whose requests never complete (routes through `send`,
/// like a real client).
class _HangingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return Completer<http.StreamedResponse>().future;
  }
}
