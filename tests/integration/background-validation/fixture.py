"""Start the real API on private, disposable local Docker resources for B2 preparation."""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import http.client
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import subprocess
import time
from urllib.parse import urlsplit
import urllib.request
import uuid

from local_tls import PrivateHTTPServer, private_bind, server_context, wrap_listener
from relay import opener, verify_fixture
from validation import PAYLOAD_BYTES, atomic_json, require, validate_request


LABEL = "io.mjora.validation.background-fixture"
IMAGE_ID = re.compile(r"sha256:[a-f0-9]{64}")
IDENTITY_PATH = "/api/__background_validation__/identity"
ASSET_ID = r"[a-f0-9-]{36}"
UPLOAD_ID = r"[a-f0-9]{64}"
ROUTES = {
    "GET": r"/api/(?:server/(?:ping|version|features|config|about|media-types)|public/config|users/me|assets/" + ASSET_ID + r"(?:/original)?)",
    "POST": r"/api/(?:auth/(?:login|validateToken|logout)|assets/background-uploads(?:/" + UPLOAD_ID + r"/status)?)",
    "PUT": r"/api/assets/background-uploads/" + UPLOAD_ID + r"/parts/(?:0|[1-9][0-9]*)",
    "DELETE": r"/api/assets(?:/background-uploads/" + UPLOAD_ID + r")?",
}
REQUEST_HEADERS = {"authorization", "content-type", "range", "x-upload-capability"}
RESPONSE_HEADERS = {"content-length", "content-type", "content-range", "content-disposition", "accept-ranges"}


