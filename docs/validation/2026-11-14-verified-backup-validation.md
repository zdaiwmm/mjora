# Verified backup validation

The complete simulator run passed at 2026-11-14 12:05:35 Asia/Shanghai: **193 tests, 192 passed, 1 skipped, 0 failures**, comprising 191 unit/integration checks and two bilingual UI flows. The skip requires physical-device file-protection metadata. [Curated machine-readable summary](2026-11-14-verified-backup-results.json).

## Backup and routing evidence

- An actual `ImoraClient.uploadAsset` multipart request reaches the pinned loopback TLS listener with the exact complete body, content type and authorization header. A distinct canonical external listener receives zero requests. Receipt-only state remains unverified; remote metadata verification increases the backed-up count; replaying the identical receipt preserves that proof and count.
- The exact duplicate-receipt fix preserves existing valid proof after source revision/type/checksum checks. Changed remote IDs and stale sources still invalidate or reject evidence.
- Real TLS tests cover the correct CA, wrong CA, hostname, validity, API boundary/port, redirect refusal, and replacement of an immutable pin. API, original readback, local media, image loading, realtime handshake and process-owned upload paths exercise fixed-identity sessions. Upload redirects remain refused.
- Manual local intent holds instead of authorizing WAN during uncertainty. Captured local/external URLs cannot bypass hold at authorization or task resume. Unpinned same/empty-gateway callbacks require confirmation; only an exact valid pin permits duplicate-callback stability. Verified Wi-Fi selection uses an authenticated unauthenticated-content ping without SSID access.
- Optional `Imora/Resources/LocalServerIdentity.json` enrollment binds the exact external account root, previous local root and new HTTPS identity. It applies once through trusted private build setup, respects disabled or edited settings, and is ignored by Git. Private keys and deployment-specific identities do not belong in this repository. No trust-on-first-use or system CA profile is installed.

These are synthetic loopback and isolated Immich 3.4.1 results. They do not establish the physical phone's actual Wi-Fi route or production server storage durability. Backup proof checks identity, ownership, checksums, type and Live Photo association; byte-for-byte original readback remains an additional device-copy-removal requirement.

## Runtime and interface

Both backup views expose each active resource's original name, preparation/iCloud/upload/verification stage, known fraction, and actual measured upload speed. Attempt/sequence/component guards reject late callbacks; speed uses monotonic transport byte counters and decays during idle periods. Preparation does not fabricate upload speed. Synthetic presentation captures: [中文](verified-backup-screenshots/zh-Hans-current-files.png), [English](verified-backup-screenshots/en-current-files.png).

Foreground user actions can request whole-library `BGContinuedProcessingTask` execution even when a whole-library run already exists. Requests and callbacks are bound to the originating workload/account generation. Ambiguous continued-task expiry preserves work and requires explicit resume; normal discretionary-processing expiry can retry. Completion cannot erase a pause barrier. Cancel withdraws pending/current owner-specific work, and a late denied/cancelled result cannot restart it through UI fallback. Selected-photo jobs do not expand into whole-library requests.

Background App Refresh availability is read-only; the interface explains settings and scheduler denials. Continued processing requires an explicit foreground request and remains subject to iOS execution limits. [Apple long-running tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados), [Apple WWDC guidance](https://developer.apple.com/videos/play/wwdc2025/227/).

All 1,639 compiler-extracted app/extension keys have English/Chinese coverage; shipped catalogs contain 1,659 entries including permissions. Placeholder, newline and fallback checks pass. Actual UI flows cover login, synthetic photos, settings, privacy, backup, local network and sign-out in both languages. The English flow's keyboard-layout timing was corrected and both complete flows passed the final run.

| Screen | 简体中文 | English |
| --- | --- | --- |
| Backup | [Screenshot](verified-backup-screenshots/zh-Hans-backup.png) | [Screenshot](verified-backup-screenshots/en-backup.png) |
| Local Network | [Screenshot](verified-backup-screenshots/zh-Hans-local-network.png) | [Screenshot](verified-backup-screenshots/en-local-network.png) |

Independent reviews identified and verified fixes for unpinned equal-gateway authorization, submission owner changes, paused completion, pending cancellation and late fallback. The reviewed scope has no remaining Important/Critical findings. Actual server enrollment, signed installation, app switching/lock, scheduler acceptance and actual LAN byte transfer remain deployment acceptance work; simulator success does not substitute for those observations.
