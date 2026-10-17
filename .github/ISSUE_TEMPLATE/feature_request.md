---
name: Feature request
about: Suggest a new capability, option, or API improvement
title: ''
labels: 'enhancement'
assignees: ''
---

## Is your feature request related to a problem?

A clear description of the problem, for example: "I'm always frustrated
when [...]". If it maps to a Deepgram API capability that this SDK does not
expose yet, link the relevant documentation page on
<https://developers.deepgram.com/reference>.

## Proposed solution

What you want to happen, in the SDK's own terms (a new options field, a new
client method, a new event on a stream, ...).

## Alternatives you've considered

Any workarounds you use today (e.g. calling the REST endpoint yourself,
post-processing results) and why they are not enough.

## API sketch

If you have an idea of what the call site should look like, sketch it. The
SDK conventions are documented in
[CONTRIBUTING.md](../../CONTRIBUTING.md): immutable `const` options classes,
`toQuery()`/`toJson()` serialization, defensive parsing, and streams for
continuous events.

```dart
final deepgram = DeepgramClient(apiKey: 'YOUR_DEEPGRAM_API_KEY');

// sketch your desired usage here
```

## Additional context

Anything else — links to the Deepgram docs, other SDKs that expose the same
feature, or downstream use cases.
