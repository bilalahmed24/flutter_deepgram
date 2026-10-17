---
name: Bug report
about: Report something in the SDK that is broken or behaves unexpectedly
title: ''
labels: 'bug'
assignees: ''
---

## Describe the bug

A clear and concise description of what is broken. If you are unsure whether
the bug is in this SDK or in Deepgram's service, say so — check the raw API
response against <https://developers.deepgram.com/reference> first if you can.

## Steps to reproduce

1. ...
2. ...

## Expected behavior

What you expected to happen.

## Actual behavior

What happened instead. Include the typed exception (message, `runtimeType`)
or the unexpected event payload.

## Environment

- `flutter_deepgram` version:
  <!-- version from your pubspec.lock -->
- Dart/Flutter (`dart --version`, `flutter doctor -v`):
- Platform(s) affected:
  <!-- Android / iOS / Web / macOS / Windows / Linux / plain Dart VM -->
- How you authenticate:
  <!-- API key / static JWT / token provider / temporary token -->

## Minimal reproducible example

A snippet that reproduces the issue with no private data. Replace any real
API key with `YOUR_DEEPGRAM_API_KEY` — never paste credentials; they must be
treated as compromised the moment they are posted.

```dart
// paste your code here
```

## Logs

Output of your `DeepgramLogger` listener (or note that logging was not
enabled). Remember: the logger never prints credentials, so this is safe to
share.

```text
paste logs here
```

## Additional context

Anything else that helps: whether it happens on every request or
intermittently, whether it started after a version bump, sample audio or
text that triggers it, etc.
