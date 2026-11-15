# Photos feedback implementation plan

**Goal:** Resolve the ten reported Photos/Albums presentation and playback defects on the installed 1.0.3 source baseline.

**Spec:** The user's ten corrections and the approved `docs/superpowers/specs/2026-11-15-photos-collections-design.md`.

**Architecture:** Keep the existing timeline, shared playback engine and album destinations. Use semantic foreground colors, one compact native glass navigation container, geometry-based scroll state, stable collection section sizes and a retained video layer.

**Constraints:** Preserve account isolation, sync, backup, safe deletion, iPad sidebar and existing viewer controls. Respect Reduce Motion. Public SwiftUI APIs can reproduce the system interaction patterns; exact private Photos animation parameters are unavailable and must not be claimed as verified.

## Tasks

- [x] Reproduce scroll return, initial selection geometry and live playback surface regressions with hosted tests; run them before fixes.
- [x] Correct semantic colors (items 1, 7, 8, 10) and selection indicator first-layout animation (5).
- [x] Restore navigation at the newest end, unify compact toolbar transitions, equalize smaller date/search controls, animate period drill-down and search (3, 4).
- [x] Query the available memories collection rather than only today's window, retain section geometry and load saved layout before first display (6, 9).
- [x] Retain and prepare Live Photo playback layers across engagement/end, prevent redundant layer work, and verify playback owner/cancellation behavior (2).
- [x] Build, run unit/UI regressions with synthetic media, inspect screenshots, review the diff and record any unverified physical-device behavior.

## Review focus

- Returning to the newest edge, short libraries and inset changes must restore navigation without flicker.
- Selection circles must have their final frame before becoming visible, including a cold first selection.
- Memories must remain isolated by account and show honest loading/empty/error states.
- A paused/ended Live Photo retains its decoding surface while its still is visible.
- Compact navigation must preserve search, album destinations, Dynamic Type and Reduce Motion.

## Progress

- Baseline: `895c4c4` (origin/main); working branch `fix/photos-native-feedback` in the existing clean native checkout.
- Investigated the installed source snapshot and current production paths. Validation uses an isolated synthetic Docker fixture; no production service was modified.

## Added user requirements

- [x] Fix explicit LAN setup on a fresh device by applying the exact authenticated bundled identity before its TLS probe; preserve existing trust boundaries and automatic-selection preference.
- [x] Keep local-address configuration accessible after setup and reflect an accepted HTTPS endpoint in the editable field.
- [x] Place changing Status/indexing progress and Current Files after stable Backup/Advanced controls, with Current Files also at the end of Active Backup content. Active Backup keeps its stable main content at a separate minimum viewport height so transfer growth does not recenter it.

## Evidence and review

- Initial five Photos regression cases failed before fixes; passed after implementation.
- Both new-device LAN cases failed before fixes; all 14 provisioning cases passed after fixes, including real loopback TLS.
- Full unit suite: 359 cases, one expected physical-device metadata skip, zero failures, including two complete synthetic motion plays using one player.
- A real isolated Immich 3.4.1 memory fixture returned 0 for today's window and 1 for the collection query. No production media was involved.
- Independent review found selection-bar overlap and insufficient bottom clearance; both were fixed. The corresponding child-timeline selection UI regression was confirmed RED then GREEN.
- Native segmented-control intrinsic height was corrected with UISegmentedControl. Compact controls use equal 36-point bounds; the normal floating bar follows the system reference's 62-point control height and bottom clearance.
- Existing ignored Xcode project was still generated from 1.0.2; regenerated from project.yml. The user then authorized merge and deployment; the release version is 1.0.4 build 6.
- Final scoped-search and single-navigation UI tests passed; native bottom search and populated historical memory screenshots inspected. English cold-session/settings flow and period/source-anchor flow passed. The search host stays on SearchTab with a visible native toolbar; explicit activation is retained. Physical-device smoothness and exact private Photos animation timing remain outside simulator evidence.
- Release validation reran all 359 unit cases and the Chinese login/settings/backup/LAN flow on 1.0.4 (6). Cold-login UI coverage now dismisses the delayed synthetic password-save sheet before interacting with the main navigation.
