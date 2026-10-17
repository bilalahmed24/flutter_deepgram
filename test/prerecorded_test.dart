/// Unit tests for the pre-recorded speech-to-text REST client
/// (`lib/src/listen/prerecorded/prerecorded_client.dart`) and its typed
/// options (`prerecorded_options.dart`).
///
/// All HTTP traffic runs through the queue-based fake client from
/// `helpers/fake_http.dart` (plus a small local recording client for raw
/// byte-upload and timeout assertions), so everything is deterministic,
/// offline, and fast. Wire names are verified against the documented
/// `POST /v1/listen` query parameters.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'helpers/fake_http.dart';
import 'helpers/fakes.dart';

/// Every documented scalar / repeated / object parameter, set at once.
const PrerecordedOptions fullOptions = PrerecordedOptions(
  model: 'nova-3',
  version: 'latest',
  language: 'en-US',
  detectLanguage: <String>['en', 'fr'],
  multilingual: true,
  alternatives: 2,
  punctuate: true,
  profanityFilter: true,
  redact: <String>['pci', 'numbers'],
  numerals: true,
  search: <String>['toronto', 'weather'],
  replace: <String>['colour:color'],
  keywords: <String>['deepest:1.5', 'shallower:-1.0'],
  keywordBoost: 'legacy-boost',
  diarize: true,
  diarizeVersion: 'v2',
  detectEntities: true,
  sentiment: true,
  topics: true,
  customTopic: <String>['Travel', 'Cooking'],
  customTopicMode: CustomTopicMode.strict,
  summarize: SummarizeOptions(
    model: 'summary-model',
    mode: SummarizeMode.bulletPoints,
    audioType: SummarizeAudioType.phoneCall,
  ),
  intents: true,
  customIntent: <String>['book_flight'],
  customIntentMode: CustomIntentMode.extended,
  paragraphs: true,
  utterances: true,
  utteranceWords: true,
  uttSplit: 0.5,
  tag: <String>['staging', 'nightly'],
  tier: 'nova',
  timeout: Duration(milliseconds: 2500),
  extra: <String, String>{'CustomerID': '12345'},
  mipOptOut: true,
  callback: 'https://example.com/callback',
  callbackMethod: 'PUT',
  multichannel: true,
  dictation: true,
  fillerWords: true,
  keyterm: <String>['Deepgram'],
  measurements: true,
  encoding: 'linear16',
  sampleRate: 16000,
);

/// The full options serialized by [fullOptions.toQuery].
const Map<String, dynamic> fullOptionsQuery = <String, dynamic>{
  'model': 'nova-3',
  'version': 'latest',
  'language': 'en-US',
  'detect_language': <String>['en', 'fr'],
  'multilingual': 'true',
  'alternatives': 2,
  'punctuate': 'true',
  'profanity_filter': 'true',
  'redact': <String>['pci', 'numbers'],
  'numerals': 'true',
  'search': <String>['toronto', 'weather'],
  'replace': <String>['colour:color'],
  'keywords': <String>['deepest:1.5', 'shallower:-1.0'],
  'keyword_boost': 'legacy-boost',
  'diarize': 'true',
  'diarize_model': 'v2',
  'detect_entities': 'true',
  'sentiment': 'true',
  'topics': 'true',
  'custom_topic': <String>['Travel', 'Cooking'],
  'custom_topic_mode': 'strict',
  'summarize': 'v2',
  'summarize_model': 'summary-model',
  'summarize_mode': 'bullet_points',
  'summarize_audio_type': 'phone_call',
  'intents': 'true',
  'custom_intent': <String>['book_flight'],
  'custom_intent_mode': 'extended',
  'paragraphs': 'true',
  'utterances': 'true',
  'utterance_words': 'true',
  'utt_split': 0.5,
  'tag': <String>['staging', 'nightly'],
  'tier': 'nova',
  'timeout': 2,
  'mip_opt_out': 'true',
  'callback': 'https://example.com/callback',
  'callback_method': 'PUT',
  'multichannel': 'true',
  'dictation': 'true',
  'filler_words': 'true',
  'keyterm': <String>['Deepgram'],
  'measurements': 'true',
  'encoding': 'linear16',
  'sample_rate': 16000,
  'extra': <String>['CustomerID:12345'],
};

