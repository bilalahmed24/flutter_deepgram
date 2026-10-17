/// Unit tests for the resilient REST engine ([HttpEngine]) and its
/// [HttpCancelToken].
///
/// Everything is faked: [QueueHttpClient] serves queued responses,
/// [HangingClient] never answers (deterministic timeout paths), and
/// [CapturingClient] records exact wire bytes. No test touches the network
/// or sleeps for more than ~150 ms of wall time.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'helpers/fake_http.dart';
import 'helpers/fakes.dart';

/// Awaits [future] and returns the error it threw; fails the test if the
/// future completed normally.
Future<Object> thrownBy(Future<Object?> future) async {
  final error = await future.then<Object?>(
    (_) => null,
    onError: (Object e) => e,
  );
  if (error == null) {
    fail('Expected the call to throw, but it completed successfully.');
  }
  return error;
}

/// Matches the [DeepgramException] the engine throws for a cancelled request.
Matcher isCancelledWith(String reason) => predicate<DeepgramException>(
  (error) => error.message == 'Request cancelled: $reason',
  'a DeepgramException cancelled with reason "$reason"',
);

/// An [http.Client] whose requests never complete — used to exercise the
/// engine's timeout paths deterministically (no sockets involved).
class HangingClient extends http.BaseClient {
  /// Number of requests that reached [send].
  int sendCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sendCount++;
    return Completer<http.StreamedResponse>().future;
  }
}

/// A request captured verbatim by [CapturingClient].
class CapturedRequest {
  CapturedRequest(this.method, this.url, this.headers, this.bodyBytes);

  /// HTTP verb of the request.
  final String method;

  /// Target URL.
  final Uri url;

  /// Headers exactly as they were sent.
  final Map<String, String> headers;

  /// Body bytes exactly as they were sent.
  final List<int> bodyBytes;
}

/// An [http.Client] that records every request verbatim — unlike the queue
/// client, which stringifies convenience-method bodies — and always answers
/// 200 with a tiny non-JSON body.
class CapturingClient extends http.BaseClient {
  /// Requests captured so far.
  final List<CapturedRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    requests.add(
      CapturedRequest(
        request.method,
        request.url,
        Map<String, String>.from(request.headers),
        bytes,
      ),
    );
    return http.StreamedResponse(
      Stream<List<int>>.value(const <int>[1, 2]),
      200,
      request: request,
    );
  }
}

/// Builds an engine over [client] with [testConfig] (or an override).
HttpEngine engineWith(http.Client client, {DeepgramConfig? config}) {
  final effective = config ?? testConfig;
  return HttpEngine(
    config: effective,
    auth: DeepgramAuth(effective),
    client: client,
  );
}

