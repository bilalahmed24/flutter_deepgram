/// Voice Agent configuration management over REST.
///
/// Covers reusable agent configurations (`/v1/projects/{id}/agents`),
/// template variables (`/v1/projects/{id}/agent-variables`), and the
/// think-model catalog (`/v1/agent/settings/think/models`).
///
/// A stored configuration holds the *agent block* of a Voice Agent
/// `Settings` message (fields such as `language`, `greeting`, `context`,
/// `listen`, `think`, `speak`). Once created, its id can be passed as the
/// `agent` field of a `Settings` message on the agent WebSocket to reuse
/// the whole configuration.
///
/// ```dart
/// final agents = deepgram.agentConfigurations;
/// final config = await agents.create(
///   projectId,
///   settings: <String, dynamic>{
///     'language': 'en',
///     'greeting': 'Hello! How can I help?',
///   },
///   metadata: <String, String>{'team': 'support'},
/// );
/// print(config.agentId);
/// ```
library;

import 'dart:convert';

import '../core/deepgram_config.dart';
import '../core/http/http_engine.dart';

// ---------------------------------------------------------------------------
// Agent configurations
// ---------------------------------------------------------------------------

/// A reusable agent configuration.
class AgentConfiguration {
  /// Creates an agent configuration model.
  const AgentConfiguration({
    this.agentId,
    this.config,
    this.metadata,
    this.createdAt,
    this.updatedAt,
  });

  /// Parses a configuration from decoded JSON (`agent_id`, `config`,
  /// `metadata`, `created_at`, `updated_at`).
  factory AgentConfiguration.fromJson(Map<String, dynamic> json) {
    return AgentConfiguration(
      agentId: _asString(json['agent_id']) ?? _asString(json['id']),
      config: _cast<Map<String, dynamic>>(json['config']),
      metadata: _stringMap(json['metadata']),
      createdAt: _asString(json['created_at']),
      updatedAt: _asString(json['updated_at']),
    );
  }

  /// Unique identifier of the configuration. Pass this as the `agent`
  /// field of a `Settings` message on the agent WebSocket to reuse the
  /// configuration.
  final String? agentId;

  /// The agent settings block (e.g. `language`, `greeting`, `context`,
  /// `listen`, `think`, `speak`).
  final Map<String, dynamic>? config;

  /// Arbitrary key-value labels attached to the configuration.
  final Map<String, String>? metadata;

  /// ISO-8601 timestamp of when the configuration was created.
  final String? createdAt;

  /// ISO-8601 timestamp of when the configuration was last updated.
  final String? updatedAt;
}

// ---------------------------------------------------------------------------
// Agent variables
// ---------------------------------------------------------------------------

/// A template variable usable inside agent configurations.
///
/// Keys follow the `DG_<VARIABLE_NAME>` format; values may be any JSON
/// type and are substituted into configurations that reference them.
class AgentVariable {
  /// Creates an agent variable model.
  const AgentVariable({
    this.variableId,
    this.key,
    this.value,
    this.createdAt,
    this.updatedAt,
  });

  /// Parses a variable from decoded JSON (`variable_id`, `key`, `value`,
  /// `created_at`, `updated_at`).
  factory AgentVariable.fromJson(Map<String, dynamic> json) {
    return AgentVariable(
      variableId: _asString(json['variable_id']) ?? _asString(json['id']),
      key: _asString(json['key']) ?? _asString(json['name']),
      value: json['value'],
      createdAt: _asString(json['created_at']),
      updatedAt: _asString(json['updated_at']),
    );
  }

  /// Unique identifier of the variable.
  final String? variableId;

  /// Variable name, following the `DG_<VARIABLE_NAME>` format.
  final String? key;

  /// The value to substitute; may be any JSON type (string, number,
  /// boolean, object, or array).
  final Object? value;

  /// ISO-8601 timestamp of when the variable was created.
  final String? createdAt;

  /// ISO-8601 timestamp of when the variable was last updated.
  final String? updatedAt;
}

