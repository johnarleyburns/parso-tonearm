# QA workflow

See the identical cross-repository QA policy in the Cladiron repository's `docs/QA_WORKFLOW.md`; this copy is the authoritative policy for Tonearm and is intentionally maintained in-repository for coding workers and testers.

## Core rule

A passing helper test, merged PR, or accepted TestFlight upload is delivery evidence, not proof a user-visible flow works. Each issue must map acceptance requirement → real production entry point → changed call site → observable result → regression → human device check.

## Labels

`testflight-uploaded` means Apple accepted upload; `testflight-distribution-confirmed` means a tester group can access it; `ready-for-qa` means an exact build is installable and eligible for human testing; `qa-passed` and `qa-failed` are human outcomes. A later upload never silently removes `qa-failed`.

## Required PR evidence

Use real production-path regressions; a test that directly instantiates a new helper is insufficient. Provide failing-before/passing-after commands, an issue-to-diff audit, and an issue-specific device checklist. Visual references are durable/versioned before implementation; implementation-generated screenshots cannot redefine the target.

## Human-only checks

Humans record exact build, device/OS, setup, expected/actual, accessibility/device checks, and result. Paired hardware, lock screen, backgrounding, AirPlay/output, real network media, and perceptual audio quality are not claimed as automated QA.

## Queue and close policy

Tonearm's queue is independent of other repositories. Do not close until linked code merged, exact TestFlight build is accessible, and human QA applies `qa-passed`. Failed QA remains visible and must become a regression scenario before retest.
