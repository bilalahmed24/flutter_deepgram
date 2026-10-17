# Contributing to flutter_deepgram

Thanks for your interest in improving `flutter_deepgram`! This document covers the
development setup, the project layout, and what a good pull request looks like.

## Getting started

1. Install the Dart SDK (3.0+); for Flutter apps, a recent Flutter SDK works too.
2. Clone the repository and fetch dependencies:
   `dart pub get --no-example` — the `example/` app is a Flutter package, so
   plain `dart pub get` resolves this SDK fine but then exits non-zero
   trying to resolve the example on a pure Dart install.
3. Before opening a pull request, make sure everything is clean:

   ```sh
   dart analyze   # must report no issues
   dart format .  # format everything you touched
   ```

There is no native code and no code generation — `dart pub get --no-example`
is the only setup step. The example app is developed like any Flutter app:
`flutter pub get` inside `example/`.

## Project layout

The package is intentionally flat; every file lives under `lib/src/` and is
exported through the single public barrel:

```
lib/
├── deepgram.dart                    # public barrel: the ONLY import surface
└── src/
    ├── core/
    │   ├── deepgram_client.dart     # DeepgramClient facade (entry point)
    │   ├── deepgram_config.dart     # DeepgramConfig, DeepgramRegion, URI builders
    │   ├── deepgram_exception.dart  # typed exception hierarchy
    │   ├── deepgram_logger.dart     # pluggable logger
    │   ├── deepgram_auth.dart       # API key / JWT / token provider / grants
    │   ├── http/http_engine.dart    # resilient REST engine, HttpCancelToken
    │   └── ws/                      # resilience engine
    │       ├── resilient_websocket.dart, ws_failure_classifier.dart
    │       ├── backoff_policy.dart, connectivity_probe.dart
    │       └── ws_factory.dart + ws_factory_{io,web,stub}.dart (conditional)
    ├── listen/                      # speech-to-text
    │   ├── stt_models.dart          # shared, transport-agnostic result models
    │   ├── prerecorded/             # POST /v1/listen (options + client)
    │   ├── live/                    # WSS /v1/listen (options, models, client)
    │   └── flux/                    # WSS /v2/listen (options, models, client)
    ├── speak/                       # TTS: voices.dart (catalog), speak_options.dart,
    │   │                            #   speak_client.dart (REST), speak_stream_client.dart
    │   │                            #   (WS v1), flux_speak_client.dart (WS v2)
    ├── agent/                       # voice agent: agent_settings.dart (Settings tree
    │                                #   + providers + functions), agent_messages.dart
    │                                #   (typed events), agent_client.dart (WS),
    │                                #   agent_configurations.dart (REST)
    └── intelligence/text_intelligence.dart  # POST /v1/read
example/                             # runnable demo app
```

When you add a file, export it from `lib/flutter_deepgram.dart` (and keep the
section-comment grouping).

## Code style

The lints in `analysis_options.yaml` are enforced: `package:lints/recommended`
plus strict-casts, strict-raw-types, `always_declare_return_types`,
`prefer_const_constructors`, `prefer_final_locals`, `prefer_single_quotes`,
`sort_constructors_first`, `directives_ordering`, `unawaited_futures`,
`cascade_invocations`, `unnecessary_parenthesis`, and `comment_references`.
Beyond the lints:

- **Doc comments are required on every public declaration.** Start files with a
  `library;` directive preceded by a library-level doc comment; reference other
  APIs with `[SquareBrackets]` so `comment_references` keeps them honest.
- **Defensive JSON parsing everywhere.** Server frames must never crash the
  SDK: use `is` checks and coercion helpers, skip malformed entries, and fall
  back to neutral defaults. Never `as`-cast untrusted JSON; a malformed frame
  in a stream yields a typed warning event, not an exception.
- **No prints.** Route everything through `DeepgramLogger`.
- **Web-safe code.** No `dart:io` under `lib/` (the only conditional import is
  the WebSocket factory). Fire-and-forget futures must go through
  `unawaited(...)`.
- **Immutable options.** Options classes are `const` constructors with
  `toQuery()`/`toJson()` serialization that omits null fields.

## How to add a feature

1. **Research first.** Start from the official Deepgram documentation
   (https://developers.deepgram.com/reference) and pin down the exact wire
   contract: endpoint, query parameters, message schemas, and error shapes.
   Prefer the OpenAPI/AsyncAPI specifications when in doubt.
2. **Models.** Add typed, defensively-parsing model classes for every response
   node (see `listen/stt_models.dart` for the house style).
3. **Options.** Add an immutable options class with a `const` constructor and
   `toQuery()` / `toJson()`; repeated query keys are expressed as
   `List<String>` fields.
4. **Client.** REST features hang off a sub-client wired through the shared
   `HttpEngine`; streaming features build a session on `ResilientWebSocket`
   following the existing subscribe-before-connect lifecycle pattern.
5. **Export** the new file from `lib/flutter_deepgram.dart`, then **document** the
   feature in `README.md` and add a bullet to `CHANGELOG.md` under an
   `Unreleased` heading.

## Testing expectations

- Every bug fix should come with a test that fails without the fix.
- Model parsing tests should include malformed/missing-field fixtures — that is
  the contract defensive parsing promises. WebSocket/HTTP behavior should be
  tested with injected fakes (`WsFactory` and `ConnectivityProbe` are
  injectable for exactly this reason).
- Run `dart analyze` and `dart format` before every commit; CI runs both.

## Pull request checklist

- [ ] `dart analyze` is clean (no infos, warnings, or errors).
- [ ] `dart format` applied to all touched files.
- [ ] Doc comments on every new public declaration.
- [ ] No `print`, no `dart:io` under `lib/`.
- [ ] Defensive parsing for every new `fromJson`.
- [ ] New exports added to `lib/flutter_deepgram.dart` (no name collisions).
- [ ] `README.md` and `CHANGELOG.md` updated.
- [ ] Tests covering the new behavior and its malformed-input paths.

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE).
