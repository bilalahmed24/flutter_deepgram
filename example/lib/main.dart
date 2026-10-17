/// Example app for the `flutter_deepgram` SDK.
///
/// This single-file demo exercises every major API surface of the package
/// across four tabs:
///
/// 1. **Prerecorded** — transcription of a public URL through
///    `POST /v1/listen` with smart formatting, diarization, entity
///    detection, sentiment, and summarization, plus plain-text analysis
///    through `POST /v1/read` (the text-intelligence endpoint).
/// 2. **Live STT** — a `/v1/listen` WebSocket session driven end to end:
///    connect, stream synthetic audio, finalize, close, with every typed
///    event stream (results, utterance ends, speech started, metadata,
///    errors, connection states) wired into the UI.
/// 3. **Text to Speech** — `POST /v1/speak` (Aura / Aura-2 voices) and
///    `POST /v2/speak` (Flux batch), returning complete audio bytes.
/// 4. **Voice Agent** — a `/v1/agent/converse` session built from a typed
///    VoiceAgentSettings object, with conversation bubbles, agent
///    thinking/speaking status, and automatic client-side function-call
///    responses.
///
/// The app deliberately avoids microphone and speaker plugins: tabs 2 and 4
/// stream synthetic silence so the streaming-session mechanics can be
/// demonstrated on any platform (including the web) without audio
/// permissions or native builds.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_deepgram/flutter_deepgram.dart';
import 'package:flutter/material.dart';

/// API key fallback supplied at launch time via
/// `flutter run --dart-define=DEEPGRAM_API_KEY=your_key`.
const String kApiKey = String.fromEnvironment('DEEPGRAM_API_KEY');

void main() {
  runApp(const DeepgramDemoApp());
}

/// Root of the demo application.
class DeepgramDemoApp extends StatelessWidget {
  /// Creates the app shell.
  const DeepgramDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_deepgram demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple,
      ),
      home: const DemoHome(),
    );
  }
}

/// Holds the shared [DeepgramClient] and hosts the four demo tabs.
///
/// Every tab receives a `clientGetter` closure (a tear-off of
/// [_DemoHomeState._client]) so it always reads the current client at
/// button-press time; the shared API-key field and the "Initialize client"
/// button live in the header above the tab views.
class DemoHome extends StatefulWidget {
  /// Creates the demo home screen.
  const DemoHome({super.key});

