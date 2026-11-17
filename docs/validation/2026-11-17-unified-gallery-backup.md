# Unified gallery and backup recovery

The library defaults to All Sources, combining cloud and accessible device originals. Verified device/cloud pairs appear once. Device-only photos remain visible in months whose cloud contents have not loaded; partial cloud ranges retain their original slots. Counts and calendar projections are built with the rows off the main actor.

The source picker is a native UIKit menu with All Sources, Cloud and On Device in the same medium palette used by the sort controls. Backup & Sync is removed from that menu. Backup status is concise, with Back Up Now and recoverable failure actions. Grid badges use the existing small white glyph style. Grid, viewer and context menu resolve the same live account/revision state. Failed items retain a typed cause from the first failure, guidance and per-item/batch retry.

Source stacks and decoded surfaces are retained. A source handoff waits for its local inventory projection and initial viewport. The old source stays visible during preparation. Same-client foreground recovery retains the image pipeline; a new client retires its previous scroll hold. Tile reuse, image-size reflow, viewer handoff and Live Photo/video behavior are preserved.

## Verification

- Seven native UI acceptance flows passed on the owned synthetic iOS 27.2 simulator: source selection, foreground recovery, rapid scrolling, viewer open/return, Live Photo hold/release/swipe, actual failed-item recovery/retry, and single-photo backup updating the open viewer. The final source test also covers many device originals deduplicated to one cloud copy; the union may correctly be smaller than the device inventory.
- The final independent local suite completed 686 tests, with 3 expected environment skips and 0 failures. All 1,952 English/zh-Hans catalog entries passed coverage, placeholder and newline validation. Unit-test hosts mount their own real windows without a competing signed-in app gallery or automatic background workers.
- The three Immich 3.4.1 service integration tests passed in the earlier release-validation batch. Their latest rerun encountered connection refusal after the local Docker engine stopped responding. No global Docker restart or unrelated container changes were performed.

## Performance evidence and limits

Optimized simulator runs recorded 2,199 scrolling display-link intervals: p95 16.67 ms, p99 34.21 ms, maximum 60.33 ms. Final source handoffs took 548/636 ms on first preparation and 30/32 ms when retained. Warm viewer lifecycle durations were about 370–375 ms open and 334–349 ms return.

These are main-run-loop/lifecycle diagnostics, not physical display FPS. Longer callback gaps occurred during viewer setup (up to 275 ms); the simulator did not emit XCTest hitch results. This evidence does not establish zero dropped frames or physical-device 60/120 Hz performance. The opt-in frame recorder is excluded from release builds.
