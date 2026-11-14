# Native Photos/Collections execution ledger

Plan: `docs/superpowers/plans/2026-11-15-photos-collections.md`
Spec: `docs/superpowers/specs/2026-11-15-photos-collections-design.md`
Workspace: `/Users/achilles/mjora/imora-photos-native`, branch `feat/photos-collections-native`.
Base: `b97bd80` (remote main, includes the earlier sync/backup work).

- User approved prototype and explicitly authorized implementation, simulator validation, remote merge and deployment. Continue without another plan approval step.
- Workspace setup: native worktree tool did not return after several minutes; canceled the call and used a Git worktree inside the authorized workspace. No source changes were made in the original checkout.
- Pre-flight interfaces: Task 1 presentation state is shared by Photos and Collections; Tasks 2/3 reuse existing destination/mutation APIs rather than duplicating them.
- Baseline full unit suite is running; output `/Users/achilles/mjora/execution/photos-native-baseline.log`.
- Native reference screenshots and interaction research: `/private/tmp/mjora-photos-research/evidence-03` and `evidence-04` (system Photos, iOS 27.2).
- Deployment uses existing private preparation/signing/updater machinery. Existing build-4 install helper is intentionally restricted to that old release; create a task-specific exact-revision request for the new release rather than weakening the old helper.

## Task status

- Task 1: complete. Five focused tests failed before implementation and now pass. Full unit suite: 340 tests, 1 physical-device-only skip, 0 failures. Logs: `execution/photos-native-state-red.log`, `photos-native-state-green.log`, `photos-native-state-suite.log`.
- Task 2: implemented. Native source/sort/filter/selection controls, full-index periods, paged media results and local filters are integrated. Simulator selection, preview, viewer and source-switch flow passed in UI run 04. Long-library/latest-end regression verification follows the final review fixes.
- Task 3: implemented. Three mobile tabs; migrated Library destinations; native collections, pinning/layout editors and complete album list. UI run 04 passed pin/collapse cold-launch persistence, album create/detail/delete and utility destinations.
- Task 4: final verification running. Version 1.0.3/build 5 follows installed 1.0.2/build 4. Final unit suite: 347 tests, 1 physical-device-only skip, 0 failures (`execution/photos-native-unit-final-03.log`).

## Fresh final review and fixes

- One fresh read-only whole-branch review found four Important lifecycle issues. Fixed initial scroll persistence before restoration, declared ascending local presentation, joined in-flight month loads, and refreshed media searches on realtime/foreground/reappearance/manual refresh with a current mutation revision.
- `testLongLibraryRestoresSourceAnchorAndDrillsIntoPeriods` exposed cold launch at the oldest end before the position fix (`photos-native-newest-red.log`); final UI verification is running.
- `testAwaitingAnAlreadyLoadingMonthWaitsForItsProjectedAssets` failed both asset/row assertions before the joining fix (`photos-native-period-red.log`) and passes in the 346-test suite.
- `testMediaSearchRefreshesAfterRealtimeChangesWithoutChangingItsFilter` failed before listener support (`photos-native-review-red.log`) and passes in the final suite.
- The three initially Minor retention findings were also treated as required: share capability rules between the home and pin editor; restore failed delete/leave detail from its originating parent; preserve unread notifications in the source menu. Availability and nested rollback tests failed before their types existed (`photos-native-navigation-red.log`) and pass in the full suite. No review findings are deferred.
- The complete final review fix pass passed 346 tests, one expected physical-device skip and zero failures.
- Synthetic long-library fixture contains 101 photos over 33 months (2024–2026). No production library is used for UI mutations.
- Native UIKit menus omit item accessibility IDs on this runtime, so UI tests select their localized visible labels. No production test-only hooks were added.
- Date Added works on cloud/all and favorites. Local added timestamps and createdAt sorting in paged media search are unavailable in the current source/API, so those combinations disable that new choice. Existing date grouping remains available in View Options.
- Simulator signing uses Xcode's normal embedded simulator entitlements and an empty actual signature entitlement dictionary; app and share extension verification passes.

## Final visual pass

- All four native Photos/Collections UI flows passed in dark appearance at Accessibility Medium text size (`photos-native-ui-final-dark-large.log`). This includes source switching, selected-items preview, viewer return, period drill-down, pin/collapse restart persistence, album create/delete and migrated utilities.
- Screenshot review found that per-month compact rows left gaps after zooming out. `testCompactGridFillsRowsAcrossMonthBoundariesWhenZoomedOut` reproduced three partial rows instead of two full rows (`photos-native-packing-red.log`). Loaded months now share continuous rows; unloaded ranges keep virtual placeholders. The final full suite passes 347 tests, one expected device skip, zero failures. A grid-only UI rerun is in progress.
- Native selection uses system blue and the trailing bottom corner; device backup badges retain a separate position. Native title text stays at navigation-bar scale while collection content supports larger accessibility sizes.
- Chinese localization/settings/privacy and repeated viewer flow passed. English cold-launch regression is running after dismissing the system credential prompt; its modal transition must not intercept test gestures. The public simulator product intentionally has no private update enrollment; the private update-check test is skipped there, while actual deployment uses the enrolled Mac service.
