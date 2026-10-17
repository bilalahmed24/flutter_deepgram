/// Unit tests for [DeepgramConfig] and [DeepgramRegion]: constructor
/// defaults and credential assert, scheme selection, the REST / media-WS /
/// agent-WS URI builders (including TLS-off and custom hosts), query
/// serialization (scalars, repeated keys, nulls, percent-encoding), the
/// [DeepgramConfig.region] factory, [DeepgramConfig.copyWith], and probe URL
/// resolution.
library;

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:test/test.dart';

void main() {
  group('DeepgramRegion', () {
    test('global keeps the dedicated agent host', () {
      expect(DeepgramRegion.global.restHost, 'api.deepgram.com');
      expect(DeepgramRegion.global.agentHost, 'agent.deepgram.com');
    });

    test('regional values route both hosts through the regional domain', () {
      expect(DeepgramRegion.eu.restHost, 'api.eu.deepgram.com');
      expect(DeepgramRegion.eu.agentHost, 'api.eu.deepgram.com');
      expect(DeepgramRegion.au.restHost, 'api.au.deepgram.com');
      expect(DeepgramRegion.au.agentHost, 'api.au.deepgram.com');
      expect(DeepgramRegion.india.restHost, 'api.in.deepgram.com');
      expect(DeepgramRegion.india.agentHost, 'api.in.deepgram.com');
    });

    test('declares exactly the four supported regions', () {
      expect(DeepgramRegion.values, hasLength(4));
      expect(
        DeepgramRegion.values,
        containsAll(<DeepgramRegion>[
          DeepgramRegion.global,
          DeepgramRegion.eu,
          DeepgramRegion.au,
          DeepgramRegion.india,
        ]),
      );
    });
  });

  group('DeepgramConfig constructor', () {
    test('api-key form has the documented defaults', () {
      const config = DeepgramConfig(apiKey: 'k');
      expect(config.apiKey, 'k');
      expect(config.jwt, isNull);
      expect(config.baseUrl, 'api.deepgram.com');
      expect(config.agentBaseUrl, 'agent.deepgram.com');
      expect(config.useTls, isTrue);
      expect(config.requestTimeout, const Duration(seconds: 60));
      expect(config.connectTimeout, const Duration(seconds: 15));
      expect(config.maxRetries, 3);
      expect(config.retryBaseDelay, const Duration(milliseconds: 500));
      expect(config.retryMaxDelay, const Duration(seconds: 10));
      expect(config.probeUrl, isNull);
      expect(config.logger, isNull);
    });

    test('jwt form satisfies the credential assert', () {
      const config = DeepgramConfig(jwt: 'j');
      expect(config.apiKey, isNull);
      expect(config.jwt, 'j');
      expect(config.baseUrl, 'api.deepgram.com');
    });

    test('accepts explicit values for every field', () {
      final logger = DeepgramLogger();
      final config = DeepgramConfig(
        apiKey: 'k',
        jwt: 'j',
        baseUrl: 'api.staging.example',
        agentBaseUrl: 'agent.staging.example',
        useTls: false,
        requestTimeout: const Duration(seconds: 1),
        connectTimeout: const Duration(seconds: 2),
        maxRetries: 4,
        retryBaseDelay: const Duration(milliseconds: 3),
        retryMaxDelay: const Duration(seconds: 4),
        probeUrl: 'https://probe.example/ping',
        logger: logger,
      );
      expect(config.apiKey, 'k');
      expect(config.jwt, 'j');
      expect(config.baseUrl, 'api.staging.example');
      expect(config.agentBaseUrl, 'agent.staging.example');
      expect(config.useTls, isFalse);
      expect(config.requestTimeout, const Duration(seconds: 1));
      expect(config.connectTimeout, const Duration(seconds: 2));
      expect(config.maxRetries, 4);
      expect(config.retryBaseDelay, const Duration(milliseconds: 3));
      expect(config.retryMaxDelay, const Duration(seconds: 4));
      expect(config.probeUrl, 'https://probe.example/ping');
      expect(identical(config.logger, logger), isTrue);
    });

    test('rejects a configuration without any credential', () {
      expect(() => DeepgramConfig(), throwsA(isA<AssertionError>()));
    });
  });

  group('scheme selection', () {
    test('TLS on maps to https/wss', () {
      const config = DeepgramConfig(apiKey: 'k');
      expect(config.restScheme, 'https');
      expect(config.wsScheme, 'wss');
    });

    test('TLS off maps to http/ws', () {
      const config = DeepgramConfig(apiKey: 'k', useTls: false);
      expect(config.restScheme, 'http');
      expect(config.wsScheme, 'ws');
    });
  });

  group('restUri', () {
    test('builds an https URI on the default host', () {
      const config = DeepgramConfig(apiKey: 'k');
      expect(
        config.restUri('/v1/listen'),
        Uri.parse('https://api.deepgram.com/v1/listen'),
      );
    });

    test('uses the configured host and scheme', () {
      const config = DeepgramConfig(
        apiKey: 'k',
        baseUrl: 'api.staging.example',
        useTls: false,
      );
      expect(
        config.restUri('/v1/read'),
        Uri.parse('http://api.staging.example/v1/read'),
      );
    });

    test('appends scalar query parameters in insertion order', () {
      const config = DeepgramConfig(apiKey: 'k');
      final uri = config.restUri('/v1/listen', <String, dynamic>{
        'model': 'nova-3',
        'punctuate': true,
        'smart_format': false,
      });
      expect(uri.query, 'model=nova-3&punctuate=true&smart_format=false');
    });

    test('renders every element of an Iterable as a repeated key', () {
      const config = DeepgramConfig(apiKey: 'k');
      final uri = config.restUri('/v1/listen', <String, dynamic>{
        'tag': <String>['podcast', 'interview'],
        'model': 'nova-3',
      });
      expect(uri.query, 'tag=podcast&tag=interview&model=nova-3');
    });

    test('skips null values', () {
      const config = DeepgramConfig(apiKey: 'k');
      final uri = config.restUri('/v1/listen', <String, dynamic>{
        'model': 'nova-3',
        'keywords': null,
      });
      expect(uri.query, 'model=nova-3');
    });

    test('percent-encodes query keys and values', () {
      const config = DeepgramConfig(apiKey: 'k');
      final uri = config.restUri('/v1/listen', <String, dynamic>{
        'key words': 'a&b=c+d/e',
      });
      expect(uri.query, 'key+words=a%26b%3Dc%2Bd%2Fe');
    });

    test('omits the query for null and empty maps', () {
      const config = DeepgramConfig(apiKey: 'k');
      expect(config.restUri('/v1/listen').hasQuery, isFalse);
      expect(
        config.restUri('/v1/listen', <String, dynamic>{}).hasQuery,
        isFalse,
      );
    });
  });

  group('wsUri and agentWsUri', () {
    test('builds the media WebSocket URI, with or without query', () {
      const config = DeepgramConfig(apiKey: 'k');
      expect(
        config.wsUri('/v1/listen'),
        Uri.parse('wss://api.deepgram.com/v1/listen'),
      );
      expect(
        config.wsUri('/v2/listen', <String, dynamic>{
          'model': 'flux-general-en',
        }),
        Uri.parse('wss://api.deepgram.com/v2/listen?model=flux-general-en'),
      );
    });

    test('builds the agent WebSocket URI on the agent host', () {
      const config = DeepgramConfig(apiKey: 'k');
      expect(
        config.agentWsUri('/v1/agent/converse'),
        Uri.parse('wss://agent.deepgram.com/v1/agent/converse'),
      );
    });

    test('respects custom hosts, TLS off, and repeated query keys', () {
      const config = DeepgramConfig(
        apiKey: 'k',
        baseUrl: 'api.staging.example',
        agentBaseUrl: 'agent.staging.example',
        useTls: false,
      );
      expect(
        config.wsUri('/v1/speak'),
        Uri.parse('ws://api.staging.example/v1/speak'),
      );
      expect(
        config.agentWsUri('/v1/agent/converse', <String, dynamic>{
          'tag': <String>['a', 'b'],
        }),
        Uri.parse('ws://agent.staging.example/v1/agent/converse?tag=a&tag=b'),
      );
    });
  });

  group('DeepgramConfig.region', () {
    test('routes REST and agent traffic to the regional endpoint', () {
      final config = DeepgramConfig.region(DeepgramRegion.eu, apiKey: 'k');
      expect(config.baseUrl, 'api.eu.deepgram.com');
      expect(config.agentBaseUrl, 'api.eu.deepgram.com');
      expect(config.apiKey, 'k');
      expect(config.jwt, isNull);
      expect(
        config.agentWsUri('/v1/agent/converse'),
        Uri.parse('wss://api.eu.deepgram.com/v1/agent/converse'),
      );
    });

    test('global uses the dedicated agent endpoint', () {
      final config = DeepgramConfig.region(DeepgramRegion.global, apiKey: 'k');
      expect(config.baseUrl, 'api.deepgram.com');
      expect(config.agentBaseUrl, 'agent.deepgram.com');
      expect(
        config.restUri('/v1/read'),
        Uri.parse('https://api.deepgram.com/v1/read'),
      );
    });

    test('forwards every tuning parameter and keeps TLS on', () {
      final logger = DeepgramLogger();
      final config = DeepgramConfig.region(
        DeepgramRegion.au,
        jwt: 'j',
        requestTimeout: const Duration(seconds: 5),
        connectTimeout: const Duration(seconds: 7),
        maxRetries: 9,
        retryBaseDelay: const Duration(milliseconds: 10),
        retryMaxDelay: const Duration(milliseconds: 20),
        probeUrl: 'https://probe.example/ping',
        logger: logger,
      );
      expect(config.jwt, 'j');
      expect(config.apiKey, isNull);
      expect(config.requestTimeout, const Duration(seconds: 5));
      expect(config.connectTimeout, const Duration(seconds: 7));
      expect(config.maxRetries, 9);
      expect(config.retryBaseDelay, const Duration(milliseconds: 10));
      expect(config.retryMaxDelay, const Duration(milliseconds: 20));
      expect(config.probeUrl, 'https://probe.example/ping');
      expect(identical(config.logger, logger), isTrue);
      expect(config.useTls, isTrue);
    });
  });

  group('copyWith', () {
    test('keeps every field when called with no arguments', () {
      final logger = DeepgramLogger();
      final source = DeepgramConfig(
        apiKey: 'k',
        baseUrl: 'api.staging.example',
        agentBaseUrl: 'agent.staging.example',
        useTls: false,
        requestTimeout: const Duration(seconds: 11),
        connectTimeout: const Duration(seconds: 12),
        maxRetries: 13,
        retryBaseDelay: const Duration(milliseconds: 14),
        retryMaxDelay: const Duration(seconds: 15),
        probeUrl: 'https://probe.example/ping',
        logger: logger,
      );
      final copy = source.copyWith();
      expect(copy.apiKey, 'k');
      expect(copy.baseUrl, 'api.staging.example');
      expect(copy.agentBaseUrl, 'agent.staging.example');
      expect(copy.useTls, isFalse);
      expect(copy.requestTimeout, const Duration(seconds: 11));
      expect(copy.connectTimeout, const Duration(seconds: 12));
      expect(copy.maxRetries, 13);
      expect(copy.retryBaseDelay, const Duration(milliseconds: 14));
      expect(copy.retryMaxDelay, const Duration(seconds: 15));
      expect(copy.probeUrl, 'https://probe.example/ping');
      expect(identical(copy.logger, logger), isTrue);
    });

    test('replaces each field individually', () {
      final logger = DeepgramLogger();
      const source = DeepgramConfig(apiKey: 'k');
      expect(source.copyWith(apiKey: 'k2').apiKey, 'k2');
      expect(source.copyWith(jwt: 'j').jwt, 'j');
      expect(source.copyWith(baseUrl: 'a.example').baseUrl, 'a.example');
      expect(
        source.copyWith(agentBaseUrl: 'b.example').agentBaseUrl,
        'b.example',
      );
      expect(source.copyWith(useTls: false).useTls, isFalse);
      expect(
        source
            .copyWith(requestTimeout: const Duration(seconds: 1))
            .requestTimeout,
        const Duration(seconds: 1),
      );
      expect(
        source
            .copyWith(connectTimeout: const Duration(seconds: 2))
            .connectTimeout,
        const Duration(seconds: 2),
      );
      expect(source.copyWith(maxRetries: 5).maxRetries, 5);
      expect(
        source
            .copyWith(retryBaseDelay: const Duration(milliseconds: 3))
            .retryBaseDelay,
        const Duration(milliseconds: 3),
      );
      expect(
        source
            .copyWith(retryMaxDelay: const Duration(seconds: 4))
            .retryMaxDelay,
        const Duration(seconds: 4),
      );
      expect(
        source.copyWith(probeUrl: 'https://p.example/').probeUrl,
        'https://p.example/',
      );
      expect(identical(source.copyWith(logger: logger).logger, logger), isTrue);
    });

    test('replaces all fields at once and leaves the source untouched', () {
      final logger = DeepgramLogger();
      const source = DeepgramConfig(apiKey: 'k');
      final copy = source.copyWith(
        apiKey: 'other',
        jwt: 'j',
        baseUrl: 'api.two.example',
        agentBaseUrl: 'agent.two.example',
        useTls: false,
        requestTimeout: const Duration(seconds: 21),
        connectTimeout: const Duration(seconds: 22),
        maxRetries: 23,
        retryBaseDelay: const Duration(milliseconds: 24),
        retryMaxDelay: const Duration(seconds: 25),
        probeUrl: 'https://probe.two.example/',
        logger: logger,
      );
      expect(copy.apiKey, 'other');
      expect(copy.jwt, 'j');
      expect(copy.baseUrl, 'api.two.example');
      expect(copy.agentBaseUrl, 'agent.two.example');
      expect(copy.useTls, isFalse);
      expect(copy.requestTimeout, const Duration(seconds: 21));
      expect(copy.connectTimeout, const Duration(seconds: 22));
      expect(copy.maxRetries, 23);
      expect(copy.retryBaseDelay, const Duration(milliseconds: 24));
      expect(copy.retryMaxDelay, const Duration(seconds: 25));
      expect(copy.probeUrl, 'https://probe.two.example/');
      expect(identical(copy.logger, logger), isTrue);
      // The source config is untouched.
      expect(source.apiKey, 'k');
      expect(source.jwt, isNull);
      expect(source.baseUrl, 'api.deepgram.com');
      expect(source.useTls, isTrue);
      expect(source.maxRetries, 3);
      expect(source.logger, isNull);
    });
  });

  group('effectiveProbeUrl', () {
    test('defaults to the REST base root', () {
      expect(
        const DeepgramConfig(apiKey: 'k').effectiveProbeUrl,
        'https://api.deepgram.com/',
      );
    });

    test('follows scheme and host overrides', () {
      const config = DeepgramConfig(
        apiKey: 'k',
        baseUrl: 'api.staging.example',
        useTls: false,
      );
      expect(config.effectiveProbeUrl, 'http://api.staging.example/');
    });

    test('prefers an explicit probeUrl', () {
      const config = DeepgramConfig(
        apiKey: 'k',
        probeUrl: 'https://example.org/health',
      );
      expect(config.effectiveProbeUrl, 'https://example.org/health');
    });
  });
}
