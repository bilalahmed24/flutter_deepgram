/// Unit tests for `lib/src/speak/speak_options.dart` and
/// `lib/src/speak/voices.dart`.
///
/// Coverage targets:
/// * [SpeakOptions] — full query serialization to the documented wire names,
///   defaults, boolean rendering, repeated `tag` keys, and the
///   `timeout`/`callback` REST-only fields.
/// * [FluxTtsOptions] — required-model serialization, the always-present
///   `encoding`, expressivity pass-through (including the -2..2 bounds), and
///   null-omission.
/// * [DeepgramVoices] — catalog sizes, distinctness, the v1-vs-Flux (v2)
///   split, membership helpers, and [DeepgramVoices.languageOf].
library;

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:test/test.dart';

void main() {
  group('SpeakOptions.toQuery', () {
    test('renders nothing by default (the server decides everything)', () {
      expect(const SpeakOptions().toQuery(), isEmpty);
    });

    test('serializes every field to its exact wire name', () {
      final Map<String, dynamic> query = const SpeakOptions(
        model: DeepgramVoices.aura2ThaliaEn,
        encoding: TtsEncoding.linear16,
        container: TtsContainer.wav,
        sampleRate: 24000,
        bitRate: 48000,
        speed: 1.2,
        tag: <String>['env:test', 'run:7'],
        mipOptOut: true,
        timeout: Duration(milliseconds: 1500),
        callback: 'https://example.com/hooks/tts',
        callbackMethod: TtsCallbackMethod.put,
      ).toQuery();
      expect(query, <String, dynamic>{
        'model': 'aura-2-thalia-en',
        'encoding': 'linear16',
        'container': 'wav',
        'sample_rate': 24000,
        'bit_rate': 48000,
        'speed': 1.2,
        'tag': <String>['env:test', 'run:7'],
        'mip_opt_out': 'true',
        'timeout': 1500,
        'callback': 'https://example.com/hooks/tts',
        'callback_method': 'PUT',
      });
    });

    test('booleans render as the strings true/false', () {
      expect(
        const SpeakOptions(mipOptOut: true).toQuery(),
        containsPair('mip_opt_out', 'true'),
      );
      expect(
        const SpeakOptions(mipOptOut: false).toQuery(),
        containsPair('mip_opt_out', 'false'),
      );
    });

    test('every encoding maps to its documented wire value', () {
      expect(TtsEncoding.linear16.wireName, 'linear16');
      expect(TtsEncoding.mulaw.wireName, 'mulaw');
      expect(TtsEncoding.alaw.wireName, 'alaw');
      expect(TtsEncoding.opus.wireName, 'opus');
      expect(TtsEncoding.flac.wireName, 'flac');
      expect(TtsEncoding.aac.wireName, 'aac');
      expect(TtsEncoding.mp3.wireName, 'mp3');
      for (final TtsEncoding encoding in TtsEncoding.values) {
        expect(
          SpeakOptions(encoding: encoding).toQuery(),
          containsPair('encoding', encoding.wireName),
        );
      }
    });

    test('every container maps to its documented wire value', () {
      expect(TtsContainer.none.wireName, 'none');
      expect(TtsContainer.wav.wireName, 'wav');
      expect(TtsContainer.ogg.wireName, 'ogg');
      for (final TtsContainer container in TtsContainer.values) {
        expect(
          SpeakOptions(container: container).toQuery(),
          containsPair('container', container.wireName),
        );
      }
    });

    test('callback methods render as POST and PUT', () {
      expect(TtsCallbackMethod.post.wireName, 'POST');
      expect(TtsCallbackMethod.put.wireName, 'PUT');
      expect(
        const SpeakOptions(callback: 'https://example.com/hook').toQuery(),
        <String, dynamic>{'callback': 'https://example.com/hook'},
      );
      expect(
        const SpeakOptions(
          callback: 'https://example.com/hook',
          callbackMethod: TtsCallbackMethod.put,
        ).toQuery(),
        containsPair('callback_method', 'PUT'),
      );
    });

    test('timeout serializes as whole milliseconds', () {
      expect(
        const SpeakOptions(timeout: Duration(milliseconds: 2500)).toQuery(),
        containsPair('timeout', 2500),
      );
      expect(
        const SpeakOptions(timeout: Duration.zero).toQuery(),
        containsPair('timeout', 0),
      );
    });

    test('tag renders as a list for the query builder to expand '
        '(empty list omitted)', () {
      expect(
        const SpeakOptions(tag: <String>['a']).toQuery(),
        containsPair('tag', <String>['a']),
      );
      expect(
        const SpeakOptions(tag: <String>[]).toQuery(),
        isNot(contains('tag')),
      );
      expect(const SpeakOptions().toQuery(), isNot(contains('tag')));
    });

    test('numeric fields pass through unstringified (the query builder '
        'stringifies later)', () {
      final Map<String, dynamic> query = const SpeakOptions(
        sampleRate: 8000,
        bitRate: 16000,
        speed: 0.7,
      ).toQuery();
      expect(query['sample_rate'], 8000);
      expect(query['sample_rate'], isA<int>());
      expect(query['bit_rate'], 16000);
      expect(query['speed'], 0.7);
      expect(query['speed'], isA<double>());
    });

    test('minimal voice-only options serialize just the model', () {
      expect(
        const SpeakOptions(model: DeepgramVoices.defaultVoice).toQuery(),
        <String, dynamic>{'model': 'aura-asteria-en'},
      );
    });
  });

  group('FluxTtsOptions.toQuery', () {
    test('always carries the required model and the default encoding', () {
      expect(
        const FluxTtsOptions(model: DeepgramVoices.fluxAlexisEn).toQuery(),
        <String, dynamic>{'model': 'flux-alexis-en', 'encoding': 'linear16'},
      );
    });

    test('serializes every field to its exact wire name', () {
      final Map<String, dynamic> query = const FluxTtsOptions(
        model: DeepgramVoices.fluxBreeEn,
        encoding: TtsEncoding.mulaw,
        sampleRate: 8000,
        expressivity: 2,
        tag: <String>['agent:demo', 'env:ci'],
        mipOptOut: false,
        timeout: Duration(seconds: 3),
      ).toQuery();
      expect(query, <String, dynamic>{
        'model': 'flux-bree-en',
        'encoding': 'mulaw',
        'sample_rate': 8000,
        'expressivity': 2,
        'tag': <String>['agent:demo', 'env:ci'],
        'mip_opt_out': 'false',
        'timeout': 3000,
      });
    });

    test('expressivity passes through the documented -2..2 bounds '
        '(no local validation)', () {
      expect(
        const FluxTtsOptions(model: 'flux-x-en', expressivity: -2).toQuery(),
        containsPair('expressivity', -2),
      );
      expect(
        const FluxTtsOptions(model: 'flux-x-en', expressivity: 0).toQuery(),
        containsPair('expressivity', 0),
      );
      expect(
        const FluxTtsOptions(model: 'flux-x-en', expressivity: 2).toQuery(),
        containsPair('expressivity', 2),
      );
      // Out-of-range values are NOT rejected locally — the server answers.
      expect(
        const FluxTtsOptions(model: 'flux-x-en', expressivity: 7).toQuery(),
        containsPair('expressivity', 7),
      );
    });

    test('expressivity 0 is emitted (only null is omitted)', () {
      expect(
        const FluxTtsOptions(model: 'flux-x-en').toQuery(),
        isNot(contains('expressivity')),
      );
    });

    test('every encoding is selectable for the batch endpoint', () {
      expect(
        const FluxTtsOptions(
          model: 'flux-x-en',
          encoding: TtsEncoding.mp3,
        ).toQuery(),
        containsPair('encoding', 'mp3'),
      );
      expect(
        const FluxTtsOptions(
          model: 'flux-x-en',
          encoding: TtsEncoding.opus,
        ).toQuery(),
        containsPair('encoding', 'opus'),
      );
    });

    test('mip_opt_out renders as true/false strings; empty tag omitted', () {
      expect(
        const FluxTtsOptions(model: 'flux-x-en', mipOptOut: true).toQuery(),
        containsPair('mip_opt_out', 'true'),
      );
      expect(
        const FluxTtsOptions(model: 'flux-x-en', tag: <String>[]).toQuery(),
        <String, dynamic>{'model': 'flux-x-en', 'encoding': 'linear16'},
      );
    });
  });

  group('DeepgramVoices', () {
    test('aura catalog: 12 distinct original English voices', () {
      expect(DeepgramVoices.aura, hasLength(12));
      expect(
        DeepgramVoices.aura.toSet().length,
        DeepgramVoices.aura.length,
        reason: 'aura voice ids must be distinct',
      );
      for (final String voice in DeepgramVoices.aura) {
        expect(voice.startsWith('aura-'), isTrue, reason: voice);
        expect(voice.endsWith('-en'), isTrue, reason: voice);
      }
      expect(DeepgramVoices.aura, contains('aura-asteria-en'));
      expect(DeepgramVoices.aura, contains(DeepgramVoices.auraHeliosEn));
    });

    test('aura2 catalog: 90 distinct voices across seven languages', () {
      expect(DeepgramVoices.aura2, hasLength(90));
      expect(
        DeepgramVoices.aura2.toSet().length,
        DeepgramVoices.aura2.length,
        reason: 'aura2 voice ids must be distinct',
      );
      expect(DeepgramVoices.aura2, contains('aura-2-thalia-en'));
      expect(DeepgramVoices.aura2, contains(DeepgramVoices.aura2ThaliaEn));
      expect(DeepgramVoices.aura2, contains(DeepgramVoices.aura2AgustinaEs));
      expect(DeepgramVoices.aura2, contains(DeepgramVoices.aura2AmaJa));
      // Language suffix census: 41 en, 17 es, 7 de, 9 nl, 2 fr, 9 it, 5 ja.
      final Map<String, int> byLanguage = <String, int>{};
      for (final String voice in DeepgramVoices.aura2) {
        final String language = voice.split('-').last;
        byLanguage[language] = (byLanguage[language] ?? 0) + 1;
      }
      expect(byLanguage, <String, int>{
        'en': 41,
        'es': 17,
        'de': 7,
        'nl': 9,
        'fr': 2,
        'it': 9,
        'ja': 5,
      });
    });

    test('flux catalog: 36 distinct turn-based English voices', () {
      expect(DeepgramVoices.flux, hasLength(36));
      expect(
        DeepgramVoices.flux.toSet().length,
        DeepgramVoices.flux.length,
        reason: 'flux voice ids must be distinct',
      );
      for (final String voice in DeepgramVoices.flux) {
        expect(voice.startsWith('flux-'), isTrue, reason: voice);
        expect(voice.endsWith('-en'), isTrue, reason: voice);
      }
      expect(DeepgramVoices.flux, contains('flux-alexis-en'));
      expect(DeepgramVoices.flux, contains(DeepgramVoices.fluxWesEn));
    });

    test('v1 and v2 (flux) catalogs are complete, disjoint, and distinct', () {
      expect(DeepgramVoices.allV1, hasLength(102));
      expect(
        DeepgramVoices.allV1,
        containsAll(<String>[...DeepgramVoices.aura, ...DeepgramVoices.aura2]),
      );
      expect(DeepgramVoices.allFlux, orderedEquals(DeepgramVoices.flux));
      expect(DeepgramVoices.all, hasLength(138));
      expect(
        DeepgramVoices.all.toSet().length,
        DeepgramVoices.all.length,
        reason: 'every known voice id must be distinct across families',
      );
      for (final String voice in DeepgramVoices.allV1) {
        expect(DeepgramVoices.flux, isNot(contains(voice)));
      }
      for (final String voice in DeepgramVoices.flux) {
        expect(DeepgramVoices.allV1, isNot(contains(voice)));
      }
    });

    test('defaultVoice is the documented server default', () {
      expect(DeepgramVoices.defaultVoice, 'aura-asteria-en');
      expect(DeepgramVoices.defaultVoice, DeepgramVoices.auraAsteriaEn);
    });

    test('membership helpers classify voices by family', () {
      expect(DeepgramVoices.isAuraVoice('aura-asteria-en'), isTrue);
      expect(DeepgramVoices.isAuraVoice('aura-2-thalia-en'), isFalse);
      expect(DeepgramVoices.isAuraVoice('flux-alexis-en'), isFalse);
      expect(DeepgramVoices.isAuraVoice('aura-asteria-fr'), isFalse);

      expect(DeepgramVoices.isAura2Voice('aura-2-thalia-en'), isTrue);
      expect(DeepgramVoices.isAura2Voice('aura-2-ama-ja'), isTrue);
      expect(DeepgramVoices.isAura2Voice('aura-asteria-en'), isFalse);
      expect(DeepgramVoices.isAura2Voice('flux-alexis-en'), isFalse);

      expect(DeepgramVoices.isFluxVoice('flux-alexis-en'), isTrue);
      expect(DeepgramVoices.isFluxVoice('flux-kit-en'), isTrue);
      expect(DeepgramVoices.isFluxVoice('aura-2-thalia-en'), isFalse);
    });

    test('isV1Voice accepts Aura and Aura-2 but never Flux', () {
      for (final String voice in DeepgramVoices.allV1) {
        expect(DeepgramVoices.isV1Voice(voice), isTrue, reason: voice);
      }
      for (final String voice in DeepgramVoices.flux) {
        expect(DeepgramVoices.isV1Voice(voice), isFalse, reason: voice);
      }
      expect(DeepgramVoices.isV1Voice('not-a-voice'), isFalse);
    });

    test('isKnownVoice accepts every cataloged voice', () {
      for (final String voice in DeepgramVoices.all) {
        expect(DeepgramVoices.isKnownVoice(voice), isTrue, reason: voice);
      }
      expect(DeepgramVoices.isKnownVoice('aura-thalia-en'), isFalse);
      expect(DeepgramVoices.isKnownVoice('flux-alexis-es'), isFalse);
      expect(DeepgramVoices.isKnownVoice(''), isFalse);
    });

    test('languageOf returns the language tag or null', () {
      expect(DeepgramVoices.languageOf('aura-asteria-en'), 'en');
      expect(DeepgramVoices.languageOf('aura-2-thalia-en'), 'en');
      expect(DeepgramVoices.languageOf('aura-2-agustina-es'), 'es');
      expect(DeepgramVoices.languageOf('aura-2-aurelia-de'), 'de');
      expect(DeepgramVoices.languageOf('aura-2-beatrix-nl'), 'nl');
      expect(DeepgramVoices.languageOf('aura-2-agathe-fr'), 'fr');
      expect(DeepgramVoices.languageOf('aura-2-cesare-it'), 'it');
      expect(DeepgramVoices.languageOf('aura-2-ama-ja'), 'ja');
      expect(DeepgramVoices.languageOf('flux-alexis-en'), 'en');
      expect(DeepgramVoices.languageOf('nonexistent-voice'), isNull);
      expect(DeepgramVoices.languageOf('flux-alexis-en-x'), isNull);
    });
  });
}
