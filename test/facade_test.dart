/// Unit tests for the [DeepgramClient] facade: the three constructors
/// (`apiKey`, `withConfig`, `withTokenProvider`), credential and logger
/// wiring, the lazily-created REST sub-client singletons, the five streaming
/// session factories, and [DeepgramClient.close] semantics.
///
/// Streaming clients are only constructed here — never started — so nothing
/// in this file opens a socket or issues a request.
library;

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:test/test.dart';

void main() {
  group('DeepgramClient(apiKey:)', () {
    test('creates a default config with the key installed', () async {
      final client = DeepgramClient(apiKey: 'key-1');
      addTearDown(client.close);
      expect(client.config.apiKey, 'key-1');
      expect(client.config.jwt, isNull);
      expect(client.config.baseUrl, 'api.deepgram.com');
      expect(client.config.agentBaseUrl, 'agent.deepgram.com');
      expect(client.config.useTls, isTrue);
      expect(client.config.maxRetries, 3);
      expect(client.logger, isA<DeepgramLogger>());
      expect(client.auth, isA<DeepgramAuth>());
      expect(client.auth.usesApiKey, isTrue);
      expect(await client.auth.authorizationHeader(), 'Token key-1');
    });

    test(
      'replaces the credentials but keeps the supplied config settings',
      () async {
        final logger = DeepgramLogger();
        final client = DeepgramClient(
          apiKey: 'new-key',
          config: DeepgramConfig(
            apiKey: 'old-key',
            jwt: 'old-jwt',
            baseUrl: 'api.staging.example',
            agentBaseUrl: 'agent.staging.example',
            useTls: false,
            maxRetries: 7,
            requestTimeout: const Duration(seconds: 11),
            retryBaseDelay: const Duration(milliseconds: 12),
            logger: logger,
          ),
        );
        expect(client.config.apiKey, 'new-key');
        // copyWith only swaps the API key; the jwt survives.
        expect(client.config.jwt, 'old-jwt');
        expect(client.config.baseUrl, 'api.staging.example');
        expect(client.config.agentBaseUrl, 'agent.staging.example');
        expect(client.config.useTls, isFalse);
        expect(client.config.maxRetries, 7);
        expect(client.config.requestTimeout, const Duration(seconds: 11));
        expect(client.config.retryBaseDelay, const Duration(milliseconds: 12));
        expect(identical(client.logger, logger), isTrue);
        // With both a jwt and an apiKey present, Bearer wins (documented
        // precedence in DeepgramAuth).
        expect(await client.auth.authorizationHeader(), 'Bearer old-jwt');
      },
    );
  });

  group('DeepgramClient.withConfig', () {
    test('keeps the exact config instance and derives logger and auth', () {
      final config = DeepgramConfig(
        apiKey: 'k',
        baseUrl: 'api.staging.example',
      );
      final client = DeepgramClient.withConfig(config);
      addTearDown(client.close);
      expect(identical(client.config, config), isTrue);
      expect(client.logger, isA<DeepgramLogger>());
      expect(client.auth.usesApiKey, isTrue);
      expect(client.config.baseUrl, 'api.staging.example');
    });

    test('uses the config logger when one is provided', () {
      final logger = DeepgramLogger();
      final client = DeepgramClient.withConfig(
        DeepgramConfig(apiKey: 'k', logger: logger),
      );
      expect(identical(client.logger, logger), isTrue);
    });

    test('accepts a token provider alongside the config', () async {
      var calls = 0;
      final client = DeepgramClient.withConfig(
        DeepgramConfig(apiKey: 'unused'),
        tokenProvider: () async {
          calls++;
          return 'minted-$calls';
        },
      );
      expect(client.auth.usesTokenProvider, isTrue);
      expect(await client.auth.authorizationHeader(), 'Bearer minted-1');
      expect(calls, 1);
    });
  });

  group('DeepgramClient.withTokenProvider', () {
    test(
      'authenticates through the provider and blanks static credentials',
      () async {
        final client = DeepgramClient.withTokenProvider(
          tokenProvider: () async => 'minted',
        );
        expect(client.auth.usesTokenProvider, isTrue);
        // usesStaticJwt is a null-check, and withTokenProvider leaves an
        // empty-string jwt on the config — not a null one.
        expect(client.auth.usesStaticJwt, isTrue);
        expect(await client.auth.authorizationHeader(), 'Bearer minted');
        expect(client.config.apiKey, '');
        expect(client.config.jwt, '');
        expect(client.config.baseUrl, 'api.deepgram.com');
      },
    );

    test('keeps the non-credential settings of the supplied config', () {
      final logger = DeepgramLogger();
      final client = DeepgramClient.withTokenProvider(
        tokenProvider: () async => 'minted',
        config: DeepgramConfig(
          apiKey: 'masked',
          jwt: 'masked',
          baseUrl: 'api.staging.example',
          maxRetries: 8,
          logger: logger,
        ),
      );
      expect(client.config.apiKey, '');
      expect(client.config.jwt, '');
      expect(client.config.baseUrl, 'api.staging.example');
      expect(client.config.maxRetries, 8);
      expect(identical(client.logger, logger), isTrue);
    });
  });

  group('REST sub-clients', () {
    test('expose lazily-created singletons of the right type', () {
      final client = DeepgramClient(apiKey: 'k');
      expect(client.prerecorded, isA<PrerecordedClient>());
      expect(identical(client.prerecorded, client.prerecorded), isTrue);
      expect(client.tts, isA<TtsClient>());
      expect(identical(client.tts, client.tts), isTrue);
      expect(client.intelligence, isA<TextIntelligenceClient>());
      expect(identical(client.intelligence, client.intelligence), isTrue);
      expect(client.agentConfigurations, isA<AgentConfigurationsClient>());
      expect(
        identical(client.agentConfigurations, client.agentConfigurations),
        isTrue,
      );
    });

    test('expose the shared HTTP engine', () {
      final client = DeepgramClient(apiKey: 'k');
      expect(client.http, isA<HttpEngine>());
      expect(identical(client.http, client.http), isTrue);
    });
  });

  group('streaming session factories', () {
    test('createLiveClient returns fresh, unconnected sessions', () {
      final client = DeepgramClient(apiKey: 'k');
      final first = client.createLiveClient(
        options: const LiveTranscriptionOptions(model: 'nova-2'),
      );
      final second = client.createLiveClient();
      expect(first, isA<DeepgramLiveClient>());
      expect(second, isA<DeepgramLiveClient>());
      expect(identical(first, second), isFalse);
      expect(first.isConnected, isFalse);
      expect(second.isConnected, isFalse);
      expect(first.reconnectAttempts, 0);
    });

    test('createFluxClient returns fresh, unconnected sessions', () {
      final client = DeepgramClient(apiKey: 'k');
      final first = client.createFluxClient(
        options: const FluxSttOptions(model: 'flux-general-multi'),
      );
      final second = client.createFluxClient();
      expect(first, isA<FluxSttClient>());
      expect(second, isA<FluxSttClient>());
      expect(identical(first, second), isFalse);
      expect(first.isConnected, isFalse);
      expect(second.isConnected, isFalse);
      expect(second.reconnectAttempts, 0);
    });

    test('createTtsStreamClient returns fresh, unconnected sessions', () {
      final client = DeepgramClient(apiKey: 'k');
      final first = client.createTtsStreamClient(
        options: const SpeakOptions(model: 'aura-asteria-en'),
      );
      final second = client.createTtsStreamClient();
      expect(first, isA<TtsStreamClient>());
      expect(second, isA<TtsStreamClient>());
      expect(identical(first, second), isFalse);
      expect(first.isConnected, isFalse);
      expect(second.isConnected, isFalse);
    });

    test('createFluxTtsClient returns fresh, unconnected sessions', () {
      final client = DeepgramClient(apiKey: 'k');
      final first = client.createFluxTtsClient(
        options: const FluxTtsOptions(model: 'flux-alexis-en'),
      );
      final second = client.createFluxTtsClient(
        options: const FluxTtsOptions(model: 'flux-alexis-en'),
      );
      expect(first, isA<FluxTtsClient>());
      expect(second, isA<FluxTtsClient>());
      expect(identical(first, second), isFalse);
      expect(first.isConnected, isFalse);
      expect(second.isConnected, isFalse);
    });

    test('createVoiceAgent returns sessions wired to the shared engine', () {
      final client = DeepgramClient(apiKey: 'k');
      final agent = client.createVoiceAgent();
      expect(agent, isA<DeepgramVoiceAgent>());
      expect(identical(agent.http, client.http), isTrue);
      expect(agent.isConnected, isFalse);
      expect(agent.reconnectAttempts, 0);
      expect(identical(client.createVoiceAgent(), agent), isFalse);
    });

    test('forward websocket options without connecting', () {
      final client = DeepgramClient(apiKey: 'k');
      final session = client.createLiveClient(
        wsOptions: const ResilientWebSocketOptions(
          autoReconnect: false,
          keepAliveInterval: Duration(seconds: 9),
        ),
      );
      expect(session.isConnected, isFalse);
    });
  });

  group('close()', () {
    test('is idempotent', () {
      final client = DeepgramClient(apiKey: 'k');
      client.close();
      // A second close must be a no-op, not an error.
      client.close();
    });

    test('rejects every streaming factory with a StateError', () {
      final client = DeepgramClient(apiKey: 'k')..close();
      expect(() => client.createLiveClient(), throwsStateError);
      expect(() => client.createFluxClient(), throwsStateError);
      expect(() => client.createTtsStreamClient(), throwsStateError);
      expect(() => client.createFluxTtsClient(), throwsStateError);
      expect(() => client.createVoiceAgent(), throwsStateError);
    });

    test('names the closed client in the error message', () {
      final client = DeepgramClient(apiKey: 'k')..close();
      expect(
        () => client.createVoiceAgent(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'DeepgramClient.close() was already called.',
          ),
        ),
      );
    });

    test('shuts the shared HTTP engine down', () async {
      final client = DeepgramClient(apiKey: 'k');
      final engine = client.http;
      final prerecorded = client.prerecorded;
      client.close();
      // Cached REST sub-clients are still reachable, but any request fails
      // fast with a StateError — no request leaves the process.
      expect(identical(client.prerecorded, prerecorded), isTrue);
      await expectLater(engine.getJson('/v1/projects'), throwsStateError);
    });
  });
}
