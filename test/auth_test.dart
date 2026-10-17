/// Unit tests for [DeepgramAuth]: the credential-mode getters, `token()`
/// precedence, `Authorization` header formatting (Token vs Bearer), the
/// temporary-token grant flow (`POST /v1/auth/grant`), and
/// [DeepgramAuth.useTemporaryTokens] with caching.
///
/// The grant call uses the top-level `http.post`, so these tests install the
/// [QueueHttpClient] as the ambient HTTP client with `http.runWithClient` —
/// no request ever leaves the process.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'helpers/fake_http.dart';
import 'helpers/fakes.dart';

/// Runs [body] with [queue] installed as the ambient `http.Client`, so the
/// top-level `http.post` inside `grantTemporaryToken` is served by the fake
/// instead of the network.
Future<T> _withFakeHttp<T>(QueueHttpClient queue, Future<T> Function() body) {
  return http.runWithClient<Future<T>>(body, () => queue);
}

void main() {
  group('credential-mode getters', () {
    test('API-key configuration', () {
      final auth = DeepgramAuth(DeepgramConfig(apiKey: 'k'));
      expect(auth.usesApiKey, isTrue);
      expect(auth.usesStaticJwt, isFalse);
      expect(auth.usesTokenProvider, isFalse);
    });

    test('static-JWT configuration', () {
      final auth = DeepgramAuth(DeepgramConfig(jwt: 'j'));
      expect(auth.usesApiKey, isFalse);
      expect(auth.usesStaticJwt, isTrue);
      expect(auth.usesTokenProvider, isFalse);
    });

    test(
      'token-provider configuration (with and without a config API key)',
      () {
        final provider = DeepgramAuth(
          DeepgramConfig(apiKey: ''),
          tokenProvider: () async => 'minted',
        );
        expect(provider.usesTokenProvider, isTrue);
        // The mode getters are null-checks on the config fields, so even an
        // empty-string apiKey counts as "an API key is configured".
        expect(provider.usesApiKey, isTrue);
        expect(provider.usesStaticJwt, isFalse);

        // A non-empty config API key also claims API-key mode alongside the
        // provider; the header tests below show the provider wins regardless.
        final withKey = DeepgramAuth(
          DeepgramConfig(apiKey: 'k'),
          tokenProvider: () async => 'minted',
        );
        expect(withKey.usesApiKey, isTrue);
        expect(withKey.usesTokenProvider, isTrue);
      },
    );
  });

  group('token()', () {
    test('returns the API key directly', () async {
      final auth = DeepgramAuth(DeepgramConfig(apiKey: 'key-1'));
      expect(await auth.token(), 'key-1');
    });

    test('returns the static JWT', () async {
      final auth = DeepgramAuth(DeepgramConfig(jwt: 'jwt-1'));
      expect(await auth.token(), 'jwt-1');
    });

    test('prefers the static JWT over the API key', () async {
      final auth = DeepgramAuth(DeepgramConfig(apiKey: 'key-1', jwt: 'jwt-1'));
      expect(await auth.token(), 'jwt-1');
    });

    test('calls the provider on every call while nothing is cached', () async {
      var calls = 0;
      final auth = DeepgramAuth(
        DeepgramConfig(apiKey: ''),
        tokenProvider: () async {
          calls++;
          return 'minted-$calls';
        },
      );
      expect(await auth.token(), 'minted-1');
      expect(await auth.token(), 'minted-2');
      expect(calls, 2);
    });

    test('prefers the provider over a static JWT', () async {
      final auth = DeepgramAuth(
        DeepgramConfig(jwt: 'static'),
        tokenProvider: () async => 'minted',
      );
      expect(await auth.token(), 'minted');
    });

    test('throws a typed exception without any credential', () async {
      final emptyKey = DeepgramAuth(DeepgramConfig(apiKey: ''));
      await expectLater(
        emptyKey.token(),
        throwsA(
          isA<DeepgramAuthException>().having(
            (e) => e.message,
            'message',
            contains('No Deepgram credentials'),
          ),
        ),
      );
      final emptyJwt = DeepgramAuth(DeepgramConfig(jwt: ''));
      await expectLater(
        emptyJwt.token(),
        throwsA(isA<DeepgramAuthException>()),
      );
    });
  });

  group('authorizationHeader()', () {
    test('formats API keys as Token', () async {
      final auth = DeepgramAuth(DeepgramConfig(apiKey: 'key-1'));
      expect(await auth.authorizationHeader(), 'Token key-1');
    });

    test('formats JWTs as Bearer', () async {
      final auth = DeepgramAuth(DeepgramConfig(jwt: 'jwt-1'));
      expect(await auth.authorizationHeader(), 'Bearer jwt-1');
    });

    test('prefers Bearer when both apiKey and jwt are configured', () async {
      final auth = DeepgramAuth(DeepgramConfig(apiKey: 'key-1', jwt: 'jwt-1'));
      expect(await auth.authorizationHeader(), 'Bearer jwt-1');
    });

    test('uses Bearer for provider-minted tokens', () async {
      final auth = DeepgramAuth(
        DeepgramConfig(apiKey: ''),
        tokenProvider: () async => 'minted',
      );
      expect(await auth.authorizationHeader(), 'Bearer minted');
    });

    test('a provider wins over a configured API key', () async {
      final auth = DeepgramAuth(
        DeepgramConfig(apiKey: 'key-1'),
        tokenProvider: () async => 'minted',
      );
      expect(await auth.authorizationHeader(), 'Bearer minted');
    });
  });

  group('grantTemporaryToken()', () {
    test('requires an API key', () async {
      final auth = DeepgramAuth(DeepgramConfig(jwt: 'jwt-1'));
      await expectLater(
        auth.grantTemporaryToken(),
        throwsA(
          isA<DeepgramAuthException>().having(
            (e) => e.message,
            'message',
            contains('requires an API key'),
          ),
        ),
      );
    });

    test(
      'POSTs /v1/auth/grant with Token auth, JSON body, and the ttl',
      () async {
        final queue = QueueHttpClient();
        queue.enqueueJson(<String, dynamic>{
          'access_token': 'temp-1',
          'expires_in': 30,
        });
        final auth = DeepgramAuth(testConfig);

        final grant = await _withFakeHttp(
          queue,
          () => auth.grantTemporaryToken(),
        );

        expect(grant.accessToken, 'temp-1');
        expect(grant.expiresIn, 30.0);
        final request = queue.requests.single;
        expect(request.method, 'POST');
        expect(
          request.url,
          Uri.parse('https://api.deepgram.com/v1/auth/grant'),
        );
        expect(request.headers['Authorization'], 'Token test-api-key');
        expect(request.headers['Content-Type'], 'application/json');
        expect(request.body, jsonEncode(<String, dynamic>{'ttl_seconds': 30}));
      },
    );

    test('defaults the ttl to 30 seconds and honors custom ttls', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{'access_token': 'a'});
      queue.enqueueJson(<String, dynamic>{'access_token': 'b'});
      final auth = DeepgramAuth(testConfig);
      await _withFakeHttp(queue, () => auth.grantTemporaryToken());
      await _withFakeHttp(
        queue,
        () => auth.grantTemporaryToken(ttl: const Duration(minutes: 2)),
      );
      expect(
        queue.requests[0].body,
        jsonEncode(<String, dynamic>{'ttl_seconds': 30}),
      );
      expect(
        queue.requests[1].body,
        jsonEncode(<String, dynamic>{'ttl_seconds': 120}),
      );
    });

    test('parses expires_in as int or double, or leaves it null', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{
        'access_token': 'a',
        'expires_in': 45,
      });
      queue.enqueueJson(<String, dynamic>{
        'access_token': 'b',
        'expires_in': 4.5,
      });
      queue.enqueueJson(<String, dynamic>{'access_token': 'c'});
      queue.enqueueJson(<String, dynamic>{
        'access_token': 'd',
        'expires_in': 'soon',
      });
      final auth = DeepgramAuth(testConfig);
      final first = await _withFakeHttp(
        queue,
        () => auth.grantTemporaryToken(),
      );
      final second = await _withFakeHttp(
        queue,
        () => auth.grantTemporaryToken(),
      );
      final third = await _withFakeHttp(
        queue,
        () => auth.grantTemporaryToken(),
      );
      final fourth = await _withFakeHttp(
        queue,
        () => auth.grantTemporaryToken(),
      );
      expect(first.expiresIn, 45.0);
      expect(second.expiresIn, 4.5);
      expect(third.expiresIn, isNull);
      expect(fourth.expiresIn, isNull);
    });

    test('maps 401/403 to DeepgramAuthException using err_msg, message, or '
        'reason', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{
        'err_msg': 'invalid key',
      }, status: 401);
      queue.enqueueJson(<String, dynamic>{
        'message': 'membership required',
      }, status: 403);
      queue.enqueueJson(<String, dynamic>{'reason': 'revoked'}, status: 403);
      final auth = DeepgramAuth(testConfig);
      await expectLater(
        _withFakeHttp(queue, () => auth.grantTemporaryToken()),
        throwsA(
          isA<DeepgramAuthException>().having(
            (e) => e.message,
            'message',
            'invalid key',
          ),
        ),
      );
      await expectLater(
        _withFakeHttp(queue, () => auth.grantTemporaryToken()),
        throwsA(
          isA<DeepgramAuthException>().having(
            (e) => e.message,
            'message',
            'membership required',
          ),
        ),
      );
      await expectLater(
        _withFakeHttp(queue, () => auth.grantTemporaryToken()),
        throwsA(
          isA<DeepgramAuthException>().having(
            (e) => e.message,
            'message',
            'revoked',
          ),
        ),
      );
    });

    test(
      'falls back to a generic message for empty or non-JSON bodies',
      () async {
        final queue = QueueHttpClient();
        queue.enqueueJson(<String, dynamic>{'err_msg': ''}, status: 401);
        queue.enqueueJson('Forbidden', status: 403);
        final auth = DeepgramAuth(testConfig);
        await expectLater(
          _withFakeHttp(queue, () => auth.grantTemporaryToken()),
          throwsA(
            isA<DeepgramAuthException>().having(
              (e) => e.message,
              'message',
              'Token grant failed with HTTP 401.',
            ),
          ),
        );
        await expectLater(
          _withFakeHttp(queue, () => auth.grantTemporaryToken()),
          throwsA(
            isA<DeepgramAuthException>().having(
              (e) => e.message,
              'message',
              'Token grant failed with HTTP 403.',
            ),
          ),
        );
      },
    );

    test('maps other error statuses to DeepgramServerException', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{
        'message': 'internal error',
      }, status: 500);
      queue.enqueueJson('Bad Gateway', status: 502);
      final auth = DeepgramAuth(testConfig);
      await expectLater(
        _withFakeHttp(queue, () => auth.grantTemporaryToken()),
        throwsA(
          isA<DeepgramServerException>().having(
            (e) => e.message,
            'message',
            'internal error',
          ),
        ),
      );
      await expectLater(
        _withFakeHttp(queue, () => auth.grantTemporaryToken()),
        throwsA(
          isA<DeepgramServerException>().having(
            (e) => e.message,
            'message',
            'Token grant failed with HTTP 502.',
          ),
        ),
      );
    });

    test('rejects malformed success payloads', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{'request_id': 'r'}); // no token
      queue.enqueueJson(<String, dynamic>{'access_token': 42}); // non-string
      queue.enqueueJson('[1, 2]'); // valid JSON, but not a map
      final auth = DeepgramAuth(testConfig);
      for (var i = 0; i < 3; i++) {
        await expectLater(
          _withFakeHttp(queue, () => auth.grantTemporaryToken()),
          throwsA(
            isA<DeepgramServerException>().having(
              (e) => e.message,
              'message',
              'Malformed grant response from Deepgram.',
            ),
          ),
        );
      }
    });

    test('maps transport timeouts to DeepgramTimeoutException', () async {
      final queue = QueueHttpClient();
      queue.enqueueError(TimeoutException('too slow'));
      final auth = DeepgramAuth(testConfig);
      await expectLater(
        _withFakeHttp(queue, () => auth.grantTemporaryToken()),
        throwsA(
          isA<DeepgramTimeoutException>().having(
            (e) => e.message,
            'message',
            'Token grant request timed out.',
          ),
        ),
      );
    });

    test(
      'maps client failures to DeepgramNetworkException with a cause',
      () async {
        final queue = QueueHttpClient();
        queue.enqueueError(http.ClientException('socket died'));
        final auth = DeepgramAuth(testConfig);
        await expectLater(
          _withFakeHttp(queue, () => auth.grantTemporaryToken()),
          throwsA(
            isA<DeepgramNetworkException>()
                .having(
                  (e) => e.message,
                  'message',
                  'Token grant transport failure.',
                )
                .having((e) => e.cause, 'cause', isA<http.ClientException>()),
          ),
        );
      },
    );
  });

  group('useTemporaryTokens()', () {
    test('grants once and switches the header to Bearer', () async {
      final queue = QueueHttpClient();
      queue.enqueueJson(<String, dynamic>{
        'access_token': 'temp-9',
        'expires_in': 30,
      });
      final auth = DeepgramAuth(
        DeepgramConfig(
          apiKey: 'key-1',
          requestTimeout: const Duration(seconds: 2),
        ),
      );

      await _withFakeHttp(queue, auth.useTemporaryTokens);

      expect(await auth.token(), 'temp-9');
      expect(await auth.authorizationHeader(), 'Bearer temp-9');
      // The cached token serves further calls without another grant.
      expect(await auth.authorizationHeader(), 'Bearer temp-9');
      expect(queue.requests, hasLength(1));
    });

    test(
      'the cached token also short-circuits a configured provider',
      () async {
        final queue = QueueHttpClient();
        queue.enqueueJson(<String, dynamic>{'access_token': 'temp-8'});
        var providerCalls = 0;
        final auth = DeepgramAuth(
          DeepgramConfig(
            apiKey: 'key-1',
            requestTimeout: const Duration(seconds: 2),
          ),
          tokenProvider: () async {
            providerCalls++;
            return 'minted';
          },
        );

        await _withFakeHttp(queue, auth.useTemporaryTokens);

        expect(providerCalls, 0);
        expect(await auth.token(), 'temp-8');
        expect(await auth.authorizationHeader(), 'Bearer temp-8');
        expect(providerCalls, 0);
      },
    );
  });
}
