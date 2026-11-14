# mjora

A native iOS client for self-hosted photos, based on [Imora iOS](https://code.vexcited.com/imora/ios). Original upstream author: **Mikkel ALMONTE--RINGAUD (Vexcited)**. Upstream snapshot: `619fa7882595fb50670d54b4c85fe1c0cc143f1b`.

This modified version adds Simplified Chinese, immutable account/request boundaries, exact Live Photo backup verification, strict original-file readback before removing device copies, and recoverable upload queues. It remains licensed under **GNU GPL v3**; see [LICENSE.md](LICENSE.md).

The repository starts from a reviewed publication snapshot. Local implementation/audit history containing private server settings is not published. The app's display name and original upstream notices are retained.

Latest local validation: **193 tests, 192 passed, 1 physical-device check skipped, 0 failures**, including pinned TLS LAN routing, real multipart upload and verified-count replay, background continuation policy, live transfer progress, local Immich 3.4.1 integration, and English/Chinese UI flows. See [verified backup validation](docs/validation/2026-11-14-verified-backup-validation.md) and [publication notes](PUBLICATION.md). Physical server/phone acceptance, signed share-extension and system Photos confirmation gates remain separate.

## Build and test

Use Xcode with the iOS 26+ SDK and install XcodeGen. Generate the project with `xcodegen generate`, then open `Imora.xcodeproj`. Configure your own development team, bundle identifiers and App Group for device signing.

```sh
# Choose a simulator installed on your Mac.
IMORA_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17' scripts/test-ios.sh
```

`IMORA_XCODEGEN_PATH`, `IMORA_DERIVED_DATA`, and `IMORA_PACKAGE_CACHE` can override local tool/cache paths. Integration/UI tests use only a dedicated local synthetic fixture; see [fixture setup](tests/integration/README.md).

## Upstream features

A native iOS client for your self-hosted photos. Supports [Imora](https://imora.vexcited.com), [Noodle Gallery](https://github.com/open-noodle/gallery) and [Immich](https://github.com/immich-app/immich).

## Features

### Library

- Photo timeline with month sections, a drag scrubber and live updates from the server.
- Memories, birthdays, trips and recaps included, which you can remove from the memory lane.
- People, places, favorites, archive, trash and a locked folder behind Face ID.
- Favorite any photo you can see, shared ones included, where the server keeps favorites per user.
- Stacks to show, create and manage.
- Photo map with clustering and filters.
- Duplicates and large files to review.
- Library Cleanup: a daily rewind to keep, favorite or trash the photos taken on this day, and queues for space hogs, blurry photos, screenshots and bursts.

### Viewer and editing

- Full-screen viewer with zoom, video playback, EXIF and map, favorite, archive, trash and share.
- Text found in photos, shown and copied.
- Spatial Scene, a 3D parallax view that follows the tilt of your phone.
- Photo editor with crop, rotate, mirror, exposure, contrast, saturation and invert.
- Video trim.

### Albums and sharing

- Albums with sharing, public links and covers, plus multi-select actions everywhere.
- Comments and likes on shared albums.
- Gallery's shared spaces and user groups.

### Search

- Search by content, file name, description, folder or text in photos.
- Recent searches, people and place suggestions.
- Filters for people, date, location, tags, media, camera, rating and library, with live counts for each option.

### People

- People and pets, with face suggestions to review.
- Share people with the members of your face sharing group, with a role, and keep their names in sync.
- A Face Sharing screen to invite members, answer invites, leave and recognize faces again.

### Backup

- Guarded uploads while iOS grants the app execution time, with protected recovery records for resuming after interruptions. Sensitive uploads reject redirects; daemon-owned background continuation is not currently enabled.
- Resumable uploads in chunks on Imora.
- A saved local server address, selectable from Backup or Local Network without reading the Wi-Fi name. Builds with Wi-Fi-name access can also select it automatically on saved networks. Manual LAN failures do not silently fall back to the external address.
- Automatic LAN selection can authenticate a saved HTTPS server using an app-scoped CA enrolled through trusted setup. Manual local mode holds instead of silently switching to WAN when connectivity or consent is unavailable.
- Backup and Active Mode show original filenames, preparation/iCloud/upload/verification stages, and upload speeds measured from actual transport counters.
- An explicit whole-library backup can request iOS continued-processing time, including promotion of an existing run. iOS controls runtime; automatic recovery uses discretionary processing, and selected-photo uploads retain foreground behavior.
- Share extension that uploads photos and videos from any app.

### Account and administration

- Sign in with a password, OAuth or a passkey, the passkey going through the server's web login on Imora.
- Manage passkeys, your password, devices, API keys and the OAuth link.
- Notifications inbox for album invites, activity and server alerts, mirrored as iOS banners.
- Admin panel for users, job queues and server statistics.

The app reads what each server offers and only shows what it supports, so the same build works on old and new versions of every server.
