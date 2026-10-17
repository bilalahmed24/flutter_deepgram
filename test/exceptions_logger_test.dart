/// Unit tests for the typed exception hierarchy ([DeepgramException] and
/// every subclass), the pluggable [DeepgramLogger], and the HTTP status →
/// exception mapping performed by [HttpEngine] against the fake HTTP client.
library;

import 'dart:async';

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'helpers/fake_http.dart';

/// An [HttpEngine] wired to [queue] with retries disabled, so retryable
/// statuses (429/5xx) map to exceptions immediately instead of sleeping.
HttpEngine _engine(QueueHttpClient queue) {
  final config = DeepgramConfig(
    apiKey: 'test-api-key',
    requestTimeout: const Duration(seconds: 2),
    maxRetries: 0,
    retryBaseDelay: const Duration(milliseconds: 1),
    retryMaxDelay: const Duration(milliseconds: 5),
  );
  return HttpEngine(config: config, auth: DeepgramAuth(config), client: queue);
}

void main() {
  group('DeepgramException', () {
    test('exposes message, requestId, and code', () {
      const e = DeepgramException('boom', requestId: 'r-1', code: 'E_1');
      expect(e.message, 'boom');
      expect(e.requestId, 'r-1');
      expect(e.code, 'E_1');
      expect(e, isA<Exception>());
    });

    test('toString appends code and request id only when present', () {
      expect(
        const DeepgramException('boom').toString(),
        'DeepgramException: boom',
      );
      expect(
        const DeepgramException('boom', code: 'E_1').toString(),
        'DeepgramException: boom (code: E_1)',
      );
      expect(
        const DeepgramException('boom', requestId: 'r-1').toString(),
        'DeepgramException: boom (request_id: r-1)',
      );
      expect(
        const DeepgramException('boom', requestId: 'r-1', code: 'E_1')
            .toString(),
        'DeepgramException: boom (code: E_1) (request_id: r-1)',
      );
    });

    test('every specialized exception is a const DeepgramException', () {
      const exceptions = <DeepgramException>[
        DeepgramAuthException('a'),
        DeepgramBadRequestException('b'),
        DeepgramNotFoundException('c'),
        DeepgramQuotaException('d'),
        DeepgramRateLimitException('e'),
        DeepgramServerException('f'),
        DeepgramNetworkException('g'),
        DeepgramTimeoutException('h'),
        DeepgramWebSocketException('i'),
        DeepgramStateException('j'),
      ];
      for (final e in exceptions) {
        expect(e, isA<DeepgramException>());
        expect(e, isA<Exception>());
      }
      expect(exceptions.first.message, 'a');
      expect(exceptions.last.message, 'j');
    });

    test('subclasses carry their optional metadata', () {
      const rateLimited = DeepgramRateLimitException(
        'slow down',
        retryAfter: Duration(seconds: 3),
        requestId: 'r-9',
        code: 'RATE',
      );
      expect(rateLimited.retryAfter, const Duration(seconds: 3));
      expect(rateLimited.requestId, 'r-9');
      expect(rateLimited.code, 'RATE');

      const socket = DeepgramWebSocketException(
        'abnormal closure',
        closeCode: 1006,
        closeReason: 'gone',
      );
      expect(socket.closeCode, 1006);
      expect(socket.closeReason, 'gone');

      const timeout = DeepgramTimeoutException('too slow');
      expect(timeout.requestId, isNull);
      expect(timeout.code, isNull);

      const state = DeepgramStateException('already closed');
      expect(state.message, 'already closed');
    });
  });

  group('DeepgramNetworkException', () {
    test('without a cause', () {
      const e = DeepgramNetworkException('dns failure');
      expect(e.cause, isNull);
      expect(e.toString(), 'DeepgramNetworkException: dns failure');
    });

    test('with a cause', () {
      final cause = StateError('socket closed');
      final e = DeepgramNetworkException('transport', cause: cause);
      expect(e.cause, same(cause));
      expect(
        e.toString(),
        'DeepgramNetworkException: transport '
        '(cause: Bad state: socket closed)',
      );
    });
  });

  group('DeepgramWebSocketException', () {
    test('omits the close suffix without a close code', () {
      expect(
        const DeepgramWebSocketException('refused').toString(),
        'DeepgramWebSocketException: refused',
      );
    });

    test('prints the close code alone', () {
      expect(
        const DeepgramWebSocketException('closed', closeCode: 1011).toString(),
        'DeepgramWebSocketException: closed (closeCode: 1011)',
      );
    });

    test('prints the close reason next to the code', () {
      expect(
        const DeepgramWebSocketException(
          'closed',
          closeCode: 4008,
          closeReason: 'session expired',
        ).toString(),
        'DeepgramWebSocketException: closed '
        '(closeCode: 4008, closeReason: session expired)',
      );
    });

    test('skips an empty close reason', () {
      expect(
        const DeepgramWebSocketException('closed',
                closeCode: 4008, closeReason: '')
            .toString(),
        'DeepgramWebSocketException: closed (closeCode: 4008)',
      );
    });
  });

  group('DeepgramLogger', () {
    test('a fresh logger has no listeners and logging is a safe no-op', () {
      final logger = DeepgramLogger();
      expect(logger.hasListeners, isFalse);
      logger.debug('d');
      logger.info('i');
      logger.warn('w');
      logger.error('e', StateError('boom'));
      expect(logger.hasListeners, isFalse);
    });

    test('the sink constructor receives all four levels and the error', () {
      final events = <(String, String, Object?)>[];
      final logger = DeepgramLogger(
        sink: (level, message, error) => events.add((level, message, error)),
      );
      expect(logger.hasListeners, isTrue);
      final boom = StateError('boom');
      logger.debug('m1');
      logger.info('m2');
      logger.warn('m3');
      logger.error('m4', boom);
      expect(events, <(String, String, Object?)>[
        ('debug', 'm1', null),
        ('info', 'm2', null),
        ('warn', 'm3', null),
        ('error', 'm4', boom),
      ]);
    });

    test('addListener returns a working detach function', () {
      final logger = DeepgramLogger();
      final seen = <String>[];
      final detach = logger.addListener((level, message, error) {
        seen.add(message);
      });
      expect(logger.hasListeners, isTrue);
      logger.info('one');
      detach();
      expect(logger.hasListeners, isFalse);
      logger.info('two');
      expect(seen, <String>['one']);
      // Double-detaching is harmless.
      detach();
    });

    test('all listeners receive events, in registration order', () {
      final logger = DeepgramLogger();
      final order = <String>[];
      logger.addListener((level, message, error) => order.add('a:$message'));
      logger.addListener((level, message, error) => order.add('b:$message'));
      logger.warn('w');
      expect(order, <String>['a:w', 'b:w']);
    });

    test('a throwing listener cannot break logging or block others', () {
      final logger = DeepgramLogger();
      final seen = <String>[];
      logger.addListener((level, message, error) {
        throw StateError('listener bug');
      });
      logger.addListener((level, message, error) {
        seen.add(message);
      });
      logger.info('still delivered');
      expect(seen, <String>['still delivered']);
    });

    test('listeners added during an emit do not receive the in-flight event',
        () {
      final logger = DeepgramLogger();
      final order = <String>[];
      logger.addListener((level, message, error) {
        order.add('first:$message');
        logger.addListener((level, message, error) {
          order.add('third:$message');
        });
      });
      logger.addListener((level, message, error) {
        order.add('second:$message');
      });
      logger.info('a');
      expect(order, <String>['first:a', 'second:a']);
      logger.info('b');
      expect(order, <String>[
        'first:a',
        'second:a',
        'first:b',
        'second:b',
        'third:b',
      ]);
    });

    test('clearListeners removes every listener', () {
      var sinkCalls = 0;
      var listenerCalls = 0;
      final logger = DeepgramLogger(
        sink: (level, message, error) => sinkCalls++,
      );
      logger.addListener((level, message, error) => listenerCalls++);
      logger.info('before');
      logger.clearListeners();
      expect(logger.hasListeners, isFalse);
      logger.info('after');
      expect(sinkCalls, 1);
      expect(listenerCalls, 1);
    });

    test('the shared noop logger discards events', () {
      expect(DeepgramLogger.noop.hasListeners, isFalse);
      DeepgramLogger.noop.debug('ignored');
      DeepgramLogger.noop.info('ignored');
      DeepgramLogger.noop.warn('ignored');
      DeepgramLogger.noop.error('ignored');
      expect(DeepgramLogger.noop.hasListeners, isFalse);
    });
  });

  group('HTTP status mapping (via HttpEngine)', () {
    test('200 decodes a JSON body and surfaces the request id', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(
        <String, dynamic>{'ok': true},
        headers: <String, String>{'x-request-id': 'rid-1'},
      );
      final result = await _engine(queue).getJson('/v1/projects');
      expect(result.body, <String, dynamic>{'ok': true});
      expect(result.requestId, 'rid-1');
    });

    test('400 maps to DeepgramBadRequestException with body metadata',
        () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{
        'err_msg': 'the query was invalid',
        'request_id': 'req-1',
        'err_code': 'INVALID_QUERY',
      }, status: 400);
      await expectLater(
        _engine(queue).getJson('/v1/listen'),
        throwsA(isA<DeepgramBadRequestException>()
            .having((e) => e.message, 'message', 'the query was invalid')
            .having((e) => e.requestId, 'requestId', 'req-1')
            .having((e) => e.code, 'code', 'INVALID_QUERY')),
      );
    });

    test('400 with an undecodable body falls back to the status text',
        () async {
      final queue = QueueHttpClient();
      queue.enqueueJson('not json', status: 400);
      await expectLater(
        _engine(queue).getJson('/v1/listen'),
        throwsA(isA<DeepgramBadRequestException>()
            .having((e) => e.message, 'message', 'HTTP 400.')
            .having((e) => e.requestId, 'requestId', isNull)
            .having((e) => e.code, 'code', isNull)),
      );
    });

    test('nested {error:{message}} bodies are unwrapped', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{
        'error': <String, dynamic>{'message': 'nested reason'},
      }, status: 400);
      await expectLater(
        _engine(queue).getJson('/v1/listen'),
        throwsA(isA<DeepgramBadRequestException>()
            .having((e) => e.message, 'message', 'nested reason')),
      );
    });

    test('401 and 403 map to DeepgramAuthException', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{'message': 'invalid api key'},
          status: 401);
      queue.enqueueJson(<String, dynamic>{'reason': 'membership required'},
          status: 403);
      await expectLater(
        _engine(queue).getJson('/v1/projects'),
        throwsA(isA<DeepgramAuthException>()
            .having((e) => e.message, 'message', 'invalid api key')),
      );
      await expectLater(
        _engine(queue).getJson('/v1/projects'),
        throwsA(isA<DeepgramAuthException>()
            .having((e) => e.message, 'message', 'membership required')),
      );
    });

    test('402 maps to DeepgramQuotaException', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{'message': 'insufficient credit'},
          status: 402);
      await expectLater(
        _engine(queue).getJson('/v1/listen'),
        throwsA(isA<DeepgramQuotaException>()
            .having((e) => e.message, 'message', 'insufficient credit')),
      );
    });

    test(
        '404 maps to DeepgramNotFoundException, preferring the body request '
        'id over the header', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{'message': 'no such project'},
          status: 404, headers: <String, String>{'x-request-id': 'hdr-7'});
      queue.enqueueJson(<String, dynamic>{},
          status: 404, headers: <String, String>{'x-request-id': 'hdr-8'});
      await expectLater(
        _engine(queue).getJson('/v1/projects/missing'),
        throwsA(isA<DeepgramNotFoundException>()
            .having((e) => e.message, 'message', 'no such project')
            .having((e) => e.requestId, 'requestId', 'hdr-7')),
      );
      await expectLater(
        _engine(queue).getJson('/v1/projects/missing'),
        throwsA(isA<DeepgramNotFoundException>()
            .having((e) => e.message, 'message', 'HTTP 404.')
            .having((e) => e.requestId, 'requestId', 'hdr-8')),
      );
    });

    test('429 maps to DeepgramRateLimitException with a parsed Retry-After',
        () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{'message': 'rate limited'},
          status: 429, headers: <String, String>{'retry-after': '2'});
      await expectLater(
        _engine(queue).getJson('/v1/listen'),
        throwsA(isA<DeepgramRateLimitException>()
            .having((e) => e.message, 'message', 'rate limited')
            .having(
                (e) => e.retryAfter, 'retryAfter', const Duration(seconds: 2))),
      );
    });

    test('429 with a fractional Retry-After rounds to milliseconds', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{'message': 'slow down'},
          status: 429, headers: <String, String>{'retry-after': '0.25'});
      await expectLater(
        _engine(queue).getJson('/v1/listen'),
        throwsA(isA<DeepgramRateLimitException>().having((e) => e.retryAfter,
            'retryAfter', const Duration(milliseconds: 250))),
      );
    });

    test('429 without a Retry-After header leaves retryAfter null', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{'message': 'slow down'}, status: 429);
      await expectLater(
        _engine(queue).getJson('/v1/listen'),
        throwsA(isA<DeepgramRateLimitException>()
            .having((e) => e.retryAfter, 'retryAfter', isNull)),
      );
    });

    test('unknown 4xx statuses map to the base DeepgramException', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{'message': 'teapot'}, status: 418);
      await expectLater(
        _engine(queue).getJson('/v1/coffee'),
        throwsA(isA<DeepgramException>()
            .having((e) => e.message, 'message', 'teapot')
            .having((e) => e is DeepgramAuthException, 'notAuth', isFalse)
            .having((e) => e is DeepgramBadRequestException, 'notBadRequest',
                isFalse)
            .having((e) => e is DeepgramServerException, 'notServer', isFalse)),
      );
    });

    test('5xx map to DeepgramServerException', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{'message': 'internal error'},
          status: 500);
      queue.enqueueJson('Service Unavailable', status: 503);
      await expectLater(
        _engine(queue).getJson('/v1/listen'),
        throwsA(isA<DeepgramServerException>()
            .having((e) => e.message, 'message', 'internal error')),
      );
      await expectLater(
        _engine(queue).getJson('/v1/listen'),
        throwsA(isA<DeepgramServerException>()
            .having((e) => e.message, 'message', 'HTTP 503.')),
      );
    });

    test('transport timeouts map to DeepgramTimeoutException', () async {
      final queue = QueueHttpClient();
      queue.enqueueError(TimeoutException('too slow'));
      await expectLater(
        _engine(queue).getJson('/v1/listen'),
        throwsA(isA<DeepgramTimeoutException>().having(
            (e) => e.message, 'message', 'Request timed out after 2s.')),
      );
    });

    test('client failures map to DeepgramNetworkException with a cause',
        () async {
      final queue = QueueHttpClient();
      queue.enqueueError(http.ClientException('connection refused'));
      await expectLater(
        _engine(queue).getJson('/v1/listen'),
        throwsA(isA<DeepgramNetworkException>()
            .having((e) => e.message, 'message', 'HTTP transport failure.')
            .having((e) => e.cause, 'cause', isA<http.ClientException>())),
      );
    });

    test('a cancelled token throws DeepgramException naming the reason',
        () async {
      final queue = QueueHttpClient();
      final engine = _engine(queue);
      final token = HttpCancelToken()..cancel('user aborted');
      await expectLater(
        engine.getJson('/v1/projects', cancelToken: token),
        throwsA(isA<DeepgramException>().having(
          (e) => e.message,
          'message',
          'Request cancelled: user aborted',
        )),
      );
    });

    test('HttpCancelToken reports its state and completes whenCancelled',
        () async {
      final token = HttpCancelToken();
      expect(token.isCancelled, isFalse);
      expect(token.reason, isNull);
      final fired = token.whenCancelled;
      token.cancel('why');
      expect(token.isCancelled, isTrue);
      expect(token.reason, 'why');
      await fired;
      // A later cancel() call overwrites the reason with the default.
      token.cancel();
      expect(token.reason, 'cancelled');

      final defaulted = HttpCancelToken()..cancel();
      expect(defaulted.reason, 'cancelled');
    });
  });
}
