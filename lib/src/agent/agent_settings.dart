/// Typed builders for the `Settings` message of the Deepgram Voice Agent API
/// (`wss://agent.deepgram.com/v1/agent/converse`).
///
/// Every class in this library models one node of the Settings JSON tree.
/// By convention each `toJson()` returns the *inner* object of its node and
/// the parent places it under its wire key, so [VoiceAgentSettings.toJson]
/// emits the complete, ready-to-send `Settings` message:
///
/// ```json
/// {
///   "type": "Settings",
///   "audio": {"input": {"encoding": "linear16", "sample_rate": 24000}},
///   "agent": {
///     "listen": {"provider": {"type": "deepgram", "version": "v1"}},
///     "think":  {"provider": {"type": "open_ai", "model": "gpt-5-mini"}},
///     "speak":  {"provider": {"type": "deepgram", "version": "v1"}}
///   }
/// }
/// ```
///
/// Wire names follow the authoritative AsyncAPI schemas for the agent v1
/// channel (`sample_rate`, `bitrate`, `mip_opt_out`, `defer_until_eot`,
/// `thought_signature`, ...). Optional values are omitted from the JSON when
/// not set.
library;

/// The complete `Settings` message, sent to the agent right after the
/// server's `Welcome` frame.
class VoiceAgentSettings {
  /// Creates a Settings message. [agent] and [audio] are required.
  const VoiceAgentSettings({
    required this.agent,
    required this.audio,
    this.tags,
    this.experimental = false,
    this.flags,
    this.mipOptOut = false,
  });

  /// The `agent` block: providers, conversation context, and greeting.
  final AgentAgentSettings agent;

  /// The `audio` block: input (STT) and output (TTS) media configuration.
  final AgentAudioSettings audio;

  /// Tags to associate with the request for filtered searching.
  final List<String>? tags;

  /// Enables experimental features. Defaults to `false`.
  final bool experimental;

  /// Optional feature flags, e.g. disabling function-call history reporting.
  final AgentSettingsFlags? flags;

  /// Opts out of the Model Improvement Program. Defaults to `false`.
  final bool mipOptOut;

  /// Serializes to the full `Settings` message, omitting optional fields
  /// that were not set.
  Map<String, dynamic> toJson() {
    final tagsValue = tags;
    final flagsValue = flags;
    return <String, dynamic>{
      'type': 'Settings',
      'tags': ?tagsValue,
      'experimental': experimental,
      'mip_opt_out': mipOptOut,
      if (flagsValue != null) 'flags': flagsValue.toJson(),
      'audio': audio.toJson(),
      'agent': agent.toJson(),
    };
  }
}

/// Feature flags carried by the `Settings` message.
class AgentSettingsFlags {
  /// Creates a flags object.
  const AgentSettingsFlags({this.history = true});

  /// Whether the server reports conversation `History` messages (including
  /// function calls) during the session. Defaults to `true`.
  final bool history;

  /// Serializes to the `flags` object.
  Map<String, dynamic> toJson() => <String, dynamic>{'history': history};
}

/// The `audio` block of [VoiceAgentSettings].
class AgentAudioSettings {
  /// Creates an audio block. [output] may be omitted to accept the server's
  /// default output format.
  const AgentAudioSettings({required this.input, this.output});

  /// Inbound (speech-to-text) media configuration.
  final AgentAudioInput input;

  /// Outbound (text-to-speech) media configuration, when provided.
  final AgentAudioOutput? output;

  /// Serializes to the `audio` object:
  /// `{'input': {...}, 'output'?: {...}}`.
  Map<String, dynamic> toJson() {
    final outputValue = output;
    return <String, dynamic>{
      'input': input.toJson(),
      if (outputValue != null) 'output': outputValue.toJson(),
    };
  }
}

/// `audio.input` — encoding and sample rate of the media the client streams
/// to the agent.
class AgentAudioInput {
  /// Creates an input configuration. Defaults match the server defaults:
  /// [AgentAudioEncoding.linear16] at 24 kHz.
  const AgentAudioInput({
    this.encoding = AgentAudioEncoding.linear16,
    this.sampleRate = 24000,
  });

