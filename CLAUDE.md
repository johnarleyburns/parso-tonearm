# CLAUDE.md

## Swift 6 hard rule

Tonearm is fully on Swift 6 language mode with complete strict-concurrency checking and is kept as warning-free as the selected toolchain permits. Do not introduce or permit any deviation, mixed Swift modes, warning suppression, or unexplained concurrency escape hatch. A commit runs logic tests and simulator tests; a push runs logic tests only.

Read [`docs/plans/tonearm-mvp-ios/HANDOFF.md`](docs/plans/tonearm-mvp-ios/HANDOFF.md) for the full operating brief. **§0 of that file is how to start a session** — the one-commit-per-task session model and the kickoff prompts.

## Three rules that get broken by being helpful

- **Work on `main`; do not create a branch.** The owner's explicit preference — agents kept opening branches and abandoning them. Commit to `main` one task per commit, and **ask before `git push`**: pushing triggers CI and a TestFlight build, so push is the approval gate, not the branch.

- **CI runs `swift test` only.** The UI regression suite (`make test-ui-regression`) is run by hand before a release. It needs Docker, a simulator and third-party demo servers. Do not wire it into CI, a git hook, or `make test-swift`. It lives in its own target and scheme (`TonearmUIRegressionTests` / `TonearmUIRegression`) so the smoke path cannot reach it — keep that separation.
- **Never commit `.test-credentials`.** Real values live there and it is gitignored; `.test-credentials.example` carries key names only. No credential belongs in a test, a compose file, a script, or a spec.

## Git hook timeouts

- Set the command timeout to at least **5 minutes (300 seconds)** for `git commit`; the pre-commit hook runs the full local suite, including simulator tests.
- Set the command timeout to about **2 minutes (120 seconds)** for `git push`; the pre-push hook runs unit tests only.
