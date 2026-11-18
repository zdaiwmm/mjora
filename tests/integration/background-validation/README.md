# Synthetic background validation tools

These tools prepare isolated candidates and check acceptance evidence. `prepare` is offline. `fixture.py serve` explicitly creates disposable local credentials and contacts only its own real API. No command installs an app or reads Photos. Lock-screen and whole-library product acceptance remain separate B2/B3 tasks.

## Files and boundaries

- `tool.py prepare` exports the explicitly named **current HEAD**. It rejects a stale request or revision before exporting. It adds a compile-gated transport panel to `RootView`, retains `AppDelegate` and `SessionStore`, and isolates bundle IDs, App Groups and the Keychain service. It does not copy signing profiles or renewal configuration.
- `BackgroundValidationPanel.swift` requires manual preparation/run actions after a new synthetic login through the normal session. Its configuration pins the API origin, fixture ID, account ID and synthetic email. An unauthenticated fixture attestation must pass before authenticated requests are allowed. It never falls back to reading a production Keychain item.
- `BackgroundValidationLedger.swift` owns opening, acknowledged staging, provisional/verified results and cleanup states. It writes an `openingUnknown` intent before opening a session and persists the exact staging reference before another network action. Recovery queries only that reference. A reference owns staging only. Asset deletion additionally requires a durably observed exact `status == "created"` receipt, authenticated owner/unique run filename checks, and fresh original byte count/SHA-1/SHA-256 matching the manifest. Unknown statuses and unqualified duplicates never grant deletion authority.
- `SyntheticValidationVideo.swift` generates two H.264 frames and a valid MP4 `free` box. `GenerateVideo.swift` is its separate macOS command. This fixture proves transport byte handling, not preparation cost for a large, fully encoded video.
- `relay.py` receives only encrypted parts and the upload capability. A registration pins one run, upload ID and capability digest. Account authentication headers, arbitrary upload IDs and redirects are rejected. The body is bounded to one 8 MiB part plus 28 AES-GCM bytes. Raw headers, capability, key and bodies are never written to evidence.
- `validation.py` checks versioned manifests and separate stable, interrupted and PhotoKit scenarios. A complete result is always `EVIDENCE_COMPLETE_REVIEW_REQUIRED`, never product PASS.

Both listeners default to `127.0.0.1`. The relay can also use TLS on one explicitly selected private IPv4 interface. Its bind address, port and scheme must match the candidate request; the relay verifies the backend with the supplied fixture CA, and neither listener follows redirects. Both commands are bounded foreground processes.

## Start the isolated real API

Use a local Docker daemon with sufficient memory for the server and PostgreSQL, Python 3.12+ and OpenSSL 3. Choose the **immutable local image IDs** of a tested MJora API, its compatible PostgreSQL image (including its vector extensions), and Redis. The known-good image roles and the origin of this setup are documented in `execution/batch1-rollout-20261118/server-integration/REPORT.md` in the workspace. IDs in that historical report are from another host; confirm the images exist locally and that the server image corresponds to the revision under test. Do not supply a prior database, production Compose `.env`, or existing library volume. The launcher uses only a local Unix socket, fresh labelled resources and an internal Docker network, and does not pull images or publish Docker ports.

From this tools directory, run one fixture per scenario. Use a fresh private output directory and unused ports. For a no-device smoke use the default loopback; use the full 512 MiB default for physical acceptance. Choose either `transport-stable` or `transport-interrupted`.

```sh
NATIVE_HEAD=$(git rev-parse HEAD)
python3 -B fixture.py serve \
  --output /private/task/stable-fixture --source-revision "$NATIVE_HEAD" \
  --scenario transport-stable --duration-seconds 5400 \
  --backend-port 9443 --relay-port 9444 \
  --server-image "${MJORA_SERVER_IMAGE_ID:?Set the local MJora image ID}" \
  --database-image "${MJORA_DATABASE_IMAGE_ID:?Set the local PostgreSQL image ID}" \
  --redis-image "${MJORA_REDIS_IMAGE_ID:?Set the local Redis image ID}"
```

Read `FIXTURE_READY` before continuing. `request.json` contains the real account and fixture IDs. The listener opens only after the image declares `backgroundUploadsV1` and the new synthetic user can log in and retrieve an authenticated `/users/me` with its exact ID and email and `isAdmin: false`. The private login lives temporarily in `private-login.json`; keep that file and `leaf-key.pem` on the test host and out of evidence. The TLS gateway only forwards transport routes to the owned container and refuses setup/admin routes and other account emails. From another terminal run `python3 -B fixture.py probe --output /private/task/stable-fixture` to verify the private CA, identity document, background feature and synthetic user again over HTTPS, then use that request for `tool.py prepare`. `FIXTURE_TLS_IDENTITY_VERIFIED` is a readiness result, not upload or device acceptance.

On normal exit or Ctrl-C, the launcher stops its listener, removes its private login and leaf key, and removes only the resources carrying its fixture label. If the launcher died without cleanup, verify that it has exited before running `python3 -B fixture.py cleanup --output /private/task/stable-fixture`. Keep the request, public CA and receipt for review. If Docker or the API is not ready, no `FIXTURE_READY` receipt or physical acceptance can be recorded.

