# Retained offline albums

Albums offer **Keep on This Device**. Retained albums are also available from Collections → Offline Albums and Storage → Offline Albums, including after an app restart and ordinary cache clearing.

## Behavior

- The retained manifest includes album metadata, membership, media revisions, actual saved byte counts and per-component completion. Complete photos use the edited original endpoint; videos use a self-contained playback file. A Live Photo requires its still and motion file before it becomes available in the retained grid.
- Downloads run while the app is active and pause when it leaves the foreground. Completed files survive interruption; an unfinished file starts again when the user resumes. Updates are explicit. Download on Wi-Fi prevents cellular, expensive and constrained transfers; cellular use requires the separate confirmation action.
- Partial files, invalid image/video containers, response length mismatches and storage failures cannot produce a complete album. Resume checks actual files, so missing or truncated saved files are downloaded again.
- Application Support storage is separate from the ordinary image/list/video caches. Removing a download removes its retained files. Signing out removes that account's retained files. The account/server identity and current request context bound every read.
- Locked and standalone hidden media are excluded. Immich normally marks a Live Photo's motion asset hidden; it is accepted only through two authenticated reads establishing the visible parent's exact pair. Both parent and motion revisions/authorization generations remain bound to the retained component. Parent retirement, hiding, pairing changes or file removal revoke existing playback leases as well as future reads.
- A held manual LAN route can read local retained media. Scoped local/cache checks accept only the active context and its canonical or explicitly saved account LAN root. A cache miss still uses the original network authorization, route and TLS checks. Holding a LAN route does not grant permission to send to either endpoint.
- Observed edits, removal or access rejection invalidate affected copies. During an actual network outage the app cannot learn a server-side change until connectivity or a subsequent authenticated response provides that information.

## Verification

- `offline-hidden-motion-focus.xcresult`: 11 focused checks passed, including hidden/visible paired-motion parent revocation and actual HTTP downloading followed by stopping the listener.
- `offline-held-lan-focus.xcresult`: 55 focused checks passed, including 13 offline checks plus existing manual LAN, account isolation, TLS transport and thumbnail-network regressions. The held-route test uses the real Nuke/ImageLoader path and local video file path; both loopback servers receive zero requests, while foreign origins, stale contexts and API network sends remain rejected.
- `offline-ui-grid-en.xcresult`: the complete English UI flow passed: download, service unavailable (HTTP 503), process relaunch, ordinary cache clearing, retained album discovery, photo viewing/return, ordinary video viewing/return and hidden-motion Live playback/return. Exported screenshots show the actual synthetic gradient photos and decoded color-bar video/Live frames.
- `offline-ui-dark-and-clean-host.xcresult`: 2 UI checks passed. Chinese album details were captured with the simulator's actual system appearance set to dark, then the synthetic account was signed out through Settings before native regressions. The system appearance was restored to light afterward.
- `native-clean-final.xcresult`: the final native unit/integration run executed 701 tests, with 3 environment skips and 0 failures (`TEST EXECUTE SUCCEEDED`). It ran after granting Photos permission on the dedicated simulator and normal fixture-account sign-out, with no restored gallery/realtime account competing with the unit host. The earlier `native-final.xcresult` failed those environment preconditions and is not the final passing result.
- Localization validation passed for 2,025 catalog entries using 1,941 compiler-extracted keys. The 27 new English/Simplified Chinese entries preserve the existing catalog order and values.

The final native run's 3 environment skips were:

| Test | Reason |
| --- | --- |
| `MemoryPlaybackTests.testOwnedMemoryFixtureCanBeReadOnlyOnItsAllocatedSimulator` | Requires its separately allocated memory UI simulator and synthetic fixture. |
| `PhotoEditDraftLegacyRestartTests.testPhase2RecoversPartialCommitInNewProcessAndConfirmsExplicitRetry` | Requires phase two in a separate invocation to verify process restart. |
| `TransferIsolationTests.testDataProtectionMetadataOnPhysicalDevice` | The simulator does not expose physical-device Data Protection metadata. |

Three existing external-service cases were explicitly excluded, rather than counted as skips, because `http://127.0.0.1:33284/api/server/ping` refused the connection. Their ownership/guard test remained included:

- `Immich341IntegrationTests.testActual341ExactPairRepairBulkCheckAndBothOriginalReadbacks`
- `Immich341IntegrationTests.testActual341NewUploadAndHeaderDuplicateShortCircuit`
- `Immich341IntegrationTests.testActual341PlaybackDownloadsLocallyAndAVFoundationDecodesFrame`

Evidence is retained locally under `execution/batch1-20261117/offline`. The dedicated UI fixture binds only `127.0.0.1:43891` and uses a generated PNG plus an existing synthetic MOV. It never authenticates to the production server or imports media into the system photo library. Its system password-saving prompt is dismissed without saving the synthetic password.

English image evidence is in `screenshots-en/` (`offline-en-downloaded.png`, `offline-en-restarted-after-cache-clear.png`, and the photo/video/Live viewer images). The verified Chinese dark image is `screenshots-zh-actual-dark/offline-zh-system-dark.png`. The older `screenshots-zh/offline-zh-dark-restarted.png` is light appearance despite its filename and is not dark-mode evidence. Build and test products remain in the task's `DerivedData/Build/Products`; result bundles and logs remain beside that directory.

The HTTP-listener-stop integration checks and the UI fixture's 503 mode are separate evidence. The UI result does not represent airplane mode or physical-device network testing. Physical-device playback, frame rate and Data Protection behavior have not been measured in this task.
