/// Unit tests for the Text Intelligence client
/// (`lib/src/intelligence/text_intelligence.dart`).
///
/// All HTTP traffic runs through the queue-based fake client from
/// `helpers/fake_http.dart`, wired into the client exactly the way the
/// `DeepgramClient` facade builds it (`HttpEngine(config:…, auth:…, client:…)`
/// + `TextIntelligenceClient(http:…, config:…)`), so everything is
/// deterministic, offline, and fast. Wire names are verified against the
/// documented `POST /v1/read` contract.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'helpers/fake_http.dart';
import 'helpers/fakes.dart';

/// Every documented `/v1/read` parameter, set at once.
const TextIntelligenceOptions fullOptions = TextIntelligenceOptions(
  sentiment: true,
  topics: true,
  summarize: true,
  intents: true,
  customTopic: <String>['Travel', 'Cooking'],
  customTopicMode: 'strict',
  customIntent: <String>['book_flight', 'cancel_flight'],
  customIntentMode: 'extended',
  language: 'en-US',
  tag: <String>['staging', 'nightly'],
  callback: 'https://example.com/cb',
  callbackMethod: 'PUT',
);

/// The full options serialized by [fullOptions.toQuery].
const Map<String, dynamic> fullOptionsQuery = <String, dynamic>{
  'sentiment': true,
  'topics': true,
  'summarize': true,
  'intents': true,
  'custom_topic': <String>['Travel', 'Cooking'],
  'custom_topic_mode': 'strict',
  'custom_intent': <String>['book_flight', 'cancel_flight'],
  'custom_intent_mode': 'extended',
  'language': 'en-US',
  'tag': <String>['staging', 'nightly'],
  'callback': 'https://example.com/cb',
  'callback_method': 'PUT',
};

/// A current-shape `/v1/read` response: list-based results, full metadata.
const Map<String, dynamic> currentShapeResponse = <String, dynamic>{
  'metadata': <String, dynamic>{
    'request_id': 'req-1',
    'created': '2025-06-01T00:00:00Z',
    'language': 'en',
    'summary_info': <String, dynamic>{
      'model_uuid': 'uuid-summary',
      'input_tokens': 120,
      'output_tokens': 30,
    },
    'sentiment_info': <String, dynamic>{
      'model_uuid': 'uuid-sentiment',
      'input_tokens': 80,
      'output_tokens': 20,
    },
    'model_info': <String, dynamic>{'name': 'read-gen', 'version': '1'},
    'models': <dynamic>['read-sentiment', 'read-topics', 42],
  },
  'results': <String, dynamic>{
    'sentiments': <Map<String, dynamic>>[
      <String, dynamic>{
        'text': 'I love this product.',
        'sentiment': 'positive',
        'sentiment_score': 0.8,
        'start_word': 0,
        'end_word': 3,
      },
      <String, dynamic>{
        'text': 'It broke.',
        'sentiment': 'negative',
        'sentiment_score': -0.5,
        'start_word': 4,
        'end_word': 5,
      },
    ],
    'summaries': <Map<String, dynamic>>[
      <String, dynamic>{
        'summary': 'An enthusiastic product review.',
        'start_word': 0,
        'end_word': 5,
      },
    ],
    'topics': <Map<String, dynamic>>[
      <String, dynamic>{
        'topic': 'Travel',
        'confidence_score': 0.9,
        'start_word': 0,
        'end_word': 2,
      },
    ],
    'intents': <Map<String, dynamic>>[
      <String, dynamic>{
        'intent': 'book_flight',
        'confidence_score': 0.75,
        'start_word': 0,
        'end_word': 2,
      },
    ],
  },
};

/// Builds a client wired exactly like the facade does.
TextIntelligenceClient _client(
  QueueHttpClient queue, {
  DeepgramConfig config = testConfig,
}) {
  return TextIntelligenceClient(
    http: HttpEngine(config: config, auth: DeepgramAuth(config), client: queue),
    config: config,
  );
}

