/// Unit tests for `lib/src/agent/agent_configurations.dart` — the REST
/// Management client for reusable Voice Agent configurations
/// (`/v1/projects/{id}/agents`), template variables
/// (`/v1/projects/{id}/agent-variables`), and the think-model catalog
/// (`/v1/agent/settings/think/models`) — plus its three response models.
///
/// All HTTP traffic runs through the queue-based fake client from
/// `helpers/fake_http.dart` injected into a real `HttpEngine`, so every
/// request (method, exact path, headers, JSON body) is captured and every
/// response is scripted: no network, fully deterministic, every test fast.
///
/// Wire facts pinned from the OpenAPI spec: none of the agent-configuration
/// endpoints carry query or pagination parameters (asserted below), `create`
/// wraps the settings block as a JSON-encoded *string* under `config`, `PUT`
/// updates only `metadata`, and `PATCH` on a variable updates only `value`.
library;

import 'dart:convert';

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:test/test.dart';

import 'helpers/fake_http.dart';
import 'helpers/fakes.dart';

/// Builds a client wired exactly like the `DeepgramClient` facade does
/// (`AgentConfigurationsClient(http: _http, config: config)`).
AgentConfigurationsClient _client(
  QueueHttpClient queue, {
  DeepgramConfig config = testConfig,
}) {
  return AgentConfigurationsClient(
    http: HttpEngine(config: config, auth: DeepgramAuth(config), client: queue),
    config: config,
  );
}

/// A canned agent configuration payload as returned by the API.
const Map<String, dynamic> _agentJson = <String, dynamic>{
  'agent_id': 'cfg-123',
  'config': <String, dynamic>{
    'language': 'en',
    'greeting': 'Hello! How can I help?',
    'listen': <String, dynamic>{
      'provider': <String, dynamic>{'type': 'deepgram'},
    },
  },
  'metadata': <String, dynamic>{'team': 'support', 'env': 'staging'},
  'created_at': '2025-01-02T03:04:05Z',
  'updated_at': '2025-06-07T08:09:10Z',
};