## Later private device connection

When B2 physical execution is authorized, choose a dedicated private test LAN with no port forwarding and verify that phone and test computer can reach each other. Use `--bind <test-computer-LAN-IPv4>` when creating the fixture so both request URLs and the leaf certificate use that exact IP. Its CA lasts one day. Transfer only the public `ca.cer` to the dedicated test phone; verify the SHA-256 fingerprint on the host (`openssl x509 -in ca.pem -noout -fingerprint -sha256`), install it and enable full trust for this test root. The app uses its normal TLS policy. Grant the candidate local network access if prompted, use the exact `backendURL`, and sign in only with `private-login.json`. Remove the temporary CA trust after exporting evidence. Keep the same address and trust throughout each run; if the certificate expires or the address changes, create a fresh fixture and candidate request.

After the device exports `relay-registration.json`, run the bounded relay in a separate foreground terminal using the same address and certificate:

```sh
python3 -B tool.py relay \
  --request /private/task/stable-fixture/request.json \
  --registration /private/task/relay-registration.json --evidence /private/task/relay.json \
  --bind "${MJORA_TEST_LAN_IP:?Set the exact fixture bind IP}" --port 9444 --duration-seconds 3600 \
  --tls-cert /private/task/stable-fixture/leaf.pem --tls-key /private/task/stable-fixture/leaf-key.pem \
  --backend-ca /private/task/stable-fixture/ca.pem
```

## Prepare an unsigned candidate

Use the active fixture's `request.json` for device preparation. For offline build checks only, you can copy `example-request.json` to a private task directory, replace the zero source revision with the current commit, and choose a unique `b2-bg-<UTC>-<8 hex>` runID. The example's endpoints and IDs are placeholders.

```sh
python3 -B tool.py prepare \
  --source /path/to/current/native \
  --source-revision <full-current-HEAD> \
  --request /private/task/request.json \
  --output /private/task/candidate
```

Preparation has no network or device actions. The candidate contains `prepared-receipt.json` and `source-files.json` outside its source folder. The receipt records the base commit, candidate fingerprint and isolation checks. Build it only with signing disabled for local validation until physical execution is separately authorized.

The fixture must expose exactly this identity document at `/api/__background_validation__/identity` without account authentication:

```json
{
  "schemaVersion": 2,
  "syntheticOnly": true,
  "fixtureID": "<configured fixture UUID>",
  "accountID": "<configured non-admin synthetic account UUID>"
}
```

The production server has no such route. A missing or different identity stops the harness and relay. The opaque-byte HTTP fixture in `test_validation.py` is for relay fault tests only; it cannot substitute for the real upload API in B2/B3.

## Generate and decode a small local fixture

From this directory, compile the separate macOS tool into the task's output directory. Use the same source helper in the exported iOS candidate.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -parse-as-library -module-cache-path /private/task/module-cache \
  SyntheticValidationVideo.swift GenerateVideo.swift \
  -o /private/task/generate-video

python3 -B tool.py generate \
  --generator /private/task/generate-video \
  --request /private/task/request.json \
  --output /private/task/synthetic-media
```

`generate` requires an explicitly supplied generator, refuses an existing output directory, decodes a real first frame, and saves SHA-1, SHA-256 and exact byte count in the manifest. A small smoke file cannot satisfy the 512 MiB transport acceptance check. Some macOS sandboxes cannot access the system encoder; report that failure rather than calling it a decode pass.

## Later physical transport steps

These steps describe B2 and are not executed by preparation or self-tests.

1. Verify the formal recovery artifact, isolated signed candidate and approved synthetic backend. Confirm the phone is connected and has been unlocked after reboot. Do not grant Photos access for the transport-only run.
2. Sign in through the candidate's normal login flow. Tap **Prepare Synthetic Transfer**. Export its manifest and `relay-registration.json`. The registration contains only an upload reference and capability digest.
3. Start this run's bounded relay with the exact request and registration. Default throttle is 256 KiB/s. For an interrupted run, registration selects a nonzero middle part and drops its response only after upstream 204.
4. Tap **Run Prepared Transfer**, detach the debugger, then physically lock the phone. The stable run must have at least 1800 seconds between advancing, authenticated committed offsets while independently observed locked. A 512 MiB file at 256 KiB/s has only about 34 minutes total transfer time.
5. Keep external physical lock start/end observation. The app's protected-data flag alone is insufficient. The app emits fractional UTC timestamps; the relay records request start, upstream completion and finish.
6. The harness queries authenticated status before sending after an ambiguous reply. It reads the authenticated unedited original and compares both hashes and exact size. Cleanup is a separate explicit action, limited to the received asset and staging references. A failed cleanup retains its precise receipt.
7. Export evidence before removing the test candidate. Inspect the actual formal version and renewal binding. No test candidate is published or pinned for automatic renewal.

The authoritative ledger is atomically stored inside `record.json` with its source, run, account, target, SHA-1, SHA-256 and byte-count binding. A known staging reference survives a lost final status response. Preparation restores that reference and queries its authenticated status instead of opening another session. If a created receipt was durably saved, the same asset's later duplicate result can be reverified. If the first created response was lost entirely, the duplicate stays provisional and requires manual asset recovery; its staging can still be cancelled. A corrupt, missing-ledger or mismatched existing record stops preparation. The harness never regenerates missing source bytes under the same run. Cleanup can authenticate the original against the saved manifest without that local video.

Cleanup first inspects the owned reference and saves any completed result as provisional. It supports cancelling staging before an asset exists. Only an explicitly created result with matching authenticated owner, unique filename and original digests becomes a confirmed asset ID. The current server does not expose device IDs in asset detail; no such field or endpoint is invented. A checksum duplicate, filename or staging reference alone is insufficient. Cleanup rechecks qualified assets using fresh authenticated metadata and original bytes before deletion. A normal missing status is not proof of cleanup. Re-entering a previously qualified asset's cleanup can confirm authenticated absence. If staging is cancelled while an asset remains unqualified, the ledger keeps a manual-recovery state and never reports complete cleanup. One runner owns status/finalization for this isolated run; the server's cancellation endpoint returns no asset receipt, so do not run a second authenticated finalizer against the same staging reference during cleanup.

The panel retains normal app lifecycle behavior. It is a transport entry only. Its synthetic local ID is not a PhotoKit asset. It cannot establish PhotoKit scanning, preparation or whole-library scheduling. Do not use another bundle ID as an isolation boundary for a personal Photos library.

## Review evidence

```sh
python3 -B tool.py review \
  --manifest /private/task/manifest.json \
  --record /private/task/record.json \
  --relay /private/task/relay.json