void main() {
  group('HttpCancelToken', () {
    test('starts uncancelled and whenCancelled stays pending', () async {
      final token = HttpCancelToken();

      expect(token.isCancelled, isFalse);
      expect(token.reason, isNull);

      var notified = false;
      unawaited(token.whenCancelled.then((_) => notified = true));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(notified, isFalse);
    });

    test('cancel() completes whenCancelled and records the reason', () async {
      final token = HttpCancelToken();
      var notified = false;
      unawaited(token.whenCancelled.then((_) => notified = true));

      token.cancel('user closed the page');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(token.isCancelled, isTrue);
      expect(token.reason, 'user closed the page');
      expect(notified, isTrue);
    });

    test('default reason is "cancelled"; double cancel is safe', () async {
      final token = HttpCancelToken();

      token.cancel();
      expect(token.reason, 'cancelled');
      expect(token.isCancelled, isTrue);

      token.cancel('second attempt');
      expect(token.reason, 'second attempt');

      // Already completed once — still completes exactly once.
      await expectLater(token.whenCancelled, completes);
    });
  });

  group('getJson', () {
    late QueueHttpClient queue;
    late HttpEngine engine;

    setUp(() {
      queue = QueueHttpClient();
      engine = engineWith(queue);
    });

    test('decodes a 200 JSON body and extracts x-request-id', () async {
      queue.enqueueJson(
        {'request_id': 'b41f', 'results': <String, dynamic>{}},
        headers: {'x-request-id': 'hdr-1'},
      );

      final result = await engine.getJson('/v1/listen');

      expect(result.body['request_id'], 'b41f');
      expect(result.requestId, 'hdr-1');
    });

    test('builds the URL from path and query parameters', () async {
      queue.enqueueJson({'ok': true});

      await engine.getJson(
        '/v1/listen',
        query: {
          'model': 'nova-3',
          'punctuate': true,
          'skipped': null,
          'tag': ['alpha', 'beta'],
        },
      );

      final uri = queue.requests.single.url;
      expect(uri.scheme, 'https');
      expect(uri.host, 'api.deepgram.com');
      expect(uri.path, '/v1/listen');
      expect(uri.queryParametersAll, containsPair('model', ['nova-3']));
      expect(uri.queryParametersAll, containsPair('punctuate', ['true']));
      expect(uri.queryParametersAll, containsPair('tag', ['alpha', 'beta']));
      expect(uri.queryParameters, isNot(contains('skipped')));
    });

    test('sends Authorization: Token <key> plus extra headers', () async {
      queue.enqueueJson({'ok': true});

      await engine.getJson('/v1/listen', headers: {'X-Custom': 'yes'});

      final headers = queue.requests.single.headers;
      expect(headers['Authorization'], 'Token test-api-key');
      expect(headers['X-Custom'], 'yes');
    });

    test('sends Authorization: Bearer <jwt> for JWT credentials', () async {
      const config = DeepgramConfig(jwt: 'jwt-credential');
      final jwtEngine = engineWith(queue, config: config);
      queue.enqueueJson({'ok': true});

      await jwtEngine.getJson('/v1/read');

      expect(
        queue.requests.single.headers['Authorization'],
        'Bearer jwt-credential',
      );
    });

    test('sends Authorization: Bearer <jwt> for token providers', () async {
      final providerEngine = HttpEngine(
        config: testConfig,
        auth: DeepgramAuth(testConfig, tokenProvider: () async => 'minted-jwt'),
        client: queue,
      );
      queue.enqueueJson({'ok': true});

      await providerEngine.getJson('/v1/listen');

      expect(
        queue.requests.single.headers['Authorization'],
        'Bearer minted-jwt',
      );
    });

    test('returns an empty map when the body is not a JSON object', () async {
      queue.enqueueJson('plain text, not json');
      queue.enqueueJson('[1, 2, 3]');
      queue.enqueueJson('null');
      queue.enqueueJson('');

      for (var i = 0; i < 4; i++) {
        final result = await engine.getJson('/v1/listen');
        expect(result.body, isEmpty, reason: 'case $i');
      }
    });
  });

  group('status error mapping', () {
    late QueueHttpClient queue;
    late HttpEngine engine;

    setUp(() {
      queue = QueueHttpClient();
      engine = engineWith(queue);
    });

    test('400 -> DeepgramBadRequestException with body details', () async {
      queue.enqueueJson(
        {'err_msg': 'invalid parameter', 'request_id': 'rid-400'},
        status: 400,
        headers: {'x-request-id': 'hdr-400'},
      );

      final error = await thrownBy(engine.getJson('/v1/listen'));

      expect(error, isA<DeepgramBadRequestException>());
      final bad = error as DeepgramBadRequestException;
      expect(bad.message, 'invalid parameter');
      // The body request_id wins over the x-request-id header.
      expect(bad.requestId, 'rid-400');
    });

    test('401 and 403 -> DeepgramAuthException', () async {
      queue.enqueueJson({'err_msg': 'invalid api key'}, status: 401);
      queue.enqueueJson({'err_msg': 'forbidden'}, status: 403);

      final unauthorized =
          await thrownBy(engine.getJson('/v1/listen')) as DeepgramAuthException;
      expect(unauthorized.message, 'invalid api key');

      final forbidden =
          await thrownBy(engine.getJson('/v1/listen')) as DeepgramAuthException;
      expect(forbidden.message, 'forbidden');
    });

    test('402 -> DeepgramQuotaException', () async {
      queue.enqueueJson({'err_msg': 'out of credit'}, status: 402);

      final error = await thrownBy(engine.getJson('/v1/listen'));

      expect(error, isA<DeepgramQuotaException>());
      expect((error as DeepgramQuotaException).message, 'out of credit');
    });

    test('404 -> DeepgramNotFoundException', () async {
      queue.enqueueJson({'err_msg': 'no such project'}, status: 404);

      final error = await thrownBy(engine.getJson('/v1/projects/missing'));

      expect(error, isA<DeepgramNotFoundException>());
      expect((error as DeepgramNotFoundException).message, 'no such project');
    });

    test('other 4xx statuses -> generic DeepgramException', () async {
      queue.enqueueJson({'err_msg': 'teapot'}, status: 418);

      final error = await thrownBy(engine.getJson('/v1/listen'));

      expect(error, isA<DeepgramException>());
      expect(error, isNot(isA<DeepgramBadRequestException>()));
      expect(error, isNot(isA<DeepgramAuthException>()));
      expect(error, isNot(isA<DeepgramNotFoundException>()));
      expect((error as DeepgramException).message, 'teapot');
    });

    test('extracts messages from every documented body shape', () async {
      final cases = <(Object, String)>[
        ({'err_msg': 'm-err-msg'}, 'm-err-msg'),
        ({'message': 'm-message'}, 'm-message'),
        ({'reason': 'm-reason'}, 'm-reason'),
        ({'error': 'm-error-string'}, 'm-error-string'),
        (
          {
            'error': {'message': 'm-error-nested'},
          },
          'm-error-nested',
        ),
        ('just plain text', 'HTTP 400.'),
      ];
      for (final (body, expected) in cases) {
        queue.enqueueJson(body, status: 400);
        final error =
            await thrownBy(engine.getJson('/v1/listen')) as DeepgramException;
        expect(error.message, expected, reason: 'body was: $body');
      }
    });

    test('request id falls back to the header; err_code is surfaced', () async {
      // No request_id in the body: the x-request-id header is used.
      queue.enqueueJson(
        {'err_msg': 'x'},
        status: 400,
        headers: {'x-request-id': 'from-header'},
      );
      // Non-string request_id in the body: the header still wins.
      queue.enqueueJson(
        {'err_msg': 'x', 'request_id': 12345},
        status: 400,
        headers: {'x-request-id': 'from-header-2'},
      );
      // err_code is surfaced as the machine-readable code.
      queue.enqueueJson({'err_msg': 'x', 'err_code': 'E-42'}, status: 400);

      final first =
          await thrownBy(engine.getJson('/v1/listen')) as DeepgramException;
      expect(first.requestId, 'from-header');

      final second =
          await thrownBy(engine.getJson('/v1/listen')) as DeepgramException;
      expect(second.requestId, 'from-header-2');

      final third =
          await thrownBy(engine.getJson('/v1/listen')) as DeepgramException;
      expect(third.code, 'E-42');
    });
  });

  group('retries and backoff', () {
    test(
      '429 without Retry-After retries, then surfaces the rate limit',
      () async {
        final queue = QueueHttpClient();
        final engine = engineWith(queue); // maxRetries: 2

        for (var i = 0; i < 3; i++) {
          queue.enqueueJson({'err_msg': 'rate limited'}, status: 429);
        }

        final error = await thrownBy(engine.getJson('/v1/listen'));

        expect(error, isA<DeepgramRateLimitException>());
        final rateLimit = error as DeepgramRateLimitException;
        expect(rateLimit.retryAfter, isNull);
        expect(rateLimit.message, 'rate limited');
        expect(queue.requests, hasLength(3));
      },
    );

    test('429 with Retry-After fails fast when retries are disabled', () async {
      final queue = QueueHttpClient();
      final engine = engineWith(
        queue,
        config: testConfig.copyWith(maxRetries: 0),
      );

      queue.enqueueJson(
        {'err_msg': 'slow down'},
        status: 429,
        headers: {'retry-after': '1.5'},
      );

      final error = await thrownBy(engine.getJson('/v1/listen'));

      expect(error, isA<DeepgramRateLimitException>());
      expect(
        (error as DeepgramRateLimitException).retryAfter,
        const Duration(milliseconds: 1500),
      );
      expect(queue.requests, hasLength(1));
    });

    test('429 honors a fractional Retry-After between attempts', () async {
      final queue = QueueHttpClient();
      final engine = engineWith(queue); // maxRetries: 2

      for (var i = 0; i < 3; i++) {
        queue.enqueueJson(
          {'err_msg': 'slow down'},
          status: 429,
          headers: {'retry-after': '0.02'}, // 20 ms
        );
      }

      final stopwatch = Stopwatch()..start();
      final error = await thrownBy(engine.getJson('/v1/listen'));
      stopwatch.stop();

      expect(error, isA<DeepgramRateLimitException>());
      expect(
        (error as DeepgramRateLimitException).retryAfter,
        const Duration(milliseconds: 20),
      );
      // Two enforced 20 ms waits between the three attempts.
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(40));
      expect(queue.requests, hasLength(3));
    });

    test(
      '429 with an unparseable Retry-After yields a null retryAfter',
      () async {
        final queue = QueueHttpClient();
        final engine = engineWith(
          queue,
          config: testConfig.copyWith(maxRetries: 0),
        );

        queue.enqueueJson(
          {'err_msg': 'slow down'},
          status: 429,
          headers: {'retry-after': 'soon-ish'},
        );

        final error = await thrownBy(engine.getJson('/v1/listen'));

        expect((error as DeepgramRateLimitException).retryAfter, isNull);
      },
    );

    test('5xx responses are retried and then succeed', () async {
      final queue = QueueHttpClient();
      final engine = engineWith(queue);

      queue.enqueueJson({'err_msg': 'boom'}, status: 500);
      queue.enqueueJson({'err_msg': 'unavailable'}, status: 503);
      queue.enqueueJson({'ok': true});

      final result = await engine.getJson('/v1/listen');

      expect(result.body['ok'], true);
      expect(queue.requests, hasLength(3));
    });

    test('5xx retries exhausted -> DeepgramServerException', () async {
      final queue = QueueHttpClient();
      final engine = engineWith(queue);

      for (var i = 0; i < 3; i++) {
        queue.enqueueJson({'err_msg': 'down again'}, status: 503);
      }

      final error = await thrownBy(engine.getJson('/v1/listen'));

      expect(error, isA<DeepgramServerException>());
      expect((error as DeepgramServerException).message, 'down again');
      expect(queue.requests, hasLength(3));
    });

    test('transport failures are retried and then succeed', () async {
      final queue = QueueHttpClient();
      final engine = engineWith(queue);

      queue.enqueueError(http.ClientException('connection reset'));
      queue.enqueueError(http.ClientException('socket closed'));
      queue.enqueueJson({'ok': true});

      final result = await engine.getJson('/v1/listen');

      expect(result.body['ok'], true);
      expect(queue.requests, hasLength(3));
    });

    test(
      'transport failures exhausted -> DeepgramNetworkException with cause',
      () async {
        final queue = QueueHttpClient();
        final engine = engineWith(queue);

        final cause = http.ClientException('connection reset');
        for (var i = 0; i < 3; i++) {
          queue.enqueueError(cause);
        }

        final error = await thrownBy(engine.getJson('/v1/listen'));

        expect(error, isA<DeepgramNetworkException>());
        final network = error as DeepgramNetworkException;
        expect(network.cause, same(cause));
        expect(queue.requests, hasLength(3));
      },
    );

    test('unexpected client errors propagate unchanged', () async {
      final queue = QueueHttpClient();
      final engine = engineWith(queue);

      queue.enqueueError(Exception('surprise'));

      final error = await thrownBy(engine.getJson('/v1/listen'));

      expect(error, isNot(isA<DeepgramException>()));
      expect(error.toString(), contains('surprise'));
    });
  });

  group('timeouts', () {
    test('getJson times out per attempt, retries, then throws '
        'DeepgramTimeoutException', () async {
      final client = HangingClient();
      final engine = engineWith(
        client,
        config: testConfig.copyWith(
          requestTimeout: const Duration(milliseconds: 40),
          maxRetries: 1,
        ),
      );

      final stopwatch = Stopwatch()..start();
      final error = await thrownBy(engine.getJson('/v1/listen'));
      stopwatch.stop();

      expect(error, isA<DeepgramTimeoutException>());
      expect(
        (error as DeepgramTimeoutException).message,
        'Request timed out after 0s.',
      );
      // One initial attempt plus one retry.
      expect(client.sendCount, 2);
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(80));
    });

    test('postForByteStream times out with a descriptive message', () async {
      final client = HangingClient();
      final engine = engineWith(
        client,
        config: testConfig.copyWith(
          requestTimeout: const Duration(milliseconds: 40),
          maxRetries: 1,
        ),
      );

      final error = await thrownBy(
        engine.postForByteStream('/v1/speak', body: {'text': 'hi'}),
      );

      expect(error, isA<DeepgramTimeoutException>());
      expect(
        (error as DeepgramTimeoutException).message,
        contains('Request to https://api.deepgram.com/v1/speak timed out'),
      );
      expect(client.sendCount, 2);
    });

    test('postAudio scales its timeout with the payload size', () async {
      final client = HangingClient();
      final engine = engineWith(
        client,
        config: testConfig.copyWith(
          requestTimeout: const Duration(milliseconds: 60),
          maxRetries: 0,
        ),
      );

      // Tiny payload: the base timeout applies and fires.
      final stopwatch = Stopwatch()..start();
      final tiny = await thrownBy(
        engine.postAudio(
          '/v1/listen',
          audio: <int>[1, 2, 3],
          contentType: 'audio/wav',
        ),
      );
      stopwatch.stop();
      expect(tiny, isA<DeepgramTimeoutException>());
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(60));

      // 1 MB payload: base timeout + ~2 s per MB, so the request must still
      // be in flight well past the base timeout (base would be only 60 ms).
      var settled = false;
      final bigAudio = List<int>.filled(1024 * 1024, 7);
      unawaited(
        engine
            .postAudio('/v1/listen', audio: bigAudio, contentType: 'audio/wav')
            .then<bool>((_) => settled = true)
            .catchError((Object _) => settled = true),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(
        settled,
        isFalse,
        reason: 'the payload-scaled timeout should exceed 150 ms',
      );
      expect(client.sendCount, 2);
    });
  });

  group('close', () {
    test('requests after close throw StateError (injected client)', () async {
      final queue = QueueHttpClient();
      final engine = engineWith(queue);

      engine.close();

      await expectLater(engine.getJson('/v1/listen'), throwsStateError);
      expect(queue.requests, isEmpty);
    });

    test('closing an engine that owns its client also works', () async {
      final engine = HttpEngine(
        config: testConfig,
        auth: DeepgramAuth(testConfig),
      );

      engine.close();

      await expectLater(engine.getJson('/v1/listen'), throwsStateError);
    });
  });

  group('cancellation', () {
    test('cancelling before the request starts aborts immediately', () async {
      final queue = QueueHttpClient();
      final engine = engineWith(queue);
      final token = HttpCancelToken();

      token.cancel('before start');

      final error = await thrownBy(
        engine.getJson('/v1/listen', cancelToken: token),
      );

      expect(error, isCancelledWith('before start'));
      expect(queue.requests, isEmpty);
    });

    test('cancelling during a Retry-After backoff aborts the retry', () async {
      final queue = QueueHttpClient();
      final engine = engineWith(queue);

      queue.enqueueJson(
        {'err_msg': 'rate limited'},
        status: 429,
        headers: {'retry-after': '30'}, // would wait 30 s
      );

      final token = HttpCancelToken();
      final pending = engine.getJson('/v1/listen', cancelToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(token.isCancelled, isFalse);
      token.cancel('user navigated away');

      final error = await thrownBy(pending);

      expect(error, isCancelledWith('user navigated away'));
      expect(queue.requests, hasLength(1)); // no second attempt was made
    });

    test('cancelling during the plain backoff aborts the retry', () async {
      final queue = QueueHttpClient();
      final engine = engineWith(
        queue,
        config: testConfig.copyWith(
          maxRetries: 2,
          retryBaseDelay: const Duration(seconds: 2),
          retryMaxDelay: const Duration(seconds: 2),
        ),
      );

      queue.enqueueError(http.ClientException('connection reset'));

      final token = HttpCancelToken();
      final pending = engine.getJson('/v1/listen', cancelToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      token.cancel(); // default reason

      final error = await thrownBy(pending);

      expect(error, isCancelledWith('cancelled'));
      expect(queue.requests, hasLength(1));
    });
  });

  group('HTTP verbs', () {
    late QueueHttpClient queue;
    late HttpEngine engine;

    setUp(() {
      queue = QueueHttpClient();
      engine = engineWith(queue);
    });

    test('postJson encodes the body as JSON', () async {
      queue.enqueueJson({'ok': true});

      final result = await engine.postJson('/v1/read', body: {'text': 'hello'});

      final request = queue.requests.single;
      expect(request.method, 'POST');
      expect(request.body, jsonEncode({'text': 'hello'}));
      expect(result.body['ok'], true);
    });

    test('postJson without a body sends an empty body', () async {
      queue.enqueueJson({'ok': true});

      await engine.postJson('/v1/read');

      expect(queue.requests.single.body, isEmpty);
    });

    test('putJson sends PUT with a JSON body', () async {
      queue.enqueueJson({'ok': true});

      await engine.putJson('/v1/projects/p1', body: {'name': 'renamed'});

      final request = queue.requests.single;
      expect(request.method, 'PUT');
      expect(request.body, jsonEncode({'name': 'renamed'}));
    });

    test('patchJson sends PATCH with a JSON body', () async {
      queue.enqueueJson({'ok': true});

      await engine.patchJson('/v1/keys/k1', body: {'comment': 'rotated'});

      final request = queue.requests.single;
      expect(request.method, 'PATCH');
      expect(request.body, jsonEncode({'comment': 'rotated'}));
    });

    test('deleteJson sends DELETE, with or without a body', () async {
      queue.enqueueJson('');
      queue.enqueueJson({'deleted': true});

      await engine.deleteJson('/v1/keys/k1');
      await engine.deleteJson('/v1/keys/k2', body: {'confirm': true});

      final first = queue.requests[0];
      final second = queue.requests[1];
      expect(first.method, 'DELETE');
      expect(first.body, isEmpty);
      expect(second.method, 'DELETE');
      expect(second.body, jsonEncode({'confirm': true}));
    });
  });

  group('postAudio', () {
    test(
      'sends the raw audio bytes with content type and auth headers',
      () async {
        final client = CapturingClient();
        final engine = engineWith(client);

        final result = await engine.postAudio(
          '/v1/listen',
          audio: <int>[10, 20, 30, 40],
          contentType: 'audio/wav',
          query: {'model': 'nova-3'},
          headers: {'X-Deepgram-Client': 'test'},
        );

        final request = client.requests.single;
        expect(request.method, 'POST');
        expect(request.bodyBytes, <int>[10, 20, 30, 40]);
        expect(request.headers['Content-Type'], 'audio/wav');
        expect(request.headers['Authorization'], 'Token test-api-key');
        expect(request.headers['X-Deepgram-Client'], 'test');
        expect(request.url.queryParameters['model'], 'nova-3');
        // The canned 200 response carries a non-JSON body; decoding yields {}.
        expect(result.body, isEmpty);
      },
    );

    test('decodes a JSON transcription response and its request id', () async {
      final queue = QueueHttpClient();
      final engine = engineWith(queue);

      queue.enqueueJson(
        {
          'request_id': 'audio-1',
          'results': {'channels': <dynamic>[]},
        },
        headers: {'x-request-id': 'audio-1'},
      );

      final result = await engine.postAudio(
        '/v1/listen',
        audio: <int>[1, 2, 3],
        contentType: 'audio/mpeg',
      );

      expect(result.body['request_id'], 'audio-1');
      expect(result.requestId, 'audio-1');
      expect(queue.requests.single.headers['Content-Type'], 'audio/mpeg');
    });
  });

  group('postForByteStream / postForBytes', () {
    late QueueHttpClient queue;
    late HttpEngine engine;

    setUp(() {
      queue = QueueHttpClient();
      engine = engineWith(queue);
    });

    test('streams the response bytes of a TTS call', () async {
      queue.enqueueBytes(<int>[1, 2, 3, 4, 5]);

      final stream = await engine.postForByteStream(
        '/v1/speak',
        body: {'text': 'hello'},
        query: {'model': 'aura-asteria-en'},
      );

      final collected = <int>[];
      await for (final chunk in stream) {
        collected.addAll(chunk);
      }

      expect(collected, <int>[1, 2, 3, 4, 5]);
      final request = queue.requests.single;
      expect(request.method, 'POST');
      expect(request.body, jsonEncode({'text': 'hello'}));
      expect(request.headers['Content-Type'], 'application/json');
      expect(request.headers['Authorization'], 'Token test-api-key');
      expect(request.url.queryParameters['model'], 'aura-asteria-en');
    });

    test('postForBytes collects the whole stream', () async {
      queue.enqueueBytes(<int>[9, 8, 7]);

      final bytes = await engine.postForBytes(
        '/v1/speak',
        body: {'text': 'hi'},
      );

      expect(bytes, <int>[9, 8, 7]);
    });

    test('postForByteStream works without a body', () async {
      queue.enqueueBytes(<int>[1]);

      final bytes = await engine.postForBytes('/v1/speak');

      expect(bytes, <int>[1]);
      expect(queue.requests.single.body, isEmpty);
    });

    test('extra headers can override the default content type', () async {
      queue.enqueueBytes(<int>[1]);

      await engine.postForByteStream(
        '/v1/speak',
        body: {'text': 'hi'},
        headers: {'Content-Type': 'text/plain'},
      );

      // http.Request appends "; charset=utf-8" to text/* content types when a
      // body is set; the engine's override itself is what we assert here.
      expect(
        queue.requests.single.headers['Content-Type'],
        startsWith('text/plain'),
      );
    });

    test('error statuses throw immediately, without retrying', () async {
      queue.enqueueJson(
        {'err_msg': 'voice not found'},
        status: 500,
        headers: {'x-request-id': 'speak-500'},
      );

      final error = await thrownBy(
        engine.postForByteStream('/v1/speak', body: {'text': 'hi'}),
      );

      expect(error, isA<DeepgramServerException>());
      final server = error as DeepgramServerException;
      expect(server.message, 'voice not found');
      expect(server.requestId, 'speak-500');
      // Stream downloads do not retry on 5xx — one attempt only.
      expect(queue.requests, hasLength(1));
    });

    test('429 on a stream surfaces Retry-After, without retrying', () async {
      queue.enqueueJson(
        {'err_msg': 'slow down'},
        status: 429,
        headers: {'retry-after': '2'},
      );

      final error = await thrownBy(
        engine.postForByteStream('/v1/speak', body: {'text': 'hi'}),
      );

      expect(error, isA<DeepgramRateLimitException>());
      expect(
        (error as DeepgramRateLimitException).retryAfter,
        const Duration(seconds: 2),
      );
      expect(queue.requests, hasLength(1));
    });

    test('transport failures are retried, then succeed', () async {
      queue.enqueueError(http.ClientException('connection reset'));
      queue.enqueueBytes(<int>[6, 7]);

      final bytes = await engine.postForBytes(
        '/v1/speak',
        body: {'text': 'hi'},
      );

      // The first attempt failed with a transport error, so receiving the
      // queued bytes at all proves the retry happened. (The queue client
      // does not record send-path requests that fail.)
      expect(bytes, <int>[6, 7]);
    });

    test('transport failures exhausted -> DeepgramNetworkException', () async {
      for (var i = 0; i < 3; i++) {
        queue.enqueueError(http.ClientException('connection reset'));
      }

      final error = await thrownBy(
        engine.postForByteStream('/v1/speak', body: {'text': 'hi'}),
      );

      // Exactly three attempts were made: the queue held only three errors,
      // so a fourth attempt would have surfaced the fake's NoResponseQueued
      // instead of the engine's typed DeepgramNetworkException.
      expect(error, isA<DeepgramNetworkException>());
    });

    test('cancelling before the request starts aborts immediately', () async {
      final token = HttpCancelToken()..cancel('nope');

      final error = await thrownBy(
        engine.postForByteStream('/v1/speak', cancelToken: token),
      );

      expect(error, isCancelledWith('nope'));
      expect(queue.requests, isEmpty);
    });

    test('cancelling while consuming the stream stops the download', () async {
      queue.enqueueBytes(<int>[1, 2, 3]);

      final token = HttpCancelToken();
      final stream = await engine.postForByteStream(
        '/v1/speak',
        cancelToken: token,
      );

      token.cancel('enough audio');

      final error = await thrownBy(stream.drain<void>());

      expect(error, isCancelledWith('enough audio'));
    });
  });
}