// ---------------------------------------------------------------------------
// Think models
// ---------------------------------------------------------------------------

/// A think-provider model available to Voice Agents.
class AgentThinkModel {
  /// Creates a think model model.
  const AgentThinkModel({this.id, this.name, this.provider});

  /// Parses a think model from decoded JSON (`id`, `name`, `provider`).
  factory AgentThinkModel.fromJson(Map<String, dynamic> json) {
    return AgentThinkModel(
      id: _asString(json['id']),
      name: _asString(json['name']),
      provider: _asString(json['provider']),
    );
  }

  /// Unique model identifier (e.g. `gpt-4o-mini`, `claude-sonnet-4-20250514`).
  final String? id;

  /// Human-readable display name of the model.
  final String? name;

  /// Provider of the model (e.g. `open_ai`, `anthropic`, `google`,
  /// `groq`, `aws_bedrock`).
  final String? provider;
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// REST client for managing reusable Voice Agent configurations.
class AgentConfigurationsClient {
  /// Creates an agent configurations client.
  AgentConfigurationsClient({
    required HttpEngine http,
    required DeepgramConfig config,
  }) : _http = http,
       _config = config;

  final HttpEngine _http;
  final DeepgramConfig _config;

  /// The configuration this client was built from.
  DeepgramConfig get config => _config;

  // ---- Agent configurations ----------------------------------------------

  /// Lists reusable agent configurations:
  /// `GET /v1/projects/{projectId}/agents`.
  Future<List<AgentConfiguration>> list(String projectId) async {
    final result = await _http.getJson(
      '/v1/projects/${_seg(projectId)}/agents',
    );
    return <AgentConfiguration>[
      for (final item in _mapObjectList(result.body['agents']))
        AgentConfiguration.fromJson(item),
    ];
  }

  /// Creates a reusable agent configuration:
  /// `POST /v1/projects/{projectId}/agents`.
  ///
  /// [settings] is the agent block of a `Settings` message (fields such as
  /// `language`, `greeting`, `context`, `listen`, `think`, `speak`); the
  /// OpenAPI spec requires it to travel as a JSON-encoded string in the
  /// `config` field, which this method handles for you. [metadata] holds
  /// arbitrary string labels; [apiVersion] defaults to 1 server-side.
  Future<AgentConfiguration> create(
    String projectId, {
    required Map<String, dynamic> settings,
    Map<String, String>? metadata,
    int? apiVersion,
  }) async {
    final body = <String, dynamic>{
      'config': jsonEncode(settings),
      'metadata': ?metadata,
      'api_version': ?apiVersion,
    };
    final result = await _http.postJson(
      '/v1/projects/${_seg(projectId)}/agents',
      body: body,
    );
    return AgentConfiguration.fromJson(result.body);
  }

  /// Fetches one agent configuration:
  /// `GET /v1/projects/{projectId}/agents/{configurationId}`.
  Future<AgentConfiguration> get(
    String projectId,
    String configurationId,
  ) async {
    final result = await _http.getJson(
      '/v1/projects/${_seg(projectId)}/agents/${_seg(configurationId)}',
    );
    return AgentConfiguration.fromJson(result.body);
  }

  /// Updates an agent configuration's metadata:
  /// `PUT /v1/projects/{projectId}/agents/{configurationId}`.
  ///
  /// Per the OpenAPI spec (`UpdateAgentMetadataV1Request`), only the
  /// metadata map is updatable via PUT — the stored settings themselves
  /// are immutable. Delete and re-create the configuration to change them.
  Future<AgentConfiguration> update(
    String projectId,
    String configurationId, {
    required Map<String, String> metadata,
  }) async {
    final result = await _http.putJson(
      '/v1/projects/${_seg(projectId)}/agents/${_seg(configurationId)}',
      body: <String, dynamic>{'metadata': metadata},
    );
    return AgentConfiguration.fromJson(result.body);
  }