```

The app deliberately does not manufacture `physicalLock`. Add the independently observed `observer: "external"`, UTC `startedAt` and `endedAt` before review. Keep the original exported file and the observation separately.

All documents bind schema 2, runID, source revision and target fingerprint. Each accepted request must have a valid byte range, ciphertext length equal to plaintext plus 28, and an ordered UTC timeline. Accepted pieces must cover the exact manifest size. Lock evidence must show forward confirmed progress linked to upstream 204, not repeated samples at one offset. Readback and cleanup must match the precise created IDs.

- `transport-stable` requires the 512 MiB resource and no injected drop.
- `transport-interrupted` additionally requires exactly one middle-part upstream 204 followed by a dropped response, an authenticated status after it, and later requests at or beyond its confirmed offset.
- No request may start between that drop and its authenticated status, including a retransmission of the dropped piece or an early send of the next offset.
- `photokit-pipeline` requires the explicit pipeline stages and a verified synthetic-only library in addition to media evidence. The panel does not generate these stages. A dedicated test library and product-entry trace collector remain B3 execution prerequisites.

For B3, first verify a dedicated device library contains only the intended generated photo, video and Live Photo pair, with no personal iCloud Photos sync. Retain an inventory and hashes for both Live Photo resources. Use the product's normal backup entry and collect its actual `product-backup-start`, `photokit-scan`, `photokit-hash`, `photokit-resource`, `system-handoff`, `next-asset-scheduled` and `index-persisted` events. Match each relevant event to that inventory and verify authenticated originals and index state. The B2 fixture's route allowlist serves the transport panel; B3 needs a separately validated isolated endpoint for the real product pipeline (including bulk-check, asset creation and Live Photo linkage) and its trace collector. Do not synthesize pipeline events or give the transport panel Photos access to make up for missing evidence.

The checker verifies consistency of supplied material. It cannot authenticate a JSON claim, observe a screen lock, verify a signed artifact, or turn simulated evidence into physical proof. Keep candidate source review and authenticated-readback review as separate acceptance checks.

## Local tests

```sh
python3 -B -m unittest discover -s . -p 'test_*.py' -v
```

Tests use temporary directories and bounded loopback servers that stop before the process exits. The interruption test actually commits a synthetic part upstream, drops the response, reads the synthetic authoritative offset and continues without retransmitting that part. The HTTPS test checks CA trust, exact fixture identity, fixed forwarding, redirect and credential refusal. Both use an opaque-byte upstream; launch the real isolated fixture separately to verify Docker startup and real API behavior. Other tests reject missing pieces, invalid timelines, false lock progress, credentials, stale source, run mixing and overbroad cleanup.

Run the separate executable Foundation ledger checks without an app, device or network:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -parse-as-library -module-cache-path /private/task/module-cache \
  BackgroundValidationLedger.swift LedgerTests.swift -o /private/task/ledger-tests
/private/task/ledger-tests
```

These execute the same typed model used by the panel. They cover staging-only cancellation, lost final status, a crash before verification persistence, foreign duplicates bound to owned references, exact created-status matching, unknown-status rejection, verified created-to-duplicate recovery, each metadata/hash mismatch, cleanup re-entry, ambiguous cancellation, wrong binding and corrupt records.

The tests prove the tools' behavior. They are not the physical B2/B3 acceptance runs.