/// Case-insensitive header lookup.
String? _headerOf(Map<String, String> headers, String name) {
  final lower = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}

/// Renders a toQuery value the way the wire shows it: scalars via toString,
/// lists as one entry per element.
List<String> _wireValues(Object? value) {
  if (value is Iterable) {
    return <String>[for (final item in value) item.toString()];
  }
  return <String>[value.toString()];
}

void main() {
  group('TextIntelligenceOptions', () {
    test('default options produce no query parameters', () {
      expect(const TextIntelligenceOptions().toQuery(), isEmpty);
    });

    test('serializes every field to its documented wire name', () {
      expect(fullOptions.toQuery(), equals(fullOptionsQuery));
    });

    test('booleans serialize as true/false', () {
      final query = const TextIntelligenceOptions(
        sentiment: true,
        topics: false,
      ).toQuery();
      expect(
        query,
        equals(const <String, dynamic>{'sentiment': true, 'topics': false}),
      );
    });

    test('omits empty list fields', () {
      expect(
        const TextIntelligenceOptions(
          customTopic: <String>[],
          customIntent: <String>[],
          tag: <String>[],
        ).toQuery(),
        isEmpty,
      );
    });

    test('exposes the allowed-value catalogs', () {
      expect(
        TextIntelligenceOptions.customTopicModes,
        equals(<String>['strict', 'extended']),
      );
      expect(
        TextIntelligenceOptions.customIntentModes,
        equals(<String>['strict', 'extended']),
      );
      expect(
        TextIntelligenceOptions.callbackMethods,
        equals(<String>['POST', 'PUT']),
      );
    });
  });

  group('TextIntelligenceClient.analyze (wire)', () {
    test('POSTs /v1/read with {text} body and no query by default', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(currentShapeResponse);

      final result = await client.analyze('I love this product.');

      final request = queue.requests.single;
      expect(request.method, 'POST');
      expect(request.url.scheme, 'https');
      expect(request.url.host, 'api.deepgram.com');
      expect(request.url.path, '/v1/read');
      expect(request.url.query, '');
      expect(_headerOf(request.headers, 'authorization'), 'Token test-api-key');
      // The engine currently sends no explicit Content-Type for JSON bodies;
      // package:http defaults a string body to text/plain. A future engine may
      // default to application/json — accept either.
      final contentType = _headerOf(request.headers, 'content-type');
      expect(
        contentType,
        anyOf(isNull, 'application/json', 'text/plain; charset=utf-8'),
      );
      expect(
        jsonDecode(request.body),
        equals(<String, dynamic>{'text': 'I love this product.'}),
      );

      expect(result.metadata.requestId, 'req-1');
      expect(result.sentiments, hasLength(2));
      expect(result.sentiments.first.sentiment, 'positive');
    });

    test('serializes the full option set onto the wire', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(const <String, dynamic>{
        'metadata': <String, dynamic>{},
      });

      await client.analyze('Hello', options: fullOptions);

      final params = queue.requests.single.url.queryParametersAll;
      final expected = <String, List<String>>{
        for (final entry in fullOptionsQuery.entries)
          entry.key: _wireValues(entry.value),
      };
      expected.forEach((String key, List<String> value) {
        expect(params[key], value, reason: 'wire param $key');
      });
      // Repeated keys for the list-valued options.
      expect(queue.requests.single.url.query, contains('custom_topic=Travel'));
    });

    test('analyzeUrl sends {url} in the body instead', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(currentShapeResponse);

      final result = await client.analyzeUrl(
        'https://example.com/review.txt',
        options: const TextIntelligenceOptions(language: 'en'),
      );

      final request = queue.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/v1/read');
      expect(
        jsonDecode(request.body),
        equals(<String, dynamic>{'url': 'https://example.com/review.txt'}),
      );
      expect(
        request.url.queryParametersAll,
        equals(const <String, List<String>>{
          'language': <String>['en'],
        }),
      );
      expect(result.metadata.requestId, 'req-1');
    });

    test('uses Bearer auth for a jwt config', () async {
      final queue = QueueHttpClient();
      final config = DeepgramConfig(
        jwt: 'jwt-1',
        requestTimeout: const Duration(seconds: 2),
      );
      final client = _client(queue, config: config);
      queue.enqueueJson(const <String, dynamic>{
        'metadata': <String, dynamic>{},
      });

      await client.analyze('Hi');

      expect(
        _headerOf(queue.requests.single.headers, 'authorization'),
        'Bearer jwt-1',
      );
    });

    test('exposes the config it was built from', () {
      final queue = QueueHttpClient();
      final client = _client(queue);
      expect(client.config, same(testConfig));
    });
  });

  group('TextIntelligenceResult parsing', () {
    test('current shape: lists, metadata, model usage, models', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(currentShapeResponse);

      final result = await client.analyze('text');

      // Metadata.
      final metadata = result.metadata;
      expect(metadata.requestId, 'req-1');
      expect(metadata.created, '2025-06-01T00:00:00Z');
      expect(metadata.language, 'en');
      expect(metadata.summaryInfo!.modelUuid, 'uuid-summary');
      expect(metadata.summaryInfo!.inputTokens, 120);
      expect(metadata.summaryInfo!.outputTokens, 30);
      expect(metadata.sentimentInfo!.inputTokens, 80);
      expect(
        metadata.modelInfo,
        equals(<String, dynamic>{'name': 'read-gen', 'version': '1'}),
      );
      // Non-string model names are filtered out of the models list.
      expect(
        metadata.models,
        equals(<String>['read-sentiment', 'read-topics']),
      );
      expect(metadata.topicsInfo, isNull);
      expect(metadata.intentsInfo, isNull);

      // Sentiments.
      expect(result.sentiments, hasLength(2));
      final first = result.sentiments.first;
      expect(first.text, 'I love this product.');
      expect(first.sentiment, 'positive');
      expect(first.sentimentScore, 0.8);
      expect(first.startWord, 0);
      expect(first.endWord, 3);
      expect(result.sentiments.last.sentiment, 'negative');
      expect(result.sentiments.last.sentimentScore, -0.5);

      // No map envelope -> no average reported.
      expect(result.averageSentiment, isNull);
      expect(result.averageSentimentScore, isNull);

      // Summaries.
      expect(result.summaries, hasLength(1));
      expect(
        result.summaries.single.summary,
        'An enthusiastic product review.',
      );
      expect(result.summaries.single.startWord, 0);
      expect(result.summaries.single.endWord, 5);

      // Topics: direct topic objects on the current shape carry the label and
      // the word range but not the confidence (only nested entries do).
      expect(result.topics, hasLength(1));
      expect(result.topics.single.topic, 'Travel');
      expect(result.topics.single.confidenceScore, isNull);
      expect(result.topics.single.startWord, 0);
      expect(result.topics.single.endWord, 2);

      // Intents.
      expect(result.intents, hasLength(1));
      expect(result.intents.single.intent, 'book_flight');
      expect(result.intents.single.confidenceScore, isNull);
    });

    test('legacy segment shape with average sentiment', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{
        'metadata': <String, dynamic>{'request_id': 'req-legacy'},
        'results': <String, dynamic>{
          'sentiments': <String, dynamic>{
            'average': <String, dynamic>{
              'sentiment': 'positive',
              'sentiment_score': 0.62,
            },
            'segments': <Map<String, dynamic>>[
              <String, dynamic>{
                'text': 'Great stuff.',
                'sentiment': 'positive',
                'sentiment_score': 0.9,
                'start_word': 0,
                'end_word': 2,
              },
            ],
          },
          'topics': <String, dynamic>{
            'segments': <Map<String, dynamic>>[
              <String, dynamic>{
                'start_word': 0,
                'end_word': 2,
                'topics': <Map<String, dynamic>>[
                  <String, dynamic>{'topic': 'Travel', 'confidence_score': 0.9},
                  <String, dynamic>{'topic': 'Cooking'},
                ],
              },
              <String, dynamic>{
                'start_word': 3,
                'end_word': 4,
                'topic': 'Direct topic',
              },
            ],
          },
          'intents': <String, dynamic>{
            'segments': <Map<String, dynamic>>[
              <String, dynamic>{
                'start_word': 0,
                'end_word': 2,
                'intents': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'intent': 'book_flight',
                    'confidence_score': 0.75,
                  },
                ],
              },
              <String, dynamic>{
                'start_word': 3,
                'end_word': 4,
                'intent': 'ask_help',
              },
            ],
          },
        },
      });

      final result = await client.analyze('text');

      expect(result.averageSentiment, 'positive');
      expect(result.averageSentimentScore, 0.62);
      expect(result.sentiments, hasLength(1));
      expect(result.sentiments.single.text, 'Great stuff.');

      // Segment-nested topics inherit the segment word range; nested entries
      // may omit it and fall back; a segment without a nested list contributes
      // its direct topic string.
      expect(result.topics, hasLength(3));
      expect(result.topics[0].topic, 'Travel');
      expect(result.topics[0].confidenceScore, 0.9);
      expect(result.topics[0].startWord, 0);
      expect(result.topics[0].endWord, 2);
      expect(result.topics[1].topic, 'Cooking');
      expect(result.topics[1].confidenceScore, isNull);
      expect(result.topics[1].startWord, 0);
      expect(result.topics[2].topic, 'Direct topic');
      expect(result.topics[2].startWord, 3);

      expect(result.intents, hasLength(2));
      expect(result.intents[0].intent, 'book_flight');
      expect(result.intents[0].confidenceScore, 0.75);
      expect(result.intents[0].startWord, 0);
      expect(result.intents[1].intent, 'ask_help');
      expect(result.intents[1].startWord, 3);
    });

    test('double legacy results envelope unwraps to the payload', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{
        'metadata': <String, dynamic>{'request_id': 'req-env'},
        'results': <String, dynamic>{
          'sentiments': <String, dynamic>{
            'results': <String, dynamic>{
              'sentiments': <String, dynamic>{
                'results': <String, dynamic>{
                  'sentiments': <String, dynamic>{
                    'average': <String, dynamic>{
                      'sentiment': 'neutral',
                      'sentiment_score': 0.1,
                    },
                    'segments': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'text': 'Meh.',
                        'sentiment': 'neutral',
                        'sentiment_score': 0.1,
                      },
                    ],
                  },
                },
              },
            },
          },
          'topics': <String, dynamic>{
            'results': <String, dynamic>{
              'topics': <String, dynamic>{
                'segments': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'start_word': 0,
                    'end_word': 1,
                    'topics': <Map<String, dynamic>>[
                      <String, dynamic>{'topic': 'News'},
                    ],
                  },
                ],
              },
            },
          },
          'intents': <String, dynamic>{
            'results': <String, dynamic>{
              'intents': <String, dynamic>{
                'segments': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'start_word': 0,
                    'end_word': 1,
                    'intents': <Map<String, dynamic>>[
                      <String, dynamic>{'intent': 'read_news'},
                    ],
                  },
                ],
              },
            },
          },
        },
      });

      final result = await client.analyze('text');

      expect(result.averageSentiment, 'neutral');
      expect(result.sentiments.single.text, 'Meh.');
      expect(result.topics.single.topic, 'News');
      expect(result.topics.single.startWord, 0);
      expect(result.intents.single.intent, 'read_news');
    });

    test(
      'topics envelope without the feature key falls back to inner map',
      () async {
        final queue = QueueHttpClient();
        final client = _client(queue);
        queue.enqueueJson(<String, dynamic>{
          'results': <String, dynamic>{
            'topics': <String, dynamic>{
              'results': <String, dynamic>{
                'segments': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'start_word': 0,
                    'end_word': 1,
                    'topics': <Map<String, dynamic>>[
                      <String, dynamic>{'topic': 'Sports'},
                    ],
                  },
                ],
              },
            },
          },
        });

        final result = await client.analyze('text');
        expect(result.topics.single.topic, 'Sports');
        expect(result.topics.single.startWord, 0);
      },
    );

    test('summary legacy shapes', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{
        'results': <String, dynamic>{
          'summary': <String, dynamic>{
            'results': <String, dynamic>{
              'summary': <String, dynamic>{
                'text': 'Nested summary text.',
                'start_word': 0,
                'end_word': 9,
              },
            },
          },
        },
      });

      final result = await client.analyze('text');
      expect(result.summaries, hasLength(1));
      expect(result.summaries.single.summary, 'Nested summary text.');
      expect(result.summaries.single.startWord, 0);
      expect(result.summaries.single.endWord, 9);
    });

    test(
      'summary flat object accepts text/result/short and nested summary',
      () {
        // Flat {text}.
        final fromText = TextIntelligenceResult.fromJson(<String, dynamic>{
          'results': <String, dynamic>{
            'summary': <String, dynamic>{'text': 'Flat text.'},
          },
        });
        expect(fromText.summaries.single.summary, 'Flat text.');

        // Flat {result}.
        final fromResult = TextIntelligenceResult.fromJson(<String, dynamic>{
          'results': <String, dynamic>{
            'summary': <String, dynamic>{'result': 'Flat result.'},
          },
        });
        expect(fromResult.summaries.single.summary, 'Flat result.');

        // Flat {short}.
        final fromShort = TextIntelligenceResult.fromJson(<String, dynamic>{
          'results': <String, dynamic>{
            'summary': <String, dynamic>{'short': 'Flat short.'},
          },
        });
        expect(fromShort.summaries.single.summary, 'Flat short.');

        // Nested {summary: {text}}.
        final fromNested = TextIntelligenceResult.fromJson(<String, dynamic>{
          'results': <String, dynamic>{
            'summary': <String, dynamic>{
              'summary': <String, dynamic>{'text': 'Nested under summary.'},
            },
          },
        });
        expect(fromNested.summaries.single.summary, 'Nested under summary.');
      },
    );

    test(
      'summaries list with unusable entries falls back to legacy summary',
      () {
        final result = TextIntelligenceResult.fromJson(<String, dynamic>{
          'results': <String, dynamic>{
            'summaries': <Map<String, dynamic>>[
              <String, dynamic>{'start_word': 0}, // no usable text -> skipped
              <String, dynamic>{'summary': ''}, // empty text -> skipped
            ],
            'summary': <String, dynamic>{'text': 'Legacy fallback.'},
          },
        });
        expect(result.summaries, hasLength(1));
        expect(result.summaries.single.summary, 'Legacy fallback.');
      },
    );

    test('summary text aliases: summary beats text', () {
      final result = TextIntelligenceResult.fromJson(<String, dynamic>{
        'results': <String, dynamic>{
          'summaries': <Map<String, dynamic>>[
            <String, dynamic>{
              'summary': 'Primary.',
              'text': 'Alias.',
              'start_word': '2',
              'end_word': '7',
            },
          ],
        },
      });
      expect(result.summaries.single.summary, 'Primary.');
      // Numeric strings are coerced for the word ranges.
      expect(result.summaries.single.startWord, 2);
      expect(result.summaries.single.endWord, 7);
    });

    test('metadata legacy {metadata: {metadata: …}} envelope', () {
      final result = TextIntelligenceResult.fromJson(<String, dynamic>{
        'metadata': <String, dynamic>{
          'metadata': <String, dynamic>{
            'request_id': 'req-env-2',
            'created': '2025-06-02T00:00:00Z',
            'language': 'fr',
          },
        },
      });
      expect(result.metadata.requestId, 'req-env-2');
      expect(result.metadata.created, '2025-06-02T00:00:00Z');
      expect(result.metadata.language, 'fr');
    });

    test('empty body response decodes to an empty result', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson('');

      final result = await client.analyze('text');
      expect(result.metadata.requestId, isNull);
      expect(result.sentiments, isEmpty);
      expect(result.summaries, isEmpty);
      expect(result.topics, isEmpty);
      expect(result.intents, isEmpty);
    });

    test('missing and malformed fields degrade to defaults', () {
      final result = TextIntelligenceResult.fromJson(<String, dynamic>{
        'results': <String, dynamic>{
          'sentiments': 'not-a-map-or-list',
          'topics': <dynamic>[
            <String, dynamic>{
              'start_word': 3.7, // num -> rounded int
              'end_word': '9', // numeric string
              'topics': <dynamic>[
                <String, dynamic>{
                  'topic': 42, // non-string -> ''
                  'confidence_score': true, // non-numeric -> null
                },
                'not-a-map',
              ],
            },
          ],
          'intents': <Map<String, dynamic>>[
            <String, dynamic>{
              'start_word': 0,
              'end_word': 1,
              'intents': <Map<String, dynamic>>[
                <String, dynamic>{
                  'intent': 'buy',
                  'confidence_score': '0.5', // numeric string
                },
              ],
            },
          ],
          'sentiments_alt': null,
        },
        'metadata': <String, dynamic>{
          'summary_info': 'not-a-map',
          'models': 'not-a-list',
        },
      });

      // Sentiments with a wrong type produce no segments.
      expect(result.sentiments, isEmpty);
      expect(result.averageSentiment, isNull);

      // Malformed nested topics degrade: non-string topic -> '', non-numeric
      // confidence -> null, non-map entries skipped, num word ranges rounded.
      expect(result.topics, hasLength(1));
      expect(result.topics.single.topic, '');
      expect(result.topics.single.confidenceScore, isNull);
      expect(result.topics.single.startWord, 4); // 3.7 rounds to 4
      expect(result.topics.single.endWord, 9);

      expect(result.intents.single.confidenceScore, 0.5);
      expect(result.metadata.summaryInfo, isNull);
      expect(result.metadata.models, isNull);
    });

    test('sentiment segment numeric coercions and list tolerance', () {
      final result = TextIntelligenceResult.fromJson(<String, dynamic>{
        'results': <String, dynamic>{
          'sentiments': <dynamic>[
            <String, dynamic>{
              'text': 7, // non-string -> ''
              'sentiment': true, // non-string -> ''
              'sentiment_score': '0.25', // numeric string
              'start_word': 1.2, // num -> 1
              'end_word': '4', // numeric string
            },
            'not-a-map', // skipped
          ],
        },
      });
      final segment = result.sentiments.single;
      expect(segment.text, '');
      expect(segment.sentiment, '');
      expect(segment.sentimentScore, 0.25);
      expect(segment.startWord, 1);
      expect(segment.endWord, 4);
    });

    test('average block with malformed members degrades to nulls', () {
      final result = TextIntelligenceResult.fromJson(<String, dynamic>{
        'results': <String, dynamic>{
          'sentiments': <String, dynamic>{
            'average': <String, dynamic>{
              'sentiment': 42, // non-string -> null
              'sentiment_score': 'high', // non-numeric -> null
            },
            'segments': <Map<String, dynamic>>[
              <String, dynamic>{'text': 'x', 'sentiment': 'neutral'},
            ],
          },
        },
      });
      expect(result.averageSentiment, isNull);
      expect(result.averageSentimentScore, isNull);
      expect(result.sentiments.single.sentiment, 'neutral');
    });

    test('summary/topic/intent fromJson factories parse their payloads', () {
      // TextSummary: `summary` wins over the `text` alias.
      final summary = TextSummary.fromJson(<String, dynamic>{
        'summary': 'First.',
        'text': 'Alias.',
        'start_word': 1,
        'end_word': 6,
      });
      expect(summary.summary, 'First.');
      expect(summary.startWord, 1);
      expect(summary.endWord, 6);

      final summaryAlias = TextSummary.fromJson(<String, dynamic>{
        'text': 'Alias only.',
      });
      expect(summaryAlias.summary, 'Alias only.');
      expect(summaryAlias.startWord, isNull);

      // TextTopic.
      final topic = TextTopic.fromJson(<String, dynamic>{
        'topic': 'Travel',
        'confidence_score': 0.9,
        'start_word': 0,
        'end_word': 2,
      });
      expect(topic.topic, 'Travel');
      expect(topic.confidenceScore, 0.9);
      expect(topic.startWord, 0);
      expect(topic.endWord, 2);

      final topicMissing = TextTopic.fromJson(<String, dynamic>{});
      expect(topicMissing.topic, '');
      expect(topicMissing.confidenceScore, isNull);

      // TextIntent.
      final intent = TextIntent.fromJson(<String, dynamic>{
        'intent': 'book_flight',
        'confidence_score': 0.75,
        'start_word': 0,
        'end_word': 2,
      });
      expect(intent.intent, 'book_flight');
      expect(intent.confidenceScore, 0.75);
      expect(intent.startWord, 0);
      expect(intent.endWord, 2);

      final intentMissing = TextIntent.fromJson(<String, dynamic>{});
      expect(intentMissing.intent, '');
      expect(intentMissing.confidenceScore, isNull);
    });

    test('model value classes expose documented defaults', () {
      const TextSentiment sentiment = TextSentiment();
      expect(sentiment.text, '');
      expect(sentiment.sentiment, '');
      expect(sentiment.sentimentScore, isNull);
      expect(sentiment.startWord, isNull);
      expect(sentiment.endWord, isNull);

      const TextSummary summary = TextSummary();
      expect(summary.summary, '');
      expect(summary.startWord, isNull);
      expect(summary.endWord, isNull);

      const TextTopic topic = TextTopic();
      expect(topic.topic, '');
      expect(topic.confidenceScore, isNull);

      const TextIntent intent = TextIntent();
      expect(intent.intent, '');
      expect(intent.confidenceScore, isNull);

      const TextModelUsageInfo usage = TextModelUsageInfo();
      expect(usage.modelUuid, isNull);
      expect(usage.inputTokens, isNull);
      expect(usage.outputTokens, isNull);

      const TextIntelligenceMetadata metadata = TextIntelligenceMetadata();
      expect(metadata.requestId, isNull);
      expect(metadata.created, isNull);
      expect(metadata.language, isNull);
      expect(metadata.summaryInfo, isNull);
      expect(metadata.modelInfo, isNull);
      expect(metadata.models, isNull);
    });

    test('TextModelUsageInfo.fromJson parses token accounting', () {
      final info = TextModelUsageInfo.fromJson(<String, dynamic>{
        'model_uuid': 'uuid-x',
        'input_tokens': 10,
        'output_tokens': '20', // numeric string coerced
      });
      expect(info.modelUuid, 'uuid-x');
      expect(info.inputTokens, 10);
      expect(info.outputTokens, 20);
    });
  });

  group('TextIntelligenceClient errors', () {
    test('401 maps to DeepgramAuthException without retrying', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{
        'err_msg': 'Invalid credentials.',
        'request_id': 'req-401',
        'err_code': 'AUTH_FAIL',
      }, status: 401);

      await expectLater(
        client.analyze('text'),
        throwsA(
          isA<DeepgramAuthException>()
              .having((e) => e.message, 'message', 'Invalid credentials.')
              .having((e) => e.requestId, 'requestId', 'req-401')
              .having((e) => e.code, 'code', 'AUTH_FAIL'),
        ),
      );
      expect(queue.requests, hasLength(1));
    });

    test(
      '404 maps to DeepgramNotFoundException with header request id',
      () async {
        final queue = QueueHttpClient();
        final client = _client(queue);
        queue.enqueueJson(
          '',
          status: 404,
          headers: <String, String>{'x-request-id': 'hdr-404'},
        );

        await expectLater(
          client.analyze('text'),
          throwsA(
            isA<DeepgramNotFoundException>()
                .having((e) => e.message, 'message', 'HTTP 404.')
                .having((e) => e.requestId, 'requestId', 'hdr-404'),
          ),
        );
      },
    );

    test('429 retries and then maps to DeepgramRateLimitException', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(
        <String, dynamic>{'err_msg': 'Rate limited.'},
        status: 429,
        headers: <String, String>{'retry-after': '0.01'},
      );
      queue.enqueueJson(
        <String, dynamic>{'err_msg': 'Rate limited.'},
        status: 429,
        headers: <String, String>{'retry-after': '0.01'},
      );
      queue.enqueueJson(
        <String, dynamic>{'err_msg': 'Rate limited.'},
        status: 429,
        headers: <String, String>{'retry-after': '0.01'},
      );

      await expectLater(
        client.analyze('text'),
        throwsA(
          isA<DeepgramRateLimitException>()
              .having((e) => e.message, 'message', 'Rate limited.')
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(milliseconds: 10),
              ),
        ),
      );
      // 1 attempt + maxRetries (2) more.
      expect(queue.requests, hasLength(3));
    });

    test('a single 429 is retried transparently to success', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(
        <String, dynamic>{'err_msg': 'Rate limited.'},
        status: 429,
        headers: <String, String>{'retry-after': '0.01'},
      );
      queue.enqueueJson(currentShapeResponse);

      final result = await client.analyze('text');
      expect(queue.requests, hasLength(2));
      expect(result.metadata.requestId, 'req-1');
    });

    test('500 retries then maps to DeepgramServerException', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      for (var i = 0; i < 3; i++) {
        queue.enqueueJson(<String, dynamic>{
          'err_msg': 'Server exploded.',
        }, status: 500);
      }

      await expectLater(
        client.analyze('text'),
        throwsA(
          isA<DeepgramServerException>().having(
            (e) => e.message,
            'message',
            'Server exploded.',
          ),
        ),
      );
      expect(queue.requests, hasLength(3));
    });

    test('500 then 200 recovers', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson('boom', status: 500);
      queue.enqueueJson(currentShapeResponse);

      final result = await client.analyze('text');
      expect(queue.requests, hasLength(2));
      expect(result.sentiments, isNotEmpty);
    });

    test(
      'transport failure retries then maps to DeepgramNetworkException',
      () async {
        final queue = QueueHttpClient();
        final client = _client(queue);
        final cause = http.ClientException('boom');
        queue.enqueueError(cause);
        queue.enqueueError(cause);
        queue.enqueueError(cause);

        await expectLater(
          client.analyze('text'),
          throwsA(
            isA<DeepgramNetworkException>().having(
              (e) => e.cause,
              'cause',
              same(cause),
            ),
          ),
        );
        expect(queue.requests, hasLength(3));
      },
    );
  });

  group('TextIntelligenceClient cancellation', () {
    test('a pre-cancelled token rejects before any request is made', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      final token = HttpCancelToken()..cancel('nope');

      await expectLater(
        client.analyze('text', cancelToken: token),
        throwsA(
          isA<DeepgramException>().having(
            (e) => e.message,
            'message',
            'Request cancelled: nope',
          ),
        ),
      );
      expect(queue.requests, isEmpty);
    });

    test('cancelling during a 429 backoff aborts the wait', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(
        <String, dynamic>{'err_msg': 'Rate limited.'},
        status: 429,
        headers: <String, String>{'retry-after': '30'},
      );

      final token = HttpCancelToken();
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 20),
          () => token.cancel('enough'),
        ),
      );

      await expectLater(
        client.analyze('text', cancelToken: token),
        throwsA(
          isA<DeepgramException>().having(
            (e) => e.message,
            'message',
            'Request cancelled: enough',
          ),
        ),
      );
      // The first (and only) attempt was made; the 30s backoff never ran.
      expect(queue.requests, hasLength(1));
    });
  });
}