  /// The input encoding.
  final AgentAudioEncoding encoding;

  /// The input sample rate in Hz (common values: 16000, 24000, 44100, 48000).
  final int sampleRate;

  /// Serializes to the `audio.input` object.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'encoding': encoding.wireName,
    'sample_rate': sampleRate,
  };
}

/// `audio.output` — the format the agent's text-to-speech audio is
/// delivered in.
class AgentAudioOutput {
  /// Creates an output configuration.
  const AgentAudioOutput({
    this.encoding = AgentAudioOutputEncoding.linear16,
    this.sampleRate = 24000,
    this.container = AgentAudioOutputContainer.none,
    this.bitRate,
  });

  /// The output encoding.
  final AgentAudioOutputEncoding encoding;

  /// The output sample rate in Hz.
  final int sampleRate;

  /// The output container format.
  final AgentAudioOutputContainer container;

  /// Output bitrate in bits per second. Emitted as `bitrate` (the agent
  /// Settings wire name) and omitted when `null`.
  final int? bitRate;

  /// Serializes to the `audio.output` object, omitting [bitRate] when null.
  Map<String, dynamic> toJson() {
    final rate = bitRate;
    return <String, dynamic>{
      'encoding': encoding.wireName,
      'sample_rate': sampleRate,
      'container': container.wireName,
      'bitrate': ?rate,
    };
  }
}

/// Audio encodings accepted for the agent's inbound (speech-to-text) media.
enum AgentAudioEncoding {
  /// 16-bit linear PCM. The default.
  linear16('linear16'),

  /// 32-bit linear PCM.
  linear32('linear32'),

  /// Free Lossless Audio Codec.
  flac('flac'),

  /// 8-bit A-law companded PCM.
  alaw('alaw'),

  /// 8-bit mu-law companded PCM.
  mulaw('mulaw'),

  /// Narrowband AMR (4.75–12.2 kbit/s).
  amrNb('amr-nb'),

  /// Wideband AMR (16–24 kbit/s).
  amrWb('amr-wb'),

  /// Raw Opus frames.
  opus('opus'),

  /// Opus in an Ogg container.
  oggOpus('ogg-opus'),

  /// Speex narrowband.
  speex('speex'),

  /// ITU-T G.729.
  g729('g729');

  /// Creates an encoding value.
  const AgentAudioEncoding(this.wireName);

  /// The wire name of this encoding, as sent to Deepgram.
  final String wireName;
}

/// Audio encodings accepted for the agent's outbound (text-to-speech) media.
enum AgentAudioOutputEncoding {
  /// 16-bit linear PCM. The default.
  linear16('linear16'),

  /// 8-bit mu-law companded PCM.
  mulaw('mulaw'),

  /// 8-bit A-law companded PCM.
  alaw('alaw'),

  /// MPEG-1/2 Audio Layer III.
  mp3('mp3'),

  /// Raw Opus frames.
  opus('opus'),

  /// Free Lossless Audio Codec.
  flac('flac'),

  /// Advanced Audio Coding.
  aac('aac');

  /// Creates an encoding value.
  const AgentAudioOutputEncoding(this.wireName);

  /// The wire name of this encoding, as sent to Deepgram.
  final String wireName;
}

/// Container formats for the agent's outbound (text-to-speech) media.
enum AgentAudioOutputContainer {
  /// Raw frames with no container. The default.
  none('none'),

  /// RIFF/WAVE container.
  wav('wav'),

  /// Ogg container.
  ogg('ogg');

  /// Creates a container value.
  const AgentAudioOutputContainer(this.wireName);

  /// The wire name of this container, as sent to Deepgram.
  final String wireName;
}

/// The `agent` block of [VoiceAgentSettings]: providers, conversation
/// context, greeting, and the deprecated top-level language.
///
/// There is intentionally no `goodbye` field — it is not part of the agent
/// v1 wire schema.
class AgentAgentSettings {
  /// Creates an agent block. All fields except the providers are optional
  /// and omitted from the JSON when `null`.
  const AgentAgentSettings({
    this.greeting,
    this.context,
    this.listen,
    this.think,
    this.speak,
    this.language,
  });