def create_tls(output: Path, host: str) -> None:
    """Generate a one-day private CA and a leaf with only the exact IP SAN."""
    private_bind(host)
    ca_key, csr, extensions = (output / name for name in ("ca-key.pem", "leaf.csr", "leaf.ext"))
    leaf_key, leaf_cert, ca_cert = (output / name for name in ("leaf-key.pem", "leaf.pem", "ca.pem"))
    extensions.write_text(f"basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
                          f"extendedKeyUsage=serverAuth\nsubjectAltName=IP:{host}\n")

    def openssl(*args):
        subprocess.run(["openssl", *map(str, args)], check=True, timeout=30, capture_output=True)

    try:
        openssl("req", "-new", "-x509", "-newkey", "rsa:2048", "-noenc", "-sha256", "-days", "1",
                "-subj", "/CN=MJora disposable validation " + secrets.token_hex(5),
                "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0", "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                "-keyout", ca_key, "-out", ca_cert)
        openssl("req", "-new", "-newkey", "rsa:2048", "-noenc", "-sha256", "-subj", f"/CN={host}",
                "-keyout", leaf_key, "-out", csr)
        openssl("x509", "-req", "-in", csr, "-CA", ca_cert, "-CAkey", ca_key, "-set_serial", "0x" + secrets.token_hex(16),
                "-sha256", "-days", "1", "-extfile", extensions, "-out", leaf_cert)
        openssl("verify", "-CAfile", ca_cert, "-verify_ip", host, leaf_cert)
        openssl("x509", "-in", ca_cert, "-outform", "DER", "-out", output / "ca.cer")
    finally:
        for temporary in (ca_key, csr, extensions):
            temporary.unlink(missing_ok=True)


# Every connection reaches the exact owned container over local Docker stdio.
# This works on native Linux and Docker Desktop without publishing a Docker port.
BRIDGE = """const net = require('node:net');
const socket = net.createConnection({host:'127.0.0.1',port:2283});
process.stdin.pipe(socket, {end:false});
socket.pipe(process.stdout);
socket.on('error',()=>process.exit(1));
socket.on('close',()=>process.exit(0));"""


class DockerHTTPConnection(http.client.HTTPConnection):
    def __init__(self, docker, container):
        super().__init__("127.0.0.1", 2283, timeout=45)
        self.docker, self.container, self.bridge = docker, container, None

    def connect(self):
        ours, child = socket.socketpair()
        try:
            self.bridge = subprocess.Popen(self.docker.command("exec", "-i", self.container, "node", "-e", BRIDGE),
                                           env=self.docker.env, stdin=child, stdout=child, stderr=subprocess.DEVNULL)
            ours.settimeout(self.timeout)
            self.sock = ours
        except BaseException:
            ours.close()
            raise
        finally:
            child.close()

    def close_bridge(self):
        self.close()
        if self.bridge is not None:
            try:
                self.bridge.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.bridge.kill()
                self.bridge.wait()


def serve_gateway(bind, port, tls, identity, account_email, connect):
    """Serve only the transport panel's API routes; no setup or admin forwarding."""
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def setup(self):
            self.request.settimeout(20)
            super().setup()

        def reply(self, status, body=b""):
            self.close_connection = True
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.send_header("Cache-Control", "no-store")
            if body:
                self.send_header("Content-Type", "application/json")
            self.end_headers()
            if body:
                self.wfile.write(body)

        def forward(self):
            self.close_connection = True
            # Never pass alternate authority, encoded paths, or arbitrary queries.
            if not self.path.startswith("/api/") or len(self.path) > 300:
                return self.reply(404)
            target = urlsplit(self.path)
            if target.fragment or (target.query and not (
                self.command == "GET" and target.path.endswith("/original") and target.query == "edited=false"
            )):
                return self.reply(404)
            if self.command == "GET" and self.path == IDENTITY_PATH:
                return self.reply(200, json.dumps(identity).encode())
            if not re.fullmatch(ROUTES[self.command], target.path):
                return self.reply(404)
            lengths = self.headers.get_all("Content-Length", [])
            limit = 8 * 1024 * 1024 + 28 if self.command == "PUT" else 64 * 1024
            if self.headers.get_all("Transfer-Encoding") or len(lengths) > 1 or (
                lengths and not re.fullmatch(r"[0-9]{1,9}", lengths[0])
            ):
                return self.reply(400)
            length = int(lengths[0]) if lengths else 0
            if length > limit:
                return self.reply(413)
            headers = {}
            for header in REQUEST_HEADERS:
                values = self.headers.get_all(header, [])
                if len(values) > 1:
                    return self.reply(400)
                if values:
                    headers[header] = values[0]
            if self.command == "PUT" and "authorization" in headers:
                return self.reply(400)
            connection, started = connect(), False
            try:
                body = self.rfile.read(length) if length else None
                if length and len(body) != length:
                    return self.reply(400)
                if self.path == "/api/auth/login":
                    try:
                        login = json.loads(body or b"")
                    except (ValueError, UnicodeError):
                        return self.reply(400)
                    if not isinstance(login, dict) or login.get("email") != account_email:
                        return self.reply(403)
                connection.request(self.command, self.path, body=body, headers={**headers, "Connection": "close"})
                with connection.getresponse() as response:
                    if 300 <= response.status < 400:
                        return self.reply(502)
                    started = True
                    self.send_response(response.status)
                    for key, value in response.getheaders():
                        if key.lower() in RESPONSE_HEADERS:
                            self.send_header(key, value)
                    self.send_header("Connection", "close")
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    shutil.copyfileobj(response, self.wfile, length=64 * 1024)
            except (OSError, http.client.HTTPException):
                if not started:
                    with contextlib.suppress(OSError):
                        self.reply(502)
            finally:
                getattr(connection, "close_bridge", connection.close)()

        do_GET = do_POST = do_PUT = do_DELETE = forward

    server = PrivateHTTPServer((private_bind(bind), port), Handler)
    server.daemon_threads = False
    try:
        return wrap_listener(server, tls)
    except BaseException:
        server.server_close()
        raise


class Stack:
    def __init__(self, docker_socket, fixture_id):
        docker_socket = docker_socket.resolve()
        require(docker_socket.is_socket(), "A local Docker Unix socket is required")
        self.host = "unix://" + str(docker_socket)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("DOCKER_")}
        self.label = f"{LABEL}={uuid.UUID(fixture_id)}"
        self.prefix = "mjora-bg-" + uuid.UUID(fixture_id).hex
        self.resources = [(kind, self.prefix + "-" + suffix) for kind, suffix in (
            ("network", "network"), ("volume", "dbdata"), ("volume", "redisdata"), ("volume", "data"),
            ("container", "database"), ("container", "redis"), ("container", "server"),
        )]
        self.server = self.prefix + "-server"

    def command(self, *args):
        return ["docker", "--host", self.host, *args]

    def run(self, *args, check=True, timeout=65):
        try:
            return subprocess.run(self.command(*args), env=self.env, capture_output=True, timeout=timeout, check=check)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            # Shell arguments and Docker output may contain disposable passwords.
            raise RuntimeError("Local Docker command failed") from error

    def check_engine(self):
        try:
            self.run("version", "--format", "{{.Server.Version}}", timeout=10)
        except RuntimeError as error:
            raise RuntimeError("Local Docker engine is unavailable on the selected Unix socket") from error

    def connect(self):
        return DockerHTTPConnection(self, self.server)

    def create(self, images, output):
        for expected in images.values():
            require(IMAGE_ID.fullmatch(expected) is not None, "Supply immutable local image IDs")
            observed = json.loads(self.run("image", "inspect", expected).stdout)[0]
            require(observed["Id"] == expected, "Docker image ID mismatch")
        prefix = self.prefix
        db, cache = prefix + "-database", prefix + "-redis"
        self.run("network", "create", "--internal", "--label", self.label, prefix + "-network")
        for suffix in ("dbdata", "redisdata", "data"):
            self.run("volume", "create", "--label", self.label, prefix + "-" + suffix)
        password = secrets.token_hex(24)

        def create(suffix, alias, *args):
            self.run("create", "--name", prefix + "-" + suffix, "--label", self.label, "--pull", "never",
                     "--network", prefix + "-network", "--network-alias", alias, *args)

        def mount(suffix, target):
            return "type=volume,source=" + prefix + "-" + suffix + ",target=" + target

        create("database", "database", "--memory", "1g", "--shm-size", "128m", "--mount", mount("dbdata", "/var/lib/postgresql/data"),
               "-e", "POSTGRES_USER=fixture", "-e", "POSTGRES_PASSWORD=" + password,
               "-e", "POSTGRES_DB=fixture", "-e", "POSTGRES_INITDB_ARGS=--data-checksums", images["database"])
        create("redis", "redis", "--memory", "256m", "--mount", mount("redisdata", "/data"), images["redis"])
        create("server", "server", "--memory", "3g", "--mount", mount("data", "/data"),
               "-e", "DB_HOSTNAME=database", "-e", "DB_USERNAME=fixture", "-e", "DB_PASSWORD=" + password,
               "-e", "DB_DATABASE_NAME=fixture", "-e", "REDIS_HOSTNAME=redis", "-e", "IMMICH_WORKERS_INCLUDE=api,microservices",
               "-e", "IMMICH_CONFIG_FILE=/tmp/background-fixture.json", "-e", "IMMICH_LOG_LEVEL=warn", images["server"])
        config = output / "server-config.json"
        atomic_json(config, {key: {"enabled": False} for key in ("machineLearning", "newVersionCheck", "reverseGeocoding", "map")})
        self.run("cp", str(config), self.server + ":/tmp/background-fixture.json")
        self.run("start", db, cache)
        wait_until(lambda: self.run("exec", db, "pg_isready", "-U", "fixture", "-d", "fixture", check=False).returncode == 0,
                   75, "Database did not become ready")
        self.run("start", self.server)
        wait_until(lambda: api(self.connect, "GET", "/server/ping") == {"res": "pong"}, 180, "Real API did not become ready")

    def cleanup(self):
        grouped = []
        for kind in ("container", "volume", "network"):
            argv = [kind, "ls", "--filter", "label=" + self.label, "--format", "{{.Names}}" if kind == "container" else "{{.Name}}"]
            if kind == "container":
                argv.insert(2, "--all")
            present = self.run(*argv).stdout.decode().splitlines()
            expected = {name for resource_kind, name in self.resources if resource_kind == kind}
            require(set(present) <= expected, "Unexpected resource with the fixture ownership label")
            grouped.extend((kind, name) for name in present)
        for kind, name in grouped:
            resource = json.loads(self.run(kind, "inspect", name).stdout)[0]
            labels = resource["Config"]["Labels"] if kind == "container" else resource["Labels"]
            require(labels[LABEL] == self.label.partition("=")[2], "Refusing non-owned cleanup target")
            identity = resource["Id"] if kind != "volume" else resource["Name"]
            options = ["--force", "--volumes"] if kind == "container" else []
            self.run(kind, "rm", *options, identity)


