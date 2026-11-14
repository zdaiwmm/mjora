# Manual LAN route validation

The full simulator suite passed on 2026-11-14 at 09:54:47 Asia/Shanghai: **110 tests, 109 passed, 1 skipped, 0 failures**. This includes 27 new route tests and two bilingual UI flows. The skipped check requires physical-device file-protection metadata. See the [Xcode summary](2026-11-14-manual-lan-results.json).

Backup and Local Network now show the active endpoint and explicit local/external actions. A manual local choice uses only the enabled saved address for the current account, requires Wi-Fi and confirmation, and checks reachability with an unauthenticated, redirect-blocking ping. HTTP confirmation explains the lack of encryption and server identity verification. No Wi-Fi-name entitlement or sign-out is needed.

Manual local connection failures do not fall back to the external endpoint. A changed network, account, local configuration, or a real return from background clears the temporary choice. Permission dialogs and other inactive/active transitions preserve it. Previously captured local media/upload URLs cannot acquire account credentials after the active route is cleared. Existing upload redirect refusal remains in force.

The route tests use isolated preferences, injected probes and notification centers. They cover unavailable/mismatched settings, missing SSID, failed probes, cancellation and stale results, explicit external selection, transport failures, lifecycle transitions, and authorization revocation. Reviews identified the stale-URL and permission-dialog cases; both have regression coverage and passed the final suite.

English/Chinese resources cover all 1,592 current compiler-extracted app/extension keys. The shipped catalogs contain 1,608 entries including permission descriptions; placeholders, line breaks and English fallback validation pass.

| Screen | 简体中文 | English |
| --- | --- | --- |
| Backup | [Screenshot](manual-lan-screenshots/zh-Hans-backup.png) | [Screenshot](manual-lan-screenshots/en-backup.png) |
| Local Network | [Screenshot](manual-lan-screenshots/zh-Hans-local-network.png) | [Screenshot](manual-lan-screenshots/en-local-network.png) |

UI flows use only the dedicated loopback Immich fixture and synthetic account/media. These screenshots show the controls and unset-local-address state; they do not establish a physical home-network transition or a signed device installation. The unauthenticated ping is a reachability check, not server identity proof. No production photo service was queried for this validation.