void main() {
  group('AgentConfiguration.fromJson', () {
    test('parses the documented response shape', () {
      final config = AgentConfiguration.fromJson(_agentJson);
      expect(config.agentId, 'cfg-123');
      expect(config.config, <String, dynamic>{
        'language': 'en',
        'greeting': 'Hello! How can I help?',
        'listen': <String, dynamic>{
          'provider': <String, dynamic>{'type': 'deepgram'},
        },
      });
      expect(config.metadata, <String, String>{
        'team': 'support',
        'env': 'staging',
      });
      expect(config.createdAt, '2025-01-02T03:04:05Z');
      expect(config.updatedAt, '2025-06-07T08:09:10Z');
    });

    test('falls back to `id` when `agent_id` is absent', () {
      final config = AgentConfiguration.fromJson(<String, dynamic>{
        'id': 'cfg-fallback',
        'config': <String, dynamic>{'greeting': 'Hi'},
      });
      expect(config.agentId, 'cfg-fallback');
      expect(config.config, <String, dynamic>{'greeting': 'Hi'});
    });

    test('metadata keeps only string keys and string values', () {
      final config = AgentConfiguration.fromJson(<String, dynamic>{
        'agent_id': 'a',
        'metadata': <String, dynamic>{
          'ok': 'yes',
          'numeric': 7,
          'nullish': null,
          'nested': <String, dynamic>{'deep': 'no'},
        },
      });
      expect(config.metadata, <String, String>{'ok': 'yes'});
    });

    test('non-map metadata and non-map config yield null; missing ids too', () {
      final config = AgentConfiguration.fromJson(<String, dynamic>{
        'agent_id': <String>['nope'],
        'config': 'not-a-map',
        'metadata': 'not-a-map',
      });
      expect(config.agentId, isNull);
      expect(config.config, isNull);
      expect(config.metadata, isNull);
      expect(config.createdAt, isNull);
      expect(config.updatedAt, isNull);

      final empty = AgentConfiguration.fromJson(<String, dynamic>{});
      expect(empty.agentId, isNull);
      expect(empty.config, isNull);
      expect(empty.metadata, isNull);
    });

    test('numeric timestamps are not coerced (only strings survive)', () {
      final config = AgentConfiguration.fromJson(<String, dynamic>{
        'agent_id': 'a',
        'created_at': 1234,
        'updated_at': true,
      });
      expect(config.createdAt, isNull);
      expect(config.updatedAt, isNull);
    });
  });

  group('AgentVariable.fromJson', () {
    test('parses the documented response shape', () {
      final variable = AgentVariable.fromJson(<String, dynamic>{
        'variable_id': 'var-1',
        'key': 'DG_SUPPORT_TIER',
        'value': 'gold',
        'created_at': '2025-01-02T03:04:05Z',
        'updated_at': '2025-06-07T08:09:10Z',
      });
      expect(variable.variableId, 'var-1');
      expect(variable.key, 'DG_SUPPORT_TIER');
      expect(variable.value, 'gold');
      expect(variable.createdAt, '2025-01-02T03:04:05Z');
      expect(variable.updatedAt, '2025-06-07T08:09:10Z');
    });

    test('falls back to `id` and `name` aliases', () {
      final variable = AgentVariable.fromJson(<String, dynamic>{
        'id': 'var-2',
        'name': 'DG_ALIAS',
      });
      expect(variable.variableId, 'var-2');
      expect(variable.key, 'DG_ALIAS');
      expect(variable.value, isNull);
      expect(variable.createdAt, isNull);
      expect(variable.updatedAt, isNull);
    });

    test('value may be any JSON type and survives untouched', () {
      expect(
        AgentVariable.fromJson(<String, dynamic>{
          'variable_id': 'v',
          'key': 'k',
          'value': 3.5,
        }).value,
        3.5,
      );
      expect(
        AgentVariable.fromJson(<String, dynamic>{
          'variable_id': 'v',
          'key': 'k',
          'value': <String, dynamic>{
            'nested': <String>['a', 'b'],
          },
        }).value,
        <String, dynamic>{
          'nested': <String>['a', 'b'],
        },
      );
      expect(
        AgentVariable.fromJson(<String, dynamic>{
          'variable_id': 'v',
          'key': 'k',
          'value': <dynamic>[1, true, null],
        }).value,
        <dynamic>[1, true, null],
      );
      expect(
        AgentVariable.fromJson(<String, dynamic>{
          'variable_id': 'v',
          'key': 'k',
          'value': false,
        }).value,
        isFalse,
      );
      expect(
        AgentVariable.fromJson(<String, dynamic>{
          'variable_id': 'v',
          'key': 'k',
        }).value,
        isNull,
      );
    });
  });

  group('AgentThinkModel.fromJson', () {
    test('parses the documented response shape', () {
      final model = AgentThinkModel.fromJson(<String, dynamic>{
        'id': 'gpt-4o-mini',
        'name': 'GPT-4o mini',
        'provider': 'open_ai',
      });
      expect(model.id, 'gpt-4o-mini');
      expect(model.name, 'GPT-4o mini');
      expect(model.provider, 'open_ai');
    });

    test('missing or malformed fields default to null', () {
      final model = AgentThinkModel.fromJson(<String, dynamic>{
        'id': 42,
        'name': <String>['nope'],
        'provider': null,
      });
      expect(model.id, isNull);
      expect(model.name, isNull);
      expect(model.provider, isNull);
    });
  });

  group('AgentConfigurationsClient — configurations', () {
    test('list() GETs /v1/projects/{id}/agents with Token auth', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{
        'agents': <dynamic>[_agentJson],
      });

      final configs = await client.list('proj-1');

      final request = queue.requests.single;
      expect(request.method, 'GET');
      expect(
        request.url.toString(),
        'https://api.deepgram.com/v1/projects/proj-1/agents',
      );
      // The OpenAPI surface defines no query or pagination parameters.
      expect(request.url.query, isEmpty);
      expect(_headerOf(request.headers, 'authorization'), 'Token test-api-key');

      expect(configs, hasLength(1));
      expect(configs.single.agentId, 'cfg-123');
      expect(configs.single.metadata, <String, String>{
        'team': 'support',
        'env': 'staging',
      });
    });

    test(
      'list() tolerates missing, non-list, and junk `agents` payloads',
      () async {
        final queue = QueueHttpClient();
        final client = _client(queue);

        queue.enqueueJson(<String, dynamic>{});
        expect(await client.list('p'), isEmpty);

        queue.enqueueJson(<String, dynamic>{
          'agents': <String, dynamic>{'not': 'a list'},
        });
        expect(await client.list('p'), isEmpty);

        queue.enqueueJson(<String, dynamic>{
          'agents': <dynamic>['a string entry', 7, null, _agentJson],
        });
        final onlyValid = await client.list('p');
        expect(onlyValid, hasLength(1));
        expect(onlyValid.single.agentId, 'cfg-123');
        expect(queue.requests, hasLength(3));
      },
    );

    test(
      'create() POSTs the settings as a JSON string under `config`',
      () async {
        final queue = QueueHttpClient();
        final client = _client(queue);
        queue.enqueueJson(_agentJson);

        final created = await client.create(
          'proj-1',
          settings: <String, dynamic>{
            'language': 'en',
            'greeting': 'Hello! How can I help?',
          },
          metadata: <String, String>{'team': 'support'},
          apiVersion: 1,
        );

        final request = queue.requests.single;
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/projects/proj-1/agents');

        // The OpenAPI spec requires the settings block to travel as a
        // JSON-encoded string inside the `config` field.
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body, <String, dynamic>{
          'config': '{"language":"en","greeting":"Hello! How can I help?"}',
          'metadata': <String, dynamic>{'team': 'support'},
          'api_version': 1,
        });

        expect(created.agentId, 'cfg-123');
        expect(created.config, _agentJson['config']);
      },
    );

    test('create() omits metadata and api_version when not supplied', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{'agent_id': 'cfg-bare'});

      final created = await client.create(
        'proj-1',
        settings: <String, dynamic>{'greeting': 'Hi'},
      );

      final body =
          jsonDecode(queue.requests.single.body) as Map<String, dynamic>;
      expect(body, <String, dynamic>{'config': '{"greeting":"Hi"}'});
      expect(created.agentId, 'cfg-bare');
    });

    test('get() fetches one configuration by id', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(_agentJson);

      final config = await client.get('proj-1', 'cfg-123');

      final request = queue.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/projects/proj-1/agents/cfg-123');
      expect(config.agentId, 'cfg-123');
    });

    test('path segments are percent-encoded', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{'agent_id': 'x'});

      await client.get('my project', 'cfg/needs encoding');

      expect(
        queue.requests.single.url.path,
        '/v1/projects/my%20project/agents/cfg%2Fneeds%20encoding',
      );
    });

    test('update() PUTs only the metadata map', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{
        'agent_id': 'cfg-123',
        'metadata': <String, dynamic>{'team': 'platform'},
      });

      final updated = await client.update(
        'proj-1',
        'cfg-123',
        metadata: <String, String>{'team': 'platform'},
      );

      final request = queue.requests.single;
      expect(request.method, 'PUT');
      expect(request.url.path, '/v1/projects/proj-1/agents/cfg-123');
      expect(
        jsonDecode(request.body) as Map<String, dynamic>,
        <String, dynamic>{
          'metadata': <String, String>{'team': 'platform'},
        },
      );
      expect(updated.metadata, <String, String>{'team': 'platform'});
    });

    test('delete() issues a DELETE and completes on an empty body', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson('', status: 204);

      await client.delete('proj-1', 'cfg-123');

      final request = queue.requests.single;
      expect(request.method, 'DELETE');
      expect(request.url.path, '/v1/projects/proj-1/agents/cfg-123');
      expect(request.body, isEmpty);
    });

    test('delete() surfaces 404 as DeepgramNotFoundException', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{
        'err_msg': 'Configuration not found.',
        'request_id': 'req-404',
      }, status: 404);

      await expectLater(
        client.delete('proj-1', 'missing'),
        throwsA(
          isA<DeepgramNotFoundException>()
              .having(
                (DeepgramNotFoundException error) => error.message,
                'message',
                'Configuration not found.',
              )
              .having(
                (DeepgramNotFoundException error) => error.requestId,
                'requestId',
                'req-404',
              ),
        ),
      );
      expect(
        queue.requests.single.url.path,
        '/v1/projects/proj-1/agents/missing',
      );
    });
  });

  group('AgentConfigurationsClient — variables', () {
    test('listVariables() GETs /v1/projects/{id}/agent-variables', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{
        'variables': <dynamic>[
          <String, dynamic>{
            'variable_id': 'var-1',
            'key': 'DG_TIER',
            'value': 'gold',
          },
          <String, dynamic>{
            'variable_id': 'var-2',
            'key': 'DG_SEATS',
            'value': 5,
          },
        ],
      });

      final variables = await client.listVariables('proj-1');

      final request = queue.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/projects/proj-1/agent-variables');
      expect(request.url.query, isEmpty);

      expect(variables, hasLength(2));
      expect(variables.first.variableId, 'var-1');
      expect(variables.first.key, 'DG_TIER');
      expect(variables.first.value, 'gold');
      expect(variables[1].value, 5);
    });

    test('listVariables() skips junk entries and empty payloads', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);

      queue.enqueueJson(<String, dynamic>{
        'variables': <dynamic>['junk', 3, null],
      });
      expect(await client.listVariables('p'), isEmpty);

      queue.enqueueJson(<String, dynamic>{'variables': 'nope'});
      expect(await client.listVariables('p'), isEmpty);
    });

    test(
      'createVariable() POSTs key, value, and optional api_version',
      () async {
        final queue = QueueHttpClient();
        final client = _client(queue);
        queue.enqueueJson(<String, dynamic>{
          'variable_id': 'var-9',
          'key': 'DG_NEW',
          'value': <String, dynamic>{'nested': true},
        });

        final created = await client.createVariable(
          'proj-1',
          key: 'DG_NEW',
          value: <String, dynamic>{'nested': true},
          apiVersion: 2,
        );

        final request = queue.requests.single;
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/projects/proj-1/agent-variables');
        expect(
          jsonDecode(request.body) as Map<String, dynamic>,
          <String, dynamic>{
            'key': 'DG_NEW',
            'value': <String, dynamic>{'nested': true},
            'api_version': 2,
          },
        );
        expect(created.variableId, 'var-9');
        expect(created.value, <String, dynamic>{'nested': true});
      },
    );

    test('createVariable() omits api_version when not supplied', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{'variable_id': 'v', 'key': 'k'});

      await client.createVariable('proj-1', key: 'DG_PLAIN', value: 42);

      expect(
        jsonDecode(queue.requests.single.body) as Map<String, dynamic>,
        <String, dynamic>{'key': 'DG_PLAIN', 'value': 42},
      );
    });

    test('getVariable() fetches one variable by id', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{
        'variable_id': 'var-1',
        'key': 'DG_TIER',
        'value': 'gold',
      });

      final variable = await client.getVariable('proj-1', 'var-1');

      final request = queue.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/projects/proj-1/agent-variables/var-1');
      expect(variable.key, 'DG_TIER');
    });

    test('updateVariable() PATCHes only the value', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{
        'variable_id': 'var-1',
        'key': 'DG_TIER',
        'value': 'platinum',
      });

      final updated = await client.updateVariable(
        'proj-1',
        'var-1',
        value: 'platinum',
      );

      final request = queue.requests.single;
      expect(request.method, 'PATCH');
      expect(request.url.path, '/v1/projects/proj-1/agent-variables/var-1');
      expect(
        jsonDecode(request.body) as Map<String, dynamic>,
        <String, dynamic>{'value': 'platinum'},
      );
      expect(updated.value, 'platinum');
    });

    test('updateVariable() accepts any JSON value type', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{'variable_id': 'v', 'value': null});

      await client.updateVariable(
        'proj-1',
        'var-1',
        value: <dynamic>['a', 1, true],
      );

      expect(
        jsonDecode(queue.requests.single.body) as Map<String, dynamic>,
        <String, dynamic>{
          'value': <dynamic>['a', 1, true],
        },
      );
    });

    test('deleteVariable() issues a DELETE', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson('', status: 204);

      await client.deleteVariable('proj-1', 'var-1');

      final request = queue.requests.single;
      expect(request.method, 'DELETE');
      expect(request.url.path, '/v1/projects/proj-1/agent-variables/var-1');
    });
  });

  group('AgentConfigurationsClient — think models', () {
    test('listThinkModels() GETs /v1/agent/settings/think/models', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{
        'models': <dynamic>[
          <String, dynamic>{
            'id': 'gpt-4o-mini',
            'name': 'GPT-4o mini',
            'provider': 'open_ai',
          },
          <String, dynamic>{
            'id': 'claude-sonnet-4-20250514',
            'name': 'Claude Sonnet 4',
            'provider': 'anthropic',
          },
          <String, dynamic>{
            'id': 'gemini-2.5-flash',
            'name': 'Gemini 2.5 Flash',
            'provider': 'google',
          },
        ],
      });

      final models = await client.listThinkModels();

      final request = queue.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/agent/settings/think/models');
      expect(request.url.host, 'api.deepgram.com');
      expect(request.url.query, isEmpty);

      expect(models, hasLength(3));
      expect(models[0].provider, 'open_ai');
      expect(models[1].id, 'claude-sonnet-4-20250514');
      expect(models[2].name, 'Gemini 2.5 Flash');
    });

    test('listThinkModels() tolerates junk payloads', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);

      queue.enqueueJson(<String, dynamic>{});
      expect(await client.listThinkModels(), isEmpty);

      queue.enqueueJson(<String, dynamic>{
        'models': <dynamic>[
          <String, dynamic>{'id': 'solo'},
          'junk',
        ],
      });
      final models = await client.listThinkModels();
      expect(models, hasLength(1));
      expect(models.single.id, 'solo');
      expect(models.single.name, isNull);
    });
  });

  group('AgentConfigurationsClient — error paths', () {
    test(
      '401 maps to DeepgramAuthException with parsed error fields',
      () async {
        final queue = QueueHttpClient();
        final client = _client(queue);
        queue.enqueueJson(<String, dynamic>{
          'err_msg': 'Invalid API key.',
          'request_id': 'req-auth',
          'err_code': 'AUTH_INVALID',
        }, status: 401);

        await expectLater(
          client.list('proj-1'),
          throwsA(
            isA<DeepgramAuthException>()
                .having(
                  (DeepgramAuthException error) => error.message,
                  'message',
                  'Invalid API key.',
                )
                .having(
                  (DeepgramAuthException error) => error.requestId,
                  'requestId',
                  'req-auth',
                )
                .having(
                  (DeepgramAuthException error) => error.code,
                  'code',
                  'AUTH_INVALID',
                ),
          ),
        );
        // Non-retryable client errors consume exactly one request.
        expect(queue.requests, hasLength(1));
      },
    );

    test('404 maps to DeepgramNotFoundException on get()', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{
        'err_msg': 'Project not found.',
      }, status: 404);

      await expectLater(
        client.get('proj-x', 'cfg-y'),
        throwsA(isA<DeepgramNotFoundException>()),
      );
      expect(queue.requests, hasLength(1));
    });

    test('429 retries up to maxRetries then maps to '
        'DeepgramRateLimitException', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      // testConfig.maxRetries is 2 → the engine attempts 3 times.
      for (var i = 0; i < 3; i++) {
        queue.enqueueJson(
          <String, dynamic>{'err_msg': 'Rate limit exceeded.'},
          status: 429,
          headers: <String, String>{'retry-after': '0'},
        );
      }

      await expectLater(
        client.list('proj-1'),
        throwsA(
          isA<DeepgramRateLimitException>().having(
            (DeepgramRateLimitException error) => error.retryAfter,
            'retryAfter',
            Duration.zero,
          ),
        ),
      );
      expect(queue.requests, hasLength(3));
    });

    test('400 maps to DeepgramBadRequestException', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{
        'err_msg': 'config must be a valid Settings object.',
      }, status: 400);

      await expectLater(
        client.create('proj-1', settings: <String, dynamic>{'bad': true}),
        throwsA(
          isA<DeepgramBadRequestException>().having(
            (DeepgramBadRequestException error) => error.message,
            'message',
            'config must be a valid Settings object.',
          ),
        ),
      );
    });

    test('5xx retries then maps to DeepgramServerException', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      for (var i = 0; i < 3; i++) {
        queue.enqueueJson(<String, dynamic>{}, status: 500);
      }

      await expectLater(
        client.listVariables('proj-1'),
        throwsA(
          isA<DeepgramServerException>().having(
            (DeepgramServerException error) => error.message,
            'message',
            'HTTP 500.',
          ),
        ),
      );
      expect(queue.requests, hasLength(3));
    });

    test('updateVariable surfaces 404 for a missing variable', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{
        'err_msg': 'Variable not found.',
      }, status: 404);

      await expectLater(
        client.updateVariable('proj-1', 'missing', value: 1),
        throwsA(isA<DeepgramNotFoundException>()),
      );
    });

    test('listThinkModels surfaces 401', () async {
      final queue = QueueHttpClient();
      final client = _client(queue);
      queue.enqueueJson(<String, dynamic>{
        'err_msg': 'Unauthorized.',
      }, status: 401);

      await expectLater(
        client.listThinkModels(),
        throwsA(isA<DeepgramAuthException>()),
      );
    });
  });

  group('AgentConfigurationsClient — wiring', () {
    test('exposes the injected config', () {
      final queue = QueueHttpClient();
      final config = DeepgramConfig(
        apiKey: 'other-key',
        baseUrl: 'api.example.com',
      );
      final client = _client(queue, config: config);
      expect(client.config, same(config));
    });

    test('uses Bearer auth when configured with a jwt', () async {
      final queue = QueueHttpClient();
      const config = DeepgramConfig(jwt: 'jwt-token');
      final client = _client(queue, config: config);
      queue.enqueueJson(<String, dynamic>{'agents': <dynamic>[]});

      await client.list('proj-1');

      expect(
        _headerOf(queue.requests.single.headers, 'authorization'),
        'Bearer jwt-token',
      );
    });

    test('regional configs target the regional REST host', () async {
      final queue = QueueHttpClient();
      final config = DeepgramConfig.region(
        DeepgramRegion.eu,
        apiKey: 'k',
        requestTimeout: const Duration(seconds: 2),
      );
      final client = _client(queue, config: config);
      queue.enqueueJson(<String, dynamic>{'agents': <dynamic>[]});

      await client.list('proj-1');

      expect(queue.requests.single.url.host, 'api.eu.deepgram.com');
    });
  });
}

/// Case-insensitive header lookup (http normalizes to lowercase).
String? _headerOf(Map<String, String> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name) return entry.value;
  }
  return null;
}