  /// Optional message the agent speaks when the conversation starts.
  final String? greeting;

  /// Optional conversation history injected at session start.
  final AgentContext? context;

  /// Speech-to-text provider configuration.
  final AgentListen? listen;

  /// LLM provider configuration, system prompt, and function definitions.
  final AgentThink? think;

  /// Text-to-speech provider configuration.
  final AgentSpeak? speak;

  /// Deprecated agent language code (defaults to `en` on the server). Prefer
  /// `listen.provider.language` / speak provider settings instead. Only
  /// emitted when explicitly set.
  final String? language;

  /// Serializes to the `agent` object, omitting every field that is `null`.
  Map<String, dynamic> toJson() {
    final greetingValue = greeting;
    final contextValue = context;
    final listenValue = listen;
    final thinkValue = think;
    final speakValue = speak;
    final languageValue = language;
    return <String, dynamic>{
      'greeting': ?greetingValue,
      if (contextValue != null) 'context': contextValue.toJson(),
      if (listenValue != null) 'listen': listenValue.toJson(),
      if (thinkValue != null) 'think': thinkValue.toJson(),
      if (speakValue != null) 'speak': speakValue.toJson(),
      'language': ?languageValue,
    };
  }
}

/// Conversation history injected at session start (`agent.context`).
class AgentContext {
  /// Creates a context object holding prior turns and function calls.
  const AgentContext({required this.messages});

  /// Conversation history as a list of messages and function calls.
  final List<AgentHistoryMessage> messages;

  /// Serializes to the `context` object: `{'messages': [...]}`.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'messages': <Map<String, dynamic>>[
      for (final message in messages) message.toJson(),
    ],
  };
}

/// One history entry: either a role/content message or a function-call
/// record list, both tagged `{'type': 'History', ...}` on the wire.
class AgentHistoryMessage {
  /// Creates a conversational history entry.
  const AgentHistoryMessage.text({required this.role, required this.content})
    : functionCalls = null;

  /// Creates a function-call history entry.
  const AgentHistoryMessage.functionCalls({
    required List<AgentFunctionCallRecord> calls,
  }) : role = null,
       content = null,
       functionCalls = calls;

  /// Who spoke the statement: `'user'` or `'assistant'`; `null` for
  /// function-call entries.
  final String? role;

  /// The statement that was spoken; `null` for function-call entries.
  final String? content;

  /// The function calls recorded in this entry; `null` for text entries.
  final List<AgentFunctionCallRecord>? functionCalls;

  /// Serializes to a `History` entry: either
  /// `{'type': 'History', 'role': ..., 'content': ...}` or
  /// `{'type': 'History', 'function_calls': [...]}`.
  Map<String, dynamic> toJson() {
    final calls = functionCalls;
    if (calls != null) {
      return <String, dynamic>{
        'type': 'History',
        'function_calls': <Map<String, dynamic>>[
          for (final call in calls) call.toJson(),
        ],
      };
    }
    return <String, dynamic>{
      'type': 'History',
      'role': role ?? '',
      'content': content ?? '',
    };
  }
}

/// A single function-call record used inside [AgentHistoryMessage] entries.
class AgentFunctionCallRecord {
  /// Creates a record.
  const AgentFunctionCallRecord({
    required this.id,
    required this.name,
    required this.arguments,
    this.response,
    this.clientSide = false,
    this.thoughtSignature,
  });

  /// Unique identifier for the function call.
  final String id;

  /// Name of the function called.
  final String name;

  /// Arguments passed to the function, as a JSON string.
  final String arguments;

  /// Response returned by the function call.
  final String? response;

  /// Whether the call was executed client-side (`true`) or server-side.
  final bool clientSide;

  /// Additional function call identifier required by some Gemini models.
  final String? thoughtSignature;

  /// Serializes to a function-call record object.
  Map<String, dynamic> toJson() {
    final responseValue = response;
    final signature = thoughtSignature;
    return <String, dynamic>{
      'id': id,
      'name': name,
      'client_side': clientSide,
      'arguments': arguments,
      'response': ?responseValue,
      'thought_signature': ?signature,
    };
  }
}

