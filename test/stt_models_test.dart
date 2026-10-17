/// Unit tests for the shared speech-to-text result models
/// (`lib/src/listen/stt_models.dart`).
///
/// Every model's defensive `fromJson` factory is exercised with:
///
/// * real Deepgram response shapes taken from the pre-recorded API
///   reference (`research/speech-to-text_listen-pre-recorded.md`),
/// * minimal payloads with missing or null optional fields, and
/// * malformed values that must fall back to neutral defaults instead of
///   throwing.
library;

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:test/test.dart';

void main() {
  group('SttWord', () {
    test('parses a fully populated word', () {
      final word = SttWord.fromJson(const <String, dynamic>{
        'word': 'yeah',
        'start': 0.08,
        'end': 0.32,
        'confidence': 0.9975586,
        'punctuated_word': 'Yeah,',
        'speaker': 0,
        'language': 'en',
      });
      expect(word.word, 'yeah');
      expect(word.start, 0.08);
      expect(word.end, 0.32);
      expect(word.confidence, 0.9975586);
      expect(word.punctuatedWord, 'Yeah,');
      expect(word.speaker, 0);
      expect(word.language, 'en');
    });

    test('falls back to defaults when fields are missing', () {
      final word = SttWord.fromJson(const <String, dynamic>{});
      expect(word.word, '');
      expect(word.start, isNull);
      expect(word.end, isNull);
      expect(word.confidence, isNull);
      expect(word.punctuatedWord, isNull);
      expect(word.speaker, isNull);
      expect(word.language, isNull);
    });

    test('ignores malformed types instead of throwing', () {
      final word = SttWord.fromJson(const <String, dynamic>{
        'word': 42,
        'start': '0.08',
        'end': null,
        'confidence': 'high',
        'punctuated_word': 7,
        'speaker': '0',
        'language': true,
      });
      expect(word.word, '');
      expect(word.start, isNull);
      expect(word.end, isNull);
      expect(word.confidence, isNull);
      expect(word.punctuatedWord, isNull);
      expect(word.speaker, isNull);
      expect(word.language, isNull);
    });
  });

  group('SttSummary', () {
    test('parses a v2 summary segment', () {
      final summary = SttSummary.fromJson(const <String, dynamic>{
        'summary': 'The caller wants to book a flight.',
        'start_word': 0,
        'end_word': 12,
      });
      expect(summary.summary, 'The caller wants to book a flight.');
      expect(summary.startWord, 0);
      expect(summary.endWord, 12);
    });

    test('falls back to defaults on empty or malformed input', () {
      final summary = SttSummary.fromJson(
        const <String, dynamic>{
          'summary': 42,
          'start_word': 'a',
          'end_word': <int>[],
        },
      );
      expect(summary.summary, '');
      expect(summary.startWord, isNull);
      expect(summary.endWord, isNull);
    });
  });

  group('SttSentiment', () {
    test('parses a sentiment segment', () {
      final sentiment = SttSentiment.fromJson(const <String, dynamic>{
        'text': 'I love this product.',
        'sentiment': 'positive',
        'sentiment_score': 0.62,
        'start_word': 0,
        'end_word': 4,
      });
      expect(sentiment.text, 'I love this product.');
      expect(sentiment.sentiment, 'positive');
      expect(sentiment.sentimentScore, 0.62);
      expect(sentiment.startWord, 0);
      expect(sentiment.endWord, 4);
    });

    test('falls back to defaults on empty input', () {
      final sentiment = SttSentiment.fromJson(const <String, dynamic>{});
      expect(sentiment.text, '');
      expect(sentiment.sentiment, '');
      expect(sentiment.sentimentScore, isNull);
      expect(sentiment.startWord, isNull);
      expect(sentiment.endWord, isNull);
    });
  });

  group('SttTopic', () {
    test('parses a plain string topic', () {
      final topic = SttTopic.fromJson(const <String, dynamic>{
        'topics': 'Travel',
        'text': 'We went to Paris.',
        'start_word': 0,
        'end_word': 4,
      });
      expect(topic.topics, 'Travel');
      expect(topic.text, 'We went to Paris.');
      expect(topic.startWord, 0);
      expect(topic.endWord, 4);
    });

    test('joins a list of string topics', () {
      final topic = SttTopic.fromJson(const <String, dynamic>{
        'topics': <String>['Travel', 'Food'],
        'text': 'We ate in Paris.',
      });
      expect(topic.topics, 'Travel, Food');
    });

    test('reads topic labels from {topic, confidence_score} objects', () {
      final topic = SttTopic.fromJson(const <String, dynamic>{
        'topics': <Map<String, dynamic>>[
          <String, dynamic>{'topic': 'Travel', 'confidence_score': 0.91},
          <String, dynamic>{'topic': 'Food'},
        ],
        'text': 'We ate in Paris.',
      });
      expect(topic.topics, 'Travel, Food');
    });

    test('skips unusable topic values and defaults to empty text', () {
      final malformed = SttTopic.fromJson(
        const <String, dynamic>{'topics': 42, 'text': 9, 'start_word': 'x'},
      );
      expect(malformed.topics, '');
      expect(malformed.text, '');
      expect(malformed.startWord, isNull);

      final mixed = SttTopic.fromJson(const <String, dynamic>{
        'topics': <dynamic>[
          'Travel',
          42,
          <String, dynamic>{'topic': 'Food'}
        ],
      });
      expect(mixed.topics, 'Travel, Food');

      final missing = SttTopic.fromJson(const <String, dynamic>{});
      expect(missing.topics, '');
      expect(missing.text, '');
    });
  });

  group('SttIntent', () {
    test('parses a primary intent with confidence', () {
      final intent = SttIntent.fromJson(const <String, dynamic>{
        'intent': 'book_flight',
        'confidence_score': 0.92,
        'text': 'I need a flight to Toronto.',
        'start_word': 0,
        'end_word': 5,
      });
      expect(intent.intent, 'book_flight');
      expect(intent.confidence, 0.92);
      expect(intent.text, 'I need a flight to Toronto.');
      expect(intent.startWord, 0);
      expect(intent.endWord, 5);
    });

    test('falls back to the first intents list entry', () {
      final intent = SttIntent.fromJson(const <String, dynamic>{
        'intents': <Map<String, dynamic>>[
          <String, dynamic>{'intent': 'ask_question', 'confidence_score': 0.81},
          <String, dynamic>{'intent': 'other', 'confidence_score': 0.2},
        ],
        'text': 'What time is it?',
      });
      expect(intent.intent, 'ask_question');
      expect(intent.confidence, 0.81);
      expect(intent.text, 'What time is it?');
    });

    test('fills only the missing half from the intents list', () {
      final intent = SttIntent.fromJson(const <String, dynamic>{
        'intent': 'primary',
        'intents': <Map<String, dynamic>>[
          <String, dynamic>{'intent': 'from-list', 'confidence_score': 0.4},
        ],
      });
      expect(intent.intent, 'primary');
      expect(intent.confidence, 0.4);
    });

    test('tolerates non-object intents entries and empty input', () {
      final nonMap = SttIntent.fromJson(const <String, dynamic>{
        'intents': <dynamic>[42, 'nope'],
      });
      expect(nonMap.intent, isNull);
      expect(nonMap.confidence, isNull);

      final empty = SttIntent.fromJson(const <String, dynamic>{});
      expect(empty.intent, isNull);
      expect(empty.confidence, isNull);
      expect(empty.text, isNull);
      expect(empty.startWord, isNull);
      expect(empty.endWord, isNull);
    });
  });

  group('SttEntity', () {
    test('parses a detected entity', () {
      final entity = SttEntity.fromJson(const <String, dynamic>{
        'label': 'LOCATION',
        'value': 'Toronto',
        'raw_value': 'toronto',
        'confidence': 0.98,
        'start_word': 3,
        'end_word': 3,
      });
      expect(entity.label, 'LOCATION');
      expect(entity.value, 'Toronto');
      expect(entity.confidence, 0.98);
      expect(entity.startWord, 3);
      expect(entity.endWord, 3);
    });

    test('falls back to defaults on empty or malformed input', () {
      final entity = SttEntity.fromJson(const <String, dynamic>{
        'label': 1,
        'value': 2,
        'confidence': 'x',
      });
      expect(entity.label, '');
      expect(entity.value, '');
      expect(entity.confidence, isNull);
      expect(entity.startWord, isNull);
      expect(entity.endWord, isNull);
    });
  });

  group('SttHit', () {
    test('parses a search hit from snippet', () {
      final hit = SttHit.fromJson(const <String, dynamic>{
        'snippet': 'toronto',
        'start': 0.42,
        'end': 0.56,
        'confidence': 0.99,
      });
      expect(hit.text, 'toronto');
      expect(hit.start, 0.42);
      expect(hit.end, 0.56);
      expect(hit.confidence, 0.99);
    });

    test('accepts text as an alias for snippet', () {
      final hit = SttHit.fromJson(
        const <String, dynamic>{'text': 'weather', 'start': 1.0, 'end': 1.4},
      );
      expect(hit.text, 'weather');
      expect(hit.start, 1.0);
      expect(hit.end, 1.4);
    });

    test('defaults to empty text and zero offsets', () {
      final hit = SttHit.fromJson(const <String, dynamic>{});
      expect(hit.text, '');
      expect(hit.start, 0.0);
      expect(hit.end, 0.0);
      expect(hit.confidence, isNull);
    });
  });

  group('SttTranslation', () {
    test('parses a translation', () {
      final translation = SttTranslation.fromJson(const <String, dynamic>{
        'language': 'es',
        'translation': 'Sí, hasta donde sea necesario.',
      });
      expect(translation.language, 'es');
      expect(translation.translation, 'Sí, hasta donde sea necesario.');
    });

    test('falls back to defaults on malformed input', () {
      final translation = SttTranslation.fromJson(
        const <String, dynamic>{'language': 1, 'translation': 2},
      );
      expect(translation.language, '');
      expect(translation.translation, '');
    });
  });

  group('SttSentence', () {
    test('parses a sentence', () {
      final sentence = SttSentence.fromJson(const <String, dynamic>{
        'text': 'Sentence one.',
        'start': 0.08,
        'end': 1.2,
      });
      expect(sentence.text, 'Sentence one.');
      expect(sentence.start, 0.08);
      expect(sentence.end, 1.2);
    });

    test('falls back to defaults on empty input', () {
      final sentence = SttSentence.fromJson(const <String, dynamic>{});
      expect(sentence.text, '');
      expect(sentence.start, 0.0);
      expect(sentence.end, 0.0);
    });
  });

  group('SttParagraph', () {
    test('parses a paragraph with sentences', () {
      final paragraph = SttParagraph.fromJson(const <String, dynamic>{
        'sentences': <Map<String, dynamic>>[
          <String, dynamic>{'text': 'One.', 'start': 0.0, 'end': 1.0},
          <String, dynamic>{'text': 'Two.', 'start': 1.0, 'end': 2.0},
        ],
        'num_words': 10,
        'start': 0.0,
        'end': 2.0,
      });
      expect(paragraph.numWords, 10);
      expect(paragraph.start, 0.0);
      expect(paragraph.end, 2.0);
      expect(
        paragraph.sentences.map((s) => s.text).toList(),
        <String>['One.', 'Two.'],
      );
    });

    test('skips non-object sentences and defaults offsets', () {
      final paragraph = SttParagraph.fromJson(const <String, dynamic>{
        'sentences': <dynamic>[
          'skip-me',
          <String, dynamic>{'text': 'Kept.'}
        ],
      });
      expect(paragraph.sentences, hasLength(1));
      expect(paragraph.sentences.single.text, 'Kept.');
      expect(paragraph.numWords, 0);
      expect(paragraph.start, 0.0);
      expect(paragraph.end, 0.0);

      final empty = SttParagraph.fromJson(const <String, dynamic>{});
      expect(empty.sentences, isEmpty);
    });
  });

  group('SttAlternative', () {
    test('parses a full alternative with every feature', () {
      final alternative = SttAlternative.fromJson(const <String, dynamic>{
        'transcript': 'Yeah, as as much as, it is worth having a talk.',
        'confidence': 0.9840088,
        'words': <Map<String, dynamic>>[
          <String, dynamic>{
            'word': 'yeah',
            'start': 0.08,
            'end': 0.32,
            'confidence': 0.9975586,
            'punctuated_word': 'Yeah,',
            'speaker': 0,
          },
          <String, dynamic>{'word': 'as', 'start': 0.32, 'end': 0.48},
        ],
        'paragraphs': <String, dynamic>{
          'transcript': 'Yeah, as as much as...',
          'paragraphs': <Map<String, dynamic>>[
            <String, dynamic>{
              'sentences': <Map<String, dynamic>>[
                <String, dynamic>{'text': 'Yeah.', 'start': 0.08, 'end': 1.0},
              ],
              'num_words': 10,
              'start': 0.08,
              'end': 1.0,
            },
          ],
        },
        'summaries': <Map<String, dynamic>>[
          <String, dynamic>{
            'summary': 'Neighbors talk.',
            'start_word': 0,
            'end_word': 10
          },
        ],
        'sentiments': <Map<String, dynamic>>[
          <String, dynamic>{
            'text': 'Yeah...',
            'sentiment': 'positive',
            'sentiment_score': 0.62,
          },
        ],
        'topics': <Map<String, dynamic>>[
          <String, dynamic>{'topics': 'Travel', 'text': 'Yeah...'},
        ],
        'intents': <Map<String, dynamic>>[
          <String, dynamic>{'intent': 'book_flight', 'confidence_score': 0.92},
        ],
        'entities': <Map<String, dynamic>>[
          <String, dynamic>{'label': 'LOCATION', 'value': 'Toronto'},
        ],
        'translations': <Map<String, dynamic>>[
          <String, dynamic>{'language': 'es', 'translation': 'Sí.'},
        ],
      });
      expect(alternative.transcript,
          'Yeah, as as much as, it is worth having a talk.');
      expect(alternative.confidence, 0.9840088);
      expect(alternative.words, hasLength(2));
      expect(alternative.words.first.punctuatedWord, 'Yeah,');
      expect(alternative.words.first.speaker, 0);
      expect(alternative.paragraphs?.single.numWords, 10);
      expect(alternative.summaries?.single.summary, 'Neighbors talk.');
      expect(alternative.sentiments?.single.sentiment, 'positive');
      expect(alternative.topics?.single.topics, 'Travel');
      expect(alternative.intents?.single.intent, 'book_flight');
      expect(alternative.entities?.single.value, 'Toronto');
      expect(alternative.translations?.single.language, 'es');
    });

    test('minimal alternative yields empty words and null features', () {
      final alternative = SttAlternative.fromJson(const <String, dynamic>{});
      expect(alternative.transcript, '');
      expect(alternative.confidence, isNull);
      expect(alternative.words, isEmpty);
      expect(alternative.paragraphs, isNull);
      expect(alternative.summaries, isNull);
      expect(alternative.sentiments, isNull);
      expect(alternative.topics, isNull);
      expect(alternative.intents, isNull);
      expect(alternative.entities, isNull);
      expect(alternative.translations, isNull);
    });

    test('parses bare-list paragraphs and single-object feature payloads', () {
      final alternative = SttAlternative.fromJson(const <String, dynamic>{
        'paragraphs': <Map<String, dynamic>>[
          <String, dynamic>{'num_words': 3, 'start': 0.0, 'end': 1.0},
        ],
        'summaries': <String, dynamic>{'summary': 'One summary.'},
        'sentiments': <String, dynamic>{'text': 'T', 'sentiment': 'neutral'},
        'intents': <String, dynamic>{'intent': 'i'},
        'words': <dynamic>[
          'skip',
          <String, dynamic>{'word': 'kept'}
        ],
      });
      // Bare list under `paragraphs` (no wrapper object) is tolerated.
      expect(alternative.paragraphs?.single.numWords, 3);
      // Single objects are promoted to one-entry lists.
      expect(alternative.summaries?.single.summary, 'One summary.');
      expect(alternative.sentiments?.single.sentiment, 'neutral');
      expect(alternative.intents?.single.intent, 'i');
      // Non-object word entries are skipped.
      expect(alternative.words.single.word, 'kept');
    });

    test('wrapper paragraphs object without a paragraphs key yields null', () {
      final alternative = SttAlternative.fromJson(const <String, dynamic>{
        'paragraphs': <String, dynamic>{'transcript': 'no paragraph list'},
      });
      expect(alternative.paragraphs, isNull);
    });
  });

  group('SttChannel', () {
    test('parses detected_language and language_code with alternatives', () {
      final channel = SttChannel.fromJson(const <String, dynamic>{
        'detected_language': 'en',
        'language_code': 'en-US',
        'alternatives': <Map<String, dynamic>>[
          <String, dynamic>{'transcript': 'First hypothesis.'},
          <String, dynamic>{
            'transcript': 'Second hypothesis.',
            'confidence': 0.7
          },
        ],
      });
      expect(channel.detectedLanguage, 'en');
      expect(channel.languageCode, 'en-US');
      expect(channel.alternatives, hasLength(2));
      expect(channel.alternatives.first.transcript, 'First hypothesis.');
      expect(channel.alternatives.last.confidence, 0.7);
    });

    test('minimal channel yields an empty alternatives list', () {
      final channel = SttChannel.fromJson(const <String, dynamic>{});
      expect(channel.alternatives, isEmpty);
      expect(channel.detectedLanguage, isNull);
      expect(channel.languageCode, isNull);
    });

    test('skips non-object alternatives entries', () {
      final channel = SttChannel.fromJson(const <String, dynamic>{
        'alternatives': <dynamic>[
          42,
          'nope',
          <String, dynamic>{'transcript': 'kept'}
        ],
      });
      expect(channel.alternatives, hasLength(1));
      expect(channel.alternatives.single.transcript, 'kept');

      final notAList = SttChannel.fromJson(
        const <String, dynamic>{'alternatives': 'none'},
      );
      expect(notAList.alternatives, isEmpty);
    });
  });

  group('SttModelInfo', () {
    test('parses name, version and arch', () {
      final info = SttModelInfo.fromJson(const <String, dynamic>{
        'name': '2-general-nova',
        'version': '2024-01-09.29447',
        'arch': 'nova-2',
      });
      expect(info.name, '2-general-nova');
      expect(info.version, '2024-01-09.29447');
      expect(info.arch, 'nova-2');
    });

    test('falls back to nulls on empty input', () {
      final info = SttModelInfo.fromJson(const <String, dynamic>{});
      expect(info.name, isNull);
      expect(info.version, isNull);
      expect(info.arch, isNull);
    });
  });

  group('SttDiarizeInfo', () {
    test('parses the diarizer description with speaker labels', () {
      final info = SttDiarizeInfo.fromJson(const <String, dynamic>{
        'model_uuid': '9a1c8b3e-2f44-4c8a-b1d0-example0000',
        'arch': 'v2',
        'hw': 'A100',
        'speaker_labels': <List<int>>[
          <int>[0, 0],
          <int>[1, 1],
        ],
      });
      expect(info.modelUuid, '9a1c8b3e-2f44-4c8a-b1d0-example0000');
      expect(info.arch, 'v2');
      expect(info.hw, 'A100');
      expect(info.speakerLabels, <List<int>>[
        <int>[0, 0],
        <int>[1, 1],
      ]);
    });

    test('skips malformed speaker label entries and elements', () {
      final info = SttDiarizeInfo.fromJson(const <String, dynamic>{
        'speaker_labels': <dynamic>[
          <int>[0, 0],
          'not-a-pair',
          <dynamic>['x', 1],
          <int>[],
        ],
      });
      expect(info.speakerLabels, <List<int>>[
        <int>[0, 0],
        <int>[1],
        <int>[],
      ]);
    });

    test('falls back to nulls on empty or non-list input', () {
      final empty = SttDiarizeInfo.fromJson(const <String, dynamic>{});
      expect(empty.modelUuid, isNull);
      expect(empty.arch, isNull);
      expect(empty.hw, isNull);
      expect(empty.speakerLabels, isNull);

      final notAList = SttDiarizeInfo.fromJson(
        const <String, dynamic>{'speaker_labels': 'nope'},
      );
      expect(notAList.speakerLabels, isNull);
    });
  });

  group('SttMetadata', () {
    test('parses every metadata field', () {
      final metadata = SttMetadata.fromJson(const <String, dynamic>{
        'request_id': 'a847f427-4ad5-4d67-9b95-db801e58251c',
        'transaction_key': 'legacy-key',
        'sha256':
            '154e291ecfa8be6ab8343560bcc109008fa7853eb5372533e8efdefc9b504c33',
        'created': '2024-05-12T18:57:13.426Z',
        'duration': 25.933313,
        'channels': 1,
        'model_uuid': '30089e05-99d1-4376-b32e-c263170674af',
        'models': <String>['30089e05-99d1-4376-b32e-c263170674af'],
        'additional_model_uuids': <dynamic>['sum-uuid', 42, 'sent-uuid'],
        'model_info': <String, dynamic>{
          '30089e05-99d1-4376-b32e-c263170674af': <String, dynamic>{
            'name': '2-general-nova',
            'version': '2024-01-09.29447',
            'arch': 'nova-2',
          },
        },
        'diarize_info': <String, dynamic>{
          'model_uuid': '9a1c8b3e-2f44-4c8a-b1d0-example0000',
          'arch': 'v2',
        },
        'extra': <String, dynamic>{'CustomerID': '12345'},
      });
      expect(metadata.requestId, 'a847f427-4ad5-4d67-9b95-db801e58251c');
      expect(metadata.transactionKey, 'legacy-key');
      expect(metadata.sha256, startsWith('154e'));
      expect(metadata.created, '2024-05-12T18:57:13.426Z');
      expect(metadata.duration, 25.933313);
      expect(metadata.channels, 1);
      expect(metadata.modelUuid, '30089e05-99d1-4376-b32e-c263170674af');
      expect(metadata.models, <String>['30089e05-99d1-4376-b32e-c263170674af']);
      // Non-string model UUID entries are skipped.
      expect(metadata.additionalModelUuids, <String>['sum-uuid', 'sent-uuid']);
      expect(metadata.modelInfo?.name, '2-general-nova');
      expect(metadata.modelInfo?.arch, 'nova-2');
      expect(metadata.diarizeInfo?.modelUuid,
          '9a1c8b3e-2f44-4c8a-b1d0-example0000');
      expect(metadata.diarizeInfo?.arch, 'v2');
      expect(metadata.extra, containsPair('CustomerID', '12345'));
    });

    test('minimal metadata yields nulls', () {
      final metadata = SttMetadata.fromJson(const <String, dynamic>{});
      expect(metadata.requestId, isNull);
      expect(metadata.transactionKey, isNull);
      expect(metadata.sha256, isNull);
      expect(metadata.created, isNull);
      expect(metadata.duration, isNull);
      expect(metadata.channels, isNull);
      expect(metadata.modelInfo, isNull);
      expect(metadata.models, isNull);
      expect(metadata.modelUuid, isNull);
      expect(metadata.diarizeInfo, isNull);
      expect(metadata.additionalModelUuids, isNull);
      expect(metadata.extra, isNull);
    });

    test('model_info accepts a direct {name, version, arch} object', () {
      final metadata = SttMetadata.fromJson(const <String, dynamic>{
        'model_info': <String, dynamic>{
          'name': 'direct-model',
          'version': '1.2.3',
          'arch': 'nova-3',
        },
      });
      expect(metadata.modelInfo?.name, 'direct-model');
      expect(metadata.modelInfo?.version, '1.2.3');
      expect(metadata.modelInfo?.arch, 'nova-3');
    });

    test('model_info skips unusable entries and yields null when empty', () {
      // Inner values that are not maps, and an outer map with no direct
      // name/version/arch keys, produce null.
      final metadata = SttMetadata.fromJson(const <String, dynamic>{
        'model_info': <String, dynamic>{'uuid-1': 'not-a-map'},
      });
      expect(metadata.modelInfo, isNull);

      final nonMap = SttMetadata.fromJson(
        const <String, dynamic>{'model_info': 42},
      );
      expect(nonMap.modelInfo, isNull);
    });

    test('model_info keyed by uuid picks the first usable entry', () {
      final metadata = SttMetadata.fromJson(const <String, dynamic>{
        'model_info': <String, dynamic>{
          'uuid-empty': <String, dynamic>{},
          'uuid-usable': <String, dynamic>{'name': 'second-entry'},
        },
      });
      expect(metadata.modelInfo?.name, 'second-entry');
    });

    test('coerces dynamically keyed maps for metadata and extra', () {
      final result = PrerecordedTranscriptionResult.fromJson(
        const <String, dynamic>{
          'metadata': <dynamic, dynamic>{'request_id': 'dyn-1'},
        },
      );
      expect(result.requestId, 'dyn-1');

      final metadata = SttMetadata.fromJson(const <String, dynamic>{
        'extra': <dynamic, dynamic>{42: 'answer'},
      });
      expect(metadata.extra, containsPair('42', 'answer'));
    });

    test('non-map diarize_info is ignored', () {
      final metadata = SttMetadata.fromJson(
        const <String, dynamic>{'diarize_info': 'nope'},
      );
      expect(metadata.diarizeInfo, isNull);
    });
  });

  group('SttUtterance', () {
    test('parses a fully populated utterance', () {
      final utterance = SttUtterance.fromJson(const <String, dynamic>{
        'start': 0.0,
        'end': 2.4,
        'confidence': 0.97,
        'transcript': 'Hello there.',
        'words': <Map<String, dynamic>>[
          <String, dynamic>{'word': 'Hello', 'start': 0.0, 'end': 0.4},
        ],
        'speaker': 1,
        'id': 'utt-1',
        'channel': 0,
        'summaries': <String, dynamic>{'summary': 'Greeting.'},
        'sentiments': <Map<String, dynamic>>[
          <String, dynamic>{'text': 'Hello there.', 'sentiment': 'neutral'},
        ],
        'topics': <String, dynamic>{'topics': 'Sports', 'text': 'Hello there.'},
        'intents': <Map<String, dynamic>>[
          <String, dynamic>{'intent': 'greet', 'confidence_score': 0.9},
        ],
        'entities': <Map<String, dynamic>>[
          <String, dynamic>{'label': 'PERSON', 'value': 'There'},
        ],
        'translations': <Map<String, dynamic>>[
          <String, dynamic>{'language': 'de', 'translation': 'Hallo.'},
        ],
        'detector': 'energy_vad',
      });
      expect(utterance.start, 0.0);
      expect(utterance.end, 2.4);
      expect(utterance.confidence, 0.97);
      expect(utterance.transcript, 'Hello there.');
      expect(utterance.words.single.word, 'Hello');
      expect(utterance.speaker, 1);
      expect(utterance.id, 'utt-1');
      expect(utterance.channel, 0);
      expect(utterance.summaries?.single.summary, 'Greeting.');
      expect(utterance.sentiments?.single.sentiment, 'neutral');
      expect(utterance.topics?.single.topics, 'Sports');
      expect(utterance.intents?.single.intent, 'greet');
      expect(utterance.entities?.single.value, 'There');
      expect(utterance.translations?.single.language, 'de');
      expect(utterance.detector, 'energy_vad');
    });

    test('falls back to the singular sentiment payload', () {
      final object = SttUtterance.fromJson(const <String, dynamic>{
        'transcript': 'Hi.',
        'sentiment': <String, dynamic>{
          'text': 'Hi.',
          'sentiment': 'negative',
          'sentiment_score': -0.45,
        },
      });
      expect(object.sentiments?.single.sentiment, 'negative');
      expect(object.sentiments?.single.sentimentScore, -0.45);

      final list = SttUtterance.fromJson(const <String, dynamic>{
        'transcript': 'Hi.',
        'sentiment': <Map<String, dynamic>>[
          <String, dynamic>{'text': 'Hi.', 'sentiment': 'positive'},
        ],
      });
      expect(list.sentiments?.single.sentiment, 'positive');
    });

    test('prefers the plural sentiments payload over the singular one', () {
      final utterance = SttUtterance.fromJson(const <String, dynamic>{
        'sentiments': <Map<String, dynamic>>[
          <String, dynamic>{'text': 'plural', 'sentiment': 'neutral'},
        ],
        'sentiment': <String, dynamic>{
          'text': 'singular',
          'sentiment': 'positive'
        },
      });
      expect(utterance.sentiments?.single.text, 'plural');
    });

    test('minimal utterance yields defaults', () {
      final utterance = SttUtterance.fromJson(const <String, dynamic>{});
      expect(utterance.transcript, '');
      expect(utterance.words, isEmpty);
      expect(utterance.start, isNull);
      expect(utterance.end, isNull);
      expect(utterance.confidence, isNull);
      expect(utterance.speaker, isNull);
      expect(utterance.id, isNull);
      expect(utterance.channel, isNull);
      expect(utterance.summaries, isNull);
      expect(utterance.sentiments, isNull);
      expect(utterance.topics, isNull);
      expect(utterance.intents, isNull);
      expect(utterance.entities, isNull);
      expect(utterance.translations, isNull);
      expect(utterance.detector, isNull);
    });
  });

  group('PrerecordedTranscriptionResult', () {
    test('parses a complete results payload', () {
      final result = PrerecordedTranscriptionResult.fromJson(
        const <String, dynamic>{
          'metadata': <String, dynamic>{
            'request_id': 'req-0001',
            'created': '2024-05-12T18:57:13.426Z',
            'duration': 25.933313,
            'channels': 1,
            'model_info': <String, dynamic>{
              '30089e05-99d1-4376-b32e-c263170674af': <String, dynamic>{
                'name': '2-general-nova',
                'version': '2024-01-09.29447',
                'arch': 'nova-2',
              },
            },
          },
          'results': <String, dynamic>{
            'channels': <Map<String, dynamic>>[
              <String, dynamic>{
                'detected_language': 'en',
                'alternatives': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'transcript': 'Yeah, as as much as, it is worth a talk.',
                    'confidence': 0.98,
                  },
                ],
              },
            ],
            'utterances': <Map<String, dynamic>>[
              <String, dynamic>{
                'transcript': 'Utterance text.',
                'speaker': 0,
                'sentiment': <String, dynamic>{
                  'text': 'Utterance text.',
                  'sentiment': 'negative',
                  'sentiment_score': -0.45,
                },
              },
            ],
            'summary': <String, dynamic>{
              'text': 'text summary',
              'short': 'short summary',
              'result': 'result summary',
            },
            'summaries': <Map<String, dynamic>>[
              <String, dynamic>{'summary': 'results summary', 'start_word': 0},
            ],
            'sentiments': <String, dynamic>{
              'segments': <Map<String, dynamic>>[
                <String, dynamic>{
                  'text': 'Yeah...',
                  'sentiment': 'positive',
                  'sentiment_score': 0.5,
                },
              ],
            },
            'topics': <String, dynamic>{
              'segments': <Map<String, dynamic>>[
                <String, dynamic>{
                  'topics': <String>['Travel'],
                  'text': 'Yeah...'
                },
              ],
            },
            'intents': <String, dynamic>{
              'segments': <Map<String, dynamic>>[
                <String, dynamic>{
                  'intents': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'intent': 'ask_question',
                      'confidence_score': 0.81
                    },
                  ],
                  'text': 'Yeah...',
                },
              ],
            },
            'translations': <String, dynamic>{'es': 'Hola.', 'fr': 42},
          },
        },
      );
      expect(result.requestId, 'req-0001');
      expect(result.metadata.duration, 25.933313);
      expect(result.metadata.modelInfo?.name, '2-general-nova');

      final channel = result.channels.single;
      expect(channel.detectedLanguage, 'en');
      expect(channel.alternatives.single.transcript,
          'Yeah, as as much as, it is worth a talk.');

      final utterance = result.utterances?.single;
      expect(utterance?.transcript, 'Utterance text.');
      expect(utterance?.sentiments?.single.sentiment, 'negative');

      // Summary object prefers text over short and result.
      expect(result.summary, 'text summary');
      expect(result.summaries?.single.summary, 'results summary');
      // Results-level feature payloads come wrapped in {segments: [...]}.
      expect(result.sentiments?.single.sentiment, 'positive');
      expect(result.topics?.single.topics, 'Travel');
      // The intent label is lifted from the first intents[] entry.
      expect(result.intents?.single.intent, 'ask_question');
      expect(result.intents?.single.confidence, 0.81);
      // Translations are keyed by language; non-string values are skipped.
      expect(result.translations, <String, String>{'es': 'Hola.'});
    });

    test('results-level segments tolerate bare objects and bare lists', () {
      final result = PrerecordedTranscriptionResult.fromJson(
        const <String, dynamic>{
          'metadata': <String, dynamic>{'request_id': 'r'},
          'results': <String, dynamic>{
            'sentiments': <String, dynamic>{
              'text': 'bare object',
              'sentiment': 'neutral'
            },
            'topics': <Map<String, dynamic>>[
              <String, dynamic>{'topics': 'Bare', 'text': 'list form'},
            ],
            'intents': <Map<String, dynamic>>[
              <String, dynamic>{
                'intent': 'direct-intent',
                'confidence_score': 0.5
              },
            ],
          },
        },
      );
      expect(result.sentiments?.single.text, 'bare object');
      expect(result.topics?.single.topics, 'Bare');
      expect(result.intents?.single.intent, 'direct-intent');
    });

    test('summary accepts a plain string, then short, then result', () {
      final plain =
          PrerecordedTranscriptionResult.fromJson(const <String, dynamic>{
        'metadata': <String, dynamic>{},
        'results': <String, dynamic>{'summary': 'Plain string summary.'},
      });
      expect(plain.summary, 'Plain string summary.');

      final shortOnly = PrerecordedTranscriptionResult.fromJson(
        const <String, dynamic>{
          'metadata': <String, dynamic>{},
          'results': <String, dynamic>{
            'summary': <String, dynamic>{
              'short': 'Short.',
              'result': 'Result.'
            },
          },
        },
      );
      expect(shortOnly.summary, 'Short.');

      final resultOnly = PrerecordedTranscriptionResult.fromJson(
        const <String, dynamic>{
          'metadata': <String, dynamic>{},
          'results': <String, dynamic>{
            'summary': <String, dynamic>{'result': 'Result.'},
          },
        },
      );
      expect(resultOnly.summary, 'Result.');

      final notTextual = PrerecordedTranscriptionResult.fromJson(
        const <String, dynamic>{
          'metadata': <String, dynamic>{},
          'results': <String, dynamic>{'summary': 42},
        },
      );
      expect(notTextual.summary, isNull);
    });

    test('translations map requires string values', () {
      final notAMap = PrerecordedTranscriptionResult.fromJson(
        const <String, dynamic>{
          'metadata': <String, dynamic>{},
          'results': <String, dynamic>{'translations': 'nope'},
        },
      );
      expect(notAMap.translations, isNull);

      final absent = PrerecordedTranscriptionResult.fromJson(
        const <String, dynamic>{
          'metadata': <String, dynamic>{},
          'results': <String, dynamic>{},
        },
      );
      expect(absent.translations, isNull);
    });

    test('lifts a top-level request_id into metadata (callback form)', () {
      final result = PrerecordedTranscriptionResult.fromJson(
        const <String, dynamic>{'request_id': 'cb-0001'},
      );
      expect(result.requestId, 'cb-0001');
      expect(result.metadata.requestId, 'cb-0001');
      expect(result.channels, isEmpty);
    });

    test('metadata request_id wins over the top-level one', () {
      final result = PrerecordedTranscriptionResult.fromJson(
        const <String, dynamic>{
          'request_id': 'top-level',
          'metadata': <String, dynamic>{'request_id': 'inner'},
        },
      );
      expect(result.requestId, 'inner');
    });

    test('non-string top-level request_id is not lifted', () {
      final result = PrerecordedTranscriptionResult.fromJson(
        const <String, dynamic>{'request_id': 42},
      );
      expect(result.requestId, isNull);
    });

    test('missing results yields empty channels and null features', () {
      final result = PrerecordedTranscriptionResult.fromJson(
        const <String, dynamic>{
          'metadata': <String, dynamic>{'request_id': 'only-meta'},
        },
      );
      expect(result.channels, isEmpty);
      expect(result.utterances, isNull);
      expect(result.summary, isNull);
      expect(result.summaries, isNull);
      expect(result.sentiments, isNull);
      expect(result.topics, isNull);
      expect(result.intents, isNull);
      expect(result.translations, isNull);

      final empty = PrerecordedTranscriptionResult.fromJson(
        const <String, dynamic>{},
      );
      expect(empty.requestId, isNull);
      expect(empty.channels, isEmpty);
    });
  });

  group('real Deepgram pre-recorded payload', () {
    // Verbatim from the pre-recorded API reference (remote file example).
    test('parses the documented spacewalk.wav response', () {
      final result = PrerecordedTranscriptionResult.fromJson(
        const <String, dynamic>{
          'metadata': <String, dynamic>{
            'channels': 1,
            'created': '2024-05-12T18:57:13.426Z',
            'diarize_info': <String, dynamic>{
              'arch': 'v2',
              'model_uuid': '9a1c8b3e-2f44-4c8a-b1d0-example0000',
            },
            'duration': 25.933313,
            'model_info': <String, dynamic>{
              '30089e05-99d1-4376-b32e-c263170674af': <String, dynamic>{
                'arch': 'nova-2',
                'name': '2-general-nova',
                'version': '2024-01-09.29447',
              },
            },
            'models': <String>['30089e05-99d1-4376-b32e-c263170674af'],
            'request_id': 'a847f427-4ad5-4d67-9b95-db801e58251c',
            'sha256':
                '154e291ecfa8be6ab8343560bcc109008fa7853eb5372533e8efdefc9b504c33',
          },
          'results': <String, dynamic>{
            'channels': <Map<String, dynamic>>[
              <String, dynamic>{
                'alternatives': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'confidence': 0.9840088,
                    'transcript':
                        "Yeah, as as much as, it's worth having a talk to the neighbors.",
                    'words': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'confidence': 0.9975586,
                        'end': 0.32,
                        'speaker': 0,
                        'speaker_confidence': 0.98,
                        'start': 0.08,
                        'word': 'yeah',
                      },
                      <String, dynamic>{
                        'confidence': 0.9862061,
                        'end': 0.48,
                        'speaker': 0,
                        'speaker_confidence': 0.98,
                        'start': 0.32,
                        'word': 'as',
                      },
                    ],
                  },
                ],
              },
            ],
          },
        },
      );
      expect(result.requestId, 'a847f427-4ad5-4d67-9b95-db801e58251c');
      expect(result.metadata.channels, 1);
      expect(result.metadata.duration, 25.933313);
      expect(result.metadata.modelInfo?.arch, 'nova-2');
      expect(result.metadata.diarizeInfo?.arch, 'v2');

      final alternative = result.channels.single.alternatives.single;
      expect(alternative.transcript,
          "Yeah, as as much as, it's worth having a talk to the neighbors.");
      expect(alternative.confidence, 0.9840088);
      expect(alternative.words, hasLength(2));
      expect(alternative.words.first.word, 'yeah');
      expect(alternative.words.first.start, 0.08);
      expect(alternative.words.first.end, 0.32);
      expect(alternative.words.first.speaker, 0);
      expect(alternative.words.last.word, 'as');
    });
  });
}
