# Parso Platterhead — iOS/iPadOS mockups (v2.0-iOS)

Open [`index.html`](index.html) to navigate all views.

Every view is a standalone HTML file with **no external dependencies** — no CDN, no webfonts, no scripts. All files
share one local stylesheet, [`platterhead.css`](platterhead.css). That is a change from the v1.0 Mac mockups, which
embedded CSS per file: thirty files drifting apart visually is a worse problem than one relative `<link>`.

The palette and idiom are inherited from the v1.0 set so the two read as one product.

## Coverage rule (spec §40.6)

Every screen in §41, §42 and §42B of
[`../PLATTERHEAD_IOS_ARCHITECTURE.md`](../PLATTERHEAD_IOS_ARCHITECTURE.md) MUST have a mockup before implementation.
Adding, removing, or materially changing a screen requires updating the spec's §40.5 inventory, the matching §41/§42
mapping, `index.html`, and this file.

**Current coverage: iPad 14/14 · iPhone 10/10 · watchOS 1/1.**

## Why some screens have more than one file

A single static image cannot show behaviour. Six screens are split:

| Screen | Files | What the second file shows |
|---|---|---|
| Vibe search | `04a`, `04b` | the empty query state vs. results with active ± refinement |
| Auto-playlist | `05a`, `05b` | the brief being composed vs. the generated sequence against its arc |
| Paywall (iPad) | `13a`, `13b` | the locked surface in context vs. the purchase sheet |
| iPhone solo deck | `05a`, `05b` | performing vs. browsing the crate mid-set without losing the crossfader |
| iPhone twin deck | `05c`, `05d` | both decks resident vs. a control bank momentarily raised over one jog |
| iPad DJ workspace | `07`, `07b` | the stems layout vs. the same decks with the jog module in the slot |
| Watch remote | one file, three states | performing · loading next · **disconnected** |

## iPad — 14 screens, 18 files

| File | Screen | Spec | Tier |
|---|---|---|---|
| `ipad/01-first-run.html` | First run &amp; sources | §41.1 | Free |
| `ipad/02-library.html` | Library | §41.2 | Free |
| `ipad/03-analysis.html` | Analysis &amp; library health | §41.3 | Free |
| `ipad/04a-vibe-search-query.html` | Vibe search — query | §41.4 | Free |
| `ipad/04b-vibe-search-results.html` | Vibe search — results &amp; refine | §41.5 | Free |
| `ipad/05a-autoplaylist-brief.html` | Auto-playlist — brief | §41.6 | Free |
| `ipad/05b-autoplaylist-result.html` | Auto-playlist — generated | §41.7 | Free |
| `ipad/06-track-preparation.html` | Track preparation | §41.8 | Pro (readout free) |
| `ipad/07-dj-workspace.html` | DJ workspace | §41.9 | Pro |
| `ipad/07b-dj-workspace-jog.html` | DJ workspace — jog module | §41.9a | Pro |
| `ipad/08-dj-stems-fx.html` | Stems &amp; filter detail | §41.10 | Pro |
| `ipad/09-recording-finish.html` | Recording finished | §41.11 | Pro |
| `ipad/10-mixes.html` | Recorded mixes | §41.12 | Pro |
| `ipad/11-midi-audio-cue.html` | MIDI, audio &amp; cue | §41.13 | Pro |
| `ipad/12-settings-storage.html` | Settings &amp; storage | §41.14 | Free |
| `ipad/13a-paywall-context.html` | Paywall — in context | §41.15 | Pro |
| `ipad/13b-paywall-sheet.html` | Paywall — purchase sheet | §41.16 | Pro |
| `ipad/14-gig-crate.html` | Gig crate | §41.17 | Pro |

## iPhone — 10 screens, 12 files

| File | Screen | Spec | Tier |
|---|---|---|---|
| `iphone/01-library-home.html` | Library home | §42.2 | Free |
| `iphone/02-vibe-search.html` | Vibe search | §42.3 | Free |
| `iphone/03-autoplaylist.html` | Auto-playlist | §42.4 | Free |
| `iphone/04-track-preparation.html` | Track preparation | §42.5 | Pro (readout free) |
| `iphone/05a-solo-deck.html` | Solo deck — performing | §42.6 | Pro |
| `iphone/05b-solo-deck-browse.html` | Browsing while performing | §42.7 | Pro |
| `iphone/05c-twin-deck-landscape.html` | Twin deck — landscape | §42.7a | Pro |
| `iphone/05d-twin-deck-drawer.html` | Momentary bank drawer | §42.7b | Pro |
| `iphone/06-stems-cue.html` | Stems &amp; split cue | §42.8 | Pro |
| `iphone/07-recording-finish.html` | Recording finished | §42.9 | Pro |
| `iphone/08-paywall.html` | Paywall | §42.10 | Pro |
| `iphone/09-settings-storage.html` | Settings &amp; storage | §42.11 | Free |

## watchOS — 1 screen, 1 file

| File | Screen | Spec | Tier |
|---|---|---|---|
| `watch/01-performance-remote.html` | Performance remote | §42B.1, §39A | Pro |

## Conventions the mockups encode

These are not decoration; each one is a normative rule the implementation must honor.

- **Pro is visible, never hidden and never faked** (§40.4). Locked surfaces show the real control surface, dimmed.
  There are no blurred stand-ins and no dummy waveforms anywhere in this set.
- **Free is stated, not implied.** Remote libraries, vibe search and auto-playlists carry a *Free* badge because the
  §2.4 line is a promise the product has to keep repeating (Appendix T.5 makes CI keep it).
- **Latency figures are granted values**, read back from `AVAudioSession`, never the requested ones (FR-SESS-2).
- **Thermal state, buffer and memory appear on the performance surfaces**, because on a phone they are correctness
  surfaces rather than diagnostics (NFR-THERM-4, NFR-REL-4).
- **Touch targets are ≥ 44 pt on every performance control** (NFR-A11Y-3) — the user is not looking at the screen.
- **Every caption cites the spec section and requirement IDs it realizes**, so a reviewer can check the mockup against
  the specification rather than against taste.
