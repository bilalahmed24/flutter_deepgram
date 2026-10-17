/// Unit tests for `lib/src/speak/speak_client.dart` — the REST
/// text-to-speech client (`POST /v1/speak` and `POST /v2/speak`).
///
/// The [TtsClient] is driven through an `HttpEngine` with an injected
/// [QueueHttpClient] (plus a local scripted transport for progressive
/// byte-stream tests), so no request ever leaves the process. Wire
/// assertions cover the URL, query parameters, JSON body, Authorization and
/// Content-Type headers; behavior assertions cover the audio bytes returned,
/// byte-stream chunking for large audio, typed error mapping (401/429/500),
/// transport-failure retries, timeouts, cancellation, and the up-front
/// 2000-character text guard.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'helpers/fake_http.dart';
import 'helpers/fakes.dart';

/// Captures the error thrown by [action] (or `null` when it completes).
///
/// The action is deferred so synchronous throws (the speak methods validate
/// text before returning a future) are captured as well.
Future<Object?> _failureOf(FutureOr<Object?> Function() action) async {
  try {
    await action();
    return null;
  } catch (error) {
    return error;
  }
}

/// Case-insensitive header lookup.
String? _headerOf(http.BaseRequest request, String name) {
  for (final MapEntry<String, String> entry in request.headers.entries) {
    if (entry.key.toLowerCase() == name) {
      return entry.value;
    }
  }
  return null;
}

/// Waits (bounded) until [condition] holds.
Future<void> _until(bool Function() condition) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met within 3s.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// An [http.Client] the test scripts with a full [http.StreamedResponse] —
/// used to deliver audio in multiple chunks and capture the exact request.
class _ScriptedTransport extends http.BaseClient {
  _ScriptedTransport(this._respond);

  final Future<http.StreamedResponse> Function() _respond;

  /// The last request seen (body already consumed into [lastBody]).
  http.BaseRequest? lastRequest;

  /// The body bytes of the last request seen.
  List<int> lastBody = const <int>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    lastBody = await request.finalize().toBytes();
    return _respond();
  }
}

