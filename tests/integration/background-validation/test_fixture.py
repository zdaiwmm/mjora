"""Loopback tests of the TLS gateway and real relay, with an opaque-byte upstream."""
from __future__ import annotations

import hashlib
import http.client
import http.server
import json
from pathlib import Path
import ssl
import tempfile
import unittest

from fixture import create_tls, probe_fixture, serve_gateway
from local_tls import relay_context, server_context
from relay import Relay, verify_fixture
from test_validation import CAPABILITY, RUN, UPLOAD, running, request


class Upstream(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_PUT(self):
        self.server.puts.append((self.path, self.headers.get("Authorization"), self.headers.get("X-Upload-Capability"),
                                 self.rfile.read(int(self.headers["Content-Length"]))))
        self.send_response(204)
        self.end_headers()

    def send_json(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/api/server/features":
            return self.send_json({"backgroundUploadsV1": True})
        if self.path == "/api/users/me" and self.headers.get("Authorization") == "Bearer test-session":
            return self.send_json(self.server.account)
        self.send_error(403)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.server.posts.append((self.path, body))
        if self.path == "/api/auth/login" and json.loads(body or b"{}").get("password") == "probe-only":
            return self.send_json({"accessToken": "test-session"})
        if self.path == "/api/auth/logout" and self.headers.get("Authorization") == "Bearer test-session":
            return self.send_json({"successful": True})
        # Exercise rejection of an upstream redirect and response cookie.
        self.send_response(302)
        self.send_header("Location", "/api/forbidden")
        self.send_header("Set-Cookie", "test=should-not-forward")
        self.end_headers()


class FixtureTLS(unittest.TestCase):
    def test_tls_identity_and_ciphertext_relay(self):
        with tempfile.TemporaryDirectory() as root:
            work = Path(root)
            ca = work / "ca.pem"
            cert, key = work / "leaf.pem", work / "leaf-key.pem"
            config = request()
            identity = {"schemaVersion": 2, "syntheticOnly": True, "fixtureID": config["fixtureID"], "accountID": config["accountID"]}
            registration = {"runID": RUN, "mediaID": "transport-video", "uploadRef": UPLOAD,
                            "capabilitySHA256": hashlib.sha256(CAPABILITY.encode()).hexdigest(), "dropOffset": None}
            create_tls(work, "127.0.0.1")
            self.assertFalse((work / "ca-key.pem").exists())
            trusted = ssl.create_default_context(cafile=str(ca))

            def call(port, method, path, *, body=None, headers=None):
                caller = http.client.HTTPSConnection("127.0.0.1", port, context=trusted, timeout=3)
                try:
                    caller.request(method, path, body=body, headers=headers or {})
                    with caller.getresponse() as response:
                        return response.status, dict(response.getheaders()), response.read()
                finally:
                    caller.close()

            upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
            upstream.puts, upstream.posts = [], []
            upstream.account = {"id": config["accountID"], "email": config["accountEmail"], "isAdmin": False}
            with running(upstream):
                gateway = serve_gateway("127.0.0.1", 0, server_context(cert, key), identity, config["accountEmail"],
                                        lambda: http.client.HTTPConnection("127.0.0.1", upstream.server_port, timeout=3))
                with running(gateway):
                    config["backendURL"] = f"https://127.0.0.1:{gateway.server_port}/api"
                    verify_fixture(config, ca)
                    with self.assertRaises(OSError):
                        verify_fixture(config)
                    with self.assertRaises(ValueError):
                        verify_fixture({**config, "accountID": config["fixtureID"]}, ca)
                    self.assertEqual(call(gateway.server_port, "POST", "/api/auth/admin-sign-up", body=b"{}")[0], 404)
                    self.assertEqual(call(gateway.server_port, "POST", "/api/auth/login", body=b'{"email":"real@example.com"}')[0], 403)
                    self.assertEqual(upstream.posts, [])
                    login = json.dumps({"email": config["accountEmail"], "password": "test-disposable"}).encode()
                    status, headers, _ = call(gateway.server_port, "POST", "/api/auth/login", body=login)
                    self.assertEqual(status, 502)
                    self.assertNotIn("Location", headers)
                    self.assertNotIn("Set-Cookie", headers)
                    self.assertEqual(upstream.posts, [("/api/auth/login", login)])
                    (work / "request.json").write_text(json.dumps(config))
                    (work / "private-login.json").write_text(json.dumps({"email": config["accountEmail"], "password": "probe-only"}))
                    receipt = {"status": "ready", **{field: config[field] for field in ("fixtureID", "accountID", "backendURL")}}
                    self.assertEqual(probe_fixture(work, receipt), {"status": "FIXTURE_TLS_IDENTITY_VERIFIED", "fixtureID": config["fixtureID"],
                                                                    "physicalAcceptance": "NOT RUN"})
                    upstream.account["isAdmin"] = True
                    with self.assertRaises(ValueError):
                        probe_fixture(work, receipt)
                    self.assertEqual(upstream.posts[-1][0], "/api/auth/logout")

                    evidence = work / "relay.json"
                    relay = Relay(config, registration, evidence, ca_file=ca, rate=1024 * 1024)
                    listener = relay.server(tls=server_context(cert, key))
                    with running(listener):
                        path = f"/api/assets/background-uploads/{UPLOAD}/parts/0"
                        packet = b"ciphertext-test-only" * 32
                        auth = {"X-Upload-Capability": CAPABILITY}
                        self.assertEqual(call(listener.server_port, "PUT", path, body=packet, headers={**auth, "Cookie": "secret"})[0], 400)
                        self.assertEqual(upstream.puts, [])
                        self.assertEqual(call(listener.server_port, "PUT", path, body=packet, headers=auth)[0], 204)
                        self.assertEqual(upstream.puts, [(path, None, CAPABILITY, packet)])
                    self.assertNotIn(CAPABILITY, evidence.read_text())

    def test_listener_rejects_unpinned_and_insecure_bindings(self):
        for url, host, port in (
            ("https://127.0.0.1:9990/api", "127.0.0.1", 9991),
            ("https://127.0.0.1:9990/api", "127.0.0.1", 9990),
            ("http://192.168.22.21:9990/api", "192.168.22.21", 9990),
            ("http://0.0.0.0:9990/api", "0.0.0.0", 9990),
            ("http://8.8.8.8:9990/api", "8.8.8.8", 9990),
        ):
            with self.subTest(url=url), self.assertRaises(ValueError):
                relay_context(url, host=host, port=port, cert=None, key=None)
