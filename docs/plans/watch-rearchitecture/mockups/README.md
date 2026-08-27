# Watch Rearchitecture Mockups

Open [`index.html`](index.html). All files are standalone static HTML with one local
stylesheet and no network dependencies.

## Coverage

| File | Plan screens |
|---|---|
| `01-connected-search.html` | W1, W2, W3 |
| `02-offline-downloads.html` | W2 offline, W4, W5, W6, W12 empty |
| `03-now-playing.html` | W7, W8, W9 transition/route states |
| `04-iphone-management.html` | P1, P2, P3, P4, P5 language |
| `05-transfer-recovery.html` | W10, W11, W12 recovery |

These mockups are normative for hierarchy, wording, state visibility, playback-target
clarity, and safe actions. They are not fixed-pixel specifications. SwiftUI must use native
watchOS layout, safe areas, Dynamic Type, and current platform components.

Adding or materially changing a plan screen requires updating the implementation plan's
UI inventory, this coverage table, the relevant mockup, and the acceptance matrix.
