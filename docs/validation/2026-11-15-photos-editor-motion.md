# Photos editor and grid motion validation

Source branch: `codex/photos-editor-motion`, based on `5f210a0`. Release target: **1.0.5 (7)** for both app and share extension.

## User correction and unresolved platform requirement

Cancel/Done retain their original housing positions. The proposed safe-area relocation was explicitly rejected and fully reverted. Public iOS APIs expose no mechanism to prohibit other apps’ Dynamic Island activities; this requirement is unresolved, not reported as fixed. Existing `statusBarHidden()` is retained. Apple describes activity selection as system-owned: https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities.

## Implemented interaction coverage

| Scenario | Behavior |
| --- | --- |
| Editor entry/exit | iOS 27 / visionOS 27 system crossfade; earlier systems retain their native presentation transition |
| Available tools | Photos-style capsule, yellow marker/highlight and value rings; unavailable adjustment tool remains visibly disabled |
| Tool switch | Moving selection marker, coordinated canvas and tool pane transitions; original comparison clears |
| Aspect panel | Top ratio control expands/collapses the tray; ratio/orientation changes animate crop guides and mask |
| Rotate/flip/reset | One history step per operation; geometry transitions share a bounded 280 ms motion policy |
| Adjustment scrubbing | Background coalesced CI preview; one history step after scrubbing; inactive tools keep their amounts |
| Original comparison | Tap to toggle, hold to compare while pressed; shows full original geometry; never changes saved edits |
| Undo/redo | Flush pending input before undo; invalidate redo on a new edit; animate restored geometry |
| Revert | Source-anchored native confirmation; dismiss preserves edits; confirmation restores geometry/adjustments and removes preserved unknown edits only with explicit intent |
| Save | Freeze input, show progress, render/encode projection off the main actor, return through optimistic preview and persist using existing rollback behavior |
| Cancel | Native confirmation for unsaved changes; discard returns without saving |
| Grid pinch | Reuse decoded images in visible tile replicas; transform per gesture frame; regroup once at release and animate each photo into its destination |
| Pinch anchor | Preserve a point inside the touched photo, or nearest photo center over a gutter/title; clamp at library ends |
| New visible tiles | Join reflow alongside existing photos when zooming out |
| Interrupted/repeated pinch | Remove previous animator/overlay; cancel on grid dismissal or width change |
| Reduce Motion | Preserve anchor without generating thumbnail replicas or zoom animation |

The server DTO accepts only 0/90/180/270-degree rotations. Arbitrary straightening, perspective, and unsupported filter controls were not added. Supported tool styling is aligned with Photos, but this is not a claim of feature-for-feature or frame-identical reproduction of private Photos internals.

## Evidence

Release 1.0.5 (7) repeats the full unit suite and the editor/pinch UI flows. The settings flow’s former build-6 assertion was updated to build 7; its initial mismatch is retained in the release log and verified by the follow-up run.

- `execution/photos-editor-motion/final.log` / `final.xcresult`: 367 unit tests, 1 expected physical-device-only skip, 0 failures; 2 synthetic UI flows, 0 failures.
- UI covers repeated pinch in both directions, opening a photo afterward, aspect tray, rotate, undo/redo, dismiss and confirm revert, save/return and discard/return.
- New unit regressions cover pinch anchor math, gutters, range/reversal/invalid scales, overlay cancellation/replacement, reduced motion and saved preview crop/rotation dimensions.
- `execution/photos-editor-motion/unit-delivery.log` / `unit-delivery.xcresult`: final source built and 367 unit tests passed, with 1 expected physical-device-only skip and 0 failures.
- `execution/photos-editor-motion/entrance-final.log`: final presentation transition editor/revert/save/cancel flow passed.
- `execution/photos-editor-motion/editor-02-evidence`: inspected editor tool, aspect, confirmation and return screenshots.
- `execution/photos-editor-motion/system-editor.png`: inspected system Photos crop editor reference.
- Localization coverage: 1,785 entries, English/Simplified Chinese, placeholders/newlines valid.
- Independent read-only code review found and closed the gutter-anchor mismatch; no other important correctness issues confirmed.

Only synthetic fixture media/account and the dedicated simulator were used. The user authorized remote merge and requested preparation of the signed package while the physical phone is unavailable. Device installation is deferred; release and signing receipts are tracked separately. Simulator functional checks do not establish real-device 60/120 Hz frame pacing, sustained memory/thermal behavior, or other-app Dynamic Island suppression.
