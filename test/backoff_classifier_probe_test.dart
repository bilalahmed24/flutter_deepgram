/// Unit tests for [BackoffPolicy], [WsFailureClassifier] and
/// [ConnectivityProbe].
///
/// The connectivity tests talk only to an ephemeral loopback HTTP server
/// (bound to 127.0.0.1 on a random free port) — no external network access
/// happens anywhere in this file.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  group('BackoffPolicy', () {
    test('grows exponentially with the multiplier', () {
      final policy = BackoffPolicy(
        baseDelay: const Duration(seconds: 1),
        maxDelay: const Duration(minutes: 10),
        multiplier: 2,
        jitterFraction: 0,
        random: math.Random(7),
      );

      expect(policy.delayFor(1), const Duration(seconds: 1));
      expect(policy.delayFor(2), const Duration(seconds: 2));
      expect(policy.delayFor(3), const Duration(seconds: 4));
      expect(policy.delayFor(4), const Duration(seconds: 8));
    });

    test('clamps attempts below one to the first-retry delay', () {
      final policy = BackoffPolicy(
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(seconds: 30),
        multiplier: 2,
        jitterFraction: 0,
        random: math.Random(7),
      );

      final first = policy.delayFor(1);
      expect(policy.delayFor(0), first);
      expect(policy.delayFor(-7), first);
    });

    test('caps the raw delay at maxDelay', () {
      final policy = BackoffPolicy(
        baseDelay: const Duration(seconds: 1),
        maxDelay: const Duration(seconds: 5),
        multiplier: 2,
        jitterFraction: 0,
        random: math.Random(7),
      );

      // Raw growth would be 16 s and 2^49 s respectively.
      expect(policy.delayFor(5), const Duration(seconds: 5));
      expect(policy.delayFor(50), const Duration(seconds: 5));
    });

    test('supports custom and fractional multipliers', () {
      final triple = BackoffPolicy(
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(minutes: 10),
        multiplier: 3,
        jitterFraction: 0,
        random: math.Random(7),
      );
      expect(triple.delayFor(2), const Duration(milliseconds: 300));

      final fractional = BackoffPolicy(
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(minutes: 10),
        multiplier: 1.5,
        jitterFraction: 0,
        random: math.Random(7),
      );
      expect(fractional.delayFor(3), const Duration(milliseconds: 225));
    });

    test('keeps jitter within ±jitterFraction of the capped delay', () {
      final policy = BackoffPolicy(
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(seconds: 1),
        multiplier: 2,
        jitterFraction: 0.25,
        random: math.Random(42),
      );

      for (var attempt = 1; attempt <= 10; attempt++) {
        final rawMs = 100 * math.pow(2.0, attempt - 1);
        final cappedMs = math.min(rawMs, 1000);
        final delay = policy.delayFor(attempt);
        expect(
          delay.inMilliseconds,
          inInclusiveRange(
            (cappedMs * 0.75).floor() - 1,
            (cappedMs * 1.25).ceil() + 1,
          ),
          reason: 'attempt $attempt',
        );
      }
    });

    test('repeated calls for the same attempt stay in bounds (stateless)',
        () async {
      final policy = BackoffPolicy(
        baseDelay: const Duration(seconds: 1),
        maxDelay: const Duration(seconds: 30),
        multiplier: 2,
        jitterFraction: 0.25,
        random: math.Random(99),
      );

      for (var i = 0; i < 5; i++) {
        final delay = policy.delayFor(2);
        expect(delay.inMilliseconds, inInclusiveRange(1499, 2501));
      }
    });

    test('default-constructed policies never exceed max + jitter', () {
      final policy = BackoffPolicy();

      for (var attempt = 1; attempt <= 12; attempt++) {
        final delay = policy.delayFor(attempt);
        expect(delay, greaterThanOrEqualTo(Duration.zero));
        expect(
          delay,
          lessThanOrEqualTo(const Duration(milliseconds: 37500)),
          reason: 'attempt $attempt',
        );
      }
    });
  });

  group('WsFailureClassifier', () {
    final classifier = WsFailureClassifier();

    test('WebSocket upgrade refusals are Deepgram-definitive', () {
      // Real dart:io exception thrown when the HTTP upgrade is refused.
      expect(
        classifier.classify(const WebSocketException('was not upgraded')),
        WsFailureClassification.deepgramDefinitive,
      );
      // The wrapper type used by the SDK's IO websocket factory.
      expect(
        classifier.classify(
          WebSocketChannelException.from(const WebSocketException('refused')),
        ),
        WsFailureClassification.deepgramDefinitive,
      );
    });

    test('upgrade-refusal text patterns are Deepgram-definitive', () {
      const messages = [
        'Connection was not upgraded to websocket',
        'server refused the websocket upgrade',
        'invalid status code (401)',
      ];
      for (final message in messages) {
        expect(
          classifier.classify(Exception(message)),
          WsFailureClassification.deepgramDefinitive,
          reason: message,
        );
      }
    });

    test('the exception type name wins over path-broken text', () {
      // A WebSocketException means a server answered — even if the message
      // mentions a timeout.
      expect(
        classifier.classify(const WebSocketException('connection timed out')),
        WsFailureClassification.deepgramDefinitive,
      );
    });

    test('path-broken socket errors are internet-suspect', () {
      const errors = [
        SocketException('Network unreachable'),
        SocketException('Network is unreachable'),
        SocketException('Connection timed out'),
        SocketException("Failed host lookup: 'api.deepgram.com'"),
      ];
      for (final error in errors) {
        expect(
          classifier.classify(error),
          WsFailureClassification.internetSuspect,
          reason: error.message,
        );
      }
    });

    test('path-broken text patterns are internet-suspect', () {
      const messages = [
        'timeout while connecting',
        'no address associated with hostname',
      ];
      for (final message in messages) {
        expect(
          classifier.classify(Exception(message)),
          WsFailureClassification.internetSuspect,
          reason: message,
        );
      }
    });

    test('peer-level failures without path keywords are ambiguous', () {
      // TLS handshake failures: a peer answered, so the path could be fine.
      expect(
        classifier.classify(const HandshakeException('bad certificate')),
        WsFailureClassification.ambiguous,
      );
      // A plain connection refusal: a peer answered and said no.
      expect(
        classifier.classify(const SocketException('Connection refused')),
        WsFailureClassification.ambiguous,
      );
    });

    test('unknown error shapes are ambiguous', () {
      expect(
        classifier.classify(Exception('something odd')),
        WsFailureClassification.ambiguous,
      );
      expect(
        classifier.classify(StateError('bad state')),
        WsFailureClassification.ambiguous,
      );
      expect(classifier.classify(42), WsFailureClassification.ambiguous);
    });
  });

  group('ConnectivityProbe', () {
    test('starts with no green or red timestamps', () {
      final probe = ConnectivityProbe(probeUrl: 'https://probe.example/');

      expect(probe.probeUrl, 'https://probe.example/');
      expect(probe.lastGreenAt, isNull);
      expect(probe.lastRedAt, isNull);
    });

    test('a reachable endpoint reports up and stamps lastGreenAt (UTC)',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) => request.response.close());

      final probe = ConnectivityProbe(
        probeUrl: 'http://127.0.0.1:${server.port}/',
      );
      final before = DateTime.now().toUtc();

      final up = await probe.isInternetAvailable();
      final after = DateTime.now().toUtc();

      expect(up, isTrue);
      expect(probe.lastGreenAt, isNotNull);
      expect(probe.lastRedAt, isNull);
      final green = probe.lastGreenAt!;
      expect(green.isUtc, isTrue);
      expect(green.isBefore(before), isFalse);
      expect(green.isAfter(after), isFalse);

      await server.close();
    });

    test('a refused connection reports down and stamps lastRedAt (UTC)',
        () async {
      // Bind an ephemeral port, then close it so nothing listens there.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = server.port;
      await server.close();

      final probe = ConnectivityProbe(
        probeUrl: 'http://127.0.0.1:$deadPort/',
      );

      final up = await probe.isInternetAvailable();

      expect(up, isFalse);
      expect(probe.lastGreenAt, isNull);
      expect(probe.lastRedAt, isNotNull);
      expect(probe.lastRedAt!.isUtc, isTrue);
    });

    test('never throws, even for a malformed probe URL', () async {
      final probe = ConnectivityProbe(probeUrl: '::not a valid url::');

      final up = await probe.isInternetAvailable();

      expect(up, isFalse);
      expect(probe.lastRedAt, isNotNull);
    });

    test('tracks green and red transitions over time', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) => request.response.close());
      final probe = ConnectivityProbe(
        probeUrl: 'http://127.0.0.1:${server.port}/',
      );

      expect(await probe.isInternetAvailable(), isTrue);

      await server.close();
      expect(await probe.isInternetAvailable(), isFalse);

      expect(probe.lastGreenAt, isNotNull);
      expect(probe.lastRedAt, isNotNull);
      expect(probe.lastRedAt!.isAfter(probe.lastGreenAt!), isTrue);
    });
  });
}