/// A minimal successful transcription response.
const Map<String, dynamic> okResponse = <String, dynamic>{
  'metadata': <String, dynamic>{'request_id': 'req-ok'},
  'results': <String, dynamic>{
    'channels': <Map<String, dynamic>>[
      <String, dynamic>{
        'alternatives': <Map<String, dynamic>>[
          <String, dynamic>{'transcript': 'Hello world.', 'confidence': 0.99},
        ],
      },
    ],
  },
};

void main() {
  group('PrerecordedOptions.toQuery', () {
    test('default options produce no query parameters', () {
      expect(const PrerecordedOptions().toQuery(), isEmpty);
    });

    test('serializes every field to its documented wire name', () {
      expect(fullOptions.toQuery(), equals(fullOptionsQuery));
    });

    test('omits empty list fields and empty extra map', () {
      final query = const PrerecordedOptions(
        search: <String>[],
        replace: <String>[],
        keywords: <String>[],
        keyterm: <String>[],
        customTopic: <String>[],
        customIntent: <String>[],
        tag: <String>[],
        extra: <String, String>{},
      ).toQuery();
      expect(query, isEmpty);
    });

    test('smart format variants', () {
      // Plain true.
      expect(
        const PrerecordedOptions(smartFormat: true).toQuery(),
        containsPair('smart_format', 'true'),
      );
      // Medium hint becomes a repeated key: smart_format=true&smart_format=web.
      expect(
        const PrerecordedOptions(smartFormat: true, fmtMedium: 'web').toQuery(),
        containsPair('smart_format', <String>['true', 'web']),
      );
      // Explicit false is sent as 'false'.
      expect(
        const PrerecordedOptions(smartFormat: false).toQuery(),
        containsPair('smart_format', 'false'),
      );
      // Null is omitted.
      expect(
        const PrerecordedOptions(fmtMedium: 'web').toQuery(),
        isNot(contains('smart_format')),
      );
    });

    test('punctuate is suppressed by smart format', () {
      // smart_format implies punctuation, so punctuate is never sent with it.
      final withSmart = const PrerecordedOptions(
        smartFormat: true,
        punctuate: true,
      ).toQuery();
      expect(withSmart, containsPair('smart_format', 'true'));
      expect(withSmart, isNot(contains('punctuate')));

      // Without smart format, punctuate is sent.
      expect(
        const PrerecordedOptions(punctuate: true).toQuery(),
        containsPair('punctuate', 'true'),
      );

      // smart_format=false keeps an explicit punctuate.
      final both = const PrerecordedOptions(
        smartFormat: false,
        punctuate: true,
      ).toQuery();
      expect(both, containsPair('smart_format', 'false'));
      expect(both, containsPair('punctuate', 'true'));
    });

    test('redact accepts bool, string, and list forms', () {
      expect(
        const PrerecordedOptions(redact: true).toQuery(),
        containsPair('redact', 'true'),
      );
      expect(
        const PrerecordedOptions(redact: DeepgramRedactions.pci).toQuery(),
        containsPair('redact', 'pci'),
      );
      expect(
        const PrerecordedOptions(
          redact: <String>[DeepgramRedactions.pci, DeepgramRedactions.ssn],
        ).toQuery(),
        containsPair('redact', <String>['pci', 'ssn']),
      );
    });

    test('detect_language accepts bool, string, and list forms', () {
      expect(
        const PrerecordedOptions(detectLanguage: true).toQuery(),
        containsPair('detect_language', 'true'),
      );
      expect(
        const PrerecordedOptions(detectLanguage: 'fr').toQuery(),
        containsPair('detect_language', 'fr'),
      );
      expect(
        const PrerecordedOptions(
          detectLanguage: <String>['en', 'fr'],
        ).toQuery(),
        containsPair('detect_language', <String>['en', 'fr']),
      );
      expect(
        const PrerecordedOptions().toQuery(),
        isNot(contains('detect_language')),
      );
    });

    test('summarize v1 sends a plain boolean', () {
      expect(
        const PrerecordedOptions(summarize: SummarizeOptions()).toQuery(),
        equals(const <String, dynamic>{'summarize': 'true'}),
      );
    });

    test('summarize v2 wire forms', () {
      expect(
        const PrerecordedOptions(
          summarize: SummarizeOptions(v2: true),
        ).toQuery(),
        equals(const <String, dynamic>{'summarize': 'v2'}),
      );
      expect(
        const PrerecordedOptions(
          summarize: SummarizeOptions(mode: SummarizeMode.paragraphs),
        ).toQuery(),
        equals(const <String, dynamic>{
          'summarize': 'v2',
          'summarize_mode': 'paragraphs',
        }),
      );
      expect(
        const PrerecordedOptions(
          summarize: SummarizeOptions(audioType: SummarizeAudioType.meeting),
        ).toQuery(),
        equals(const <String, dynamic>{
          'summarize': 'v2',
          'summarize_audio_type': 'meeting',
        }),
      );
      expect(
        const PrerecordedOptions(
          summarize: SummarizeOptions(model: 'summary-model'),
        ).toQuery(),
        equals(const <String, dynamic>{
          'summarize': 'true',
          'summarize_model': 'summary-model',
        }),
      );
    });

    test('disabled summarize sends only summarize=false', () {
      expect(
        const PrerecordedOptions(
          summarize: SummarizeOptions(
            enabled: false,
            mode: SummarizeMode.general,
          ),
        ).toQuery(),
        equals(const <String, dynamic>{'summarize': 'false'}),
      );
    });

    test('summarize_audio_type alone implies summarize=v2', () {
      expect(
        const PrerecordedOptions(summarizeAudioType: 'phone_call').toQuery(),
        equals(const <String, dynamic>{
          'summarize': 'v2',
          'summarize_audio_type': 'phone_call',
        }),
      );
    });

    test('summarize_audio_type rides along with a boolean summarize', () {
      expect(
        const PrerecordedOptions(
          summarize: SummarizeOptions(),
          summarizeAudioType: 'meeting',
        ).toQuery(),
        equals(const <String, dynamic>{
          'summarize': 'true',
          'summarize_audio_type': 'meeting',
        }),
      );
    });

    test('SummarizeOptions.audioType wins over summarizeAudioType', () {
      expect(
        const PrerecordedOptions(
          summarize: SummarizeOptions(audioType: SummarizeAudioType.podcast),
          summarizeAudioType: 'meeting',
        ).toQuery(),
        containsPair('summarize_audio_type', 'podcast'),
      );
    });

    test('summarize_audio_type is not attached to summarize=false', () {
      expect(
        const PrerecordedOptions(
          summarize: SummarizeOptions(enabled: false),
          summarizeAudioType: 'meeting',
        ).toQuery(),
        equals(const <String, dynamic>{'summarize': 'false'}),
      );
    });

    test('timeout is truncated to whole seconds', () {
      expect(
        const PrerecordedOptions(
          timeout: Duration(milliseconds: 2500),
        ).toQuery(),
        containsPair('timeout', 2),
      );
      expect(
        const PrerecordedOptions(timeout: Duration(seconds: 90)).toQuery(),
        containsPair('timeout', 90),
      );
    });

    test('extra entries serialize as repeated key:value strings', () {
      expect(
        const PrerecordedOptions(
          extra: <String, String>{'CustomerID': '12345', 'Tag2': 'abc'},
        ).toQuery(),
        containsPair('extra', <String>['CustomerID:12345', 'Tag2:abc']),
      );
    });
  });

  group('SummarizeMode and SummarizeAudioType wire values', () {
    test('every SummarizeMode maps to its documented value', () {
      expect(SummarizeMode.conversational.toQueryValue(), 'conversational');
      expect(SummarizeMode.paragraphs.toQueryValue(), 'paragraphs');
      expect(SummarizeMode.bulletPoints.toQueryValue(), 'bullet_points');
      expect(SummarizeMode.general.toQueryValue(), 'general');
    });

    test('every SummarizeAudioType maps to its documented value', () {
      expect(SummarizeAudioType.phoneCall.toQueryValue(), 'phone_call');
      expect(SummarizeAudioType.meeting.toQueryValue(), 'meeting');
      expect(SummarizeAudioType.broadcast.toQueryValue(), 'broadcast');
      expect(SummarizeAudioType.podcast.toQueryValue(), 'podcast');
      expect(SummarizeAudioType.dictation.toQueryValue(), 'dictation');
    });
  });

  group('static catalogs', () {
    test('DeepgramSttModels lists distinct, usable model ids', () {
      const models = <String>[
        DeepgramSttModels.nova3,
        DeepgramSttModels.nova2,
        DeepgramSttModels.nova2Medical,
        DeepgramSttModels.nova2Phonecall,
        DeepgramSttModels.nova2Meeting,
        DeepgramSttModels.nova2General,
        DeepgramSttModels.enhanced,
        DeepgramSttModels.base,
        DeepgramSttModels.whisperLarge,
        DeepgramSttModels.fluxGeneralEn,
        DeepgramSttModels.fluxGeneralMulti,
      ];
      expect(models, isNotEmpty);
      expect(models, contains('nova-3'));
      expect(
        models.toSet(),
        hasLength(models.length),
        reason: 'model ids must not contain duplicates',
      );
      for (final model in models) {
        expect(model, isNotEmpty);
        expect(model, isNot(contains(' ')));
      }
    });

    test('DeepgramRedactions lists distinct policies', () {
      const redactions = <String>[
        DeepgramRedactions.pci,
        DeepgramRedactions.numbers,
        DeepgramRedactions.ssn,
      ];
      expect(redactions, <String>['pci', 'numbers', 'ssn']);
      expect(redactions.toSet(), hasLength(redactions.length));
    });

    test('custom topic/intent mode constants', () {
      expect(CustomTopicMode.strict, 'strict');
      expect(CustomTopicMode.extended, 'extended');
      expect(CustomIntentMode.strict, 'strict');
      expect(CustomIntentMode.extended, 'extended');
    });
  });

  group('PrerecordedClient.transcribeFromUrl', () {
    test('POSTs to /v1/listen with the url query parameter', () async {
      final queue = QueueHttpClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: queue,
        ),
        config: testConfig,
      );
      queue.enqueueJson(okResponse);

      final result = await client.transcribeFromUrl(
        'https://dpgr.am/spacewalk.wav',
      );

      final request = queue.requests.single;
      expect(request.method, 'POST');
      expect(request.url.scheme, 'https');
      expect(request.url.host, 'api.deepgram.com');
      expect(request.url.path, '/v1/listen');
      expect(
        request.url.queryParametersAll,
        equals(const <String, List<String>>{
          'url': <String>['https://dpgr.am/spacewalk.wav'],
        }),
      );
      expect(_headerOf(request.headers, 'authorization'), 'Token test-api-key');
      expect(request.body, '');

      expect(result.requestId, 'req-ok');
      expect(
        result.channels.single.alternatives.single.transcript,
        'Hello world.',
      );
    });

    test('serializes the full option set onto the wire', () async {
      final queue = QueueHttpClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: queue,
        ),
        config: testConfig,
      );
      queue.enqueueJson(const <String, dynamic>{
        'metadata': <String, dynamic>{},
      });

      await client.transcribeFromUrl(
        'https://example.com/a.wav',
        options: fullOptions,
      );

      final params = queue.requests.single.url.queryParametersAll;
      final expected = <String, List<String>>{
        for (final entry in fullOptionsQuery.entries)
          entry.key: _wireValues(entry.value),
      };
      expected.forEach((String key, List<String> value) {
        expect(params[key], value, reason: 'wire param $key');
      });
      expect(params['url'], <String>['https://example.com/a.wav']);
      expect(params.keys, unorderedEquals(<String>[...expected.keys, 'url']));
      // Nothing was set that should not be on the wire.
      expect(params.containsKey('smart_format'), isFalse);
    });

    test('smart format medium renders as repeated query keys', () async {
      final queue = QueueHttpClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: queue,
        ),
        config: testConfig,
      );
      queue.enqueueJson(const <String, dynamic>{
        'metadata': <String, dynamic>{},
      });

      await client.transcribeFromUrl(
        'https://example.com/a.wav',
        options: const PrerecordedOptions(smartFormat: true, fmtMedium: 'web'),
      );

      final params = queue.requests.single.url.queryParametersAll;
      expect(params['smart_format'], <String>['true', 'web']);
    });

    test('callback-style response still yields a usable result', () async {
      final queue = QueueHttpClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: queue,
        ),
        config: testConfig,
      );
      queue.enqueueJson(const <String, dynamic>{'request_id': 'cb-77'});

      final result = await client.transcribeFromUrl(
        'https://example.com/a.wav',
      );
      expect(result.requestId, 'cb-77');
      expect(result.channels, isEmpty);
    });

    test('empty body response decodes to an empty result', () async {
      final queue = QueueHttpClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: queue,
        ),
        config: testConfig,
      );
      queue.enqueueJson('');

      final result = await client.transcribeFromUrl(
        'https://example.com/a.wav',
      );
      expect(result.requestId, isNull);
      expect(result.channels, isEmpty);
    });

    test('rejects an empty url before any request is made', () async {
      final queue = QueueHttpClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: queue,
        ),
        config: testConfig,
      );

      await expectLater(
        client.transcribeFromUrl(''),
        throwsA(isA<DeepgramBadRequestException>()),
      );
      expect(queue.requests, isEmpty);
    });
  });

  group('PrerecordedClient.transcribeBytes', () {
    test('uploads raw bytes with the given content type', () async {
      final recording = _RecordingClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: recording,
        ),
        config: testConfig,
      );
      const audio = <int>[0x52, 0x49, 0x46, 0x46, 0x00, 0xff, 0x10];

      final result = await client.transcribeBytes(
        audio,
        contentType: 'audio/raw;rate=16000',
        options: const PrerecordedOptions(model: 'nova-3'),
      );

      final call = recording.calls.single;
      expect(call.method, 'POST');
      expect(call.url.host, 'api.deepgram.com');
      expect(call.url.path, '/v1/listen');
      expect(call.url.queryParametersAll['model'], <String>['nova-3']);
      expect(_headerOf(call.headers, 'authorization'), 'Token test-api-key');
      expect(_headerOf(call.headers, 'content-type'), 'audio/raw;rate=16000');
      expect(call.bodyBytes, audio);
      expect(result.requestId, 'req-ok');
    });

    test('defaults to audio/wav and omits empty query', () async {
      final recording = _RecordingClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: recording,
        ),
        config: testConfig,
      );

      await client.transcribeBytes(<int>[1, 2, 3]);

      final call = recording.calls.single;
      expect(_headerOf(call.headers, 'content-type'), 'audio/wav');
      expect(call.url.query, '');
    });

    test('sends options as query parameters on byte uploads', () async {
      final queue = QueueHttpClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: queue,
        ),
        config: testConfig,
      );
      queue.enqueueJson(okResponse);

      await client.transcribeBytes(
        <int>[1, 2, 3],
        options: const PrerecordedOptions(
          model: 'nova-2',
          smartFormat: true,
          encoding: 'linear16',
          sampleRate: 16000,
        ),
      );

      final request = queue.requests.single;
      expect(request.method, 'POST');
      expect(_headerOf(request.headers, 'content-type'), 'audio/wav');
      final params = request.url.queryParametersAll;
      expect(params['model'], <String>['nova-2']);
      expect(params['smart_format'], <String>['true']);
      expect(params['encoding'], <String>['linear16']);
      expect(params['sample_rate'], <String>['16000']);
    });

    test('logs the upload size when a logger is configured', () async {
      final queue = QueueHttpClient();
      final logger = RecordingLogger();
      final loggedConfig = testConfig.copyWith(logger: logger);
      final client = PrerecordedClient(
        http: HttpEngine(
          config: loggedConfig,
          auth: DeepgramAuth(loggedConfig),
          client: queue,
        ),
        config: loggedConfig,
      );
      queue.enqueueJson(okResponse);

      await client.transcribeBytes(<int>[1, 2, 3, 4]);

      expect(logger.debugs.single, contains('4 bytes'));
    });

    test('rejects empty audio before any request is made', () async {
      final queue = QueueHttpClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: queue,
        ),
        config: testConfig,
      );

      await expectLater(
        client.transcribeBytes(<int>[]),
        throwsA(isA<DeepgramBadRequestException>()),
      );
      expect(queue.requests, isEmpty);
    });

    test('upload timeout scales with payload size', () async {
      // Base timeout of 40 ms would kill a 250 ms response, but a 1.5 MB
      // payload adds ~3 s of budget, so the request completes.
      const scaledConfig = DeepgramConfig(
        apiKey: 'test-api-key',
        requestTimeout: Duration(milliseconds: 40),
        maxRetries: 2,
        retryBaseDelay: Duration(milliseconds: 1),
        retryMaxDelay: Duration(milliseconds: 5),
      );
      final recording = _RecordingClient(
        delay: const Duration(milliseconds: 250),
      );
      final client = PrerecordedClient(
        http: HttpEngine(
          config: scaledConfig,
          auth: DeepgramAuth(scaledConfig),
          client: recording,
        ),
        config: scaledConfig,
      );
      final bigPayload = List<int>.filled(1024 * 1024 + 512 * 1024, 7);

      final result = await client.transcribeBytes(
        bigPayload,
        contentType: 'audio/raw;rate=16000',
      );

      expect(recording.calls, hasLength(1));
      expect(
        recording.calls.single.bodyBytes,
        hasLength(1024 * 1024 + 512 * 1024),
      );
      expect(result.requestId, 'req-ok');
    });

    test(
      'small payloads keep the base timeout and retry into a typed error',
      () async {
        const baseConfig = DeepgramConfig(
          apiKey: 'test-api-key',
          requestTimeout: Duration(milliseconds: 40),
          maxRetries: 2,
          retryBaseDelay: Duration(milliseconds: 1),
          retryMaxDelay: Duration(milliseconds: 5),
        );
        final recording = _RecordingClient(
          delay: const Duration(milliseconds: 250),
        );
        final client = PrerecordedClient(
          http: HttpEngine(
            config: baseConfig,
            auth: DeepgramAuth(baseConfig),
            client: recording,
          ),
          config: baseConfig,
        );

        await expectLater(
          client.transcribeBytes(<int>[1, 2, 3]),
          throwsA(isA<DeepgramTimeoutException>()),
        );
        // One initial attempt plus maxRetries retries.
        expect(recording.calls, hasLength(3));
      },
    );
  });

  group('cancellation', () {
    test('a pre-cancelled token rejects the request immediately', () async {
      final queue = QueueHttpClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: queue,
        ),
        config: testConfig,
      );
      final token = HttpCancelToken()..cancel('stop it');

      await expectLater(
        client.transcribeFromUrl(
          'https://example.com/a.wav',
          cancelToken: token,
        ),
        throwsA(
          isA<DeepgramException>().having(
            (e) => e.message,
            'message',
            contains('stop it'),
          ),
        ),
      );
      expect(token.isCancelled, isTrue);
      expect(token.reason, 'stop it');
      expect(queue.requests, isEmpty);
    });

    test('cancelling during a 429 backoff aborts the request', () async {
      final queue = QueueHttpClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: queue,
        ),
        config: testConfig,
      );
      // A long Retry-After parks the engine in its backoff wait.
      queue.enqueueJson(
        const <String, dynamic>{'err_msg': 'Slow down.'},
        status: 429,
        headers: <String, String>{'retry-after': '30'},
      );
      final token = HttpCancelToken();
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 30),
        ).then((_) => token.cancel('aborted mid-backoff')),
      );

      await expectLater(
        client.transcribeFromUrl(
          'https://example.com/a.wav',
          cancelToken: token,
        ),
        throwsA(
          isA<DeepgramException>().having(
            (e) => e.message,
            'message',
            contains('aborted'),
          ),
        ),
      );
      // Only the first, throttled attempt was made.
      expect(queue.requests, hasLength(1));
    });
  });

  group('error mapping', () {
    test('401 maps to DeepgramAuthException with parsed body fields', () async {
      final queue = QueueHttpClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: queue,
        ),
        config: testConfig,
      );
      queue.enqueueJson(const <String, dynamic>{
        'err_msg': 'Invalid API key',
        'request_id': 'req-401',
        'err_code': 'AUTH_INVALID',
      }, status: 401);

      await expectLater(
        client.transcribeFromUrl('https://example.com/a.wav'),
        throwsA(
          isA<DeepgramAuthException>()
              .having((e) => e.message, 'message', 'Invalid API key')
              .having((e) => e.requestId, 'requestId', 'req-401')
              .having((e) => e.code, 'code', 'AUTH_INVALID'),
        ),
      );
      // Auth errors are never retried.
      expect(queue.requests, hasLength(1));
    });

    test(
      '429 with Retry-After retries, then throws DeepgramRateLimitException',
      () async {
        final queue = QueueHttpClient();
        final client = PrerecordedClient(
          http: HttpEngine(
            config: testConfig,
            auth: DeepgramAuth(testConfig),
            client: queue,
          ),
          config: testConfig,
        );
        // Two immediately-retryable throttles, then a final one that carries
        // the Retry-After surfaced on the exception.
        queue.enqueueJson(
          const <String, dynamic>{'err_msg': 'Throttled.'},
          status: 429,
          headers: <String, String>{'retry-after': '0'},
        );
        queue.enqueueJson(
          const <String, dynamic>{'err_msg': 'Throttled.'},
          status: 429,
          headers: <String, String>{'retry-after': '0'},
        );
        queue.enqueueJson(
          const <String, dynamic>{'err_msg': 'Still throttled.'},
          status: 429,
          headers: <String, String>{'retry-after': '2'},
        );

        await expectLater(
          client.transcribeFromUrl('https://example.com/a.wav'),
          throwsA(
            isA<DeepgramRateLimitException>()
                .having((e) => e.message, 'message', 'Still throttled.')
                .having(
                  (e) => e.retryAfter,
                  'retryAfter',
                  const Duration(seconds: 2),
                ),
          ),
        );
        // One initial attempt plus maxRetries (2) retries.
        expect(queue.requests, hasLength(3));
      },
    );

    test('a single 429 is retried transparently', () async {
      final queue = QueueHttpClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: queue,
        ),
        config: testConfig,
      );
      queue.enqueueJson(
        const <String, dynamic>{'err_msg': 'Throttled.'},
        status: 429,
        headers: <String, String>{'retry-after': '0'},
      );
      queue.enqueueJson(okResponse);

      final result = await client.transcribeFromUrl(
        'https://example.com/a.wav',
      );

      expect(result.requestId, 'req-ok');
      expect(queue.requests, hasLength(2));
    });

    test(
      '404 maps to DeepgramNotFoundException with the header request id',
      () async {
        final queue = QueueHttpClient();
        final client = PrerecordedClient(
          http: HttpEngine(
            config: testConfig,
            auth: DeepgramAuth(testConfig),
            client: queue,
          ),
          config: testConfig,
        );
        queue.enqueueJson(
          'Not Found',
          status: 404,
          headers: <String, String>{'x-request-id': 'hdr-404'},
        );

        await expectLater(
          client.transcribeFromUrl('https://example.com/missing.wav'),
          throwsA(
            isA<DeepgramNotFoundException>()
                .having((e) => e.message, 'message', 'HTTP 404.')
                .having((e) => e.requestId, 'requestId', 'hdr-404'),
          ),
        );
        expect(queue.requests, hasLength(1));
      },
    );

    test(
      'transport failures retry, then throw DeepgramNetworkException',
      () async {
        final queue = QueueHttpClient();
        final client = PrerecordedClient(
          http: HttpEngine(
            config: testConfig,
            auth: DeepgramAuth(testConfig),
            client: queue,
          ),
          config: testConfig,
        );
        queue.enqueueError(http.ClientException('connection refused'));
        queue.enqueueError(http.ClientException('connection refused'));
        queue.enqueueError(http.ClientException('connection refused'));

        await expectLater(
          client.transcribeFromUrl('https://example.com/a.wav'),
          throwsA(
            isA<DeepgramNetworkException>()
                .having((e) => e.message, 'message', 'HTTP transport failure.')
                .having((e) => e.cause, 'cause', isA<http.ClientException>()),
          ),
        );
        expect(queue.requests, hasLength(3));
      },
    );

    test('500 retries, then throws DeepgramServerException', () async {
      final queue = QueueHttpClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: queue,
        ),
        config: testConfig,
      );
      for (var i = 0; i < 3; i++) {
        queue.enqueueJson(const <String, dynamic>{
          'err_msg': 'Internal error.',
        }, status: 500);
      }

      await expectLater(
        client.transcribeFromUrl('https://example.com/a.wav'),
        throwsA(
          isA<DeepgramServerException>().having(
            (e) => e.message,
            'message',
            'Internal error.',
          ),
        ),
      );
      expect(queue.requests, hasLength(3));
    });

    test('400 maps to DeepgramBadRequestException without retrying', () async {
      final queue = QueueHttpClient();
      final client = PrerecordedClient(
        http: HttpEngine(
          config: testConfig,
          auth: DeepgramAuth(testConfig),
          client: queue,
        ),
        config: testConfig,
      );
      queue.enqueueJson(const <String, dynamic>{
        'err_msg': 'Invalid parameter.',
      }, status: 400);

      await expectLater(
        client.transcribeFromUrl('https://example.com/a.wav'),
        throwsA(
          isA<DeepgramBadRequestException>().having(
            (e) => e.message,
            'message',
            'Invalid parameter.',
          ),
        ),
      );
      expect(queue.requests, hasLength(1));
    });
  });
}

/// Renders a toQuery value (scalar or repeated list) as wire strings.
List<String> _wireValues(dynamic value) => value is List<dynamic>
    ? <String>[for (final v in value) v.toString()]
    : <String>[value.toString()];

/// Case-insensitive header lookup over a captured header map.
String? _headerOf(Map<String, String> headers, String name) {
  final lower = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == lower) {
      return entry.value;
    }
  }
  return null;
}

/// One HTTP call captured by [_RecordingClient].
class _RecordedCall {
  const _RecordedCall(this.method, this.url, this.headers, this.bodyBytes);

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final List<int> bodyBytes;
}

/// An [http.Client] that records every call and answers after an optional
/// [delay] — used to assert raw upload bytes and payload-scaled timeouts.
class _RecordingClient extends http.BaseClient {
  _RecordingClient({this.delay});

  /// Artificial response latency.
  final Duration? delay;

  final List<_RecordedCall> calls = <_RecordedCall>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    calls.add(
      _RecordedCall(
        request.method,
        request.url,
        Map<String, String>.from(request.headers),
        bytes,
      ),
    );
    final latency = delay;
    if (latency != null) {
      await Future<void>.delayed(latency);
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(okResponse))),
      200,
      request: request,
    );
  }
}
