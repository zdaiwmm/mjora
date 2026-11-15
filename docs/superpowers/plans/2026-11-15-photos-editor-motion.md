# Photos editor and grid motion implementation plan

**Goal:** Preserve primary action positions; investigate system overlay suppression, align supported editing interactions with Photos, and make column changes continuous around the touched photo.

**Architecture:** Retain SwiftUI editor and the virtualized UIKit timeline. Preserve housing layout (explicit user correction), one bounded editor motion policy, and an interactive UIKit tile overlay that retains image identity across row regrouping. Render saved previews away from the main actor.

**Scope:** User's three requirements from 2026-11-15. Existing server capabilities remain authoritative; do not add controls for unsupported edits.

**Tech Stack:** Swift 6, SwiftUI, UIKit, XCTest; existing synthetic local fixture.

## Constraints and review focus

- Primary actions must retain their housing positions. There is no public SDK API for prohibiting other apps’ Live Activities; do not claim otherwise.
- Tool changes, aspect panel, rotate/flip, reset, undo/redo, original comparison, revert confirmation and save/cancel need coordinated transitions.
- Pinch must track the gesture and preserve the photo under its midpoint; reversal, cancellation and repeated gestures must clean up overlays.
- Animate visible tiles only; avoid bitmap re-encoding, model rebuilding and thumbnail requests on every gesture frame.
- Respect Reduce Motion. Verify actual simulator behavior; simulator results cannot establish physical ProMotion frame rate or expanded Dynamic Island behavior.

## Tasks

1. Investigate Dynamic Island suppression. Safe-area redesign was explicitly rejected; restore existing positions and document the public-API limit.
2. Inspect available system Photos editor in the simulator. Refine tool switcher and crop aspect presentation, coordinated state transitions and reversible edit history. Move save projection rendering off the main actor.
3. Add anchor/zoom geometry regressions. Capture visible tile image views once, track scale continuously, regroup once at release, restore anchor and animate each image into its new frame. Apply the same transition to menu column changes.
4. Build and run unit suite and synthetic editor/grid UI flows, inspect screenshots, review diff and document remaining device-only performance verification.

## Execution notes

- Implement in current clean checkout on `codex/photos-editor-motion`; initial implementation required no deployment or real photo mutation. The user subsequently authorized remote merge and deployment as 1.0.5 (7).
- Existing UI context loaded from `execution/ui-context`.

## Outcome

- Primary action positions preserved; Dynamic Island suppression remains an explicitly recorded public-API limitation.
- Supported editor interactions, native highlight/capsule styling, crop guide interpolation and background save projection implemented.
- Interactive anchored grid reflow, interrupted/repeated gesture cleanup and reduced-motion behavior implemented.
- See `docs/validation/2026-11-15-photos-editor-motion.md` for executed checks and real-device limitations. Initial source validation was local. Remote merge and physical deployment were subsequently authorized; release receipts track the actual outcome. No production media mutation is required.
