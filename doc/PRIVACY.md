# Privacy notice

This document describes how the `flutter_deepgram` SDK handles data. It
applies to the SDK itself, not to the applications you build with it.

## What the SDK sends, and where

`flutter_deepgram` is a client library for the Deepgram API. When you call
one of its methods, the SDK transmits your request payload to Deepgram's
servers for processing:

- **Speech-to-text** — the audio you stream or upload, plus the transcription
  options you set.
- **Text-to-speech, text intelligence, and voice agents** — the text (and, for
  agents, the audio and conversation context) you submit, plus the options you
  set.

Processing of that data is governed by Deepgram's privacy policy and your
Deepgram agreement:

- Deepgram privacy policy: https://deepgram.com/privacy-policy
- How Deepgram handles your data: https://developers.deepgram.com/trust-security/your-data

If you enable the Model Improvement Program (the default), Deepgram may use
your request data to improve its models. Every options class in this SDK
exposes `mipOptOut` if you need to opt out; review Deepgram's documentation for
the pricing implications before enabling it.

## What the SDK does NOT do

- **No telemetry.** The SDK collects no analytics, usage statistics, crash
  reports, or any other data about you or your users, and it phones home to
  nobody. The only outgoing network traffic is (a) the API requests you
  explicitly make and (b) an optional connectivity probe against the Deepgram
  endpoint, used to distinguish "the internet is down" from "Deepgram is down"
  after a connection failure.
- **No storage.** The SDK persists nothing to disk. Audio buffered during a
  live-transcription disconnect is kept in memory only, is capped by
  `LiveGapRecoveryOptions.maxBufferBytes`, and is discarded once recovered.
- **Credentials stay on-device.** API keys, JWTs, and tokens supplied through
  a `DeepgramTokenProvider` are held in memory and attached to API requests;
  they are never transmitted anywhere except to Deepgram as authentication.
  For browser deployments, use `DeepgramClient.withTokenProvider` with a
  backend that mints short-lived tokens so your API key never ships to the
  client.

## Logging

The SDK never prints. If you attach a `DeepgramLogger` listener, log events are
delivered in-process to your code only — it is your application that decides
whether and where to persist them.

## Contact

Questions about this notice or the SDK's data handling? Please open an issue in
the repository's issue tracker.