def wait_until(probe, seconds, message):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if probe():
                return
        except (OSError, ValueError, http.client.HTTPException):
            pass
        time.sleep(1)
    raise ValueError(message)


def api(connect, method, path, body=None, *, token=None):
    connection = connect()
    try:
        headers = {"Content-Type": "application/json", "Connection": "close"}
        if token:
            headers["Authorization"] = "Bearer " + token
        connection.request(method, "/api" + path, body=json.dumps(body) if body is not None else None, headers=headers)
        with connection.getresponse() as response:
            require(response.status in (200, 201, 204), "Real API operation failed: " + path + " HTTP " + str(response.status))
            data = response.read(65537)
            require(len(data) <= 65536, "Unexpected API response size")
            return json.loads(data) if data else None
    finally:
        connection.close_bridge()


def bootstrap(connect, fixture_id):
    require(api(connect, "GET", "/server/features").get("backgroundUploadsV1") is True, "Pinned image lacks background uploads")
    admin = {"email": fixture_id + "+admin@background-fixture.invalid", "password": secrets.token_urlsafe(24)}
    api(connect, "POST", "/auth/admin-sign-up", {**admin, "name": "Local fixture bootstrap"})
    admin_token = api(connect, "POST", "/auth/login", admin)["accessToken"]
    login = {"email": fixture_id + "@background-fixture.invalid", "password": secrets.token_urlsafe(24)}
    created = api(connect, "POST", "/admin/users", {**login, "name": "Background fixture", "isAdmin": False,
                                                       "shouldChangePassword": False, "notify": False}, token=admin_token)
    session = api(connect, "POST", "/auth/login", login)
    user = api(connect, "GET", "/users/me", token=session["accessToken"])
    require(user["id"] == created["id"] == session["userId"] and user["email"] == login["email"]
            and user["isAdmin"] is False, "Real API did not attest the isolated non-admin identity")
    api(connect, "POST", "/auth/logout", token=session["accessToken"])
    api(connect, "POST", "/auth/logout", token=admin_token)
    return {"schemaVersion": 2, "syntheticOnly": True, "fixtureID": fixture_id, "accountID": str(uuid.UUID(user["id"]))}, login


