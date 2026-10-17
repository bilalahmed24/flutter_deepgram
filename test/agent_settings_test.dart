/// Unit tests for `lib/src/agent/agent_settings.dart` — the typed `Settings`
/// message tree of the Voice Agent API
/// (`wss://agent.deepgram.com/v1/agent/converse`).
///
/// Every `toJson()` is asserted against the exact documented wire shape:
///
/// ```json
/// {
///   "type": "Settings",
///   "tags": [...],
///   "experimental": false,
///   "mip_opt_out": false,
///   "flags": {...},
///   "audio": {"input": {...}, "output": {...}},
///   "agent": {
///     "greeting": "...", "context": {...},
///     "listen": {"provider": {...}},
///     "think": {"provider": {...}, "prompt": "...", "functions": [...]},
///     "speak": {"provider": {...}},
///     "language": "..."
///   }
/// }
/// ```
///
/// Wire names pinned from the AsyncAPI + docs corpus: `sample_rate`,
/// `bitrate` (no underscore on the *output* block), `mip_opt_out`,
/// `defer_until_eot`, `smart_format`, `language_hints`, `eot_threshold`,
/// `eager_eot_threshold`, `eot_timeout_ms`, `reasoning_mode`,
/// `access_key_id`, `secret_access_key`, `session_token`,
/// `thought_signature`, and the server-side function `endpoint` object with
/// `authorization` merged into `endpoint.headers` (no `client_side` key in
/// the Settings message).
library;

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:test/test.dart';

