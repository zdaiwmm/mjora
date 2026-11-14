# Isolated Immich 3.4.1 fixture

This is a server contract test, independent of the iOS app. It uploads and modifies only generated JPEG/MOV files in the `imora-341-fixture` compose project. It accepts no destination URL, password, or token arguments. The API destination is fixed to `http://127.0.0.1:32283/api`; redirects and environment HTTP proxies are disabled. Before HTTP writes, it checks the container's compose label, loopback binding, dedicated volumes, and approved server source revision. It then requires API version 3.4.1.

Requires Python 3.9+ and Docker CLI with the `desktop-linux` context, Compose, and platform-aware image inspection. No host media packages are needed: the pinned Immich image supplies FFmpeg and ExifTool. The compose file pins all three image digests and runs the server as `linux/amd64`. Initial image downloads require network access. Synthetic administrator credentials are intentionally hardcoded in `fixture.py`; never use them elsewhere.

From the repository root:

```sh
python3 tests/integration/fixture.py start
python3 tests/integration/fixture.py run --report docs/validation/immich-341-fixture-results.json
```

`start` starts only this project's database/Redis, creates the server, copies the disabling configuration into it, then starts the server. The copied config must be applied again whenever the server is recreated; there are no host bind mounts. The fixture config disables ML, version checking, map access, and reverse geocoding. It does not constitute a firewall policy.

On this Mac, Docker Desktop 4.65.0's normal API proxy stalled before forwarding container-start requests to the VM. The daemon itself was healthy. The following opt-in local engine socket path worked without restarting Docker or altering any settings or unrelated containers:

```sh
IMORA_FIXTURE_RAW_SOCKET=1 python3 tests/integration/fixture.py start
IMORA_FIXTURE_RAW_SOCKET=1 python3 tests/integration/fixture.py run --report docs/validation/immich-341-fixture-results.json
```

That workaround uses the fixed local Unix socket `${HOME}/Library/Containers/com.docker.docker/Data/docker.raw.sock`. It is Mac-specific; leave the environment variable unset on other machines. Do not substitute a remote Docker context or production host.

Each run uses new synthetic identifiers, records source/image identities, hashes, byte counts, and fixture asset IDs, and leaves synthetic assets/accounts in the dedicated volumes for review. It creates and revokes its own read-only key on successful completion. Tokens and passwords are not written to the report. Failed runs may leave their fixture read-only keys/accounts/assets behind; they contain only synthetic data. Media generated on the host and under the container's `/tmp/imora-fixture-*` directory is temporary and removed in `finally`.

The corruption test creates a new synthetic JPEG, validates its owner/checksum and its path under that fixture user's `/data/upload/` directory, preserves its original bytes, tests corruption and missing-file responses, and restores the file in `finally`. It does not change database rows directly. Interruption by machine termination during that test can leave a synthetic `.imora-fixture-preserved` original in the fixture volume; no production volume is mounted.

The JPEG Live Photo identifier is a minimal EXIF Apple maker note (`0x0011`); the MOV uses `com.apple.quicktime.content.identifier` metadata. Bundled ExifTool must read matching UUIDs from both files before uploads begin. These files exercise Immich's automatic pairing; the MOV has no Apple timed still-image metadata track, so they are not evidence of PhotoKit interoperability.

For actual iOS hosted tests, create a separate account and unlinked still/motion pair:

```sh
IMORA_FIXTURE_RAW_SOCKET=1 python3 tests/integration/fixture.py ios-fixture
```

This writes `/private/tmp/imora-341-ios-fixture.json` with mode `0600`, containing `apiURL`, `email`, a fresh synthetic `password`, `ownerID`, `stillID`, `motionID`, lowercase hex SHA1 values `stillChecksum`/`motionChecksum`, integer `stillBytes`/`motionBytes`, and absolute `stillPath`/`motionPath`. It never prints credentials or writes them into the repository. Source media remains under a private temporary directory for the iOS test to read. The account and pair are separate from the Python regression IDs. Re-running creates a new account/pair and replaces the private manifest; it does not mutate earlier iOS IDs.

To stop only this project (retain evidence volumes):

```sh
/usr/local/bin/docker --context desktop-linux compose -f tests/integration/compose.yml --project-name imora-341-fixture stop
```

If the Desktop proxy stalls, replace `--context desktop-linux` with `-H unix://${HOME}/Library/Containers/com.docker.docker/Data/docker.raw.sock`. Do not use broad prune, daemon restart, or commands against other projects.
