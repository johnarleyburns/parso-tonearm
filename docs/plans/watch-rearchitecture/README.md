# Platterhead Watch Rearchitecture

This directory is the source of truth for replacing the existing Apple Watch app.
The implementation plan is written for an autonomous coding agent starting cold:

- [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) — normative architecture,
  behavior, phase sequence, file ownership, tests, gates, and acceptance criteria.
- [`ACCEPTANCE_MATRIX.md`](ACCEPTANCE_MATRIX.md) — end-to-end scenarios that must
  pass before release, including physical-device-only gates.
- [`mockups/index.html`](mockups/index.html) — normative connected, offline,
  playback, download-management, and failure-state mockups.

The old [`../watch-app.md`](../watch-app.md) documents the GRDB-based implementation
being replaced. It is historical evidence only. Where it conflicts with this directory,
this directory wins.

## Product sentence

Platterhead on Apple Watch is a fast remote for the paired iPhone when connected and
a complete local music player for explicitly downloaded music when disconnected.

## Non-negotiable boundary

The watch never reads from, writes to, authenticates with, or links an execution path
to CloudKit. Its persistent store is local SwiftData configured with
`cloudKitDatabase: .none`; its only library authority is the paired iPhone through a
versioned WatchConnectivity protocol.