/// `agent.listen` — Deepgram speech-to-text configuration.
class AgentListen {
  /// Creates a listen block.
  const AgentListen({required this.provider});

  /// The Deepgram STT provider (Nova on v1, Flux on v2).
  final AgentListenProvider provider;

  /// Serializes to the `listen` object: `{'provider': {...}}`.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider': provider.toJson(),
  };
}

/// The Deepgram listen (speech-to-text) provider.
///
/// Use [AgentListenProvider.v1] for Nova models (default `nova-3`) and
/// [AgentListenProvider.v2] for Flux models such as `flux-general-en` or
/// `flux-general-multi`.
class AgentListenProvider {
  /// Creates a v1 (Nova) provider. Defaults: `nova-3`, `en-US`.
  const AgentListenProvider.v1({
    this.model = 'nova-3',
    this.language = 'en-US',
    this.keyterms,
    this.smartFormat = false,
  }) : version = 'v1',
       languageHints = null,
       eotThreshold = null,
       eagerEotThreshold = null,
       eotTimeoutMs = null;

  /// Creates a v2 (Flux) provider. [model] is required (e.g.
  /// `flux-general-en`); Flux models derive their language from the model
  /// name and do not accept `smart_format`.
  const AgentListenProvider.v2({
    required this.model,
    this.languageHints,
    this.eotThreshold,
    this.eagerEotThreshold,
    this.eotTimeoutMs,
    this.keyterms,
  }) : version = 'v2',
       language = null,
       smartFormat = false;

  /// The Deepgram STT API version: `'v1'` (Nova) or `'v2'` (Flux).
  final String version;

  /// The STT model (e.g. `nova-3`, `flux-general-en`).
  final String? model;

  /// Language code for transcription (v1 only; defaults to `en-US`). Use
  /// `multi` for code-switching on Nova models.
  final String? language;

  /// Terms you want increased recognition for; each entry is a plain string
  /// or multi-word phrase.
  final List<String>? keyterms;

  /// Applies smart formatting to transcripts (v1 only; defaults to `false`).
  final bool smartFormat;

  /// BCP-47 language codes to bias toward (v2, `flux-general-multi` only).
  final List<String>? languageHints;

  /// End-of-turn confidence threshold, 0.5–1.0 (v2 only; default 0.7).
  final double? eotThreshold;

  /// Eager end-of-turn confidence threshold, 0.3–0.9 (v2 only).
  final double? eagerEotThreshold;

  /// Hard timeout in ms after speech before a turn finishes (v2 only;
  /// default 5000).
  final int? eotTimeoutMs;

  /// Serializes to the listen provider object:
  /// `{'type': 'deepgram', 'version': ..., ...}` with nulls omitted.
  Map<String, dynamic> toJson() {
    final modelValue = model;
    final languageValue = language;
    final keytermsValue = keyterms;
    final hints = languageHints;
    final eot = eotThreshold;
    final eagerEot = eagerEotThreshold;
    final timeout = eotTimeoutMs;
    return <String, dynamic>{
      'type': 'deepgram',
      'version': version,
      'model': ?modelValue,
      'language': ?languageValue,
      'keyterms': ?keytermsValue,
      if (smartFormat) 'smart_format': smartFormat,
      'language_hints': ?hints,
      'eot_threshold': ?eot,
      'eager_eot_threshold': ?eagerEot,
      'eot_timeout_ms': ?timeout,
    };
  }
}

/// `agent.think` — LLM provider, system prompt, and function definitions.
class AgentThink {
  /// Creates a think block.
  const AgentThink({required this.provider, this.prompt, this.functions});

  /// The LLM provider configuration.
  final AgentThinkProvider provider;

  /// The system prompt that defines the agent's behavior and personality.
  final String? prompt;

  /// Functions the agent may call during the conversation.
  final List<AgentFunctionDefinition>? functions;

  /// Serializes to the `think` object:
  /// `{'provider': {...}, 'prompt'?: ..., 'functions'?: [...]}`.
  Map<String, dynamic> toJson() {
    final promptValue = prompt;
    final functionsValue = functions;
    return <String, dynamic>{
      'provider': provider.toJson(),
      'prompt': ?promptValue,
      if (functionsValue != null)
        'functions': <Map<String, dynamic>>[
          for (final definition in functionsValue) definition.toJson(),
        ],
    };
  }
}

