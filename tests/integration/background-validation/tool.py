#!/usr/bin/env python3
"""Prepare isolated local artifacts, generate synthetic media, or review evidence. Never installs."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

from validation import SCENARIOS, atomic_json, digests, now, require, review, target_fingerprint, validate_request

ROOT = Path(__file__).resolve().parent


def load(path: Path):
    with path.open() as stream:
        return json.load(stream)


def prepare(source: Path, revision: str, request: dict, output: Path) -> dict:
    """Exports only the explicitly requested current commit. No build/network/device access."""
    validate_request(request)
    head = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    require(head == revision == request["sourceRevision"], "Request and explicit source revision must match current HEAD")
    require(not output.exists(), "Candidate output already exists")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".background-candidate-", dir=output.parent))
    staging.chmod(0o700)
    try:
        candidate = staging / "source"
        candidate.mkdir()
        process = subprocess.Popen(["git", "-C", str(source), "archive", "--format=tar", revision], stdout=subprocess.PIPE)
        try:
            with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
                archive.extractall(candidate, filter="data")
        finally:
            process.stdout.close()
        require(process.wait() == 0, "Source export failed")
        app = candidate / "Imora/App/ImoraApp.swift"
        session = candidate / "Imora/Core/API/SessionStore.swift"
        original = app.read_text()
        session_digest = hashlib.sha256(session.read_bytes()).hexdigest()
        # Add only a compile-gated overlay. Delegate and protected-data callbacks stay byte-identical.
        anchor = "        .animation(.smooth, value: session.state)\n"
        require(original.count(anchor) == 1, "Current RootView overlay anchor was not found exactly once")
        app.write_text(original.replace(anchor, anchor + "        #if BACKGROUND_VALIDATION\n        .overlay(alignment: .topTrailing) { BackgroundValidationPanel().environment(session) }\n        #endif\n"))
        delegate_start, delegate_end = original.index("final class AppDelegate:"), original.index("struct RootView:")
        require(original[delegate_start:delegate_end] == app.read_text()[delegate_start:delegate_end], "AppDelegate changed")
        require(hashlib.sha256(session.read_bytes()).hexdigest() == session_digest, "SessionStore changed")
        salt = hashlib.sha256(request["runID"].encode()).hexdigest()[:12]
        prefix = "org.imora.validation." + salt
        project = candidate / "project.yml"
        text = project.read_text()
        require("com.vexcited" in text, "Unknown bundle identifier layout")
        text = text.replace("com.vexcited", prefix)
        anchor = '    SWIFT_VERSION: "6.0"\n'
        require(text.count(anchor) == 1, "Unknown project Swift settings")
        project.write_text(text.replace(anchor, anchor + '    SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) BACKGROUND_VALIDATION"\n'))
        # A unique service also prevents group-less keychain queries finding any other app's session.
        keychain = candidate / "Imora/Core/Storage/KeychainStore.swift"
        text = keychain.read_text()
        require(text.count('"app.imora.credentials"') == 1, "Unknown Keychain service layout")
        keychain.write_text(text.replace('"app.imora.credentials"', '"' + prefix + '.credentials"'))
        api = candidate / "Imora/Core/API/ImoraClient.swift"
        with api.open("a") as stream:
            stream.write('''
#if BACKGROUND_VALIDATION
extension ImoraClient {
    func cancelBackgroundValidationUpload(_ id: String) async throws {
        guard id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw URLError(.badURL)
        }
        _ = try await send(path: "assets/background-uploads/\\(id)", method: "DELETE")
    }
}
#endif
''')
        resources = candidate / "Imora/Resources"
        atomic_json(resources / "BackgroundValidationRequest.json", request)
        for name in ("BackgroundValidationPanel.swift", "SyntheticValidationVideo.swift", "BackgroundValidationLedger.swift"):
            content = (ROOT / name).read_text().replace("__VALIDATION_SOURCE_REVISION__", revision)
            (candidate / "Imora" / name).write_text(content)
        files = {}
        fingerprint = hashlib.sha256()
        for path in sorted(p for p in candidate.rglob("*") if p.is_file()):
            relative = str(path.relative_to(candidate))
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            files[relative] = digest
            fingerprint.update((relative + "\0" + digest + "\n").encode())
        receipt = {"schemaVersion": 2, "runID": request["runID"], "sourceRevision": revision, "preparedAt": now(),
                   "sourceSHA256": fingerprint.hexdigest(), "bundleIdentifier": prefix + ".imora",
                   "targetFingerprint": target_fingerprint(request), "appDelegateUnchanged": True,
                   "sessionStoreUnchanged": True, "keychainServiceIsolated": True, "signed": False, "installed": False,
                   "physicalAcceptance": "NOT RUN"}
        atomic_json(staging / "source-files.json", files)
        atomic_json(staging / "prepared-receipt.json", receipt)
        staging.rename(output)
        return receipt
    except BaseException:
        shutil.rmtree(staging)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    candidate = commands.add_parser("prepare", help="Only export an isolated source candidate; no build/sign/install")
    candidate.add_argument("--source", required=True, type=Path)
    candidate.add_argument("--source-revision", required=True)
    candidate.add_argument("--request", required=True, type=Path)
    candidate.add_argument("--output", required=True, type=Path)
    generate = commands.add_parser("generate", help="Run an explicitly compiled synthetic generator and finalize a local manifest")
    generate.add_argument("--generator", required=True, type=Path)
    generate.add_argument("--request", required=True, type=Path)
    generate.add_argument("--output", required=True, type=Path)
    check = commands.add_parser("review", help="Offline evidence consistency review, never product PASS")
    for name in ("manifest", "record", "relay"):
        check.add_argument("--" + name, required=True, type=Path)
    serve = commands.add_parser("relay", help="Start a bounded relay on a private interface after synthetic fixture attestation")
    serve.add_argument("--request", required=True, type=Path)
    serve.add_argument("--registration", required=True, type=Path)
    serve.add_argument("--evidence", required=True, type=Path)
    serve.add_argument("--port", required=True, type=int)
    serve.add_argument("--bind", default="127.0.0.1")
    serve.add_argument("--tls-cert", type=Path)
    serve.add_argument("--tls-key", type=Path)
    serve.add_argument("--backend-ca", type=Path)
    serve.add_argument("--duration-seconds", type=int, default=3600)
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            result = prepare(args.source.resolve(), args.source_revision, load(args.request), args.output.resolve())
        elif args.command == "generate":
            request = validate_request(load(args.request))
            require(not args.output.exists(), "Output already exists")
            args.output.mkdir(parents=True, mode=0o700)
            path = args.output / (request["runID"] + ".mp4")
            subprocess.run([str(args.generator.resolve()), str(path.resolve()), str(request["payloadBytes"]), request["runID"]], check=True, timeout=60, capture_output=True)
            result = {"schemaVersion": 2, "runID": request["runID"], "scenario": request["scenario"], "sourceRevision": request["sourceRevision"],
                      "targetFingerprint": target_fingerprint(request), "createdAt": now(), "syntheticOnly": True,
                      "media": [{"mediaID": "transport-video", "role": "transportVideo", "filename": path.name, **digests(path)}]}
            atomic_json(args.output / "manifest.json", result)
        elif args.command == "review":
            result = review(load(args.manifest), load(args.record), load(args.relay))
        else:
            from local_tls import relay_context
            from relay import Relay
            require(1 <= args.duration_seconds <= 7200 and 1 <= args.port <= 65535, "Invalid bounded relay duration/port")
            request = validate_request(load(args.request))
            tls = relay_context(request["relayURL"], host=args.bind, port=args.port, cert=args.tls_cert, key=args.tls_key)
            relay = Relay(request, load(args.registration), args.evidence, ca_file=args.backend_ca)
            try:
                server = relay.server(args.port, host=args.bind, tls=tls)
            except BaseException:
                relay.close()
                raise
            server.timeout = 1
            print(json.dumps({"ready": True, "bind": args.bind, "port": args.port, "tls": tls is not None, "runID": request["runID"]}), flush=True)
            deadline = time.monotonic() + args.duration_seconds
            try:
                while time.monotonic() < deadline:
                    server.handle_request()
            finally:
                server.server_close()
            result = {"status": "RELAY_STOPPED", "runID": relay.request["runID"]}
        print(json.dumps(result, indent=2))
        return 1 if result.get("status") == "INCOMPLETE" else 0
    except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError, tarfile.TarError) as error:
        # Exceptions may include private endpoint names or supplied values. Print type only.
        print(json.dumps({"status": "NOT RUN", "reason": type(error).__name__}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
