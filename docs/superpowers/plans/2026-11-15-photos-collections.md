# Native Photos and Collections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Implement the approved native Photos/Albums interaction, preserve all existing functions, verify in Simulator, merge remotely and deploy.

**Architecture:** Reuse the virtualized timeline, paginated search, viewer and album mutation paths. Introduce account-scoped Collections presentation preferences and shared photo-grid controls. Compose native SwiftUI menus/toolbars and collections previews around existing destinations.

**Tech Stack:** Swift 6, SwiftUI/UIKit, iOS 26+, XCTest/XCUITest, XcodeGen, existing Mac updater.

**Spec:** `docs/superpowers/specs/2026-11-15-photos-collections-design.md`

## Global Constraints

- iOS 26+; no new dependencies.
- Prefer iOS native components and preserve Simplified Chinese/English localization and Dynamic Type.
- Preserve all existing viewer, album, backup, deletion, capability and account boundaries.
- No cloud/device segmented row, duplicate All Cloud Photos entry or permanent extra control row.
- Keep signing/enrollment/credentials private.

## Review Focus

- Unloaded timeline months must remain represented in Years/Months and filters must search beyond loaded pages.
- Account changes must not expose another account's pinned album IDs, previews or persisted state.
- Returning from a viewer, changing source and entering/exiting selection must preserve a usable scroll anchor and controls.
- Unsupported server features and empty/failed preview requests must not hide unrelated collections or their destinations.
- Album mutation rollback, invitation deep links and local-only actions must retain their existing permissions and targets.

### Task 1: Presentation state and aggregation

**Files:** Create `Imora/Features/Albums/CollectionsLayout.swift`, `Imora/Features/Timeline/PhotosBrowserState.swift`; test `ImoraTests/PhotosCollectionsTests.swift`.

**Interfaces:** `CollectionsLayout` stores normalized ordered/collapsed section IDs and pinned shortcut IDs. `PhotoPeriod` derives year/month IDs, totals and representative bucket IDs from `[TimelineSection]`. `PhotosGridControls` carries grid density/appearance, selection and navigation requests without per-frame Observation invalidations.

- [x] Write and run failing behavior tests for persisted account isolation, normalized reorder/pinning, unloaded period totals and month drill-down targets.
- [x] Implement the types and account-scoped preference storage.
- [x] Run the focused tests and commit the coherent state layer.

### Task 2: Native Photos browsing

**Files:** Modify `TimelineTab.swift`, `DeviceLibraryScreen.swift`, `TimelineScreen.swift`, `TimelineModel.swift`, grid row presentation as needed; create `PhotosBrowseMenu.swift` / `PhotoPeriodsView.swift`; update focused tests.

**Interfaces:** Reuse `TimelineFilter`, `TimelineModel`, `SearchModel` and `PhotosGridControls` from Task 1. Retain `TimelineNavigationRouter` behavior. A root-only presentation option hides date title bands without affecting other timeline clients.

- [x] Add a failing UI flow asserting the source menu and absence of the old segmented control, plus focused tests for full index aggregation and filter requests.
- [x] Implement native leading title/source/account menu, native filter/selection toolbar groups and edge-to-edge grid.
- [x] Implement functional sorting, local/cloud filtering, grid density/aspect presentation, period drill-down and remembered source/viewport state.
- [x] Verify selection, selected-items sheet, context menus, repeated viewer return and device access behavior in Simulator; commit.

### Task 3: Albums as Collections

**Files:** Modify `AlbumsTab.swift`, `MainTabView.swift`, `MemoryLane.swift`; create `CollectionsHome.swift` and native layout/pinning editors; reuse Library destination screens, album cards and mutation callbacks.

**Interfaces:** `CollectionsLayout` from Task 1; existing `Album`, `Person`, `LibraryDestination`, `AlbumDetailScreen`, `NotificationRouter`. Only the Albums tab owns album mutation state and its navigation path.

- [x] Add a failing UI flow for three bottom destinations, migrated utilities and absence of duplicate cloud entry.
- [x] Build the native collections home, previews, independent loading/error states and List-based editors.
- [x] Preserve all/mine/shared filtering and search on the full album list, creation, details/cover/member/link/activity operations, rollback and deep links.
- [x] Verify pin/collapse/reorder persistence and account/capability boundaries; commit.

### Task 4: Verification, native visual pass and deployment

**Files:** Update localized strings, UI tests, version/build and validation notes; no private configuration in Git.

**Interfaces:** Existing local synthetic fixture, simulator build/signing helpers and enrolled Mac release scripts. New release version/build is chosen after checking the currently deployed app.

- [ ] Run full unit suite, existing localization/viewer flows and new native Photos/Albums flows. Inspect screenshots for both system appearances, narrow/large text, menus, selection, empty/failed collection previews and nested album navigation.
- [ ] Perform a fresh whole-change review, address important findings with focused regression tests and rerun required checks.
- [ ] Commit, push, integrate into remote main, verify the integrated revision and prepare/sign the app from that revision.
- [ ] Publish/install through the existing updater using the user's deployment authorization; verify installed version/build/source revision and retain release receipts privately.