void main() {
  group('VoiceAgentSettings.toJson', () {
    test('renders the documented defaults with only required blocks', () {
      const settings = VoiceAgentSettings(
        agent: AgentAgentSettings(),
        audio: AgentAudioSettings(input: AgentAudioInput()),
      );

      expect(settings.toJson(), <String, dynamic>{
        'type': 'Settings',
        'experimental': false,
        'mip_opt_out': false,
        'audio': <String, dynamic>{
          'input': <String, dynamic>{
            'encoding': 'linear16',
            'sample_rate': 24000,
          },
        },
        'agent': <String, dynamic>{},
      });
    });

    test('renders every optional top-level field when set', () {
      const settings = VoiceAgentSettings(
        agent: AgentAgentSettings(language: 'en'),
        audio: AgentAudioSettings(input: AgentAudioInput()),
        tags: <String>['voice-agent', 'e2e'],
        experimental: true,
        mipOptOut: true,
        flags: AgentSettingsFlags(history: false),
      );

      expect(settings.toJson(), <String, dynamic>{
        'type': 'Settings',
        'tags': <String>['voice-agent', 'e2e'],
        'experimental': true,
        'mip_opt_out': true,
        'flags': <String, dynamic>{'history': false},
        'audio': <String, dynamic>{
          'input': <String, dynamic>{
            'encoding': 'linear16',
            'sample_rate': 24000,
          },
        },
        'agent': <String, dynamic>{'language': 'en'},
      });
    });

    test('emits top-level keys in the documented order', () {
      const settings = VoiceAgentSettings(
        agent: AgentAgentSettings(language: 'en'),
        audio: AgentAudioSettings(input: AgentAudioInput()),
        tags: <String>['a'],
        experimental: true,
        mipOptOut: true,
        flags: AgentSettingsFlags(),
      );

      expect(settings.toJson().keys.toList(), <String>[
        'type',
        'tags',
        'experimental',
        'mip_opt_out',
        'flags',
        'audio',
        'agent',
      ]);
    });

    test('renders a complete kitchen-sink Settings message', () {
      final settings = VoiceAgentSettings(
        agent: AgentAgentSettings(
          greeting: 'Hello! How can I help?',
          context: AgentContext(messages: <AgentHistoryMessage>[
            const AgentHistoryMessage.text(
              role: 'user',
              content: 'I need a cab to the airport.',
            ),
            AgentHistoryMessage.functionCalls(
              calls: <AgentFunctionCallRecord>[
                const AgentFunctionCallRecord(
                  id: 'call-1',
                  name: 'book_cab',
                  arguments: '{"destination":"SFO"}',
                  response: '{"eta_minutes":9}',
                  clientSide: true,
                  thoughtSignature: 'sig-abc',
                ),
              ],
            ),
            const AgentHistoryMessage.text(
              role: 'assistant',
              content: 'Your cab arrives in 9 minutes.',
            ),
          ]),
          listen: const AgentListen(
            provider: AgentListenProvider.v1(
              model: 'nova-3',
              language: 'en-US',
              keyterms: <String>['Deepgram', 'Flux STT'],
              smartFormat: true,
            ),
          ),
          think: AgentThink(
            provider: AgentThinkProvider.openAi(
              model: 'gpt-5-mini',
              temperature: 0.7,
              reasoningMode: 'high',
            ),
            prompt: 'You are a helpful concierge.',
            functions: <AgentFunctionDefinition>[
              const AgentFunctionDefinition.client(
                name: 'get_weather',
                description: 'Get the current weather.',
                parameters: <String, dynamic>{
                  'type': 'object',
                  'properties': <String, dynamic>{
                    'city': <String, dynamic>{'type': 'string'},
                  },
                  'required': <String>['city'],
                },
                deferUntilEot: true,
              ),
              const AgentFunctionDefinition.server(
                name: 'check_order_status',
                description: 'Look up an order.',
                url: 'https://api.example.com/orders/status',
                method: 'POST',
                headers: <String, String>{'x-request-id': '42'},
                authorization: <String, String>{
                  'authorization': 'Bearer {{token}}',
                },
              ),
            ],
          ),
          speak: const AgentSpeak(
            provider: AgentSpeakProvider(
              model: 'aura-2-thalia-en',
              speed: 1.1,
            ),
          ),
          language: 'en',
        ),
        audio: const AgentAudioSettings(
          input: AgentAudioInput(
            encoding: AgentAudioEncoding.opus,
            sampleRate: 48000,
          ),
          output: AgentAudioOutput(
            encoding: AgentAudioOutputEncoding.mp3,
            sampleRate: 44100,
            container: AgentAudioOutputContainer.ogg,
            bitRate: 128000,
          ),
        ),
        tags: <String>['cab', 'concierge'],
        experimental: true,
        mipOptOut: true,
        flags: const AgentSettingsFlags(history: false),
      );

      expect(settings.toJson(), <String, dynamic>{
        'type': 'Settings',
        'tags': <String>['cab', 'concierge'],
        'experimental': true,
        'mip_opt_out': true,
        'flags': <String, dynamic>{'history': false},
        'audio': <String, dynamic>{
          'input': <String, dynamic>{
            'encoding': 'opus',
            'sample_rate': 48000,
          },
          'output': <String, dynamic>{
            'encoding': 'mp3',
            'sample_rate': 44100,
            'container': 'ogg',
            'bitrate': 128000,
          },
        },
        'agent': <String, dynamic>{
          'greeting': 'Hello! How can I help?',
          'context': <String, dynamic>{
            'messages': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'History',
                'role': 'user',
                'content': 'I need a cab to the airport.',
              },
              <String, dynamic>{
                'type': 'History',
                'function_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'call-1',
                    'name': 'book_cab',
                    'client_side': true,
                    'arguments': '{"destination":"SFO"}',
                    'response': '{"eta_minutes":9}',
                    'thought_signature': 'sig-abc',
                  },
                ],
              },
              <String, dynamic>{
                'type': 'History',
                'role': 'assistant',
                'content': 'Your cab arrives in 9 minutes.',
              },
            ],
          },
          'listen': <String, dynamic>{
            'provider': <String, dynamic>{
              'type': 'deepgram',
              'version': 'v1',
              'model': 'nova-3',
              'language': 'en-US',
              'keyterms': <String>['Deepgram', 'Flux STT'],
              'smart_format': true,
            },
          },
          'think': <String, dynamic>{
            'provider': <String, dynamic>{
              'type': 'open_ai',
              'model': 'gpt-5-mini',
              'temperature': 0.7,
              'reasoning_mode': 'high',
            },
            'prompt': 'You are a helpful concierge.',
            'functions': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'get_weather',
                'description': 'Get the current weather.',
                'defer_until_eot': true,
                'parameters': <String, dynamic>{
                  'type': 'object',
                  'properties': <String, dynamic>{
                    'city': <String, dynamic>{'type': 'string'},
                  },
                  'required': <String>['city'],
                },
              },
              <String, dynamic>{
                'name': 'check_order_status',
                'description': 'Look up an order.',
                'defer_until_eot': false,
                'endpoint': <String, dynamic>{
                  'url': 'https://api.example.com/orders/status',
                  'method': 'POST',
                  'headers': <String, String>{
                    'x-request-id': '42',
                    'authorization': 'Bearer {{token}}',
                  },
                },
              },
            ],
          },
          'speak': <String, dynamic>{
            'provider': <String, dynamic>{
              'type': 'deepgram',
              'version': 'v1',
              'model': 'aura-2-thalia-en',
              'speed': 1.1,
            },
          },
          'language': 'en',
        },
      });
    });
  });

  group('AgentSettingsFlags', () {
    test('defaults history to true', () {
      expect(const AgentSettingsFlags().toJson(), <String, dynamic>{
        'history': true,
      });
    });

    test('serializes an explicit value', () {
      expect(
        const AgentSettingsFlags(history: false).toJson(),
        <String, dynamic>{'history': false},
      );
    });
  });

  group('AgentAudioSettings', () {
    test('omits the output block when not provided', () {
      const audio = AgentAudioSettings(input: AgentAudioInput());
      expect(audio.toJson(), <String, dynamic>{
        'input': <String, dynamic>{
          'encoding': 'linear16',
          'sample_rate': 24000,
        },
      });
      expect(audio.toJson().containsKey('output'), isFalse);
    });

    test('includes the output block when provided', () {
      const audio = AgentAudioSettings(
        input: AgentAudioInput(sampleRate: 16000),
        output: AgentAudioOutput(),
      );
      expect(audio.toJson(), <String, dynamic>{
        'input': <String, dynamic>{
          'encoding': 'linear16',
          'sample_rate': 16000,
        },
        'output': <String, dynamic>{
          'encoding': 'linear16',
          'sample_rate': 24000,
          'container': 'none',
        },
      });
    });
  });

  group('AgentAudioInput', () {
    test('defaults match the server defaults (linear16 @ 24 kHz)', () {
      expect(const AgentAudioInput().toJson(), <String, dynamic>{
        'encoding': 'linear16',
        'sample_rate': 24000,
      });
    });

    test('serializes an explicit encoding and sample rate', () {
      const input = AgentAudioInput(
        encoding: AgentAudioEncoding.oggOpus,
        sampleRate: 48000,
      );
      expect(input.toJson(), <String, dynamic>{
        'encoding': 'ogg-opus',
        'sample_rate': 48000,
      });
      expect(input.toJson().keys.toList(), <String>['encoding', 'sample_rate']);
    });
  });

  group('AgentAudioOutput', () {
    test('omits bitrate when null and uses container/encoding defaults', () {
      final json = const AgentAudioOutput().toJson();
      expect(json, <String, dynamic>{
        'encoding': 'linear16',
        'sample_rate': 24000,
        'container': 'none',
      });
      expect(json.containsKey('bitrate'), isFalse);
      expect(json.containsKey('bit_rate'), isFalse);
    });

    test('emits the bitrate under the AsyncAPI key `bitrate` (no underscore)',
        () {
      final json = const AgentAudioOutput(
        encoding: AgentAudioOutputEncoding.opus,
        sampleRate: 24000,
        container: AgentAudioOutputContainer.none,
        bitRate: 64000,
      ).toJson();
      expect(json, <String, dynamic>{
        'encoding': 'opus',
        'sample_rate': 24000,
        'container': 'none',
        'bitrate': 64000,
      });
      expect(json.containsKey('bit_rate'), isFalse);
    });

    test('renders every output combination', () {
      final json = const AgentAudioOutput(
        encoding: AgentAudioOutputEncoding.mulaw,
        sampleRate: 8000,
        container: AgentAudioOutputContainer.wav,
        bitRate: 64000,
      ).toJson();
      expect(json, <String, dynamic>{
        'encoding': 'mulaw',
        'sample_rate': 8000,
        'container': 'wav',
        'bitrate': 64000,
      });
    });
  });

  group('audio encoding enums', () {
    test('AgentAudioEncoding wire names (input)', () {
      const expected = <String, String>{
        'linear16': 'linear16',
        'linear32': 'linear32',
        'flac': 'flac',
        'alaw': 'alaw',
        'mulaw': 'mulaw',
        'amr-nb': 'amrNb',
        'amr-wb': 'amrWb',
        'opus': 'opus',
        'ogg-opus': 'oggOpus',
        'speex': 'speex',
        'g729': 'g729',
      };
      for (final entry in expected.entries) {
        final value = AgentAudioEncoding.values
            .firstWhere((AgentAudioEncoding e) => e.name == entry.value);
        expect(value.wireName, entry.key, reason: entry.value);
        expect(
          AgentAudioInput(encoding: value).toJson()['encoding'],
          entry.key,
          reason: entry.value,
        );
      }
      expect(AgentAudioEncoding.values.length, 11);
    });

    test('AgentAudioOutputEncoding wire names (output)', () {
      final wireNames = AgentAudioOutputEncoding.values
          .map((AgentAudioOutputEncoding e) => e.wireName)
          .toList();
      expect(wireNames, <String>[
        'linear16',
        'mulaw',
        'alaw',
        'mp3',
        'opus',
        'flac',
        'aac',
      ]);
    });

    test('AgentAudioOutputContainer wire names', () {
      final wireNames = AgentAudioOutputContainer.values
          .map((AgentAudioOutputContainer e) => e.wireName)
          .toList();
      expect(wireNames, <String>['none', 'wav', 'ogg']);
    });
  });

  group('AgentAgentSettings', () {
    test('serializes to an empty object when nothing is set', () {
      expect(const AgentAgentSettings().toJson(), <String, dynamic>{});
    });

    test('emits each field under its documented key when set', () {
      const agent = AgentAgentSettings(
        greeting: 'Hi there!',
        language: 'en',
      );
      expect(agent.toJson(), <String, dynamic>{
        'greeting': 'Hi there!',
        'language': 'en',
      });
    });

    test('emits provider blocks as {provider: {...}} wrappers', () {
      final agent = AgentAgentSettings(
        listen: const AgentListen(provider: AgentListenProvider.v1()),
        think: AgentThink(
          provider: AgentThinkProvider.anthropic(
            model: 'claude-sonnet-4-20250514',
          ),
        ),
        speak: const AgentSpeak(
          provider: AgentSpeakProvider(model: 'aura-2-asteria-en'),
        ),
      );
      final json = agent.toJson();
      expect(json.keys.toList(), <String>['listen', 'think', 'speak']);
      expect(json['listen'], <String, dynamic>{
        'provider': AgentListenProvider.v1().toJson(),
      });
      expect(json['think'], <String, dynamic>{
        'provider': AgentThinkProvider.anthropic(
          model: 'claude-sonnet-4-20250514',
        ).toJson(),
      });
      expect(json['speak'], <String, dynamic>{
        'provider': const AgentSpeakProvider(
          model: 'aura-2-asteria-en',
        ).toJson(),
      });
    });

    test('emits all six fields together in the documented order', () {
      final agent = AgentAgentSettings(
        greeting: 'g',
        context: const AgentContext(messages: <AgentHistoryMessage>[]),
        listen: const AgentListen(provider: AgentListenProvider.v1()),
        think: AgentThink(
          provider: AgentThinkProvider.groq(model: 'openai/gpt-oss-20b'),
        ),
        speak: const AgentSpeak(
          provider: AgentSpeakProvider(model: 'aura-2-apollo-en'),
        ),
        language: 'fr',
      );
      expect(agent.toJson().keys.toList(), <String>[
        'greeting',
        'context',
        'listen',
        'think',
        'speak',
        'language',
      ]);
    });
  });

  group('AgentContext', () {
    test('wraps the message list under `messages`', () {
      const context = AgentContext(messages: <AgentHistoryMessage>[
        AgentHistoryMessage.text(role: 'user', content: 'Book a table.'),
        AgentHistoryMessage.text(role: 'assistant', content: 'Done.'),
      ]);
      expect(context.toJson(), <String, dynamic>{
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'History',
            'role': 'user',
            'content': 'Book a table.',
          },
          <String, dynamic>{
            'type': 'History',
            'role': 'assistant',
            'content': 'Done.',
          },
        ],
      });
    });

    test('renders an empty history as an empty messages list', () {
      expect(
        const AgentContext(messages: <AgentHistoryMessage>[]).toJson(),
        <String, dynamic>{'messages': <Map<String, dynamic>>[]},
      );
    });
  });

  group('AgentHistoryMessage', () {
    test('text entries render as {type, role, content}', () {
      const message = AgentHistoryMessage.text(
        role: 'user',
        content: 'What is the weather?',
      );
      expect(message.toJson(), <String, dynamic>{
        'type': 'History',
        'role': 'user',
        'content': 'What is the weather?',
      });
    });

    test('null role/content fall back to empty strings', () {
      // `required` named parameters of a nullable type may still be passed
      // as explicit `null`, exercising the defensive `?? ''` fallbacks.
      const message = AgentHistoryMessage.text(role: null, content: null);
      expect(message.toJson(), <String, dynamic>{
        'type': 'History',
        'role': '',
        'content': '',
      });
    });

    test('function-call entries render as {type, function_calls: [...]}', () {
      final message = AgentHistoryMessage.functionCalls(
        calls: <AgentFunctionCallRecord>[
          const AgentFunctionCallRecord(
            id: 'call-9',
            name: 'transfer',
            arguments: '{"department":"billing"}',
          ),
          const AgentFunctionCallRecord(
            id: 'call-10',
            name: 'hang_up',
            arguments: '{}',
            response: 'null',
            clientSide: false,
            thoughtSignature: 'sig-zzz',
          ),
        ],
      );
      expect(message.toJson(), <String, dynamic>{
        'type': 'History',
        'function_calls': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'call-9',
            'name': 'transfer',
            'client_side': false,
            'arguments': '{"department":"billing"}',
          },
          <String, dynamic>{
            'id': 'call-10',
            'name': 'hang_up',
            'client_side': false,
            'arguments': '{}',
            'response': 'null',
            'thought_signature': 'sig-zzz',
          },
        ],
      });
      expect(message.toJson().containsKey('role'), isFalse);
      expect(message.toJson().containsKey('content'), isFalse);
    });
  });

  group('AgentFunctionCallRecord', () {
    test('renders the required fields with client_side defaulting to false',
        () {
      const record = AgentFunctionCallRecord(
        id: 'call-1',
        name: 'get_weather',
        arguments: '{"city":"SF"}',
      );
      expect(record.toJson(), <String, dynamic>{
        'id': 'call-1',
        'name': 'get_weather',
        'client_side': false,
        'arguments': '{"city":"SF"}',
      });
      expect(record.toJson().containsKey('response'), isFalse);
      expect(record.toJson().containsKey('thought_signature'), isFalse);
    });

    test('renders every optional field when set', () {
      const record = AgentFunctionCallRecord(
        id: 'call-2',
        name: 'get_weather',
        arguments: '{"city":"NYC"}',
        response: '{"temp":71}',
        clientSide: true,
        thoughtSignature: 'gemini-sig',
      );
      expect(record.toJson(), <String, dynamic>{
        'id': 'call-2',
        'name': 'get_weather',
        'client_side': true,
        'arguments': '{"city":"NYC"}',
        'response': '{"temp":71}',
        'thought_signature': 'gemini-sig',
      });
    });
  });

  group('AgentListenProvider', () {
    test('v1 defaults to nova-3 / en-US and omits smart_format', () {
      final json = const AgentListenProvider.v1().toJson();
      expect(json, <String, dynamic>{
        'type': 'deepgram',
        'version': 'v1',
        'model': 'nova-3',
        'language': 'en-US',
      });
      expect(json.containsKey('smart_format'), isFalse);
      expect(json.containsKey('language_hints'), isFalse);
      expect(json.containsKey('eot_threshold'), isFalse);
    });

    test('v1 renders model, language, keyterms, and smart_format', () {
      final json = const AgentListenProvider.v1(
        model: 'nova-2',
        language: 'multi',
        keyterms: <String>['Deepgram', 'guacamole toastie'],
        smartFormat: true,
      ).toJson();
      expect(json, <String, dynamic>{
        'type': 'deepgram',
        'version': 'v1',
        'model': 'nova-2',
        'language': 'multi',
        'keyterms': <String>['Deepgram', 'guacamole toastie'],
        'smart_format': true,
      });
    });

    test('v1 with smartFormat false omits the key entirely', () {
      final json = const AgentListenProvider.v1(smartFormat: false).toJson();
      expect(json.containsKey('smart_format'), isFalse);
    });

    test('v2 minimal renders only type, version, and model', () {
      final json =
          const AgentListenProvider.v2(model: 'flux-general-en').toJson();
      expect(json, <String, dynamic>{
        'type': 'deepgram',
        'version': 'v2',
        'model': 'flux-general-en',
      });
      expect(json.containsKey('language'), isFalse);
      expect(json.containsKey('smart_format'), isFalse);
    });

    test('v2 renders every Flux end-of-turn knob', () {
      final json = const AgentListenProvider.v2(
        model: 'flux-general-multi',
        languageHints: <String>['en', 'es'],
        eotThreshold: 0.8,
        eagerEotThreshold: 0.6,
        eotTimeoutMs: 3000,
        keyterms: <String>['Deepgram'],
      ).toJson();
      expect(json, <String, dynamic>{
        'type': 'deepgram',
        'version': 'v2',
        'model': 'flux-general-multi',
        'keyterms': <String>['Deepgram'],
        'language_hints': <String>['en', 'es'],
        'eot_threshold': 0.8,
        'eager_eot_threshold': 0.6,
        'eot_timeout_ms': 3000,
      });
    });
  });

  group('AgentThink', () {
    test('renders only the provider when prompt and functions are null', () {
      final think = AgentThink(
        provider: AgentThinkProvider.openAi(model: 'gpt-5-mini'),
      );
      expect(think.toJson(), <String, dynamic>{
        'provider': <String, dynamic>{
          'type': 'open_ai',
          'model': 'gpt-5-mini',
        },
      });
      expect(think.toJson().containsKey('prompt'), isFalse);
      expect(think.toJson().containsKey('functions'), isFalse);
    });

    test('renders prompt and functions when set', () {
      final think = AgentThink(
        provider: AgentThinkProvider.google(model: 'gemini-2.5-flash'),
        prompt: 'Stay terse.',
        functions: <AgentFunctionDefinition>[
          const AgentFunctionDefinition.client(
            name: 'ping',
            description: 'Ping.',
          ),
        ],
      );
      final json = think.toJson();
      expect(json.keys.toList(), <String>['provider', 'prompt', 'functions']);
      expect(json['prompt'], 'Stay terse.');
      expect(json['functions'], <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'ping',
          'description': 'Ping.',
          'defer_until_eot': false,
        },
      ]);
    });
  });

  group('AgentThinkProvider', () {
    test('openAi minimal renders type + model only', () {
      expect(
        AgentThinkProvider.openAi(model: 'gpt-5-mini').toJson(),
        <String, dynamic>{'type': 'open_ai', 'model': 'gpt-5-mini'},
      );
    });

    test('openAi renders temperature and reasoning_mode', () {
      expect(
        AgentThinkProvider.openAi(
          model: 'gpt-4.1',
          temperature: 0.4,
          reasoningMode: 'minimal',
        ).toJson(),
        <String, dynamic>{
          'type': 'open_ai',
          'model': 'gpt-4.1',
          'temperature': 0.4,
          'reasoning_mode': 'minimal',
        },
      );
    });

    test('anthropic minimal omits temperature and version', () {
      expect(
        AgentThinkProvider.anthropic(
          model: 'claude-sonnet-4-20250514',
        ).toJson(),
        <String, dynamic>{
          'type': 'anthropic',
          'model': 'claude-sonnet-4-20250514',
        },
      );
    });

    test('anthropic renders temperature and version', () {
      expect(
        AgentThinkProvider.anthropic(
          model: 'claude-opus-4',
          temperature: 1.0,
          version: 'v1',
        ).toJson(),
        <String, dynamic>{
          'type': 'anthropic',
          'model': 'claude-opus-4',
          'temperature': 1.0,
          'version': 'v1',
        },
      );
    });

    test('google minimal omits temperature and version', () {
      expect(
        AgentThinkProvider.google(model: 'gemini-2.5-flash').toJson(),
        <String, dynamic>{'type': 'google', 'model': 'gemini-2.5-flash'},
      );
    });

    test('google renders temperature and the ai-studio version', () {
      expect(
        AgentThinkProvider.google(
          model: 'gemini-2.5-pro',
          temperature: 0.2,
          version: 'ai-studio-v1beta',
        ).toJson(),
        <String, dynamic>{
          'type': 'google',
          'model': 'gemini-2.5-pro',
          'temperature': 0.2,
          'version': 'ai-studio-v1beta',
        },
      );
    });

    test('groq minimal renders type + model only', () {
      expect(
        AgentThinkProvider.groq(model: 'openai/gpt-oss-20b').toJson(),
        <String, dynamic>{'type': 'groq', 'model': 'openai/gpt-oss-20b'},
      );
    });

    test('groq renders temperature and reasoning_mode', () {
      expect(
        AgentThinkProvider.groq(
          model: 'llama-3.3-70b-versatile',
          temperature: 0.9,
          reasoningMode: 'low',
        ).toJson(),
        <String, dynamic>{
          'type': 'groq',
          'model': 'llama-3.3-70b-versatile',
          'temperature': 0.9,
          'reasoning_mode': 'low',
        },
      );
    });

    test('awsBedrock minimal renders type + model only', () {
      expect(
        AgentThinkProvider.awsBedrock(
          model: 'anthropic/claude-3-5-sonnet-20240620-v1:0',
        ).toJson(),
        <String, dynamic>{
          'type': 'aws_bedrock',
          'model': 'anthropic/claude-3-5-sonnet-20240620-v1:0',
        },
      );
    });

    test('awsBedrock renders STS credentials with session_token', () {
      expect(
        AgentThinkProvider.awsBedrock(
          model: 'anthropic/claude-3-5-sonnet-20240620-v1:0',
          temperature: 0.5,
          credentials: AgentBedrockCredentials(
            type: 'sts',
            region: 'us-east-1',
            accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
            secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
            sessionToken: 'session-token-123',
          ),
        ).toJson(),
        <String, dynamic>{
          'type': 'aws_bedrock',
          'model': 'anthropic/claude-3-5-sonnet-20240620-v1:0',
          'temperature': 0.5,
          'credentials': <String, dynamic>{
            'type': 'sts',
            'region': 'us-east-1',
            'access_key_id': 'AKIAIOSFODNN7EXAMPLE',
            'secret_access_key': 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
            'session_token': 'session-token-123',
          },
        },
      );
    });

    test('awsBedrock renders IAM credentials without session_token', () {
      final json = AgentThinkProvider.awsBedrock(
        model: 'us.amazon.nova-lite-v1:0',
        credentials: const AgentBedrockCredentials(
          type: 'iam',
          region: 'eu-west-1',
          accessKeyId: 'AKIAEXAMPLE',
          secretAccessKey: 'secret',
        ),
      ).toJson();
      expect(json['credentials'], <String, dynamic>{
        'type': 'iam',
        'region': 'eu-west-1',
        'access_key_id': 'AKIAEXAMPLE',
        'secret_access_key': 'secret',
      });
      expect(
        (json['credentials'] as Map<String, dynamic>)
            .containsKey('session_token'),
        isFalse,
      );
    });

    test('custom minimal renders type, url, and model', () {
      expect(
        AgentThinkProvider.custom(
          url: 'https://llm.example.com/v1/chat',
          model: 'my-private-model',
        ).toJson(),
        <String, dynamic>{
          'type': 'custom',
          'model': 'my-private-model',
          'url': 'https://llm.example.com/v1/chat',
        },
      );
    });

    test('custom nests authHeaders under auth.headers', () {
      expect(
        AgentThinkProvider.custom(
          url: 'https://llm.example.com/v1/chat',
          model: 'my-private-model',
          headers: <String, String>{'x-tenant': 'acme'},
          authHeaders: <String, String>{'authorization': 'Bearer tok'},
        ).toJson(),
        <String, dynamic>{
          'type': 'custom',
          'model': 'my-private-model',
          'url': 'https://llm.example.com/v1/chat',
          'headers': <String, String>{'x-tenant': 'acme'},
          'auth': <String, dynamic>{
            'headers': <String, String>{'authorization': 'Bearer tok'},
          },
        },
      );
    });

    test('emits think-provider keys in the documented order', () {
      final json = AgentThinkProvider.custom(
        url: 'https://llm.example.com',
        model: 'm',
        headers: <String, String>{'a': 'b'},
        authHeaders: <String, String>{'c': 'd'},
      ).toJson();
      expect(json.keys.toList(), <String>[
        'type',
        'model',
        'url',
        'headers',
        'auth',
      ]);
    });
  });

  group('AgentBedrockCredentials', () {
    test('omits session_token when null', () {
      const credentials = AgentBedrockCredentials(
        type: 'iam',
        region: 'ap-south-1',
        accessKeyId: 'id',
        secretAccessKey: 'secret',
      );
      expect(credentials.toJson(), <String, dynamic>{
        'type': 'iam',
        'region': 'ap-south-1',
        'access_key_id': 'id',
        'secret_access_key': 'secret',
      });
      expect(credentials.toJson().containsKey('session_token'), isFalse);
    });
  });

  group('AgentFunctionDefinition.client', () {
    test('renders name/description/defer_until_eot without an endpoint', () {
      final json = const AgentFunctionDefinition.client(
        name: 'get_weather',
        description: 'Get the current weather for a city.',
      ).toJson();
      expect(json, <String, dynamic>{
        'name': 'get_weather',
        'description': 'Get the current weather for a city.',
        'defer_until_eot': false,
      });
      expect(json.containsKey('parameters'), isFalse);
      // Client-side execution is signaled by the ABSENCE of `endpoint` —
      // there is no `client_side` key in the Settings message.
      expect(json.containsKey('endpoint'), isFalse);
      expect(json.containsKey('client_side'), isFalse);
    });

    test('passes the JSON Schema parameters through as-is', () {
      final json = const AgentFunctionDefinition.client(
        name: 'book_flight',
        description: 'Book a flight.',
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'origin': <String, dynamic>{'type': 'string'},
            'destination': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['origin', 'destination'],
        },
        deferUntilEot: true,
      ).toJson();
      expect(json, <String, dynamic>{
        'name': 'book_flight',
        'description': 'Book a flight.',
        'defer_until_eot': true,
        'parameters': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'origin': <String, dynamic>{'type': 'string'},
            'destination': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['origin', 'destination'],
        },
      });
    });
  });

  group('AgentFunctionDefinition.server', () {
    test('wraps url/method in the endpoint object (defaults to POST)', () {
      final json = const AgentFunctionDefinition.server(
        name: 'check_order_status',
        description: 'Look up an order.',
        url: 'https://api.example.com/orders/status',
      ).toJson();
      expect(json, <String, dynamic>{
        'name': 'check_order_status',
        'description': 'Look up an order.',
        'defer_until_eot': false,
        'endpoint': <String, dynamic>{
          'url': 'https://api.example.com/orders/status',
          'method': 'POST',
        },
      });
      expect(json.containsKey('client_side'), isFalse);
      expect(
        (json['endpoint'] as Map<String, dynamic>).containsKey('headers'),
        isFalse,
      );
    });

    test('merges authorization into endpoint.headers alongside extra headers',
        () {
      final json = const AgentFunctionDefinition.server(
        name: 'charge_card',
        description: 'Charge the card.',
        url: 'https://payments.example.com/charge',
        method: 'PUT',
        headers: <String, String>{'x-request-id': '42'},
        authorization: <String, String>{'authorization': 'Bearer {{token}}'},
      ).toJson();
      expect(json['endpoint'], <String, dynamic>{
        'url': 'https://payments.example.com/charge',
        'method': 'PUT',
        'headers': <String, String>{
          'x-request-id': '42',
          'authorization': 'Bearer {{token}}',
        },
      });
      // No separate authorization object on the wire.
      expect(
        (json['endpoint'] as Map<String, dynamic>).containsKey('authorization'),
        isFalse,
      );
    });

    test('authorization alone still produces endpoint.headers', () {
      final json = const AgentFunctionDefinition.server(
        name: 'refund',
        description: 'Issue a refund.',
        url: 'https://payments.example.com/refund',
        authorization: <String, String>{'authorization': 'Token sk-live'},
      ).toJson();
      expect(json['endpoint'], <String, dynamic>{
        'url': 'https://payments.example.com/refund',
        'method': 'POST',
        'headers': <String, String>{'authorization': 'Token sk-live'},
      });
    });

    test('authorization entries win over colliding header names', () {
      final json = const AgentFunctionDefinition.server(
        name: 'conflict',
        description: 'Header clash.',
        url: 'https://api.example.com/x',
        headers: <String, String>{'authorization': 'Basic keep-me'},
        authorization: <String, String>{'authorization': 'Bearer override'},
      ).toJson();
      expect(
        (json['endpoint'] as Map<String, dynamic>)['headers'],
        <String, String>{'authorization': 'Bearer override'},
      );
    });

    test('renders parameters together with the endpoint', () {
      final json = const AgentFunctionDefinition.server(
        name: 'lookup',
        description: 'Lookup.',
        url: 'https://api.example.com/lookup',
        method: 'GET',
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{'type': 'string'},
          },
        },
      ).toJson();
      expect(json.keys.toList(), <String>[
        'name',
        'description',
        'defer_until_eot',
        'parameters',
        'endpoint',
      ]);
      expect(json['parameters'], <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'id': <String, dynamic>{'type': 'string'},
        },
      });
      expect(json['endpoint'], <String, dynamic>{
        'url': 'https://api.example.com/lookup',
        'method': 'GET',
      });
    });
  });

  group('AgentSpeakProvider', () {
    test('renders an Aura-2 voice on v1 by default', () {
      final json = const AgentSpeakProvider(model: 'aura-2-thalia-en').toJson();
      expect(json, <String, dynamic>{
        'type': 'deepgram',
        'version': 'v1',
        'model': 'aura-2-thalia-en',
      });
      expect(json.containsKey('speed'), isFalse);
      expect(json.containsKey('expressivity'), isFalse);
      expect(json.containsKey('language'), isFalse);
    });

    test('serializes a representative set of Aura-2 voice ids verbatim', () {
      const aura2Voices = <String>[
        'aura-2-thalia-en',
        'aura-2-andromeda-en',
        'aura-2-apollo-en',
        'aura-2-asteria-en',
        'aura-2-apollo-en',
        'aura-2-amalthea-en',
        'aura-2-cora-en',
      ];
      for (final voice in aura2Voices) {
        expect(
          AgentSpeakProvider(model: voice).toJson()['model'],
          voice,
          reason: voice,
        );
        expect(
          AgentSpeakProvider(model: voice).toJson()['version'],
          'v1',
          reason: voice,
        );
      }
    });

    test('renders speed for an Aura-2 voice', () {
      expect(
        const AgentSpeakProvider(model: 'aura-2-zeus-en', speed: 1.4).toJson(),
        <String, dynamic>{
          'type': 'deepgram',
          'version': 'v1',
          'model': 'aura-2-zeus-en',
          'speed': 1.4,
        },
      );
    });

    test('renders a Flux voice on v2 with expressivity', () {
      expect(
        const AgentSpeakProvider(
          model: 'flux-kit-en',
          version: 'v2',
          speed: 0.9,
          expressivity: -1,
          language: 'en',
        ).toJson(),
        <String, dynamic>{
          'type': 'deepgram',
          'version': 'v2',
          'model': 'flux-kit-en',
          'speed': 0.9,
          'expressivity': -1,
          'language': 'en',
        },
      );
    });

    test('omits language when null (Deepgram voices reject it)', () {
      final json = const AgentSpeakProvider(
        model: 'flux-alexis-en',
        version: 'v2',
      ).toJson();
      expect(json, <String, dynamic>{
        'type': 'deepgram',
        'version': 'v2',
        'model': 'flux-alexis-en',
      });
    });
  });
}