/// An LLM (think) provider configuration.
///
/// Construct one of the typed providers — [AgentThinkProvider.openAi],
/// [AgentThinkProvider.anthropic], [AgentThinkProvider.google],
/// [AgentThinkProvider.awsBedrock], [AgentThinkProvider.groq], or
/// [AgentThinkProvider.custom] — each of which calls the private constant
/// constructor with its wire `kind`:
///
/// * open_ai: `{type: 'open_ai', model: 'gpt-5-mini', temperature?: num,
///   reasoning_mode?: 'none'|'minimal'|'low'|'medium'|'high'}`
/// * anthropic: `{type: 'anthropic', model: 'claude-sonnet-4-20250514',
///   temperature?: num, version?: 'v1'}`
/// * google: `{type: 'google', model: 'gemini-2.5-flash', temperature?: num,
///   version?: 'ai-studio-v1beta'}`
/// * aws_bedrock: `{type: 'aws_bedrock', model: 'anthropic/...', temperature?:
///   num, credentials?: {type: 'sts'|'iam', region, access_key_id,
///   secret_access_key, session_token?}}`
/// * groq: `{type: 'groq', model: 'openai/gpt-oss-20b', temperature?: num,
///   reasoning_mode?: ...}`
/// * custom: `{type: 'custom', url: 'https://your-llm', model: 'your-model',
///   headers?: {...}, auth?: {headers: {...}}}`
class AgentThinkProvider {
  /// Creates a provider from raw parts. Prefer the typed factories.
  const AgentThinkProvider._({
    required this.kind,
    this.model,
    this.temperature,
    this.reasoningMode,
    this.url,
    this.headers,
    this.authHeaders,
    this.credentials,
    this.version,
  });

  /// OpenAI, managed by Deepgram.
  factory AgentThinkProvider.openAi({
    required String model,
    double? temperature,
    String? reasoningMode,
  }) => AgentThinkProvider._(
    kind: 'open_ai',
    model: model,
    temperature: temperature,
    reasoningMode: reasoningMode,
  );

  /// Anthropic, managed by Deepgram. [version] selects the Anthropic API
  /// version (e.g. `'v1'`) and is emitted only when provided.
  factory AgentThinkProvider.anthropic({
    required String model,
    double? temperature,
    String? version,
  }) => AgentThinkProvider._(
    kind: 'anthropic',
    model: model,
    temperature: temperature,
    version: version,
  );

  /// Google, managed by Deepgram. [version] selects the Google API
  /// (e.g. `'ai-studio-v1beta'` for AI Studio) and is emitted only when
  /// provided.
  factory AgentThinkProvider.google({
    required String model,
    double? temperature,
    String? version,
  }) => AgentThinkProvider._(
    kind: 'google',
    model: model,
    temperature: temperature,
    version: version,
  );

  /// AWS Bedrock, using the model id format `provider/model` (e.g.
  /// `'anthropic/claude-3-5-sonnet-20240620-v1:0'`).
  factory AgentThinkProvider.awsBedrock({
    required String model,
    double? temperature,
    AgentBedrockCredentials? credentials,
  }) => AgentThinkProvider._(
    kind: 'aws_bedrock',
    model: model,
    temperature: temperature,
    credentials: credentials,
  );

  /// Groq, managed by Deepgram.
  factory AgentThinkProvider.groq({
    required String model,
    double? temperature,
    String? reasoningMode,
  }) => AgentThinkProvider._(
    kind: 'groq',
    model: model,
    temperature: temperature,
    reasoningMode: reasoningMode,
  );

  /// A custom (BYO) LLM endpoint. [headers] are sent with every request to
  /// [url]; [authHeaders] are emitted under `auth.headers`.
  factory AgentThinkProvider.custom({
    required String url,
    required String model,
    Map<String, String>? headers,
    Map<String, String>? authHeaders,
  }) => AgentThinkProvider._(
    kind: 'custom',
    url: url,
    model: model,
    headers: headers,
    authHeaders: authHeaders,
  );