  @override
  State<DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends State<DemoHome> {
  late final TextEditingController _keyController = TextEditingController(
    text: kApiKey,
  );

  /// The shared SDK client, created by the "Initialize client" button.
  DeepgramClient? _deepgram;

  /// The four tab bodies. Built once so their StatefulWidget states (and any
  /// running streaming sessions) survive key-bar rebuilds.
  late final List<Widget> _tabs = <Widget>[
    _PrerecordedTab(clientGetter: _client),
    _LiveTab(clientGetter: _client),
    _TtsTab(clientGetter: _client),
    _AgentTab(clientGetter: _client),
  ];

  @override
  void dispose() {
    _keyController.dispose();
    _deepgram?.close();
    super.dispose();
  }

  /// Callback handed to every tab: returns the current shared client.
  DeepgramClient? _client() => _deepgram;

  /// Builds the shared client from the key field.
  Future<void> _initializeClient() async {
    final String key = _keyController.text.trim();
    if (key.isEmpty) {
      _showSnackBar(
        context,
        'Enter a Deepgram API key first (or relaunch with '
        '--dart-define=DEEPGRAM_API_KEY=your_key).',
        isError: true,
      );
      return;
    }
    final DeepgramClient? previous = _deepgram;
    if (previous != null) {
      // Closing the old client retires its HTTP engine; running sessions
      // created from it are unaffected (they own their sockets).
      previous.close();
    }
    try {
      final DeepgramClient client = DeepgramClient(apiKey: key);
      setState(() => _deepgram = client);
      _showSnackBar(context, 'DeepgramClient initialized.');
    } catch (error) {
      _showSnackBar(context, 'Initialization failed: $error', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool ready = _deepgram != null;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('flutter_deepgram demo'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: <Widget>[
              Tab(text: 'Prerecorded'),
              Tab(text: 'Live STT'),
              Tab(text: 'Text to Speech'),
              Tab(text: 'Voice Agent'),
            ],
          ),
        ),
        body: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    controller: _keyController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      labelText: 'Deepgram API key',
                      helperText:
                          'Or launch with --dart-define=DEEPGRAM_API_KEY=your_key',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      FilledButton.icon(
                        onPressed: _initializeClient,
                        icon: const Icon(Icons.vpn_key_outlined),
                        label: const Text('Initialize client'),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        ready ? Icons.check_circle : Icons.radio_button_off,
                        size: 14,
                        color: ready ? Colors.green : Colors.grey,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          ready
                              ? 'Client ready — all tabs share this client.'
                              : 'No client yet — initialize before using the tabs.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(child: TabBarView(children: _tabs)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 1 — Prerecorded transcription + text intelligence
// ─────────────────────────────────────────────────────────────────────────────

/// Demonstrates `deepgram.prerecorded.transcribeFromUrl` and
/// `deepgram.intelligence.analyze`.
class _PrerecordedTab extends StatefulWidget {
  /// Creates the prerecorded demo tab.
  const _PrerecordedTab({required this.clientGetter});

  /// Returns the shared client created in the header.
  final DeepgramClient? Function() clientGetter;

  @override
  State<_PrerecordedTab> createState() => _PrerecordedTabState();
}

class _PrerecordedTabState extends State<_PrerecordedTab>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _urlController = TextEditingController(
    text:
        'https://static.deepgram.com/examples/Bueller-Life-moves-pretty-fast.wav',
  );

  final TextEditingController _readController = TextEditingController(
    text: "Deepgram's new Dart SDK is a joy to use. The live transcription is "
        'fast and accurate, and the support team is responsive. We plan to '
        'ship it in our customer support product next week.',
  );

  bool _smartFormat = true;
  bool _diarize = true;
  bool _detectEntities = true;
  bool _sentiment = true;
  bool _summarize = true;
  bool _loading = false;
  bool _reading = false;

  PrerecordedTranscriptionResult? _result;
  TextIntelligenceResult? _readResult;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _urlController.dispose();
    _readController.dispose();
    super.dispose();
  }

  /// First alternative of the first channel, or null.
  SttAlternative? get _firstAlternative {
    final PrerecordedTranscriptionResult? result = _result;
    if (result == null || result.channels.isEmpty) {
      return null;
    }
    final List<SttAlternative> alternatives =
        result.channels.first.alternatives;
    return alternatives.isEmpty ? null : alternatives.first;
  }

  String get _transcript => _firstAlternative?.transcript ?? '';

  List<SttEntity> get _entities =>
      _firstAlternative?.entities ?? const <SttEntity>[];

  List<SttSentiment> get _sentiments =>
      _firstAlternative?.sentiments ??
      _result?.sentiments ??
      const <SttSentiment>[];

  List<String> get _summaries {
    final PrerecordedTranscriptionResult? result = _result;
    if (result == null) {
      return const <String>[];
    }
    final String? top = result.summary;
    final List<SttSummary>? fromAlternative = _firstAlternative?.summaries;
    return <String>[
      if (top != null && top.isNotEmpty) top,
      if (fromAlternative != null)
        for (final SttSummary summary in fromAlternative) summary.summary,
    ];
  }

  /// Transcribes the URL with the toggled features.
  Future<void> _transcribe() async {
    final DeepgramClient? deepgram = widget.clientGetter();
    if (deepgram == null) {
      _showSnackBar(
        context,
        'Initialize the client in the header first.',
        isError: true,
      );
      return;
    }
    final String url = _urlController.text.trim();
    if (url.isEmpty) {
      _showSnackBar(context, 'Enter an audio URL first.', isError: true);
      return;
    }
    setState(() => _loading = true);
    try {
      final PrerecordedTranscriptionResult result =
          await deepgram.prerecorded.transcribeFromUrl(
        url,
        options: PrerecordedOptions(
          model: DeepgramSttModels.nova3,
          smartFormat: _smartFormat,
          diarize: _diarize,
          detectEntities: _detectEntities,
          sentiment: _sentiment,
          summarize: _summarize
              ? const SummarizeOptions(v2: true, mode: SummarizeMode.paragraphs)
              : null,
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() => _result = result);
    } catch (error) {
      if (mounted) {
        _showSnackBar(
          context,
          'Transcription failed: $error',
          isError: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  /// Runs the /v1/read text-intelligence analysis.
  Future<void> _analyze() async {
    final DeepgramClient? deepgram = widget.clientGetter();
    if (deepgram == null) {
      _showSnackBar(
        context,
        'Initialize the client in the header first.',
        isError: true,
      );
      return;
    }
    final String text = _readController.text.trim();
    if (text.isEmpty) {
      _showSnackBar(context, 'Enter some text to analyze.', isError: true);
      return;
    }
    setState(() => _reading = true);
    try {
      final TextIntelligenceResult result = await deepgram.intelligence.analyze(
        text,
        options: const TextIntelligenceOptions(
          sentiment: true,
          topics: true,
          summarize: true,
          intents: true,
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() => _readResult = result);
    } catch (error) {
      if (mounted) {
        _showSnackBar(context, 'Analysis failed: $error', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _reading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final TextStyle? labelStyle = Theme.of(context).textTheme.labelSmall;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        _SectionHeader('Transcribe audio from a URL (POST /v1/listen)'),
        TextField(
          controller: _urlController,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Audio URL',
            helperText: 'Deepgram fetches the media for you.',
          ),
        ),
        const SizedBox(height: 4),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              SwitchListTile(
                dense: true,
                title: const Text('smart_format'),
                subtitle: const Text('Punctuation, capitalization, numbers.'),
                value: _smartFormat,
                onChanged: (bool value) => setState(() => _smartFormat = value),
              ),
              SwitchListTile(
                dense: true,
                title: const Text('diarize'),
                subtitle: const Text('Recognize speaker changes.'),
                value: _diarize,
                onChanged: (bool value) => setState(() => _diarize = value),
              ),
              SwitchListTile(
                dense: true,
                title: const Text('detect_entities'),
                subtitle:
                    const Text('Extract labeled values (people, places…).'),
                value: _detectEntities,
                onChanged: (bool value) =>
                    setState(() => _detectEntities = value),
              ),
              SwitchListTile(
                dense: true,
                title: const Text('sentiment'),
                subtitle: const Text('Sentiment per segment.'),
                value: _sentiment,
                onChanged: (bool value) => setState(() => _sentiment = value),
              ),
              SwitchListTile(
                dense: true,
                title: const Text('summarize'),
                subtitle: const Text('v2 summarizer, paragraph mode.'),
                value: _summarize,
                onChanged: (bool value) => setState(() => _summarize = value),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _loading ? null : _transcribe,
          icon: const Icon(Icons.record_voice_over),
          label: const Text('Transcribe'),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(minHeight: 3),
          ),
        ..._resultCards(labelStyle),
        _SectionHeader('Analyze text (POST /v1/read)'),
        TextField(
          controller: _readController,
          maxLines: 5,
          minLines: 3,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Text to analyze',
            helperText: 'sentiment, topics, summarize, intents.',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _reading ? null : _analyze,
          icon: const Icon(Icons.psychology),
          label: const Text('Analyze text'),
        ),
        if (_reading)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(minHeight: 3),
          ),
        ..._readCards(labelStyle),
      ],
    );
  }

  /// Cards rendering the prerecorded transcription result.
  List<Widget> _resultCards(TextStyle? labelStyle) {
    final PrerecordedTranscriptionResult? result = _result;
    if (result == null) {
      return const <Widget>[];
    }
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;
    return <Widget>[
      _SectionHeader('Transcription result'),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Transcript', style: labelStyle),
              const SizedBox(height: 4),
              SelectableText(
                _transcript.isEmpty ? '(empty)' : _transcript,
              ),
              const SizedBox(height: 4),
              Text(
                'duration ${result.metadata.duration?.toStringAsFixed(1) ?? '?'} s'
                ' · request ${result.metadata.requestId ?? 'n/a'}',
                style: small,
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Detected entities (label: value)', style: labelStyle),
              const SizedBox(height: 6),
              if (_entities.isEmpty)
                const Text('None detected.')
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final SttEntity entity in _entities)
                      Chip(label: Text('${entity.label}: ${entity.value}')),
                  ],
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Sentiment per segment', style: labelStyle),
              if (_sentiments.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('None detected.'),
                )
              else
                for (final SttSentiment sentiment in _sentiments)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: _sentimentIcon(sentiment.sentiment),
                    title: Text(
                      sentiment.text.isEmpty ? '(no text)' : sentiment.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(
                      '${sentiment.sentiment} '
                      '${sentiment.sentimentScore?.toStringAsFixed(2) ?? ''}',
                      style: small,
                    ),
                  ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Summary', style: labelStyle),
              if (_summaries.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('None returned.'),
                )
              else
                for (final String summary in _summaries)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SelectableText(summary),
                  ),
            ],
          ),
        ),
      ),
    ];
  }

  /// Cards rendering the /v1/read analysis result.
  List<Widget> _readCards(TextStyle? labelStyle) {
    final TextIntelligenceResult? result = _readResult;
    if (result == null) {
      return const <Widget>[];
    }
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;
    return <Widget>[
      _SectionHeader('Text intelligence result'),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Average sentiment', style: labelStyle),
              const SizedBox(height: 4),
              Text(
                '${result.averageSentiment ?? 'n/a'} '
                '(${result.averageSentimentScore?.toStringAsFixed(2) ?? '—'})',
              ),
              const SizedBox(height: 8),
              Text('Sentiment segments', style: labelStyle),
              for (final TextSentiment sentiment in result.sentiments)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: _sentimentIcon(sentiment.sentiment),
                  title: Text(
                    sentiment.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    '${sentiment.sentiment} '
                    '${sentiment.sentimentScore?.toStringAsFixed(2) ?? ''}',
                    style: small,
                  ),
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Topics', style: labelStyle),
              const SizedBox(height: 6),
              if (result.topics.isEmpty)
                const Text('None detected.')
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final TextTopic topic in result.topics)
                      Chip(
                        label: Text(
                          topic.confidenceScore == null
                              ? topic.topic
                              : '${topic.topic} '
                                  '(${topic.confidenceScore!.toStringAsFixed(2)})',
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              Text('Intents', style: labelStyle),
              const SizedBox(height: 6),
              if (result.intents.isEmpty)
                const Text('None detected.')
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final TextIntent intent in result.intents)
                      Chip(
                        label: Text(
                          intent.confidenceScore == null
                              ? intent.intent
                              : '${intent.intent} '
                                  '(${intent.confidenceScore!.toStringAsFixed(2)})',
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Summary', style: labelStyle),
              if (result.summaries.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('None returned.'),
                )
              else
                for (final TextSummary summary in result.summaries)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SelectableText(summary.summary),
                  ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _sentimentIcon(String sentiment) {
    switch (sentiment) {
      case 'positive':
        return const Icon(Icons.sentiment_satisfied, color: Colors.green);
      case 'negative':
        return const Icon(Icons.sentiment_dissatisfied, color: Colors.red);
      default:
        return const Icon(Icons.sentiment_neutral, color: Colors.blueGrey);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 2 — Live streaming transcription
// ─────────────────────────────────────────────────────────────────────────────

/// Demonstrates a full `DeepgramLiveClient` session lifecycle with synthetic
/// audio, so no microphone plugin is needed.
class _LiveTab extends StatefulWidget {
  /// Creates the live transcription demo tab.
  const _LiveTab({required this.clientGetter});

  /// Returns the shared client created in the header.
  final DeepgramClient? Function() clientGetter;

  @override
  State<_LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends State<_LiveTab> with AutomaticKeepAliveClientMixin {
  DeepgramLiveClient? _live;
  WsConnectionState _state = WsConnectionState.idle;
  String _finalTranscript = '';
  String _interim = '';
  int _sentBytes = 0;
  bool _sending = false;
  final List<String> _events = <String>[];
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  bool get _isRunning => _live != null;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _cancelSubscriptions();
    final DeepgramLiveClient? live = _live;
    if (live != null) {
      unawaited(live.close());
    }
    super.dispose();
  }

  void _cancelSubscriptions() {
    for (final StreamSubscription<dynamic> sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
  }

  /// Prepends a timestamped entry to the in-app event log.
  void _log(String message) {
    if (!mounted) {
      return;
    }
    final DateTime now = DateTime.now();
    final String stamp = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    setState(() {
      _events.insert(0, '$stamp  $message');
      if (_events.length > 200) {
        _events.removeLast();
      }
    });
  }

  /// Connects a new live session and wires every typed event stream.
  Future<void> _startSession() async {
    final DeepgramClient? deepgram = widget.clientGetter();
    if (deepgram == null) {
      _showSnackBar(
        context,
        'Initialize the client in the header first.',
        isError: true,
      );
      return;
    }
    if (_live != null) {
      _showSnackBar(
        context,
        'A session is already running — stop it first.',
        isError: true,
      );
      return;
    }
    setState(() => _state = WsConnectionState.connecting);
    final DeepgramLiveClient live;
    try {
      live = deepgram.createLiveClient(
        options: const LiveTranscriptionOptions(
          model: 'nova-3',
          encoding: LiveEncoding.linear16,
          sampleRate: 16000,
          interimResults: true,
          smartFormat: true,
          punctuate: true,
          vadEvents: true,
          utteranceEndMs: 1000,
          endpointingMs: 300,
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _state = WsConnectionState.idle);
      _showSnackBar(
        context,
        'Could not create the live client: $error',
        isError: true,
      );
      return;
    }
    _wire(live);
    setState(() => _live = live);
    try {
      await live.start();
      _log('Session started: nova-3, linear16 @ 16 kHz, vad_events on.');
    } catch (error) {
      try {
        await live.close();
      } catch (_) {
        // The session never fully opened; ignore teardown errors.
      }
      _cancelSubscriptions();
      if (!mounted) {
        return;
      }
      setState(() {
        _live = null;
        _state = WsConnectionState.failed;
      });
      _showSnackBar(
        context,
        'Live session failed to start: $error',
        isError: true,
      );
    }
  }

  void _wire(DeepgramLiveClient live) {
    _subs.add(
      live.connectionStates.listen((WsConnectionState state) {
        if (mounted) {
          setState(() => _state = state);
        }
      }),
    );
    _subs.add(
      live.results.listen((LiveTranscriptionResult result) {
        if (!mounted) {
          return;
        }
        setState(() {
          if (result.isFinal) {
            if (result.transcript.isNotEmpty) {
              if (_finalTranscript.isNotEmpty) {
                _finalTranscript += ' ';
              }
              _finalTranscript += result.transcript;
            }
            _interim = '';
          } else {
            _interim = result.transcript;
          }
        });
      }),
    );
    _subs.add(
      live.speechStarted.listen((LiveSpeechStarted event) {
        _log('SpeechStarted @ ${event.timestamp}s '
            '(channel ${event.channel.join(', ')}).');
      }),
    );
    _subs.add(
      live.utteranceEnds.listen((LiveUtteranceEnd event) {
        _log('UtteranceEnd — last word ended at ${event.lastWordEnd}s.');
      }),
    );
    _subs.add(
      live.metadata.listen((LiveMetadataMessage event) {
        _log('Metadata: request ${event.requestId}, ${event.duration}s '
            'across ${event.channels} channel(s).');
      }),
    );
    _subs.add(
      live.errors.listen((LiveErrorMessage event) {
        _log('Error (${event.variant}): ${event.description}');
      }),
    );
  }

  /// Streams 50 chunks of 100 ms silence (3200 zero bytes each, i.e. 16 kHz
  /// 16-bit mono) to demonstrate `sendAudio` pacing without a microphone.
  Future<void> _sendSyntheticAudio() async {
    final DeepgramLiveClient? live = _live;
    if (live == null) {
      _showSnackBar(context, 'Start the session first.', isError: true);
      return;
    }
    if (!live.isConnected) {
      _showSnackBar(context, 'The socket is not open yet.', isError: true);
      return;
    }
    setState(() => _sending = true);
    try {
      final List<int> chunk = List<int>.filled(3200, 0);
      for (var i = 0; i < 50; i++) {
        live.sendAudio(chunk);
        if (mounted) {
          setState(() => _sentBytes += chunk.length);
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _log('Streamed 50 × 3200 bytes (≈5 s of synthetic silence).');
    } catch (error) {
      if (mounted) {
        _showSnackBar(context, 'Sending failed: $error', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  /// Flushes pending results without closing the stream.
  Future<void> _finalize() async {
    final DeepgramLiveClient? live = _live;
    if (live == null) {
      return;
    }
    try {
      await live.finish();
      _log('Sent Finalize — pending results flush without closing.');
    } catch (error) {
      if (mounted) {
        _showSnackBar(context, 'Finalize failed: $error', isError: true);
      }
    }
  }

  /// Gracefully closes the session.
  Future<void> _stopSession() async {
    final DeepgramLiveClient? live = _live;
    if (live == null) {
      return;
    }
    try {
      await live.close();
      _log('Session closed.');
    } catch (error) {
      if (mounted) {
        _showSnackBar(context, 'Close failed: $error', isError: true);
      }
    } finally {
      _cancelSubscriptions();
      if (mounted) {
        setState(() {
          _live = null;
          _state = WsConnectionState.closed;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        _SectionHeader('Live transcription (WSS /v1/listen)'),
        Row(
          children: <Widget>[
            _StatusChip(_state),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${_formatBytes(_sentBytes)} sent · '
                'reconnect attempts: ${_live?.reconnectAttempts ?? 0}',
                style: small,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.icon(
              onPressed: _isRunning || _sending ? null : _startSession,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start'),
            ),
            OutlinedButton.icon(
              onPressed: !_isRunning || _sending ? null : _sendSyntheticAudio,
              icon: const Icon(Icons.graphic_eq),
              label: const Text('Send synthetic audio'),
            ),
            OutlinedButton.icon(
              onPressed: !_isRunning ? null : _finalize,
              icon: const Icon(Icons.done_all),
              label: const Text('Finalize'),
            ),
            OutlinedButton.icon(
              onPressed: !_isRunning ? null : _stopSession,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
          ],
        ),
        _NoteText(
          'No microphone plugin is used: "Send synthetic audio" streams 50 '
          'chunks of 100 ms zeroed linear16 samples through sendAudio(). '
          'Swap in real PCM from your audio stack for production use.',
        ),
        _SectionHeader('Transcript'),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SelectableText(
                  _finalTranscript.isEmpty
                      ? '(no final results yet)'
                      : _finalTranscript,
                ),
                const SizedBox(height: 4),
                Text(
                  _interim,
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Colors.blueGrey.shade600,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _SectionHeader('Events (UtteranceEnd / SpeechStarted / Metadata …)'),
        _EventLog(entries: _events),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 3 — Text to speech
// ─────────────────────────────────────────────────────────────────────────────

/// Demonstrates `deepgram.tts.speak` (Aura / Aura-2) and
/// `deepgram.tts.speakFlux` (Flux batch).
class _TtsTab extends StatefulWidget {
  /// Creates the text-to-speech demo tab.
  const _TtsTab({required this.clientGetter});

  /// Returns the shared client created in the header.
  final DeepgramClient? Function() clientGetter;

  @override
  State<_TtsTab> createState() => _TtsTabState();
}

class _TtsTabState extends State<_TtsTab> with AutomaticKeepAliveClientMixin {
  final TextEditingController _textController = TextEditingController(
    text: 'Hello! This audio was synthesized by the flutter_deepgram SDK.',
  );

  String _voice = DeepgramVoices.auraAsteriaEn;
  TtsEncoding _encoding = TtsEncoding.linear16;
  bool _speaking = false;
  bool _speakingFlux = false;
  String? _speakSummary;
  String? _fluxSummary;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  /// Requests Aura / Aura-2 audio and reports byte count and latency.
  Future<void> _speak() async {
    final DeepgramClient? deepgram = widget.clientGetter();
    if (deepgram == null) {
      _showSnackBar(
        context,
        'Initialize the client in the header first.',
        isError: true,
      );
      return;
    }
    final String text = _textController.text.trim();
    if (text.isEmpty) {
      _showSnackBar(context, 'Enter some text first.', isError: true);
      return;
    }
    setState(() => _speaking = true);
    final Stopwatch watch = Stopwatch()..start();
    try {
      final List<int> bytes = await deepgram.tts.speak(
        text,
        options: SpeakOptions(
          model: _voice,
          encoding: _encoding,
          container: TtsContainer.wav,
          sampleRate: 24000,
        ),
      );
      watch.stop();
      if (!mounted) {
        return;
      }
      setState(() {
        _speakSummary = 'Received ${_formatBytes(bytes.length)} of '
            '${_encoding.wireName}/wav audio in ${watch.elapsedMilliseconds} '
            'ms — the bytes are ready for an audio player.';
      });
    } catch (error) {
      if (mounted) {
        _showSnackBar(context, 'TTS failed: $error', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _speaking = false);
      }
    }
  }

  /// Requests Flux TTS audio through the /v2/speak batch endpoint.
  Future<void> _speakFlux() async {
    final DeepgramClient? deepgram = widget.clientGetter();
    if (deepgram == null) {
      _showSnackBar(
        context,
        'Initialize the client in the header first.',
        isError: true,
      );
      return;
    }
    final String text = _textController.text.trim();
    if (text.isEmpty) {
      _showSnackBar(context, 'Enter some text first.', isError: true);
      return;
    }
    setState(() => _speakingFlux = true);
    final Stopwatch watch = Stopwatch()..start();
    try {
      final List<int> bytes = await deepgram.tts.speakFlux(
        text,
        options: const FluxTtsOptions(
          model: DeepgramVoices.fluxAlexisEn,
          expressivity: 1,
        ),
      );
      watch.stop();
      if (!mounted) {
        return;
      }
      setState(() {
        _fluxSummary = 'Received ${_formatBytes(bytes.length)} of Flux audio '
            'in ${watch.elapsedMilliseconds} ms — ready for an audio player.';
      });
    } catch (error) {
      if (mounted) {
        _showSnackBar(context, 'Flux TTS failed: $error', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _speakingFlux = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        _SectionHeader('Aura / Aura-2 voices (POST /v1/speak)'),
        TextField(
          controller: _textController,
          maxLines: 3,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Text to speak',
            helperText: 'Up to 2000 characters per request.',
          ),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _voice,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Voice (first 20 of '
                      '${DeepgramVoices.allV1.length} /v1/speak voices)',
                ),
                items: <DropdownMenuItem<String>>[
                  for (final String voice in DeepgramVoices.allV1.take(20))
                    DropdownMenuItem<String>(
                      value: voice,
                      child: Text(
                        voice,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (String? value) {
                  if (value != null) {
                    setState(() => _voice = value);
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<TtsEncoding>(
                initialValue: _encoding,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Encoding (wav container)',
                ),
                items: const <DropdownMenuItem<TtsEncoding>>[
                  DropdownMenuItem<TtsEncoding>(
                    value: TtsEncoding.linear16,
                    child: Text('linear16'),
                  ),
                  DropdownMenuItem<TtsEncoding>(
                    value: TtsEncoding.mulaw,
                    child: Text('mulaw'),
                  ),
                ],
                onChanged: (TtsEncoding? value) {
                  if (value != null) {
                    setState(() => _encoding = value);
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _speaking ? null : _speak,
          icon: const Icon(Icons.volume_up),
          label: const Text('Speak (container=wav, 24 kHz)'),
        ),
        if (_speaking)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(minHeight: 3),
          ),
        if (_speakSummary != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_speakSummary!),
          ),
        _NoteText(
          'speak() returns the complete audio as a List<int> (a WAV file in '
          'this configuration). Hand the bytes to an audio player such as '
          'just_audio, or write them to disk with dart:io on non-web '
          'platforms. The SDK also offers speakStream() for progressive '
          'playback and createTtsStreamClient() for the WebSocket endpoint.',
        ),
        _SectionHeader('Flux TTS, batch (POST /v2/speak)'),
        OutlinedButton.icon(
          onPressed: _speakingFlux ? null : _speakFlux,
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Speak with flux-alexis-en (expressivity 1)'),
        ),
        if (_speakingFlux)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(minHeight: 3),
          ),
        if (_fluxSummary != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_fluxSummary!),
          ),
        _NoteText(
          'FluxTtsOptions(model: DeepgramVoices.fluxAlexisEn, expressivity: 1) '
          'hits the turn-based /v2/speak batch endpoint. For streaming Flux '
          'TTS with barge-in interrupts, use createFluxTtsClient().',
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 4 — Voice agent
// ─────────────────────────────────────────────────────────────────────────────

/// Demonstrates a full Voice Agent session built from a typed
/// VoiceAgentSettings object, with automatic client-side function-call
/// responses and synthetic audio.
class _AgentTab extends StatefulWidget {
  /// Creates the voice agent demo tab.
  const _AgentTab({required this.clientGetter});

  /// Returns the shared client created in the header.
  final DeepgramClient? Function() clientGetter;

  @override
  State<_AgentTab> createState() => _AgentTabState();
}

class _AgentTabState extends State<_AgentTab>
    with AutomaticKeepAliveClientMixin {
  DeepgramVoiceAgent? _agent;
  WsConnectionState _state = WsConnectionState.idle;
  final List<AgentConversationText> _messages = <AgentConversationText>[];
  final List<String> _events = <String>[];
  String _status = 'Idle — start a session to begin.';
  int _audioBytes = 0;
  int _sentBytes = 0;
  bool _sending = false;
  final ScrollController _chatScroll = ScrollController();
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  /// Pretty-printed JSON of the settings sent to the agent.
  late final String _settingsJson =
      const JsonEncoder.withIndent('  ').convert(_buildSettings().toJson());

  bool get _isRunning => _agent != null;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _cancelSubscriptions();
    final DeepgramVoiceAgent? agent = _agent;
    if (agent != null) {
      unawaited(agent.close());
    }
    _chatScroll.dispose();
    super.dispose();
  }

  void _cancelSubscriptions() {
    for (final StreamSubscription<dynamic> sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
  }

  /// The typed Settings object sent right after the server's Welcome frame.
  VoiceAgentSettings _buildSettings() {
    return VoiceAgentSettings(
      agent: AgentAgentSettings(
        greeting: 'Hello! I am your Deepgram voice agent.',
        listen: const AgentListen(
          provider: AgentListenProvider.v1(model: 'nova-3', language: 'en-US'),
        ),
        think: AgentThink(
          provider: AgentThinkProvider.openAi(model: 'gpt-4o-mini'),
          prompt: 'You are a friendly, concise weather assistant. Keep every '
              'answer under three sentences. When asked about the weather, '
              'call the get_weather function and report its result.',
          functions: const <AgentFunctionDefinition>[
            AgentFunctionDefinition.client(
              name: 'get_weather',
              description: 'Returns the current weather for a city.',
              parameters: <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{
                  'city': <String, dynamic>{
                    'type': 'string',
                    'description': 'The city to get the weather for.',
                  },
                },
                'required': <String>['city'],
              },
            ),
          ],
        ),
        speak: const AgentSpeak(
          provider: AgentSpeakProvider(model: 'aura-2-thalia-en'),
        ),
      ),
      audio: const AgentAudioSettings(
        input: AgentAudioInput(
          encoding: AgentAudioEncoding.linear16,
          sampleRate: 24000,
        ),
        output: AgentAudioOutput(
          encoding: AgentAudioOutputEncoding.linear16,
          sampleRate: 24000,
          container: AgentAudioOutputContainer.none,
        ),
      ),
    );
  }

  /// Prepends a timestamped entry to the in-app event log.
  void _log(String message) {
    if (!mounted) {
      return;
    }
    final DateTime now = DateTime.now();
    final String stamp = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    setState(() {
      _events.insert(0, '$stamp  $message');
      if (_events.length > 200) {
        _events.removeLast();
      }
    });
  }

  /// Connects the agent, sends the Settings, and wires every typed stream.
  Future<void> _startAgent() async {
    final DeepgramClient? deepgram = widget.clientGetter();
    if (deepgram == null) {
      _showSnackBar(
        context,
        'Initialize the client in the header first.',
        isError: true,
      );
      return;
    }
    if (_agent != null) {
      _showSnackBar(
        context,
        'An agent session is already running — stop it first.',
        isError: true,
      );
      return;
    }
    setState(() {
      _state = WsConnectionState.connecting;
      _status = 'Connecting and negotiating Settings…';
    });
    final DeepgramVoiceAgent agent;
    try {
      agent = deepgram.createVoiceAgent();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _state = WsConnectionState.idle;
        _status = 'Idle — start a session to begin.';
      });
      _showSnackBar(
        context,
        'Could not create the voice agent: $error',
        isError: true,
      );
      return;
    }
    _wire(agent);
    setState(() => _agent = agent);
    try {
      await agent.start(_buildSettings());
      _log('Agent session established (SettingsApplied received).');
      if (mounted) {
        setState(() => _status = 'Session ready — the greeting is speaking.');
      }
    } catch (error) {
      try {
        await agent.close();
      } catch (_) {
        // The session never fully opened; ignore teardown errors.
      }
      _cancelSubscriptions();
      if (!mounted) {
        return;
      }
      setState(() {
        _agent = null;
        _state = WsConnectionState.failed;
        _status = 'Start failed.';
      });
      _showSnackBar(
        context,
        'Agent failed to start: $error',
        isError: true,
      );
    }
  }

  void _wire(DeepgramVoiceAgent agent) {
    _subs.add(
      agent.connectionStates.listen((WsConnectionState state) {
        if (mounted) {
          setState(() => _state = state);
        }
      }),
    );
    _subs.add(
      agent.welcome.listen((AgentWelcome event) {
        _log('Welcome: request ${event.requestId}.');
      }),
    );
    _subs.add(
      agent.settingsApplied.listen((_) {
        _log('SettingsApplied — the server accepted the configuration.');
      }),
    );
    _subs.add(
      agent.conversationText.listen((AgentConversationText event) {
        if (!mounted) {
          return;
        }
        setState(() {
          if (_messages.isNotEmpty && _messages.last.role == event.role) {
            final AgentConversationText last = _messages.removeLast();
            final String merged = last.content.isEmpty
                ? event.content
                : '${last.content} ${event.content}'.trim();
            _messages.add(
              AgentConversationText(role: event.role, content: merged),
            );
          } else {
            _messages.add(event);
          }
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_chatScroll.hasClients) {
            _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent);
          }
        });
      }),
    );
    _subs.add(
      agent.userStartedSpeaking.listen((_) {
        _log('UserStartedSpeaking — barge-in; mute agent playback.');
      }),
    );
    _subs.add(
      agent.agentThinking.listen((AgentAgentThinking event) {
        if (mounted) {
          setState(
            () => _status = 'Agent thinking: ${_truncate(event.content, 120)}',
          );
        }
      }),
    );
    _subs.add(
      agent.agentStartedSpeaking.listen((AgentAgentStartedSpeaking event) {
        if (mounted) {
          setState(
            () => _status = 'Agent speaking (total ${event.totalLatency}s · '
                'tts ${event.ttsLatency}s · ttt ${event.tttLatency}s).',
          );
        }
      }),
    );
    _subs.add(
      agent.agentAudioDone.listen((_) {
        if (mounted) {
          setState(() => _status = 'Agent finished speaking.');
        }
      }),
    );
    _subs.add(
      agent.audio.listen((List<int> bytes) {
        if (mounted) {
          setState(() => _audioBytes += bytes.length);
        }
      }),
    );
    _subs.add(
      agent.functionCallRequests.listen((AgentFunctionCallRequest request) {
        for (final AgentRequestedFunction function in request.functions) {
          _log('FunctionCallRequest: ${function.name}(${function.arguments}) '
              '[id ${function.id}, client_side ${function.clientSide}].');
          const String cannedResponse = '{"temperature": 72, "unit": "F"}';
          agent.sendFunctionCallResponse(
            id: function.id,
            name: function.name,
            content: cannedResponse,
          );
          _log('Sent canned $cannedResponse back for ${function.name}.');
        }
      }),
    );
    _subs.add(
      agent.errors.listen((AgentErrorEvent event) {
        _log('Error (${event.code}): ${event.description}');
      }),
    );
    _subs.add(
      agent.warnings.listen((AgentWarningEvent event) {
        _log('Warning (${event.code}): ${event.description}');
      }),
    );
  }

  /// Streams 50 chunks of 100 ms silence (4800 zero bytes each, i.e. 24 kHz
  /// 16-bit mono, matching the configured audio.input).
  Future<void> _sendSyntheticAudio() async {
    final DeepgramVoiceAgent? agent = _agent;
    if (agent == null) {
      _showSnackBar(context, 'Start the agent first.', isError: true);
      return;
    }
    if (!agent.isConnected) {
      _showSnackBar(context, 'The socket is not open yet.', isError: true);
      return;
    }
    setState(() => _sending = true);
    try {
      final List<int> chunk = List<int>.filled(4800, 0);
      for (var i = 0; i < 50; i++) {
        agent.sendAudio(chunk);
        if (mounted) {
          setState(() => _sentBytes += chunk.length);
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _log('Streamed 50 × 4800 bytes (≈5 s of synthetic silence).');
    } catch (error) {
      if (mounted) {
        _showSnackBar(context, 'Sending failed: $error', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  /// Gracefully closes the agent session.
  Future<void> _stopAgent() async {
    final DeepgramVoiceAgent? agent = _agent;
    if (agent == null) {
      return;
    }
    try {
      await agent.close();
      _log('Agent session closed.');
    } catch (error) {
      if (mounted) {
        _showSnackBar(context, 'Close failed: $error', isError: true);
      }
    } finally {
      _cancelSubscriptions();
      if (mounted) {
        setState(() {
          _agent = null;
          _state = WsConnectionState.closed;
          _status = 'Session closed.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        _SectionHeader('Voice agent (WSS /v1/agent/converse)'),
        Row(
          children: <Widget>[
            _StatusChip(_state),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${_formatBytes(_sentBytes)} sent · '
                '${_formatBytes(_audioBytes)} agent audio received',
                style: small,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.icon(
              onPressed: _isRunning ? null : _startAgent,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start'),
            ),
            OutlinedButton.icon(
              onPressed: !_isRunning || _sending ? null : _sendSyntheticAudio,
              icon: const Icon(Icons.graphic_eq),
              label: const Text('Send synthetic audio'),
            ),
            OutlinedButton.icon(
              onPressed: !_isRunning ? null : _stopAgent,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
          ],
        ),
        _NoteText(
          'Uses the API key from the field at the top of the app. The think '
          '(LLM) provider executes inside Deepgram, so your Deepgram account '
          'must have the OpenAI provider enabled for gpt-4o-mini. The demo '
          'auto-replies to every get_weather FunctionCallRequest with '
          '{"temperature": 72, "unit": "F"}; agent audio bytes would be fed '
          'to a speaker in a production app.',
        ),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Agent status', style: small),
                const SizedBox(height: 4),
                Text(_status),
              ],
            ),
          ),
        ),
        _SectionHeader('Conversation'),
        Container(
          height: 220,
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: _messages.isEmpty
              ? const Center(
                  child: Text(
                    '(no conversation yet)',
                    style: TextStyle(
                      fontStyle: FontStyle.italic,
                      color: Colors.grey,
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _chatScroll,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _messages.length,
                  itemBuilder: (BuildContext context, int index) {
                    final AgentConversationText message = _messages[index];
                    return _ChatBubble(
                      role: message.role,
                      content: message.content,
                    );
                  },
                ),
        ),
        _SectionHeader('Settings JSON (from the typed VoiceAgentSettings)'),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              _settingsJson,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _SectionHeader('Events (function calls · errors · warnings …)'),
        _EventLog(entries: _events),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared widgets and helpers
// ─────────────────────────────────────────────────────────────────────────────

/// A bold section title.
class _SectionHeader extends StatelessWidget {
  /// Creates a section header.
  const _SectionHeader(this.title);

  /// The header text.
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// A small grey explanatory note.
class _NoteText extends StatelessWidget {
  /// Creates a note.
  const _NoteText(this.text);

  /// The note text.
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: Colors.blueGrey),
      ),
    );
  }
}

/// A colored chip visualizing a WebSocket connection state.
class _StatusChip extends StatelessWidget {
  /// Creates a status chip.
  const _StatusChip(this.state);

  /// The state to render.
  final WsConnectionState state;

  @override
  Widget build(BuildContext context) {
    final Color color = _stateColor(state);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.circle, size: 8, color: color),
          const SizedBox(width: 6),
          Text(
            _stateLabel(state).toUpperCase(),
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

/// A bordered, scrollable list of timestamped event entries.
class _EventLog extends StatelessWidget {
  /// Creates an event log. Newest entries are shown at the top.
  const _EventLog({required this.entries});

  /// The log entries (newest first).
  final List<String> entries;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 160,
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: entries.isEmpty
          ? const Center(
              child: Text(
                '(no events yet)',
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: Colors.grey,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: entries.length,
              itemBuilder: (BuildContext context, int index) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 1,
                  ),
                  child: Text(
                    entries[index],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// A chat bubble for one conversation statement.
class _ChatBubble extends StatelessWidget {
  /// Creates a bubble. [role] is `'user'` or `'assistant'`.
  const _ChatBubble({required this.role, required this.content});

  /// Who spoke the statement.
  final String role;

  /// The statement text.
  final String content;

  bool get _isUser => role == 'user';

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Align(
      alignment: _isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: _isUser
              ? colorScheme.primaryContainer
              : colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _isUser ? 'User' : 'Agent',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: _isUser
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              content,
              style: TextStyle(
                color: _isUser
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSecondaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Maps a connection state to a human-readable label.
String _stateLabel(WsConnectionState state) {
  switch (state) {
    case WsConnectionState.idle:
      return 'idle';
    case WsConnectionState.connecting:
      return 'connecting';
    case WsConnectionState.open:
      return 'open';
    case WsConnectionState.reconnecting:
      return 'reconnecting';
    case WsConnectionState.closed:
      return 'closed';
    case WsConnectionState.failed:
      return 'failed';
  }
}

/// Maps a connection state to a chip color.
Color _stateColor(WsConnectionState state) {
  switch (state) {
    case WsConnectionState.idle:
      return Colors.blueGrey;
    case WsConnectionState.connecting:
      return Colors.lightBlue;
    case WsConnectionState.open:
      return Colors.green;
    case WsConnectionState.reconnecting:
      return Colors.orange;
    case WsConnectionState.closed:
      return Colors.blueGrey;
    case WsConnectionState.failed:
      return Colors.red;
  }
}

/// Shows a floating snackbar; errors render in the theme error color.
void _showSnackBar(BuildContext context, String message,
    {bool isError = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
      backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
    ),
  );
}

/// Formats a byte count for display.
String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Truncates long status text.
String _truncate(String text, int maxLength) {
  if (text.length <= maxLength) {
    return text;
  }
  return '${text.substring(0, maxLength)}…';
}
