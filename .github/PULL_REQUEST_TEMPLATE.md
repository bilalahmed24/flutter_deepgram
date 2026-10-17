# Summary

<!-- One or two sentences: what does this pull request change? -->

## Motivation

<!-- Why is this change needed? Link the issue if one exists ("Fixes #123"),
     or briefly describe the problem/feature if there is no issue yet. -->

## Changes

<!-- Bullet list of the meaningful changes (files/areas touched and why). -->

-

## Checklist

<!-- The project's full conventions are in CONTRIBUTING.md; this is the
     short version CI enforces. -->

- [ ] Tests added / updated (every bug fix ships with a failing-then-green
      test; new wire fields get malformed-input fixtures).
- [ ] `dart analyze` clean and `dart format` applied to touched files.
- [ ] Public declarations have doc comments; new exports are added to
      `lib/deepgram.dart`.
- [ ] `README.md` updated if the feature is user-visible.
- [ ] `CHANGELOG.md` entry added under `Unreleased`.
- [ ] No `print`, no `dart:io` under `lib/`, no raw `as`-casts on untrusted
      JSON.

## Test evidence

<!-- Paste the commands you ran and their outcome, e.g.

     dart test --coverage=coverage
     dart analyze --fatal-infos

     For changes that touch models or wire format, mention the coverage
     delta if you measured it. -->

```text
paste test output here
```

## Additional context

<!-- Anything else reviewers should know: screenshots, API docs links,
     migration notes for breaking changes, follow-up work. -->