  /// The provider kind: `'open_ai'`, `'anthropic'`, `'google'`,
  /// `'aws_bedrock'`, `'groq'`, or `'custom'`.
  final String kind;

  /// The LLM model identifier.
  final String? model;

  /// Controls the randomness of the LLM's output.
  final double? temperature;

  /// OpenAI-style reasoning effort (`'low'`, `'medium'`, `'high'`, ...).
  final String? reasoningMode;

  /// Custom endpoint URL (`custom` providers only).
  final String? url;

  /// Custom headers for the endpoint (`custom` providers only).
  final Map<String, String>? headers;

  /// Authentication headers, emitted under `auth.headers` (`custom`
  /// providers only).
  final Map<String, String>? authHeaders;

  /// AWS Bedrock credentials.
  final AgentBedrockCredentials? credentials;

  /// Optional API version selector (e.g. `'v1'` for Anthropic,
  /// `'ai-studio-v1beta'` for Google).
  final String? version;

  /// Serializes to the think provider object, omitting nulls.
  Map<String, dynamic> toJson() {
    final modelValue = model;
    final temperatureValue = temperature;
    final reasoning = reasoningMode;
    final versionValue = version;
    final urlValue = url;
    final headersValue = headers;
    final auth = authHeaders;
    final bedrockCredentials = credentials;
    return <String, dynamic>{
      'type': kind,
      'model': ?modelValue,
      'temperature': ?temperatureValue,
      'reasoning_mode': ?reasoning,
      'version': ?versionValue,
      'url': ?urlValue,
      'headers': ?headersValue,
      if (auth != null) 'auth': <String, dynamic>{'headers': auth},
      if (bedrockCredentials != null)
        'credentials': bedrockCredentials.toJson(),
    };
  }
}

/// AWS Bedrock credentials (STS short-lived or IAM long-lived).
class AgentBedrockCredentials {
  /// Creates a credentials object. [type] is `'sts'` or `'iam'`.
  const AgentBedrockCredentials({
    required this.type,
    required this.region,
    required this.accessKeyId,
    required this.secretAccessKey,
    this.sessionToken,
  });

  /// The credentials type: `'sts'` or `'iam'`.
  final String type;

  /// The AWS region (e.g. `'us-east-1'`).
  final String region;

  /// The AWS access key id.
  final String accessKeyId;

  /// The AWS secret access key.
  final String secretAccessKey;

  /// The AWS session token, required for STS only.
  final String? sessionToken;

  /// Serializes to the credentials object, omitting [sessionToken] when null.
  Map<String, dynamic> toJson() {
    final token = sessionToken;
    return <String, dynamic>{
      'type': type,
      'region': region,
      'access_key_id': accessKeyId,
      'secret_access_key': secretAccessKey,
      'session_token': ?token,
    };
  }
}

/// A function definition: client-side (executed by your application) or
/// server-side (executed by Deepgram against an HTTP endpoint).
class AgentFunctionDefinition {
  /// Creates a client-side function. The server delivers a
  /// `FunctionCallRequest` to your application, which replies with a
  /// `FunctionCallResponse`.
  const AgentFunctionDefinition.client({
    required this.name,
    required this.description,
    this.parameters,
    this.deferUntilEot = false,
  }) : url = null,
       method = null,
       headers = null,
       authorization = null,
       clientSide = true;

  /// Creates a server-side function. Deepgram calls [url] itself; the
  /// endpoint must be reachable when Settings are applied.
  const AgentFunctionDefinition.server({
    required this.name,
    required this.description,
    required this.url,
    this.method = 'POST',
    this.headers,
    this.authorization,
    this.parameters,
  }) : deferUntilEot = false,
       clientSide = false;

  /// The function name the LLM uses to call it.
  final String name;

  /// What the function does, shown to the LLM.
  final String description;

  /// JSON Schema object describing the parameters, sent as-is.
  final Map<String, dynamic>? parameters;

  /// The endpoint URL (server-side functions only).
  final String? url;

  /// The HTTP method used against [url] (server-side functions only).
  final String? method;

  /// Extra headers sent to [url] (server-side functions only).
  final Map<String, String>? headers;