  /// Deletes an agent configuration:
  /// `DELETE /v1/projects/{projectId}/agents/{configurationId}`.
  Future<void> delete(String projectId, String configurationId) async {
    await _http.deleteJson(
      '/v1/projects/${_seg(projectId)}/agents/${_seg(configurationId)}',
    );
  }

  // ---- Agent variables ----------------------------------------------------

  /// Lists agent template variables:
  /// `GET /v1/projects/{projectId}/agent-variables`.
  Future<List<AgentVariable>> listVariables(String projectId) async {
    final result = await _http.getJson(
      '/v1/projects/${_seg(projectId)}/agent-variables',
    );
    return <AgentVariable>[
      for (final item in _mapObjectList(result.body['variables']))
        AgentVariable.fromJson(item),
    ];
  }

  /// Creates an agent template variable:
  /// `POST /v1/projects/{projectId}/agent-variables`.
  ///
  /// [key] follows the `DG_<VARIABLE_NAME>` format; [value] may be any
  /// JSON type.
  Future<AgentVariable> createVariable(
    String projectId, {
    required String key,
    required Object value,
    int? apiVersion,
  }) async {
    final body = <String, dynamic>{
      'key': key,
      'value': value,
      'api_version': ?apiVersion,
    };
    final result = await _http.postJson(
      '/v1/projects/${_seg(projectId)}/agent-variables',
      body: body,
    );
    return AgentVariable.fromJson(result.body);
  }

  /// Fetches one agent variable:
  /// `GET /v1/projects/{projectId}/agent-variables/{variableId}`.
  Future<AgentVariable> getVariable(String projectId, String variableId) async {
    final result = await _http.getJson(
      '/v1/projects/${_seg(projectId)}/agent-variables/${_seg(variableId)}',
    );
    return AgentVariable.fromJson(result.body);
  }

  /// Updates an agent variable's value:
  /// `PATCH /v1/projects/{projectId}/agent-variables/{variableId}`.
  ///
  /// Per the OpenAPI spec (`UpdateAgentVariableV1Request`), only the
  /// `value` field is updatable.
  Future<AgentVariable> updateVariable(
    String projectId,
    String variableId, {
    required Object value,
  }) async {
    final result = await _http.patchJson(
      '/v1/projects/${_seg(projectId)}/agent-variables/${_seg(variableId)}',
      body: <String, dynamic>{'value': value},
    );
    return AgentVariable.fromJson(result.body);
  }

  /// Deletes an agent variable:
  /// `DELETE /v1/projects/{projectId}/agent-variables/{variableId}`.
  Future<void> deleteVariable(String projectId, String variableId) async {
    await _http.deleteJson(
      '/v1/projects/${_seg(projectId)}/agent-variables/${_seg(variableId)}',
    );
  }

  // ---- Think models -------------------------------------------------------

  /// Lists the think-provider models available to Voice Agents:
  /// `GET /v1/agent/settings/think/models`.
  Future<List<AgentThinkModel>> listThinkModels() async {
    final result = await _http.getJson('/v1/agent/settings/think/models');
    return <AgentThinkModel>[
      for (final item in _mapObjectList(result.body['models']))
        AgentThinkModel.fromJson(item),
    ];
  }
}

// ---------------------------------------------------------------------------
// Defensive JSON helpers (file-private)
// ---------------------------------------------------------------------------

T? _cast<T>(dynamic v) => v is T ? v : null;

String? _asString(dynamic v) => v is String ? v : null;

Map<String, String>? _stringMap(dynamic v) {
  if (v is! Map) return null;
  final out = <String, String>{};
  v.forEach((dynamic key, dynamic value) {
    if (key is String && value is String) {
      out[key] = value;
    }
  });
  return out;
}

List<Map<String, dynamic>> _mapObjectList(dynamic v) {
  if (v is! List<dynamic>) return const <Map<String, dynamic>>[];
  return <Map<String, dynamic>>[
    for (final item in v)
      if (item is Map<String, dynamic>) item,
  ];
}

/// Percent-encodes a dynamic path segment.
String _seg(String value) => Uri.encodeComponent(value);
