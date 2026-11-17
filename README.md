# mjora

A native iOS client for self-hosted photos, based on [Imora iOS](https://code.vexcited.com/imora/ios). Original upstream author: **Mikkel ALMONTE--RINGAUD (Vexcited)**. Upstream snapshot: `619fa7882595fb50670d54b4c85fe1c0cc143f1b`.

This modified version adds Simplified Chinese, immutable account/request boundaries, exact Live Photo backup verification, strict original-file readback before removing device copies, and recoverable upload queues. It remains licensed under **GNU GPL v3**; see [LICENSE.md](LICENSE.md).

The repository starts from a reviewed publication snapshot. Local implementation/audit history containing private server settings is not published. The app's display name and original upstream notices are retained.

Latest local validation: **239 tests, 238 passed, 1 physical-device check skipped, 0 failures**, including confirmed-update boundaries, version UI, server-removal protection, reconnect membership refresh, pinned TLS LAN routing, real multipart upload and receipt replay, background continuation policy, local Immich 3.4.1 integration, and English/Chinese UI flows with repeated viewer return checks. See [wireless update validation](docs/validation/2026-11-14-wireless-update-validation.md), [remote-removal validation](docs/validation/2026-11-14-remote-removal-validation.md), [background investigation](docs/validation/2026-11-14-background-runtime-validation.md), and [publication notes](PUBLICATION.md). Physical background stability remains unresolved. The separately reported fullscreen-return interaction issue was clarified as PC Web behavior and requires validation in the server repository.

## Build and test

Use Xcode with the iOS 26+ SDK and install XcodeGen. Generate the project with `xcodegen generate`, then open `Imora.xcodeproj`. Configure your own development team, bundle identifiers and App Group for device signing.

```sh
# Choose a simulator installed on your Mac.
IMORA_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17' scripts/test-ios.sh
```

`IMORA_XCODEGEN_PATH`, `IMORA_DERIVED_DATA`, and `IMORA_PACKAGE_CACHE` can override local tool/cache paths. Integration/UI tests use only a dedicated local synthetic fixture; see [fixture setup](tests/integration/README.md).

## App version and updates

Settings → About & Updates shows the installed app version and build. Private enrolled builds check an authenticated Mac HTTPS host for a prepared release and request wireless installation only after explicit confirmation. Signed personal packages stay private on the Mac; GitHub contains source. See [wireless update setup and behavior](docs/wireless-updates.md). Existing automatic re-signing remains separate from installing a new version.

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
- Keep an album on this device from its menu; find retained copies in Collections → Offline Albums or Storage → Offline Albums. Photos, video playback files and both Live Photo components persist separately from the ordinary cache. Downloads pause when the app leaves the foreground, updates are manual, and signing out removes this account's retained copies.
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

- Encrypted, resumable system background uploads on servers advertising `backgroundUploadsV1`, with protected recovery records and authenticated completion checks. Account credentials and plaintext stay on guarded connections; other servers retain guarded foreground uploads.
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
