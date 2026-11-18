"""Synthetic tooling tests. These never provide physical product acceptance evidence."""
from __future__ import annotations

import base64
import contextlib
import copy
import datetime as dt
import hashlib
import http.client
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

from relay import Relay, verify_fixture
from tool import prepare
from validation import PAYLOAD_BYTES, atomic_json, digests, review, target_fingerprint, validate_manifest, validate_request

REVISION = "6f39e2f76f2b04a92bbe2db86b89e631b5adbed4"
RUN = "b2-bg-20261118T000000Z-abcdef12"
CAPABILITY = "a" * 64  # Synthetic capability, never an account credential.
UPLOAD = "b" * 64


def request(scenario="transport-stable", backend="http://127.0.0.1:43219/api"):
    return {"schemaVersion": 2, "runID": RUN, "scenario": scenario, "sourceRevision": REVISION,
            "backendURL": backend, "relayURL": "http://127.0.0.1:43220/api", "fixtureID": "11111111-1111-4111-8111-111111111111",
            "accountID": "22222222-2222-4222-8222-222222222222", "accountEmail": "synthetic@background-fixture.invalid", "payloadBytes": 4096}


def stamp(seconds):
    return (dt.datetime(2026, 11, 18, tzinfo=dt.timezone.utc) + dt.timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")


def evidence(scenario="transport-stable"):
    config = request(scenario)
    manifest = {"schemaVersion": 2, "runID": RUN, "scenario": scenario, "sourceRevision": REVISION,
                "targetFingerprint": target_fingerprint(config), "createdAt": stamp(0), "syntheticOnly": True,
                "media": [{"mediaID": "transport-video", "role": "transportVideo", "filename": "synthetic.mp4", "byteCount": PAYLOAD_BYTES,
                           "sha1": base64.b64encode(b"s" * 20).decode(), "sha256": "c" * 64}]}
    media = manifest["media"][0]
    record = {"schemaVersion": 2, "runID": RUN, "scenario": scenario, "sourceRevision": REVISION,
              "targetFingerprint": manifest["targetFingerprint"], "appLifecycle": "unaltered", "physicalDevice": True,
              "physicalLock": {"observer": "external", "startedAt": stamp(0), "endedAt": stamp(2000)}, "events": [],
              "uploads": [{"mediaID": media["mediaID"], "uploadRef": UPLOAD, "finalOffset": PAYLOAD_BYTES,
                           "createdAssetIDs": ["33333333-3333-4333-8333-333333333333"],
                           "readback": {"authenticated": True, "assetID": "33333333-3333-4333-8333-333333333333", **{k: media[k] for k in ("byteCount", "sha1", "sha256")}},
                           "cleanup": {"complete": True, "assetIDs": ["33333333-3333-4333-8333-333333333333"], "uploadRef": UPLOAD}}]}
    relay = {"schemaVersion": 2, "runID": RUN, "targetFingerprint": manifest["targetFingerprint"], "rejectedCredentialRequests": 0, "requests": []}
    for index in range(64):
        relay["requests"].append({"runID": RUN, "mediaID": media["mediaID"], "offset": index * 8 * 1024 * 1024,
                                  "plainLength": 8 * 1024 * 1024, "cipherLength": 8 * 1024 * 1024 + 28,
                                  "startedAt": stamp(index * 30), "upstreamCompletedAt": stamp(index * 30 + 1), "finishedAt": stamp(index * 30 + 1),
                                  "upstreamStatus": 204, "responseDropped": scenario == "transport-interrupted" and index == 3})
        record["events"].append({"phase": "committed-part", "mediaID": media["mediaID"], "at": stamp(index * 30 + 2),
                                   "locked": True, "authenticated": True, "confirmedOffset": (index + 1) * 8 * 1024 * 1024})
    if scenario == "transport-interrupted":
        record["events"].insert(4, {"phase": "resumed-from-server", "mediaID": media["mediaID"], "at": stamp(93), "authenticated": True, "confirmedOffset": 4 * 8 * 1024 * 1024})
    return manifest, record, relay


class Contracts(unittest.TestCase):
    def assertIncomplete(self, values):
        try:
            self.assertEqual(review(*values)["status"], "INCOMPLETE")
        except (ValueError, TypeError, KeyError, AttributeError):
            pass

    def test_stable_material_is_only_review_required(self):
        self.assertEqual(review(*evidence())["status"], "EVIDENCE_COMPLETE_REVIEW_REQUIRED")

    def test_interruption_material_is_only_review_required(self):
        self.assertEqual(review(*evidence("transport-interrupted"))["status"], "EVIDENCE_COMPLETE_REVIEW_REQUIRED")

    def test_lock_threshold_cannot_be_lowered(self):
        with self.assertRaises(ValueError):
            review(*evidence(), minimum_locked_seconds=1799)

    def test_same_offset_does_not_prove_locked_progress(self):
        values = evidence()
        for event in values[1]["events"]:
            event["confirmedOffset"] = 8 * 1024 * 1024
        self.assertIncomplete(values)

    def test_offset_without_matching_upstream_receipt_is_rejected(self):
        values = evidence()
        values[2]["requests"][0]["upstreamStatus"] = 503
        self.assertIncomplete(values)

    def test_missing_piece_is_rejected(self):
        values = evidence()
        values[2]["requests"].pop(20)
        self.assertIncomplete(values)

    def test_malformed_request_fields_are_rejected(self):
        for field, value in (("offset", -1), ("plainLength", 0), ("cipherLength", 8), ("finishedAt", stamp(-10)), ("upstreamCompletedAt", stamp(-10))):
            with self.subTest(field=field):
                values = evidence()
                values[2]["requests"][0][field] = value
                self.assertIncomplete(values)

    def test_readback_digests_and_size_must_match(self):
        for field, value in (("sha1", base64.b64encode(b"x" * 20).decode()), ("sha256", "e" * 64), ("byteCount", 123), ("authenticated", False)):
            with self.subTest(field=field):
                values = evidence()
                values[1]["uploads"][0]["readback"][field] = value
                self.assertIncomplete(values)

    def test_unrelated_cleanup_id_is_rejected(self):
        values = evidence()
        values[1]["uploads"][0]["cleanup"]["assetIDs"].append("unrelated")
        self.assertIncomplete(values)

    def test_all_required_identity_and_evidence_fields_are_required(self):
        baseline = evidence()
        for document in (1, 2):
            for field in baseline[document]:
                with self.subTest(document=document, field=field):
                    values = copy.deepcopy(baseline)
                    del values[document][field]
                    self.assertIncomplete(values)

    def test_wrong_run_and_source_are_rejected(self):
        for document, field in ((0, "schemaVersion"), (1, "runID"), (1, "sourceRevision"), (2, "targetFingerprint")):
            values = evidence()
            values[document][field] = "wrong"
            self.assertIncomplete(values)

    def test_secrets_are_rejected_recursively(self):
        for field in ("accessToken", "Authorization", "password", "key", "capability"):
            with self.subTest(field=field):
                values = evidence()
                values[2]["requests"][0][field] = "synthetic-secret"
                with self.assertRaises(ValueError):
                    review(*values)

    def test_standard_credential_header_aliases_are_rejected_but_digests_remain_allowed(self):
        for header in ("X-Upload-Capability", "X-API-Key", "Proxy-Authorization", "Set-Cookie"):
            for alias in (header, header.upper(), header.lower(), header.replace("-", "_")):
                for nested in (False, True):
                    with self.subTest(alias=alias, nested=nested):
                        values = evidence()
                        if nested:
                            values[2]["requests"][0]["headers"] = [{alias: "synthetic-" + "a" * 64}]
                        else:
                            values[1][alias] = "synthetic-" + "a" * 64
                        with self.assertRaises(ValueError):
                            review(*values)
        values = evidence()
        values[2]["capabilitySHA256"] = "a" * 64
        self.assertEqual(review(*values)["status"], "EVIDENCE_COMPLETE_REVIEW_REQUIRED")

    def test_lock_observation_and_physical_flag_are_required(self):
        for field, value in (("physicalLock", {}), ("physicalDevice", False), ("appLifecycle", "replaced")):
            values = evidence()
            values[1][field] = value
            self.assertIncomplete(values)

    def test_insufficient_lock_window_is_rejected(self):
        values = evidence()
        values[1]["physicalLock"]["endedAt"] = stamp(1799)
        self.assertIncomplete(values)

    def test_confirmed_part_retransmission_after_status_is_rejected(self):
        values = evidence("transport-interrupted")
        repeated = copy.deepcopy(values[2]["requests"][3])
        repeated.update(startedAt=stamp(94), upstreamCompletedAt=stamp(95), finishedAt=stamp(95), responseDropped=False)
        values[2]["requests"].insert(4, repeated)
        self.assertIncomplete(values)

    def test_retransmission_between_drop_and_status_is_rejected(self):
        values = evidence("transport-interrupted")
        repeated = copy.deepcopy(values[2]["requests"][3])
        repeated.update(startedAt=stamp(92), upstreamCompletedAt=stamp(92.5), finishedAt=stamp(92.5), responseDropped=False)
        values[2]["requests"].insert(4, repeated)
        self.assertIncomplete(values)

    def test_next_offset_sent_before_status_is_also_rejected(self):
        values = evidence("transport-interrupted")
        values[2]["requests"][4].update(startedAt=stamp(92), upstreamCompletedAt=stamp(92.5), finishedAt=stamp(92.5))
        self.assertIncomplete(values)

    def test_status_before_upstream_commit_is_rejected(self):
        values = evidence("transport-interrupted")
        values[1]["events"][4]["at"] = stamp(90)
        self.assertIncomplete(values)

    def test_drop_at_zero_or_last_piece_is_rejected(self):
        for index in (0, 63):
            values = evidence("transport-interrupted")
            values[2]["requests"][3]["responseDropped"] = False
            values[2]["requests"][index]["responseDropped"] = True
            self.assertIncomplete(values)

    def test_resume_offset_below_committed_end_is_rejected(self):
        values = evidence("transport-interrupted")
        values[1]["events"][4]["confirmedOffset"] = 3 * 8 * 1024 * 1024
        self.assertIncomplete(values)

    def test_wrong_request_run_or_media_is_rejected(self):
        for field, value in (("runID", "another-run"), ("mediaID", "another-media")):
            values = evidence()
            values[2]["requests"][0][field] = value
            self.assertIncomplete(values)

    def test_malformed_digest_never_confirms_material(self):
        values = evidence()
        values[0]["media"][0]["sha1"] = "not-base64"
        self.assertIncomplete(values)

    def test_small_smoke_payload_is_never_physical_acceptance(self):
        values = evidence()
        values[0]["media"][0]["byteCount"] = 4096
        self.assertIncomplete(values)

    def test_pipeline_cannot_be_claimed_from_transport(self):
        values = evidence()
        values[0]["scenario"] = values[1]["scenario"] = "photokit-pipeline"
        self.assertIncomplete(values)

    def test_config_rejects_unknown_fields_real_accounts_and_untrusted_http(self):
        for field, value in (("unknown", True), ("accountEmail", "personal@example.com"), ("backendURL", "http://example.com/api"), ("backendURL", "https://user:pass@example.com/api"), ("relayURL", "https://example.com/api?token=x"), ("schemaVersion", True)):
            with self.subTest(field=field, value=value):
                config = request()
                config[field] = value
                with self.assertRaises(ValueError):
                    validate_request(config)

    def test_manifest_rejects_path_escape_and_duplicate_media(self):
        values = evidence()
        values[0]["media"][0]["filename"] = "../private.mp4"
        with self.assertRaises(ValueError):
            validate_manifest(values[0])
        values = evidence()
        values[0]["media"].append(values[0]["media"][0])
        with self.assertRaises(ValueError):
            validate_manifest(values[0])

    def test_atomic_run_outputs_are_isolated(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def write(run):
                for index in range(10):
                    atomic_json(root / run / "record.json", {"runID": run, "index": index})
            threads = [threading.Thread(target=write, args=(run,)) for run in ("one", "two")]
            for thread in threads: thread.start()
            for thread in threads: thread.join()
            for run in ("one", "two"):
                self.assertEqual(json.loads((root / run / "record.json").read_text()), {"runID": run, "index": 9})

    def test_cli_wrong_json_root_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "wrong.json"
            path.write_text("[]")
            result = subprocess.run(["python3", "-B", str(Path(__file__).with_name("tool.py")), "review", "--manifest", str(path), "--record", str(path), "--relay", str(path)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout)["status"], "NOT RUN")

    def test_prepare_rejects_stale_source_before_export(self):
        source = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory() as temp:
            config = request()
            config["sourceRevision"] = "0" * 40
            with self.assertRaises(ValueError):
                prepare(source, "0" * 40, config, Path(temp) / "candidate")
            self.assertFalse((Path(temp) / "candidate").exists())


class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path == "/api/__background_validation__/identity":
            body = json.dumps(self.server.identity).encode()
            self.send_response(200); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def do_PUT(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        if self.server.redirect:
            self.send_response(307); self.send_header("Location", self.server.redirect); self.end_headers(); return
        offset = int(self.path.rsplit("/", 1)[-1])
        self.server.offsets.append(offset)
        self.server.confirmed = max(self.server.confirmed, offset + int(self.headers["Content-Length"]) - 28)
        self.send_response(204); self.end_headers()


@contextlib.contextmanager
def running(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=3)


class ActualRelay(unittest.TestCase):
    def setupRelay(self, root, *, interrupted=True):
        backend = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        config = request("transport-interrupted" if interrupted else "transport-stable", f"http://127.0.0.1:{backend.server_port}/api")
        backend.identity = {"schemaVersion": 2, "syntheticOnly": True, "fixtureID": config["fixtureID"], "accountID": config["accountID"]}
        backend.offsets, backend.confirmed, backend.redirect = [], 0, None
        registration = {"runID": RUN, "mediaID": "transport-video", "uploadRef": UPLOAD,
                        "capabilitySHA256": hashlib.sha256(CAPABILITY.encode()).hexdigest(), "dropOffset": 1024 if interrupted else None}
        return backend, config, registration

    def put(self, port, offset, *, headers=None, upload=UPLOAD):
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        try:
            values = {"X-Upload-Capability": CAPABILITY, **(headers or {})}
            connection.request("PUT", f"/api/assets/background-uploads/{upload}/parts/{offset}", body=b"x" * 1052, headers=values)
            return connection.getresponse().status
        finally:
            connection.close()

    def test_actual_committed_drop_then_confirmed_offset_continuation(self):
        with tempfile.TemporaryDirectory() as temp:
            backend, config, registration = self.setupRelay(temp)
            with running(backend):
                relay = Relay(config, registration, Path(temp) / "relay.json", rate=10**9)
                with running(relay.server()) as server:
                    self.assertEqual(self.put(server.server_port, 0), 204)
                    with self.assertRaises(http.client.RemoteDisconnected):
                        self.put(server.server_port, 1024)
                    # The synthetic upstream's authoritative state advanced despite the lost reply.
                    self.assertEqual(backend.confirmed, 2048)
                    for offset in (backend.confirmed, 3072):
                        self.assertEqual(self.put(server.server_port, offset), 204)
                self.assertEqual(backend.offsets, [0, 1024, 2048, 3072])
                log = json.loads((Path(temp) / "relay.json").read_text())
                self.assertEqual(sum(item["responseDropped"] for item in log["requests"]), 1)
                self.assertTrue(all(item["upstreamStatus"] == 204 for item in log["requests"]))
                self.assertNotIn(CAPABILITY, json.dumps(log))

    def test_account_credentials_and_wrong_upload_are_not_forwarded(self):
        with tempfile.TemporaryDirectory() as temp:
            backend, config, registration = self.setupRelay(temp)
            with running(backend):
                relay = Relay(config, registration, Path(temp) / "relay.json", rate=10**9)
                with running(relay.server()) as server:
                    self.assertEqual(self.put(server.server_port, 0, headers={"Authorization": "Bearer synthetic-account"}), 400)
                    self.assertEqual(self.put(server.server_port, 0, upload="c" * 64), 400)
                    self.assertEqual(self.put(server.server_port, 0, headers={"X-Upload-Capability": "d" * 64}), 403)
                self.assertEqual(backend.offsets, [])
                self.assertEqual(relay.record["rejectedCredentialRequests"], 1)

    def test_upstream_redirect_is_never_followed(self):
        with tempfile.TemporaryDirectory() as temp:
            backend, config, registration = self.setupRelay(temp, interrupted=False)
            with running(backend):
                backend.redirect = f"http://127.0.0.1:{backend.server_port}/forbidden-redirect"
                relay = Relay(config, registration, Path(temp) / "relay.json", rate=10**9)
                with running(relay.server()) as server:
                    self.assertEqual(self.put(server.server_port, 0), 502)
                self.assertEqual(backend.offsets, [])
                self.assertEqual(relay.record["requests"][0]["upstreamStatus"], 307)

    def test_fixture_attestation_mismatch_prevents_relay(self):
        with tempfile.TemporaryDirectory() as temp:
            backend, config, registration = self.setupRelay(temp)
            with running(backend):
                backend.identity["syntheticOnly"] = False
                with self.assertRaises(ValueError):
                    Relay(config, registration, Path(temp) / "relay.json")
                self.assertFalse((Path(temp) / "relay.json").exists())

    def test_same_evidence_path_has_single_owner_and_restart_keeps_drop(self):
        with tempfile.TemporaryDirectory() as temp:
            backend, config, registration = self.setupRelay(temp)
            path = Path(temp) / "relay.json"
            with running(backend):
                relay = Relay(config, registration, path, rate=10**9)
                with self.assertRaises(OSError):
                    Relay(config, registration, path, rate=10**9)
                with running(relay.server()) as server:
                    with self.assertRaises(http.client.RemoteDisconnected):
                        self.put(server.server_port, 1024)
                restored = Relay(config, registration, path, rate=10**9)
                try:
                    self.assertTrue(restored.dropped)
                    self.assertEqual(len(restored.record["requests"]), 1)
                finally:
                    restored.close()
                other = copy.deepcopy(config)
                other["runID"] = "b2-bg-20261118T000000Z-abcdef34"
                other_registration = {**registration, "runID": other["runID"]}
                with self.assertRaises(ValueError):
                    Relay(other, other_registration, path, rate=10**9)


if __name__ == "__main__":
    unittest.main()
