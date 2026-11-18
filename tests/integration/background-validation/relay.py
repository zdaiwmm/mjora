"""Fixed-target synthetic ciphertext relay. Account credentials never cross it."""
from __future__ import annotations

import hashlib
import hmac
import http.server
import fcntl
import json
import os
from pathlib import Path
import re
import socket
import threading
import time
import urllib.error
import urllib.request

from validation import HEX64, atomic_json, endpoint, integer, now, require, target_fingerprint, validate_request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def opener():
    # Never use ambient proxy configuration or user cookies.
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())


def verify_fixture(request: dict) -> None:
    validate_request(request)
    connection = opener().open(request["backendURL"] + "/__background_validation__/identity", timeout=5)
    with connection:
        require(connection.status == 200, "Synthetic fixture identity unavailable")
        identity = json.loads(connection.read(4097))
    require(identity == {"schemaVersion": 2, "syntheticOnly": True, "fixtureID": request["fixtureID"], "accountID": request["accountID"]}
            and type(identity.get("schemaVersion")) is int and identity.get("syntheticOnly") is True, "Synthetic fixture identity mismatch")


class Relay:
    def __init__(self, request: dict, registration: dict, evidence: Path, *, rate=256 * 1024):
        validate_request(request)
        require(set(registration) == {"runID", "mediaID", "uploadRef", "capabilitySHA256", "dropOffset"}, "Invalid relay registration")
        require(registration["runID"] == request["runID"], "Relay registration belongs to another run")
        require(registration["mediaID"] == "transport-video", "Invalid transport media ID")
        require(HEX64.fullmatch(registration["uploadRef"]) is not None and HEX64.fullmatch(registration["capabilitySHA256"]) is not None, "Invalid registration fingerprints")
        drop = registration["dropOffset"]
        require(drop is None or integer(drop, 1) and drop < request["payloadBytes"], "Invalid drop offset")
        require((request["scenario"] == "transport-interrupted") == (drop is not None), "Drop scenario does not match registration")
        require(integer(rate, 1), "Invalid throttle")
        verify_fixture(request)
        self.request, self.registration, self.evidence, self.rate = request, registration, evidence, rate
        self.lock = threading.Lock()
        self.lock_fd = None
        evidence.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            self.lock_fd = os.open(evidence.with_suffix(evidence.suffix + ".lock"), os.O_CREAT | os.O_RDWR, 0o600)
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            registration_hash = hashlib.sha256(json.dumps(registration, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
            if evidence.exists():
                previous = json.loads(evidence.read_text())
                require(previous.get("schemaVersion") == 2 and previous.get("runID") == request["runID"]
                        and previous.get("targetFingerprint") == target_fingerprint(request)
                        and previous.get("registrationFingerprint") == registration_hash, "Existing relay evidence has another owner")
                self.record = previous
            else:
                self.record = {"schemaVersion": 2, "runID": request["runID"], "targetFingerprint": target_fingerprint(request),
                               "registrationFingerprint": registration_hash, "requests": [], "rejectedCredentialRequests": 0}
            self.dropped = any(item.get("responseDropped") is True for item in self.record["requests"])
            self.checkpoint()
        except BaseException:
            self.close()
            raise

    def close(self):
        if getattr(self, "lock_fd", None) is not None:
            os.close(self.lock_fd)
            self.lock_fd = None

    def __del__(self):
        self.close()

    def checkpoint(self):
        # Caller holds lock when mutating, or constructor has not published self.
        atomic_json(self.evidence, self.record)

    def server(self, port=0):
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def reject(self, status):
                self.close_connection = True
                self.send_response(status)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def do_PUT(self):
                self.connection.settimeout(10)
                if any(self.headers.get(h) for h in ("Authorization", "Cookie", "X-API-Key", "Proxy-Authorization")):
                    with owner.lock:
                        owner.record["rejectedCredentialRequests"] += 1
                        owner.checkpoint()
                    return self.reject(400)
                match = re.fullmatch(r"/api/assets/background-uploads/([0-9a-f]{64})/parts/(0|[1-9][0-9]*)", self.path)
                raw_length = self.headers.get_all("Content-Length", [])
                if not match or len(raw_length) != 1 or not raw_length[0].isdigit() or self.headers.get("Transfer-Encoding"):
                    return self.reject(400)
                capability = self.headers.get("X-Upload-Capability", "")
                if not HEX64.fullmatch(capability) or not hmac.compare_digest(hashlib.sha256(capability.encode()).hexdigest(), owner.registration["capabilitySHA256"]):
                    return self.reject(403)
                offset, length = int(match[2]), int(raw_length[0])
                plain_length = length - 28
                if match[1] != owner.registration["uploadRef"] or not 1 <= plain_length <= 8 * 1024 * 1024 or offset + plain_length > owner.request["payloadBytes"]:
                    return self.reject(400)
                event = {"runID": owner.request["runID"], "mediaID": owner.registration["mediaID"], "offset": offset,
                         "plainLength": plain_length, "cipherLength": length, "startedAt": now(), "upstreamStatus": None, "responseDropped": False}
                with owner.lock:
                    owner.record["requests"].append(event)
                    owner.checkpoint()
                try:
                    remaining, pieces, started = length, [], time.monotonic()
                    while remaining:
                        value = self.rfile.read(min(64 * 1024, remaining))
                        if not value:
                            raise ConnectionError()
                        pieces.append(value)
                        remaining -= len(value)
                        time.sleep(max(0, started + (length - remaining) / owner.rate - time.monotonic()))
                    target = owner.request["backendURL"] + self.path.removeprefix("/api")
                    request = urllib.request.Request(target, data=b"".join(pieces), headers={"Content-Type": "application/octet-stream", "X-Upload-Capability": capability}, method="PUT")
                    try:
                        response = opener().open(request, timeout=15)
                    except urllib.error.HTTPError as error:
                        response = error
                    with response:
                        status = response.status
                        # Do not forward response bodies/headers that could contain secrets or redirects.
                        with owner.lock:
                            event["upstreamStatus"] = status
                            event["upstreamCompletedAt"] = now()
                            if status == 204 and offset == owner.registration["dropOffset"] and offset + plain_length < owner.request["payloadBytes"] and not owner.dropped:
                                owner.dropped = True
                                event["responseDropped"] = True
                            event["finishedAt"] = now()
                            owner.checkpoint()
                    if event["responseDropped"]:
                        self.close_connection = True
                        self.connection.shutdown(socket.SHUT_RDWR)
                        return
                    self.reject(204 if status == 204 else 502)
                except (OSError, urllib.error.URLError, TimeoutError):
                    with owner.lock:
                        event["failure"] = "transport-error"
                        event["finishedAt"] = now()
                        owner.checkpoint()
                    self.close_connection = True

            def do_GET(self):
                self.reject(405)

            def do_POST(self):
                self.reject(405)

            def do_DELETE(self):
                self.reject(405)

        class OwnedServer(http.server.ThreadingHTTPServer):
            def server_close(self):
                try:
                    super().server_close()
                finally:
                    owner.close()

        server = OwnedServer(("127.0.0.1", port), Handler)
        server.daemon_threads = False
        return server
