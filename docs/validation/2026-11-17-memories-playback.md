# Native memory collections and music playback

Memory cards open the complete collection. A separate play button on each card and in the collection opens a fullscreen slideshow. The collection retains normal single-photo viewing and return navigation.

The slideshow plays photos and short video segments with a bundled soundtrack. It provides play/pause, replay, previous/next, thumbnail selection, mute, and close. Loading does not consume a photo's display duration. Upcoming previews and videos are prefetched; failed items have a retry action and can be skipped. Moving to the background, an audio interruption, or unplugging headphones pauses playback. Closing cancels loading and stops the soundtrack.

Card transition identity uses the memory ID rather than its cover asset, allowing multiple memories to share a cover. Cover retry controls do not intercept the card action, and the slideshow presentation host stays mounted across loading states. Navigation uses native zoom transitions; frame and control transitions use short fades. The actual system Reduce Motion preference disables the custom zoom and frame animations. The filmstrip has a bounded height and transport controls have explicit touch regions.

Soundtrack decoding and audio-queue startup run in a separate actor with ordered play/pause commands and cancellation checks. On iOS 27, audio-session activation and deactivation use the asynchronous APIs. The soundtrack loops, fades volume changes, and is quieter during video playback.

## Soundtrack provenance

The bundled, unmodified recording is **Vaporware (Calm Piano 1)** by **The Cynic Project / cynicmusic**. The author released it under CC0 1.0 Universal:

- Author's release: https://opengameart.org/content/calm-piano-1-vaporware
- Terms: https://creativecommons.org/publicdomain/zero/1.0/
- Attribution, download source and SHA-256 are bundled in `Imora/Resources/Music/Memory-Music-LICENSE.txt`.

The player shows the track and artist credit. Playback works without an Apple Music account.

## Verification

Xcode 27.2 and an independently allocated iPhone 17 / iOS 27.2 simulator, using only the local synthetic fixture:

- **40 targeted unit/integration checks passed**, covering playback timing and boundaries, pauses/buffering, completion/replay, actual soundtrack decoding and non-silent samples, cancellation during download, retry/skip, soundtrack stop, asset deduplication, locked/deleted item exclusion, collection behavior and viewer lifecycle.
- **Four UI flows passed**: shared-cover cards repeatedly opening collections and individual photos; actual bundled music playback with pause/mute, video selection and repeated reopen; background pause preserving the selected frame; playback and return navigation with the real global system Reduce Motion preference enabled and restored.
- After moving audio startup off the main thread, the final 40-check run and all three playback UI flows passed again, with no audio activation main-thread warning in the final UI log.
- English/zh-Hans catalog coverage, placeholders, newlines and reviewed unchanged literals passed for 1,900 entries. The recorded soundtrack SHA-256 matches the bundled file.
- Screenshot inspection confirmed the collection hero, grid, playback controls and bounded bottom filmstrip.

Local result bundles are retained under `execution/memories-20261117`: `unit-final2.xcresult`, `ui-cards.xcresult` and `ui-final2.xcresult`.

The dedicated memory UI fixture can be prepared with `python3 tests/integration/prepare-memories-ui.py` after the existing Phase 4 local service and legacy synthetic account are available. The script accepts no production destination. UI fixture and simulator ownership guards remain enforced; unrelated simulators skip these task-specific acceptance tests.

Physical-device frame rate and listening quality have not been measured. This implementation uses the existing memory API and selection; Apple's private story generation and Apple Music integration are outside this change.