  /// Authorization headers for [url], merged into `endpoint.headers` on the
  /// wire (server-side functions only). Use key names your endpoint expects,
  /// e.g. `{'authorization': 'Bearer {{token}}'}` with a stored agent
  /// variable.
  final Map<String, String>? authorization;

  /// Whether your application executes this function. Informational on the
  /// Dart side: on the wire, client-side vs server-side execution is
  /// determined by the presence of the `endpoint` object, so this flag is
  /// not serialized in the Settings message.
  final bool clientSide;

  /// When `true` (`defer_until_eot`), the call is held until the user's
  /// turn is confirmed instead of dispatching speculatively. Use it for
  /// actions that cannot be undone.
  final bool deferUntilEot;

  /// Serializes to a function definition object. Server-side functions
  /// carry an `endpoint` object; its presence (not a `client_side` flag) is
  /// what tells the server the function runs server-side, and authorization
  /// entries are merged into `endpoint.headers` per the documented wire
  /// shape:
  ///
  /// ```json
  /// {
  ///   "name": "check_order_status",
  ///   "description": "...",
  ///   "parameters": { ... },
  ///   "defer_until_eot": false,
  ///   "endpoint": {
  ///     "url": "https://api.example.com/orders/status",
  ///     "method": "post",
  ///     "headers": {"authorization": "Bearer {{token}}"}
  ///   }
  /// }
  /// ```
  Map<String, dynamic> toJson() {
    final schema = parameters;
    final endpointUrl = url;
    final endpointMethod = method;
    final endpointHeaders = headers;
    final auth = authorization;
    return <String, dynamic>{
      'name': name,
      'description': description,
      'defer_until_eot': deferUntilEot,
      'parameters': ?schema,
      if (endpointUrl != null)
        'endpoint': <String, dynamic>{
          'url': endpointUrl,
          'method': ?endpointMethod,
          if (endpointHeaders != null || auth != null)
            'headers': <String, String>{...?endpointHeaders, ...?auth},
        },
    };
  }
}

/// `agent.speak` — Deepgram text-to-speech configuration.
class AgentSpeak {
  /// Creates a speak block.
  const AgentSpeak({required this.provider});

  /// The Deepgram TTS provider (Aura on v1, Flux on v2).
  final AgentSpeakProvider provider;

  /// Serializes to the `speak` object: `{'provider': {...}}`.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider': provider.toJson(),
  };
}

/// The Deepgram speak (text-to-speech) provider.
///
/// Aura voices use the default version `v1` (e.g. `aura-2-thalia-en`); Flux
/// voices use version `v2` (e.g. `flux-kit-en`). Change `version` and `model`
/// together — each family is served only on its own version.
class AgentSpeakProvider {
  /// Creates a Deepgram TTS provider.
  const AgentSpeakProvider({
    required this.model,
    this.version = 'v1',
    this.speed,
    this.expressivity,
    this.language,
  });

  /// The TTS voice model, e.g. `aura-2-thalia-en` (v1) or `flux-kit-en` (v2).
  final String model;

  /// The Deepgram TTS model family: `'v1'` (Aura, the default) or `'v2'`
  /// (Flux TTS).
  final String version;

  /// Speaking rate multiplier. Aura: 0.7–1.5; Flux: 0.5–1.5 in 0.05 steps.
  final double? speed;

  /// Delivery register for Flux TTS (v2) only: whole numbers -2..2,
  /// defaulting to 0.
  final int? expressivity;

  /// Optional language setting. Deepgram voices carry their language in the
  /// model name and reject this field, so leave it `null` for Deepgram
  /// voices; it is emitted only when set.
  final String? language;

  /// Serializes to the speak provider object:
  /// `{'type': 'deepgram', 'version': ..., 'model': ..., 'speed'?: ...,
  /// 'expressivity'?: ..., 'language'?: ...}` with nulls omitted.
  Map<String, dynamic> toJson() {
    final speedValue = speed;
    final expressivityValue = expressivity;
    final languageValue = language;
    return <String, dynamic>{
      'type': 'deepgram',
      'version': version,
      'model': model,
      'speed': ?speedValue,
      'expressivity': ?expressivityValue,
      'language': ?languageValue,
    };
  }
}