def probe_fixture(output, evidence):
    """Check the live, real fixture from outside Docker using its ordinary TLS path."""
    request = validate_request(json.loads((output / "request.json").read_text()))
    url = urlsplit(request["backendURL"])
    require(url.scheme == "https" and private_bind(url.hostname) == url.hostname and evidence["status"] == "ready"
            and all(evidence[key] == request[key] for key in ("fixtureID", "accountID", "backendURL")),
            "No matching ready private fixture")
    ca = output / "ca.pem"
    verify_fixture(request, ca)
    login = json.loads((output / "private-login.json").read_text())
    require(set(login) == {"email", "password"} and login["email"] == request["accountEmail"], "Unexpected fixture login")
    client = opener(ca)

    def call(path, *, method="GET", body=None, token=None):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        message = urllib.request.Request(request["backendURL"] + path,
                                         data=json.dumps(body).encode() if body is not None else None,
                                         method=method, headers=headers)
        with client.open(message, timeout=15) as response:
            data = response.read(65537)
            require(len(data) <= 65536, "Unexpected fixture API response size")
            return json.loads(data) if data else None

    require(call("/server/features").get("backgroundUploadsV1") is True, "Real fixture lacks background upload support")
    token = call("/auth/login", method="POST", body=login)["accessToken"]
    try:
        user = call("/users/me", token=token)
        require(user["id"] == request["accountID"] and user["email"] == request["accountEmail"] and user["isAdmin"] is False,
                "TLS readback did not match the fixture account")
    finally:
        call("/auth/logout", method="POST", token=token)
    return {"status": "FIXTURE_TLS_IDENTITY_VERIFIED", "fixtureID": request["fixtureID"], "physicalAcceptance": "NOT RUN"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve", help="Provision, attest and serve the isolated fixture for a bounded duration")
    cleanup = commands.add_parser("cleanup", help="Remove only the resources owned by a prior fixture receipt")
    probe = commands.add_parser("probe", help="Verify TLS, capability and authenticated synthetic account via the live gateway")
    probe.add_argument("--output", required=True, type=Path)
    for command in (serve, cleanup):
        command.add_argument("--output", required=True, type=Path)
        command.add_argument("--docker-socket", default=Path("/var/run/docker.sock"), type=Path)
    for role in ("server", "database", "redis"):
        serve.add_argument(f"--{role}-image", required=True)
    serve.add_argument("--bind", default="127.0.0.1")
    serve.add_argument("--backend-port", required=True, type=int)
    serve.add_argument("--relay-port", required=True, type=int)
    serve.add_argument("--source-revision", required=True)
    serve.add_argument("--scenario", choices=("transport-stable", "transport-interrupted"), required=True)
    serve.add_argument("--payload-bytes", type=int, default=PAYLOAD_BYTES)
    serve.add_argument("--duration-seconds", type=int, default=3600)
    args = parser.parse_args(argv)
    output = args.output.resolve()
    receipt = output / "fixture-receipt.json"
    os.umask(0o077)
    try:
        if args.command == "probe":
            print(json.dumps(probe_fixture(output, json.loads(receipt.read_text()))), flush=True)
            return 0
        if args.command == "cleanup":
            evidence = json.loads(receipt.read_text())
            Stack(args.docker_socket, evidence["fixtureID"]).cleanup()
            for private in ("private-login.json", "leaf-key.pem"):
                (output / private).unlink(missing_ok=True)
            atomic_json(receipt, {**evidence, "status": "resources-removed"})
            return 0
        host = private_bind(args.bind)
        require(1 <= args.duration_seconds <= 7200, "Fixture duration must be 1–7200 seconds")
        require(1024 <= args.backend_port <= 65535 and 1024 <= args.relay_port <= 65535 and args.backend_port != args.relay_port,
                "Use distinct unprivileged backend and relay ports")
        fixture_id = str(uuid.uuid4())
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        request = validate_request({"schemaVersion": 2, "runID": f"b2-bg-{stamp}-{secrets.token_hex(4)}",
                                    "sourceRevision": args.source_revision, "scenario": args.scenario, "fixtureID": fixture_id,
                                    "accountID": fixture_id, "accountEmail": fixture_id + "@background-fixture.invalid",
                                    "backendURL": f"https://{host}:{args.backend_port}/api",
                                    "relayURL": f"https://{host}:{args.relay_port}/api", "payloadBytes": args.payload_bytes})
        images = {role: getattr(args, role + "_image") for role in ("server", "database", "redis")}
        require(all(IMAGE_ID.fullmatch(image) for image in images.values()), "Supply immutable local image IDs")
        stack = Stack(args.docker_socket, fixture_id)
        stack.check_engine()
        output.mkdir(mode=0o700, parents=True, exist_ok=False)
        evidence = {"fixtureID": fixture_id, "images": images, "status": "provisioning", "physicalAcceptance": "NOT RUN"}
        atomic_json(receipt, evidence)
        try:
            create_tls(output, host)
            stack.create(images, output)
            identity, login = bootstrap(stack.connect, fixture_id)
            request["accountID"] = identity["accountID"]
            require(request["accountEmail"] == login["email"], "Fixture login does not match the request")
            credentials = output / "private-login.json"
            try:
                with serve_gateway(host, args.backend_port, server_context(output / "leaf.pem", output / "leaf-key.pem"),
                                   identity, login["email"], stack.connect) as server:
                    # Keep credentials outside the candidate/evidence, in the fresh private directory.
                    with credentials.open("x") as stream:
                        json.dump(login, stream)
                    atomic_json(output / "request.json", validate_request(request))
                    evidence.update(status="ready", accountID=identity["accountID"], backendURL=request["backendURL"])
                    atomic_json(receipt, evidence)
                    print(json.dumps({"status": "FIXTURE_READY", "request": str(output / "request.json")}), flush=True)
                    server.timeout = 1
                    deadline = time.monotonic() + args.duration_seconds
                    while time.monotonic() < deadline:
                        server.handle_request()
            finally:
                credentials.unlink(missing_ok=True)
        finally:
            (output / "leaf-key.pem").unlink(missing_ok=True)
            stack.cleanup()
            atomic_json(receipt, {**evidence, "status": "resources-removed"})
        return 0
    except KeyboardInterrupt:
        return 130
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError, http.client.HTTPException) as error:
        message = str(error) if type(error) in (RuntimeError, ValueError) else type(error).__name__
        print(json.dumps({"status": "NOT RUN", "reason": message}), flush=True)
        return 1


if __name__ == "__main__":
    def interrupt(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    raise SystemExit(main())