void main() {
  late QueueHttpClient queue;
  late TtsClient client;

  setUp(() {
    queue = QueueHttpClient();
    final engine = HttpEngine(
      config: testConfig,
      auth: DeepgramAuth(testConfig),
      client: queue,
    );
    client = TtsClient(http: engine, config: testConfig);
  });

  group('TtsClient constant', () {
    test('maxTextLength matches the documented 2000-character limit', () {
      expect(TtsClient.maxTextLength, 2000);
    });
  });

  group('speak (POST /v1/speak)', () {
    test('sends {text} as the JSON body with Token auth and returns the '
        'audio bytes', () async {
      queue.enqueueBytes(<int>[1, 2, 3, 200, 255, 0, 128]);

      final List<int> audio = await client.speak('Hello, world!');

      expect(audio, <int>[1, 2, 3, 200, 255, 0, 128]);
      final http.Request request = queue.requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://api.deepgram.com/v1/speak');
      expect(request.url.queryParameters, isEmpty);
      expect(request.body, '{"text":"Hello, world!"}');
      expect(_headerOf(request, 'authorization'), 'Token test-api-key');
      expect(_headerOf(request, 'content-type'), 'application/json');
    });

    test(
      'serializes every option to its documented wire name in the query',
      () async {
        queue.enqueueBytes(const <int>[9]);

        await client.speak(
          'Hi',
          options: const SpeakOptions(
            model: DeepgramVoices.aura2ThaliaEn,
            encoding: TtsEncoding.mp3,
            container: TtsContainer.none,
            sampleRate: 24000,
            bitRate: 48000,
            speed: 1.2,
            tag: <String>['env:test', 'run:7'],
            mipOptOut: true,
            timeout: Duration(milliseconds: 1500),
            callback: 'https://example.com/hook',
            callbackMethod: TtsCallbackMethod.put,
          ),
        );

        final Uri url = queue.requests.single.url;
        expect(url.path, '/v1/speak');
        expect(url.queryParametersAll, <String, List<String>>{
          'model': <String>['aura-2-thalia-en'],
          'encoding': <String>['mp3'],
          'container': <String>['none'],
          'sample_rate': <String>['24000'],
          'bit_rate': <String>['48000'],
          'speed': <String>['1.2'],
          'tag': <String>['env:test', 'run:7'],
          'mip_opt_out': <String>['true'],
          'timeout': <String>['1500'],
          'callback': <String>['https://example.com/hook'],
          'callback_method': <String>['PUT'],
        });
      },
    );

    test('returns large audio byte responses intact', () async {
      final List<int> big = List<int>.generate(256 * 1024, (int i) => i % 251);
      queue.enqueueBytes(big);
      expect(await client.speak('A long one'), big);
      expect(queue.requests, hasLength(1));
    });

    test('rejects text over 2000 characters before any request', () async {
      final String tooLong = 'a' * 2001;
      final Object? error = await _failureOf(() => client.speak(tooLong));
      expect(error, isA<DeepgramBadRequestException>());
      final DeepgramBadRequestException bad =
          error! as DeepgramBadRequestException;
      expect(bad.message, contains('2000 character limit'));
      expect(bad.message, contains('2001 characters'));
      expect(
        queue.requests,
        isEmpty,
        reason: 'validation must happen before the transport',
      );
    });

    test('accepts text of exactly 2000 characters', () async {
      queue.enqueueBytes(const <int>[42]);
      expect(await client.speak('a' * 2000), <int>[42]);
    });

    test('maps 401 to DeepgramAuthException with parsed body fields', () async {
      queue.enqueueJson(<String, Object>{
        'err_msg': 'Invalid API key',
        'request_id': 'req-401',
        'err_code': 'AUTH-0000',
      }, status: 401);

      final Object? error = await _failureOf(() => client.speak('Hi'));
      expect(error, isA<DeepgramAuthException>());
      final DeepgramAuthException auth = error! as DeepgramAuthException;
      expect(auth.message, 'Invalid API key');
      expect(auth.requestId, 'req-401');
      expect(auth.code, 'AUTH-0000');
      expect(queue.requests, hasLength(1));
    });

    test('maps 429 to DeepgramRateLimitException immediately (no retry) '
        'with the Retry-After header parsed', () async {
      queue.enqueueJson(
        <String, Object>{'err_msg': 'Rate limited'},
        status: 429,
        headers: <String, String>{'retry-after': '2'},
      );

      final Object? error = await _failureOf(() => client.speak('Hi'));
      expect(error, isA<DeepgramRateLimitException>());
      final DeepgramRateLimitException rate =
          error! as DeepgramRateLimitException;
      expect(rate.retryAfter, const Duration(seconds: 2));
      expect(rate.message, 'Rate limited');
      expect(
        queue.requests,
        hasLength(1),
        reason: 'the byte-stream path maps 429 without retrying',
      );
    });

    test('maps 500 to DeepgramServerException without retrying', () async {
      queue.enqueueJson(<String, Object>{
        'message': 'Internal server error',
      }, status: 500);

      final Object? error = await _failureOf(() => client.speak('Hi'));
      expect(error, isA<DeepgramServerException>());
      expect(
        (error! as DeepgramServerException).message,
        'Internal server error',
      );
      expect(queue.requests, hasLength(1));
    });

    test('retries a transport failure and then succeeds', () async {
      queue.enqueueError(http.ClientException('socket reset'));
      queue.enqueueBytes(<int>[7, 8, 9]);

      expect(await client.speak('Hi'), <int>[7, 8, 9]);
    });

    test('exhausts retries after repeated transport failures and throws '
        'DeepgramNetworkException', () async {
      queue.enqueueError(http.ClientException('boom 1'));
      queue.enqueueError(http.ClientException('boom 2'));
      queue.enqueueError(http.ClientException('boom 3'));

      final Object? error = await _failureOf(() => client.speak('Hi'));
      expect(error, isA<DeepgramNetworkException>());
      // testConfig.maxRetries is 2: 1 attempt + 2 retries.
      final Object? fourth = await _failureOf(() => client.speak('Hi'));
      expect(
        fourth,
        isA<NoResponseQueued>(),
        reason: 'exactly three transport attempts were made',
      );
    });

    test(
      'retries timeouts and finally throws DeepgramTimeoutException',
      () async {
        queue.enqueueError(TimeoutException('slow'));
        queue.enqueueError(TimeoutException('slow'));
        queue.enqueueError(TimeoutException('slow'));

        final Object? error = await _failureOf(() => client.speak('Hi'));
        expect(error, isA<DeepgramTimeoutException>());
        expect(
          (error! as DeepgramTimeoutException).message,
          contains('timed out after 2s.'),
        );
      },
    );

    test(
      'a pre-cancelled token rejects the request before the transport',
      () async {
        final token = HttpCancelToken()..cancel('nope');

        final Object? error = await _failureOf(
          () => client.speak('Hi', cancelToken: token),
        );
        expect(error, isA<DeepgramException>());
        expect(
          (error! as DeepgramException).message,
          'Request cancelled: nope',
        );
        expect(queue.requests, isEmpty);
      },
    );
  });

  group('speakStream (POST /v1/speak, byte stream)', () {
    test('delivers audio chunks progressively as they arrive', () async {
      final body = StreamController<List<int>>();
      final transport = _ScriptedTransport(
        () async => http.StreamedResponse(body.stream, 200),
      );
      final engine = HttpEngine(
        config: testConfig,
        auth: DeepgramAuth(testConfig),
        client: transport,
      );
      final streamClient = TtsClient(http: engine, config: testConfig);

      final Stream<List<int>> audio = await streamClient.speakStream('Hi');
      final List<List<int>> chunks = <List<int>>[];
      final done = Completer<void>();
      audio.listen(chunks.add, onDone: done.complete);

      body.add(<int>[1, 2, 3]);
      await _until(() => chunks.length == 1);
      body.add(<int>[4, 5]);
      await _until(() => chunks.length == 2);
      await body.close();
      await done.future;

      expect(chunks, <List<int>>[
        <int>[1, 2, 3],
        <int>[4, 5],
      ]);

      // The request wire: /v1/speak, JSON body, JSON content type.
      final http.BaseRequest? request = transport.lastRequest;
      expect(request, isNotNull);
      expect(request!.method, 'POST');
      expect(request.url.toString(), 'https://api.deepgram.com/v1/speak');
      expect(jsonDecode(utf8.decode(transport.lastBody)), <String, dynamic>{
        'text': 'Hi',
      });
      expect(_headerOf(request, 'content-type'), 'application/json');
      expect(_headerOf(request, 'authorization'), 'Token test-api-key');
    });

    test('emits a large audio response as multiple ordered chunks', () async {
      final List<List<int>> source = List<List<int>>.generate(
        8,
        (int i) => List<int>.generate(8 * 1024, (int j) => (i + j) % 256),
      );
      final transport = _ScriptedTransport(
        () async =>
            http.StreamedResponse(Stream<List<int>>.fromIterable(source), 200),
      );
      final engine = HttpEngine(
        config: testConfig,
        auth: DeepgramAuth(testConfig),
        client: transport,
      );
      final streamClient = TtsClient(http: engine, config: testConfig);

      final Stream<List<int>> audio = await streamClient.speakStream(
        'Big',
        options: const SpeakOptions(
          model: DeepgramVoices.aura2ThaliaEn,
          encoding: TtsEncoding.mp3,
        ),
      );
      final List<List<int>> chunks = <List<int>>[];
      await for (final List<int> chunk in audio) {
        chunks.add(chunk);
      }

      expect(
        transport.lastRequest!.url.queryParameters['model'],
        'aura-2-thalia-en',
      );
      expect(transport.lastRequest!.url.queryParameters['encoding'], 'mp3');
      expect(chunks, hasLength(8));
      expect(
        chunks.expand((List<int> chunk) => chunk).toList(),
        source.expand((List<int> chunk) => chunk).toList(),
      );
    });

    test('surfaces 401 as DeepgramAuthException', () async {
      queue.enqueueJson(<String, Object>{'err_msg': 'bad key'}, status: 401);
      final Object? error = await _failureOf(() => client.speakStream('Hi'));
      expect(error, isA<DeepgramAuthException>());
      expect((error! as DeepgramAuthException).message, 'bad key');
    });

    test('rejects oversized text before any request', () async {
      final Object? error = await _failureOf(
        () => client.speakStream('x' * 2001),
      );
      expect(error, isA<DeepgramBadRequestException>());
      expect(queue.requests, isEmpty);
    });
  });

  group('speakFlux (POST /v2/speak)', () {
    test('posts {text} to /v2/speak and returns the audio bytes', () async {
      queue.enqueueBytes(<int>[10, 20, 250]);

      final List<int> audio = await client.speakFlux(
        'Turn one',
        options: const FluxTtsOptions(model: DeepgramVoices.fluxAlexisEn),
      );

      expect(audio, <int>[10, 20, 250]);
      final http.Request request = queue.requests.single;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://api.deepgram.com/v2/speak?model=flux-alexis-en'
        '&encoding=linear16',
      );
      expect(request.body, '{"text":"Turn one"}');
      expect(_headerOf(request, 'authorization'), 'Token test-api-key');
      expect(_headerOf(request, 'content-type'), 'application/json');
    });

    test('serializes every Flux option to its exact wire name', () async {
      queue.enqueueBytes(const <int>[1]);

      await client.speakFlux(
        'Hi',
        options: const FluxTtsOptions(
          model: DeepgramVoices.fluxBreeEn,
          encoding: TtsEncoding.mulaw,
          sampleRate: 8000,
          expressivity: -2,
          tag: <String>['agent:demo', 'env:ci'],
          mipOptOut: false,
          timeout: Duration(seconds: 3),
        ),
      );

      expect(
        queue.requests.single.url.queryParametersAll,
        <String, List<String>>{
          'model': <String>['flux-bree-en'],
          'encoding': <String>['mulaw'],
          'sample_rate': <String>['8000'],
          'expressivity': <String>['-2'],
          'tag': <String>['agent:demo', 'env:ci'],
          'mip_opt_out': <String>['false'],
          'timeout': <String>['3000'],
        },
      );
    });

    test('expressivity bounds -2, 0, and 2 reach the wire', () async {
      for (final int expressivity in <int>[-2, 0, 2]) {
        queue.enqueueBytes(const <int>[1]);
        await client.speakFlux(
          'Hi',
          options: FluxTtsOptions(
            model: DeepgramVoices.fluxAlexisEn,
            expressivity: expressivity,
          ),
        );
      }
      final List<Uri> urls = queue.requests
          .map((http.Request r) => r.url)
          .toList();
      expect(urls[0].queryParameters['expressivity'], '-2');
      expect(urls[1].queryParameters['expressivity'], '0');
      expect(urls[2].queryParameters['expressivity'], '2');
    });

    test(
      'maps 429 to DeepgramRateLimitException on the v2 endpoint too',
      () async {
        queue.enqueueJson(<String, Object>{
          'err_msg': 'slow down',
        }, status: 429);
        final Object? error = await _failureOf(
          () => client.speakFlux(
            'Hi',
            options: const FluxTtsOptions(model: DeepgramVoices.fluxAlexisEn),
          ),
        );
        expect(error, isA<DeepgramRateLimitException>());
        expect((error! as DeepgramRateLimitException).retryAfter, isNull);
      },
    );

    test('rejects oversized text before any request', () async {
      final Object? error = await _failureOf(
        () => client.speakFlux('y' * 2001),
      );
      expect(error, isA<DeepgramBadRequestException>());
      expect(queue.requests, isEmpty);
    });
  });

  group('speakFluxStream (POST /v2/speak, byte stream)', () {
    test('streams v2 audio progressively and validates text', () async {
      final body = StreamController<List<int>>();
      final transport = _ScriptedTransport(
        () async => http.StreamedResponse(body.stream, 200),
      );
      final engine = HttpEngine(
        config: testConfig,
        auth: DeepgramAuth(testConfig),
        client: transport,
      );
      final streamClient = TtsClient(http: engine, config: testConfig);

      final Stream<List<int>> audio = await streamClient.speakFluxStream(
        'Hi',
        options: const FluxTtsOptions(
          model: DeepgramVoices.fluxAlexisEn,
          encoding: TtsEncoding.mulaw,
          sampleRate: 8000,
        ),
      );
      final List<List<int>> chunks = <List<int>>[];
      final done = Completer<void>();
      audio.listen(chunks.add, onDone: done.complete);
      body.add(<int>[250, 251]);
      await _until(() => chunks.length == 1);
      await body.close();
      await done.future;

      expect(chunks, <List<int>>[
        <int>[250, 251],
      ]);
      final http.BaseRequest? request = transport.lastRequest;
      expect(request!.url.path, '/v2/speak');
      expect(request.url.queryParameters['model'], 'flux-alexis-en');
      expect(request.url.queryParameters['encoding'], 'mulaw');
      expect(request.url.queryParameters['sample_rate'], '8000');

      final Object? error = await _failureOf(
        () => streamClient.speakFluxStream('z' * 2001),
      );
      expect(error, isA<DeepgramBadRequestException>());
    });
  });

  group('credentials', () {
    test('uses Bearer auth when the config carries a jwt', () async {
      const jwtConfig = DeepgramConfig(jwt: 'jwt-token-1');
      final jwtQueue = QueueHttpClient();
      final engine = HttpEngine(
        config: jwtConfig,
        auth: DeepgramAuth(jwtConfig),
        client: jwtQueue,
      );
      final jwtClient = TtsClient(http: engine, config: jwtConfig);
      jwtQueue.enqueueBytes(const <int>[5]);

      await jwtClient.speak('Hi');

      expect(
        _headerOf(jwtQueue.requests.single, 'authorization'),
        'Bearer jwt-token-1',
      );
    });
  });
}
