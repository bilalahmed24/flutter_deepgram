# Security Policy

## Supported versions

This package is maintained by a single maintainer, so security fixes are only
made on the latest minor line. Please make sure you are on the newest published
release before reporting an issue.

| Version | Supported |
| ------- | --------- |
| 1.x (latest release) | Yes |
| anything older | No |

Fixes are released as patch versions (for example `1.2.0` -> `1.2.1`); the
[CHANGELOG](CHANGELOG.md) notes anything security-relevant.

## Reporting a vulnerability

**Do not open a public GitHub issue, discussion, or pull request for a
suspected security problem.** Please use one of these private channels instead:

1. **GitHub private vulnerability reporting** (preferred): go to the
   repository's **Security** tab and choose **Report a vulnerability**. This
   keeps the report and its discussion private and lets us publish a GitHub
   Security Advisory with credits when the fix ships.
2. **Email**: `bilalahmed24.dev@gmail.com`

Please include, as far as you can:

- a description of the issue and its impact,
- the `flutter_deepgram` version(s) affected (the `version:` line of the pubspec
  you depend on),
- steps or a minimal snippet to reproduce the problem,
- any suggested mitigation or fix.

You should get an acknowledgment within 72 hours, and we will agree on a fix
and disclosure timeline from there. Please give us a reasonable window to fix
and publish before disclosing publicly; we credit reporters in the changelog
and advisory unless you prefer to stay anonymous.

## Scope

In scope:

- All code in this repository: `lib/`, `example/`, and the repo's tooling.
  For example: anything that could leak credentials, crash applications using
  the SDK, or let a malicious server response compromise a client app.

Out of scope:

- **The Deepgram service itself.** Problems with Deepgram's API, console,
  account handling, or infrastructure must be reported to Deepgram through
  their official security channels — see the trust & security section of the
  Deepgram documentation
  (<https://developers.deepgram.com/trust-security/your-data>).
- **Vulnerabilities in dependencies** (`http`, `web_socket_channel`). Report
  those upstream to the owning package; we will pick up the patched release
  through regular dependency updates.
- **Applications built with this SDK.** If the vulnerability is in the app's
  own code (hard-coded keys, permissive CORS, etc.), we cannot fix it here,
  though the credential guidance below may help.

## Credential-handling guidance

`flutter_deepgram` is designed so Deepgram credentials never leak:

- **API keys and tokens are never logged.** The opt-in
  [`DeepgramLogger`](lib/src/core/deepgram_logger.dart) emits lifecycle and
  diagnostic events only; it never emits `Authorization` headers, API keys,
  JWTs, or temporary tokens. The SDK never prints anything on its own.
- **Do not ship your API key to a browser.** In web apps, static credentials
  are visible to anyone who opens devtools. Use a
  `DeepgramClient.withTokenProvider(...)` backed by your own server that mints
  short-lived tokens via the Deepgram auth grant endpoint
  (`POST /v1/auth/grant`, exposed by `DeepgramAuth.grantTemporaryToken`), or
  scope-limited keys. The example app and README show the pattern.
- **Reported credentials are treated as security issues.** A code path in this
  package that writes a credential to a log, error message, or exception is a
  vulnerability — please report it as described above.

For what the SDK sends over the network and what it never collects, see
[doc/PRIVACY.md](doc/PRIVACY.md).
