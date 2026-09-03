# Platterhead DJ — Platform & Monetization Strategy

**Question on the table:** should the Pro/DJ tier be **iPhone-only** instead of the macOS-first
product specced in `TONEARM_DJ_ARCHITECTURE.md`, on the theory that mobile is less contested
than the desktop?

**Short answer:** the *platform* instinct is right, the *reason* is wrong, and "iPhone-only"
is one notch too narrow.

- Mobile DJ is **not** less contested than desktop. It is *more* concentrated — one dominant
  incumbent (Algoriddim's djay) versus three or four on desktop.
- But the axes it competes on are almost entirely orthogonal to Platterhead's. Every serious
  mobile DJ app is **subscription-priced and streaming-first**. Platterhead is **one-time and
  owned-library-first**. That is a real, defensible seam — it just isn't the "empty market"
  seam the premise assumed.
- The decisive argument for mobile isn't differentiation at all. It's **distribution and
  scope**: the iPhone app already exists, already has the library, the formats, the cache and
  the users. The Mac app has none of that, and the Mac-first plan spends an entire milestone
  (Part VI, CloudKit sync + companion) on a problem that only exists *because* the studio and
  the listener are on different devices.
- Recommendation: **iPhone + iPad universal, one-time purchase, in the existing app.** Not
  iPhone-only. Not Mac-first. Mac deferred but architecturally uncut.

Sections 1–3 establish the landscape and test the premise. Section 4 quantifies what the
pivot does to the 4,888-line spec. Section 5 covers pricing and SKU. Section 6 is the verdict
and the concrete edits to the spec.

---

## 1. The competitive field on mobile

| App | Platform | Price model | Owned local files | Stems | Hardware/MIDI | Posture |
|---|---|---|---|---|---|---|
| **djay** (Algoriddim) | iOS, iPadOS, macOS, Windows, Android, visionOS | **Subscription only** — ~$6.99/mo, ~$49.99/yr. No one-time tier. | Yes — Files app, by reference, FLAC supported | **Neural Mix**, on-device, real-time | 100+ controllers plug-and-play, DVS | The incumbent. Apple Design Award lineage, deep Apple Music/Spotify integration. |
| **rekordbox** (AlphaTheta) | iOS, Android, desktop | **Subscription** — Core $12/mo ($120/yr), Creative $18/mo, Professional $36/mo. Mobile needs a paid plan for anything real. | Yes | Vocal/stem separation in paid tiers | Native — it *is* the Pioneer/AlphaTheta club ecosystem | Owns the club-gear workflow. Mobile is an extension of CDJ prep, not a destination. |
| **edjing Mix** (MWM) | iOS, Android | Freemium + IAP $7.99–$49.99, ad-supported free tier | Yes, secondary | Limited | Thin — largely the discontinued DDJ-200 | Consumer/beginner volume play. Streaming-forward (Tidal, SoundCloud, Deezer). |
| **Cross DJ** (Mixvibes) | iOS, Android | Freemium / paid unlock | Yes | Limited | Some controllers | Stripped-back, no-nonsense. Quiet, stable, not growing. |
| **DJ Player Professional** (iMect) | **iOS only** | Was ~$9.99 upfront; **now subscription** (1-year and 5-year terms) | Yes, FLAC | 4 decks × 4 stems | Extensive class-compliant MIDI/HID, DVS, multichannel USB audio | **The most instructive datapoint in this table.** See §2.3. |
| **Traktor DJ 2** (Native Instruments) | iOS, desktop | Was free | — | — | — | **Discontinued.** NI states it is no longer maintained and that they are *not currently working on a Traktor version for iOS.* |
| **Serato** | iOS | — | — | — | — | **No first-class mobile DJ app.** Only companions: Serato Remote (controls desktop Serato) and Pyro (consumer automix). |

Ecosystem pricing anchors for one-time-purchase iOS pro audio, for §5:
Koala Sampler **$4.99**; AUM ~**$21** (launched at $9.99 in 2016, raised over time); Loopy Pro
**pay-once** (~$30 class) with optional paid 12-month feature-update extensions and explicitly
"no subscriptions, no lock-in."

Scale anchor: djay's iOS listing is estimated at roughly **400k downloads and ~$1M revenue per
month**. The DJ software market overall is estimated in the $370M–$700M/yr range depending on
whose methodology you take.

---

## 2. Premise check: is the iPhone actually less contested?

### 2.1 No — it is more concentrated

Desktop DJ has **Serato, rekordbox, Traktor, djay Pro, VirtualDJ** — five credible products
splitting the professional market. Mobile has **djay**, and then a gap, and then everyone else.
djay is cross-platform, Apple-blessed, ships real-time on-device stem separation, and has the
streaming-service deals nobody else got. If the goal were "find a market with fewer
incumbents," mobile is the wrong answer.

So the pivot cannot be justified as *avoiding* competition. It has to be justified on the
axes where the incumbent is structurally unable to follow.

### 2.2 Where djay structurally cannot follow

Three, and they are the three the architecture doc already builds toward:

1. **One-time purchase.** djay abandoned paid-upfront for subscription in 2015 and is not
   coming back; its whole revenue model depends on it. rekordbox mobile starts at $120/yr.
   DJ Player Professional — the last holdout, and an iOS-only one — has since moved to
   subscription too. As of now, **no pro-grade mobile DJ app offers a one-time purchase at
   all.** The field has converged completely, which means the position is not just open, it is
   *uncontested*. "One year of djay costs more than Platterhead costs forever" is the sharpest
   single line of marketing available to this product, and it is true against every competitor
   in the table.

2. **Owned-library-first.** Every mobile DJ app treats streaming as the primary source and
   local files as the fallback. And here is the tell: **djay's own Neural Mix cannot be used
   on tracks streamed from Apple Music or Spotify**, and neither can recording. The incumbent's
   flagship AI feature and its recording feature *only work on owned files* — the exact
   population Platterhead already serves, and serves better (FLAC, Opus, ALAC, ReplayGain,
   gapless, tag editing, transparent cache, ten remote-library providers). Platterhead's
   library layer is a genuine asset here, not a prerequisite to rebuild.

3. **On-device semantic search.** Nobody in the table has it. "Find the next track by feel"
   over a 12,000-track owned library, with no network call, is a feature no competitor
   currently ships on any platform. This is the one thing in the spec that is not a
   commoditized DJ feature.

The differentiation story survives the move to mobile intact. It just isn't about emptiness.

### 2.3 The cautionary datapoint: DJ Player Professional

An iOS-only, technically excellent pro DJ app with 4 decks, 16 stem channels, DVS,
multichannel USB audio and deep MIDI/HID support has existed for over fifteen years, was
priced around $9.99 upfront for most of that time, and remains a niche product with no
meaningful market share. It has now capitulated to a subscription model.

Two lessons, and they point in opposite directions — both matter:

- **Cautionary:** on mobile, technical professional-grade capability does not by itself move
  units. DJ Player Pro proves the engineering is possible on iOS (4 decks × 4 stems on an
  iPhone is not a research question), and it proves that competing with djay on
  being-a-better-DJ-app is a losing frame. Which points directly at the repositioning in §6.3.
- **Encouraging:** its one-time price was $9.99 — too low to fund the product, and too low to
  signal seriousness to a buyer comparing it against a $50/yr incumbent. The failure is at
  least as consistent with "underpriced and undifferentiated" as with "nobody wants a
  pay-once mobile DJ app." Platterhead differs on both counts: it is priced as a real tool
  (§5.2) and it carries a feature no competitor has at any price.

### 2.4 What is genuinely working in Platterhead's favor on mobile

- **USB-C.** Every current iPhone is USB-C. AlphaTheta ships the DDJ-FLX2 and DDJ-GRV6 with
  bus-powered USB-C connection to an iPhone as a headline feature; the DDJ-FLX4 does the same.
  Class-compliant controller support from an iPhone is a solved, vendor-endorsed path — which
  it was not three years ago.
- **Silicon parity.** The A-series NPU and GPU run the same Core ML CLAP and Demucs graphs the
  spec targets on M-series. This is one Apple-Silicon codebase, not two.
- **The install base already exists.** This is the big one, and §3 is about it.

---

## 3. The argument the premise missed: distribution and scope

The strongest case for mobile has nothing to do with the competitive field.

**Distribution.** Platterhead on iOS is shipping, has users, has a working $7.99 IAP, and
those users are *definitionally people who own their music* — the exact persona P1 in the
spec. A DJ tier there is an upsell to a warm, precisely-qualified audience. On macOS the
product is a cold start: new app, new listing, no users, competing head-on with Serato and
rekordbox for the attention of professionals who already have a workflow and a controller.

**Scope.** The Mac-first plan pays for a device split it invents itself. Because the studio is
the Mac and the listener is the phone, the spec needs **Part VI in its entirety** — a CloudKit
sync protocol (§38, with record types, mapping, conflict resolution, CKAsset upload lifecycle,
silent push, retention policy) and an iPhone companion (§39, five screens) whose only job is
to get finished mixes onto the phone. If the DJ device *is* the phone, **that whole milestone
(M5) collapses to near-nothing.** The mix is recorded where it is played. There is no bridge
to build because there is no gap.

That is the real prize: not a better competitive position, but roughly a milestone of
eliminated work and one fewer application to maintain, market, and support.

---

## 4. Blast radius on the existing spec

The doc is 4,888 lines. Here is what survives, what dies, and what gets genuinely harder.

### 4.1 Survives essentially unchanged (~60% of the spec)

All of it is portable Swift on frameworks that exist identically on iOS:

- **Part III — Data layer** (§13–18). GRDB, SQLite, sqlite-vec, 46-table schema, migrations,
  analysis versioning. Zero change; `TonearmCore` already targets iOS 17.
- **Part IV — Analysis pipeline** (§19–28). vDSP/Accelerate FFT, onset/tempo/beat/downbeat,
  Constant-Q key detection, phrase segmentation, waveform pyramid, CLAP embeddings, hybrid
  ranking. All Accelerate + Core ML, both fully present on iOS.
- **Part V — Real-time engine** (§29–35). AVAudioEngine, AVAudioSourceNode, master clock,
  sample-accurate scheduling, beat sync, key lock, deck/mixer/EQ/crossfader/limiter. All iOS
  frameworks. The lock-free render-callback contract in §12 is identical.
- **§36 stem separation.** Demucs via Core ML on the GPU/ANE — runs on A-series.
- **Appendices F–L** (reference algorithms, semantic subsystem, interface index, config,
  concurrency). Platform-neutral.

**Important:** the spec's `#if os(macOS)` gating of the `TonearmDJ` modules (§9) becomes an
`#if os(iOS)` gate — or better, **no gate at all**. Keeping the DSP and engine modules
platform-neutral is what preserves the option to ship Mac later on the same purchase.

### 4.2 Dies or collapses (the savings)

| Spec area | Fate |
|---|---|
| **§38 CloudKit sync protocol** (record types, mapping, upload lifecycle, silent push, quota, retention) | Collapses to *optional* iPhone↔iPad↔future-Mac library sync. No longer on the critical path; mixes are recorded where they are played. |
| **§39 iPhone companion architecture** | Deleted. There is no companion; there is one app. |
| **§41 macOS screens (Mac-01 … Mac-10)** | Deleted. Ten screens of design and implementation. |
| **§42 iOS companion screens (iOS-01 … iOS-05)** | Deleted as *companion* screens; replaced by real DJ screens (§6.3). |
| **§48.6 Milestone M5** (sync + companion) | Mostly eliminated; residual hardware work folds into M4. |
| **AppKit hosting, macOS window/menu chrome** | Deleted. |
| **Second app target, second App Store listing, second support surface** | Deleted. |

### 4.3 Gets genuinely harder — and how to answer each

These are the real costs, and they need explicit answers in the spec, not hand-waving.

**(a) Storage. The spec's budgets are Mac budgets.** §43.6 and the mockups assume a 6.3 GB
vector index and an **18.7 GB stem cache** for 12,842 tracks. That is unacceptable on a
128 GB iPhone whose owner already keeps a music library on it.

*Answer — two changes:*
- **Vector index:** the 6.3 GB figure is window-level embeddings for the whole library. A
  track-level pooled f16 512-dim vector is ~1 KB/track → **~13 MB for 12k tracks**. Ship
  track-level pooled vectors library-wide by default (§27.4 already defines the pooling), and
  compute window-level vectors *only* for tracks in a prepared crate. Semantic search over the
  full library is preserved; window-level "find the moment that sounds like this" becomes a
  crate-scoped feature.
- **Stem cache:** replace the "cache everything" posture with a **gig crate** model. The user
  marks a crate (100–300 tracks) as prepared; stems are separated and cached only for those,
  with LRU eviction and a visible storage budget the user sets. At ~1.5 MB/track-minute × 4
  stems this is a few GB for a realistic set, not 18.7 GB. This is arguably a *better* model
  than the Mac one anyway — it matches how DJs actually prepare for a gig.

**(b) Thermals and battery.** Background analysis of a 12k-track library on an iPhone is a
sustained ANE + GPU + CPU load. §43.7 already specifies runtime adaptation; it needs teeth on
iOS: gate bulk analysis on **charging + thermal state nominal**, expose it as an explicit
"Analyze library" activity with progress rather than a silent background crawl, and always
let a prepared-crate job jump the queue. During performance, analysis suspends entirely —
§4.2's FR-ANL-2 (playback thread protected) is already the rule; on iOS it must be enforced
against thermal throttling too, not just scheduling priority.

**(c) The 6-inch two-deck UI.** This is the hardest problem and it is a *design* problem, not
an engineering one. Two decks + four stem faders + 3-band EQ + crossfader does not fit an
iPhone screen as a scaled-down Mac workspace, and attempting it produces the worst version of
every competitor's app. The answer is §6.3: **do not ship the Mac workspace shrunk.** Ship a
one-deck-focused, gesture-driven performance surface with the incoming deck as a
prepare-and-drop target, and let iPad carry the full two-deck layout. This is precisely why
the recommendation is iPhone **+ iPad**, not iPhone-only.

**(d) Latency and audio session.** §34's ≤10 ms budget at 128-frame buffers is achievable on
iOS but is mediated by `AVAudioSession` (category, preferred IO buffer duration, route
changes, interruptions). The spec has no `AVAudioSession` state machine because macOS doesn't
need one. **New required section:** session configuration, route-change and interruption
handling (a phone call must not corrupt a recording), and USB-C audio interface routing.

**(e) Hardware (§44) shrinks but does not vanish.** CoreMIDI exists on iOS and class-compliant
USB-C controllers work — MIDI-learn (FR-HW-2/3) is fully deliverable. Multichannel routing to
a USB interface (FR-HW-1) is more constrained on iOS and should drop to a v1.1 item. DVS was
already a non-goal.

**(f) Background audio and app lifecycle.** Recording a set while the screen locks, or while
another app takes foreground, is an iOS concern with no Mac analogue. Needs specifying
alongside (d).

### 4.4 Net

The pivot **deletes more spec than it invalidates.** Parts III–V — the hard, novel,
high-value engineering — port essentially unchanged. What dies is the device-split
infrastructure and a whole platform's worth of UI. What is added is a new mobile UI design
problem, an `AVAudioSession` layer, and a rescoping of two storage budgets.

---

## 5. Monetization

### 5.1 What the field will bear

Every mobile competitor is now a subscription: djay ~$49.99/yr, rekordbox $120–$360/yr,
edjing IAP to $49.99, and DJ Player Professional has joined them. The one-time-purchase iOS
pro-audio band runs roughly **$5 (Koala) to $30 (Loopy Pro)**, with AUM at ~$21 — note that
AUM launched at $9.99 and raised its price repeatedly as the product matured, which is the
pattern to imitate. DJ Player Professional's ~$9.99 was, in hindsight, priced too low to fund
the product or to signal seriousness against a $50/yr incumbent.

The proprietary posture makes the purchase a product-and-support transaction. It argues for a
*fair, obviously-good-value* price rather than a professional-tool price.

### 5.2 Recommended price

**$39.99, one-time, universal (iPhone + iPad), Family Sharing on.** Launch at **$24.99** as a
founding price for the first release window, then settle at $39.99.

The pitch writes itself: *one year of djay, forever, and it works on your own files.*

With Apple's Small Business Program (15% under $1M/yr), $39.99 nets ~$34. Break-even framing
rather than a fabricated TAM: **$100k/yr requires ~2,950 purchases — about 8 a day.** Whether
that is plausible depends entirely on the existing install base and the free→paid conversion
rate on the current $7.99 Remote Libraries IAP. **That number is the single most important
input to this decision and it is not in the repo.** Pull it from App Store Connect before
committing budget; if Remote Libraries converts at a healthy rate on a real base, DJ at 5×
the price to a subset of that base is a straightforward extension. If the base is small, this
is a bet on new-user acquisition, which is a different and harder plan.

### 5.3 SKU structure

The shipped app has exactly one Pro feature — `ProFeature.remoteLibraries` at $7.99
(`Sources/Pro/ProFeature.swift`, one case, `ProEntitlement.isActive`). Three options:

| Option | Structure | Assessment |
|---|---|---|
| **A. Second IAP in the same app** | Add `ProFeature.djPerformance` as a second non-consumable alongside `remoteLibraries`. | **Recommended.** Zero new distribution surface, the upsell reaches an already-qualified audience, and it keeps the free player promise intact. Requires changing `isEnabled` from a single global `ProEntitlement.isActive` to per-feature entitlement — a small, contained refactor, and one the current single-case enum was clearly designed to allow. |
| **B. Separate DJ app** | New listing, new bundle ID. | Only justified if the DJ UI cannot coexist with the player UI. It can — as a mode, not a takeover. Rejected: doubles marketing and support for no gain. |
| **C. Raise the single Pro price** | One $34.99 "Pro" covering remote libraries + DJ. | Rejected. Breaks the promise made to existing $7.99 buyers, and forces listeners who only want remote libraries to pay for a DJ engine they will never open. |

Offer a **bundle**: DJ + Remote Libraries at a modest discount, and credit prior Remote
Libraries purchasers the $7.99 toward DJ. That is both fair and a strong conversion lever on
exactly the users most likely to buy.

### 5.4 What must not happen

The README documents a hard promise: features that are "taxes on your own disk and your own
phone" are free forever, enforced by `Tests/FreeTierRegistryTests.swift`. **The DJ tier must
gate only genuinely new capability** — decks, stems, mixing, recording, semantic search,
MIDI. Nothing currently free may move behind it, and nothing about playing your own music may
regress. Extend the free-tier CI guard to cover the DJ feature set explicitly, the same way
§45/§3207 of the spec extends the zero-telemetry guard to the DJ target. The credibility of
the free tier is a marketing asset worth more than any feature you could claw back into Pro.

---

## 6. Verdict and recommended plan

### 6.1 The three options, decided

| | Option | Verdict |
|---|---|---|
| **A** | **Mac-first as specced.** | **Reject.** Cold start, five entrenched desktop incumbents, an entire invented milestone (Part VI) to bridge a device split of its own making, and a second app to maintain forever. |
| **B** | **iPhone-only.** | **Reject as literally stated.** Right platform, wrong boundary — see §6.2. |
| **C** | **iPhone + iPad universal, one purchase, in the existing app; Mac deferred but uncut.** | **Adopt.** |

### 6.2 Why not iPhone-only

Excluding iPad would be self-inflicted. It is one universal binary and one purchase — there is
no meaningful incremental cost. iPad is where mobile DJing actually happens: it is djay's
flagship surface, it is the screen the two-deck layout in mockup Mac-06 can actually live on,
and it is the device a DJ props next to a controller. iPhone-only would hand the only
comfortable mobile DJ screen to the incumbent for free.

The right framing is **iPhone-first, iPad-complete**: iPhone gets a focused single-deck
performance surface that respects the screen; iPad gets the full two-deck workspace.

### 6.3 The repositioning that makes this work

This is the part that matters more than the platform choice.

**Do not ship "a DJ app for iPhone."** That is the frame DJ Player Professional has been
losing in for a decade, and it puts a small project in a feature war with a
well-capitalized incumbent that has better hardware support, better streaming deals and a
head start on stems.

**Ship "your library, mixable."** The buyer is not the working DJ shopping for a Serato
replacement. The buyer is **the person who already owns thousands of FLACs and already uses
Platterhead to listen to them** — persona P1 in the spec, minus the small-venue gigging. What
they want is to make a two-hour continuous mix of their own collection, find the next track by
feel, and have it come out sounding intentional. That user is *unserved*: djay wants them
streaming, rekordbox wants them buying CDJs, edjing wants them watching ads.

Everything follows from this frame:
- **Semantic vibe search is the headline feature**, not stems. It is the thing no competitor
  has, and it is the thing that is *only* valuable if you own a large library — which is the
  exact audience already installed.
- **Live stem separation drops to v1.1.** Prep-time cached stems (§36.1's first moment) are
  enough; on-demand real-time separation is where the thermal and latency risk concentrates.
- **Recording and the mix archive are core, not an afterthought.** Persona P3 becomes primary.
- **Two decks, no four-deck ambition, no DVS, no video.** Already the spec's non-goals.
- **MIDI-learn stays in v1** — USB-C controller support is a credible-professional signal at
  low cost, and AlphaTheta is actively marketing that path.

### 6.4 Concrete changes to `TONEARM_DJ_ARCHITECTURE.md`

1. **§1 thesis:** replace "your Mac is the studio" with a single-device thesis. Remove
   "built exclusively for Apple Silicon **Mac**"; the constraint becomes Apple Silicon
   generally (A-series and M-series), iOS 17+ / iPadOS 17+.
2. **§2 topology:** one app, one core, no bridge. The CloudKit diagram becomes optional
   multi-device library sync, not the product's spine.
3. **§2.1 division-of-responsibility table:** collapse to a single column.
4. **§3 personas:** promote P3 (mix archivist) and reframe P1 as the owner-listener per §6.3.
5. **§6 constraints:** drop Intel/macOS framing; add thermal-state and storage-budget
   constraints; add an explicit `AVAudioSession` constraint.
6. **§9 module map:** remove `#if os(macOS)` gating from the DJ modules entirely. This is the
   single most important edit for keeping the Mac option alive.
7. **§27.4 / §43.6:** adopt the track-level-pooled + crate-scoped-window vector policy and the
   gig-crate stem cache with a user-set storage budget (§4.3a).
8. **§34 / new section:** `AVAudioSession` configuration, route changes, interruptions,
   background recording, USB-C interface routing.
9. **§38–39:** delete the companion; demote sync to optional.
10. **§41–42:** delete the ten Mac screens; replace with an iPhone/iPad screen inventory. The
    existing Mac-04 (vibe search), Mac-05 (track prep) and Mac-06 (workspace) mockups are the
    right *content* for the iPad layout — they need reflowing, not redesigning.
11. **§43.7 runtime adaptation:** add thermal-state-driven degradation as a first-class path.
12. **§48 roadmap:** M5 mostly dissolves; hardware folds into M4. Net saving is close to a
    full milestone.
13. **New section:** monetization and entitlement — per-feature `ProFeature` entitlement, the
    free-tier CI guard extension, and the bundle/credit policy from §5.3.

### 6.5 Open questions to close before building

1. **Install base and conversion rate on the $7.99 Remote Libraries IAP** (App Store Connect).
   This is the gating input to the whole business case — §5.2.
2. **Does the free player's `ProFeature`/`ProEntitlement` refactor to per-feature entitlement
   cleanly?** Looks contained, but confirm before designing the paywall.
3. **Real thermal envelope:** how many tracks per hour can an iPhone 15/16-class device
   analyze while charging before it throttles? Validate in Phase 1, not Phase 4 — it sets the
   whole onboarding story.
4. **Key-lock quality on A-series** (spec §50.3 already flags this on M-series; re-validate).
5. **iPhone performance-surface design** — the one genuinely unsolved design problem. Mock it
   before committing to the engine's control surface API.
6. **Does the existing library layer (remote providers, transparent cache) feed the DJ engine
   directly?** Mixing from a Subsonic/Dropbox-backed track is a differentiator nobody else can
   touch — but the engine's real-time contract forbids network in the render path, so it needs
   an explicit "fully cached before load-to-deck" rule.

---

## Sources

- [djay Pro review 2026 — Offbeat](https://offbeatinc.com/djay-pro-review.html)
- [What features are included with a PRO subscription on djay for iOS — Algoriddim Support](https://help.algoriddim.com/hc/en-us/articles/360022496092-What-is-the-difference-between-the-FREE-version-and-the-PRO-subscription-to-djay-Pro-AI-for-iOS-)
- [How do I add songs from Files app on djay for iOS — Algoriddim Support](https://help.algoriddim.com/hc/en-us/articles/360009357980-How-do-I-play-or-add-songs-from-external-media-like-USB-sticks-or-hard-drives-iCloud-Drive-or-the-Files-app-on-djay-for-iOS)
- [rekordbox Plans & pricing](https://rekordbox.com/en/plan/)
- [rekordbox for iOS/Android features](https://rekordbox.com/en/feature/mobile/)
- [djay — Sensor Tower overview (download/revenue estimates)](https://app.sensortower.com/overview/450527929?country=US)
- [Best DJ Apps for Mobile in 2026 — DJ.Studio](https://dj.studio/blog/apps-for-dj-mixing)
- [Best DJ Apps 2026: We Tested 5 on Phone & iPad — We Are Crossfader](https://wearecrossfader.co.uk/blog/the-best-dj-apps-for-mobile/)
- [edjing Mix on the App Store](https://apps.apple.com/il/app/dj-mixer-edjing-mix/id493226494)
- [DJ Player Professional on the App Store](https://apps.apple.com/nl/app/dj-player-professional/id339810085?l=en)
- [Notes on the Discontinuation of Traktor DJ 2 — Native Instruments](https://support.native-instruments.com/hc/en-us/articles/16921462005405-Notes-on-the-Discontinuation-of-Traktor-DJ-2)
- [Serato Limited apps on the App Store](https://apps.apple.com/sg/developer/serato-limited/id1270510568)
- [AUM — Audio Mixer on the App Store](https://apps.apple.com/us/app/aum-audio-mixer/id1055636344)
- [djay 3.0 debuts as a free app with a subscription option — MacStories](https://www.macstories.net/news/djay-30-debuts-as-a-free-universal-app-with-a-subscription-option-for-pro-features/)
- [Koala Sampler on the App Store](https://apps.apple.com/us/app/koala-sampler-beat-maker/id1449584007)
- [Loopy Pro on the App Store](https://apps.apple.com/us/app/loopy-pro-looper-daw-sampler/id1492670451)
- [AlphaTheta DDJ-FLX2 (USB-C to iPhone)](https://alphatheta.com/en/product/dj-controller/ddj-flx2/black/)
- [AlphaTheta DDJ-GRV6](https://alphatheta.com/en/product/dj-controller/ddj-grv6/black/)
- [DJing with Smartphones & Tablets — Reloop](https://www.reloop.com/djing-with-smartphones-and-tablets)
- [DJ Software Market Size — Verified Market Research](https://www.verifiedmarketresearch.com/product/dj-software-market/)
