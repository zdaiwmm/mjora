#!/usr/bin/env python3
"""Synthetic-only Immich 3.4.1 integration; immutable loopback destination.

No production URL/token argument is accepted. Docker commands are limited to the
dedicated compose project. Credentials below are intentionally local fixtures.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parent
BASE = "http://127.0.0.1:32283/api"
SERVER = "imora-341-fixture-server-1"
PROJECT = "imora-341-fixture"
EMAIL = "admin@imora-fixture.invalid"
PASSWORD = "Synthetic-Local-Fixture-Only-341!"
RAW_SOCKET = "unix://" + str(Path.home() / "Library/Containers/com.docker.docker/Data/docker.raw.sock")
EXIFTOOL = "/usr/src/app/server/node_modules/.pnpm/node_modules/.bin/exiftool"


def docker(*args, timeout=45):
    # Opt-in workaround for Docker Desktop's host proxy hanging before startup.
    route = ["-H", RAW_SOCKET] if os.environ.get("IMORA_FIXTURE_RAW_SOCKET") == "1" else ["--context", "desktop-linux"]
    result = subprocess.run(["/usr/local/bin/docker", *route, *args], capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"fixture Docker command {args[0]} failed (exit {result.returncode})")
    return result.stdout


def fixture_identity():
    data = json.loads(docker("inspect", SERVER))[0]
    assert data["Config"]["Labels"]["com.docker.compose.project"] == PROJECT
    bindings = data["HostConfig"]["PortBindings"]
    assert bindings == {"2283/tcp": [{"HostIp": "127.0.0.1", "HostPort": "32283"}]}, "Unexpected fixture port binding"
    assert all(m.get("Name", "").startswith(PROJECT + "_") for m in data["Mounts"]), "Non-fixture volume"
    image = json.loads(docker("image", "inspect", "--platform", "linux/amd64", data["Image"]))[0]
    assert image["Config"]["Labels"]["org.opencontainers.image.revision"] == "22b95194c80a2f2e6201093916b6c8c3d6d271dd"
    return {"container": SERVER, "imageId": data["Image"], "imageArchitecture": image["Architecture"],
            "repoDigests": image.get("RepoDigests", []), "manifest": data.get("ImageManifestDescriptor"),
            "runtimeArchitecture": docker("exec", SERVER, "uname", "-m").decode().strip(),
            "sourceRevision": image["Config"]["Labels"]["org.opencontainers.image.revision"]}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class API:
    def __init__(self, token=None, key=None):
        self.token, self.key = token, key
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, method, path, body=None, headers=None, expected=(200, 201, 204), binary=False):
        assert path.startswith("/") and not path.startswith("//") and "://" not in path
        h = dict(headers or {})
        if self.token:
            h["Authorization"] = "Bearer " + self.token
        if self.key:
            h["x-api-key"] = self.key
        if body is not None and not isinstance(body, bytes):
            body = json.dumps(body).encode()
            h["Content-Type"] = "application/json"
        req = urllib.request.Request(BASE + path, data=body, headers=h, method=method)
        try:
            response = self.opener.open(req, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            status = response.code
            if status not in expected:
                # Never print response bodies: login/key responses contain secrets.
                raise AssertionError(f"{method} {path} returned {status}; expected {expected}")
            if binary:
                digest, count = hashlib.sha1(), 0
                while chunk := response.read(64 * 1024):
                    digest.update(chunk)
                    count += len(chunk)
                return {"httpStatus": status, "sha1": digest.hexdigest(), "bytes": count,
                        "contentType": response.headers.get("Content-Type")}
            raw = response.read()
            return json.loads(raw) if raw else None

    def upload(self, path, **fields):
        data = path.read_bytes()
        boundary = "imora-fixture-" + uuid.uuid4().hex
        values = {"fileCreatedAt": "2026-11-14T00:00:00.000Z", "fileModifiedAt": "2026-11-14T00:00:00.000Z", **fields}
        parts = []
        for name, value in values.items():
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
        mime = "image/jpeg" if path.suffix == ".jpg" else "video/quicktime"
        parts += [f'--{boundary}\r\nContent-Disposition: form-data; name="assetData"; filename="{path.name}"\r\nContent-Type: {mime}\r\n\r\n'.encode(), data, f"\r\n--{boundary}--\r\n".encode()]
        return self.request("POST", "/assets", b"".join(parts), {"Content-Type": "multipart/form-data; boundary=" + boundary,
                                                              "x-immich-checksum": hashlib.sha1(data).hexdigest()})


def jpeg_identifier(jpeg, identifier):
    """Minimal EXIF Apple maker note, tag 0x0011, using synthetic UUID only."""
    value = identifier.encode() + b"\0"
    note = b"Apple iOS\0\0\x01MM" + struct.pack(">H", 1) + struct.pack(">HHII", 0x11, 2, len(value), 32) + b"\0" * 4 + value
    tiff = b"MM\0*\0\0\0\x08" + struct.pack(">H", 1) + struct.pack(">HHII", 0x8769, 4, 1, 26) + b"\0" * 4
    tiff += struct.pack(">H", 1) + struct.pack(">HHII", 0x927C, 7, len(note), 44) + b"\0" * 4 + note
    exif = b"Exif\0\0" + tiff
    assert jpeg.startswith(b"\xff\xd8")
    return jpeg[:2] + b"\xff\xe1" + struct.pack(">H", len(exif) + 2) + exif + jpeg[2:]


def make_media(local, run_id):
    remote = "/tmp/imora-fixture-" + run_id
    docker("exec", SERVER, "mkdir", "-p", remote)
    try:
        docker("exec", SERVER, "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=0x268f75:s=96x64", "-frames:v", "1", "-threads", "1", remote + "/base.jpg")
        cid = str(uuid.uuid4()).upper()
        for name, identifier in [("manual", run_id), ("auto", cid)]:
            metadata = ["-metadata", "com.apple.quicktime.content.identifier=" + identifier] if name == "auto" else ["-metadata", "comment=" + run_id]
            docker("exec", SERVER, "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=0x268f75:s=96x64:r=10", "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-threads", "1", "-movflags", "use_metadata_tags", *metadata, remote + "/" + name + ".mov")
            docker("cp", SERVER + ":" + remote + "/" + name + ".mov", str(local / (name + ".mov")))
        docker("cp", SERVER + ":" + remote + "/base.jpg", str(local / "base.jpg"))
        base = (local / "base.jpg").read_bytes()
        (local / "auto.jpg").write_bytes(jpeg_identifier(base, cid))
        for name in ["manual", "trash", "missing", "corrupt"]:
            comment = (run_id + name).encode()
            (local / (name + ".jpg")).write_bytes(base[:2] + b"\xff\xfe" + struct.pack(">H", len(comment) + 2) + comment + base[2:])
        docker("cp", str(local / "auto.jpg"), SERVER + ":" + remote + "/auto.jpg")
        metadata = json.loads(docker("exec", SERVER, EXIFTOOL, "-j", "-ContentIdentifier", remote + "/auto.jpg", remote + "/auto.mov"))
        assert len(metadata) == 2 and all(item.get("ContentIdentifier") == cid for item in metadata), "Synthetic Live Photo CID malformed"
        return {"livePhotoContentIdentifier": cid,
                "files": {p.name: {"sha1": hashlib.sha1(p.read_bytes()).hexdigest(), "bytes": p.stat().st_size} for p in sorted(local.glob("*")) if p.name != "base.jpg"}}
    finally:
        docker("exec", SERVER, "rm", "-rf", remote)


def wait_for(callback, timeout=30):
    end = time.monotonic() + timeout
    while True:
        value = callback()
        if value:
            return value
        if time.monotonic() >= end:
            raise AssertionError(f"Fixture condition did not become true within {timeout}s")
        time.sleep(0.5)


def run(report):
    report["identity"] = fixture_identity()  # Guard before any HTTP writes.
    public = API()
    version = public.request("GET", "/server/version")
    assert (version["major"], version["minor"], version["patch"]) == (3, 4, 1)
    report["serverVersion"] = version
    try:
        public.request("POST", "/auth/admin-sign-up", {"email": EMAIL, "password": PASSWORD, "name": "Synthetic fixture administrator"})
    except AssertionError:
        # Reusing a fixture volume is valid only if the fixed synthetic login works.
        pass
    login = public.request("POST", "/auth/login", {"email": EMAIL, "password": PASSWORD})
    api = API(token=login["accessToken"])
    owner = login["userId"]
    run_id = uuid.uuid4().hex
    report["runId"] = run_id
    report["checks"] = []

    def passed(name, **evidence):
        report["checks"].append({"name": name, "status": "passed", **evidence})
        print("PASS " + name, flush=True)

    with tempfile.TemporaryDirectory(prefix="imora-fixture-media-") as temp:
        local = Path(temp)
        report["syntheticMedia"] = make_media(local, run_id)
        passed("synthetic-jpeg-mov-live-photo-identifiers")
        still = api.upload(local / "manual.jpg")
        assert still["status"] == "created"
        still_id = still["id"]
        passed("new-jpeg-upload", assetId=still_id)
        duplicate = api.upload(local / "manual.jpg")
        assert duplicate == {"id": still_id, "status": "duplicate"}
        bulk = api.request("POST", "/assets/bulk-upload-check", {"assets": [{"id": "manual", "checksum": report["syntheticMedia"]["files"]["manual.jpg"]["sha1"]}]})
        assert bulk["results"] == [{"id": "manual", "action": "reject", "reason": "duplicate", "assetId": still_id, "isTrashed": False}]
        passed("upload-and-bulk-check-deduplication", assetId=still_id)
        checksum = report["syntheticMedia"]["files"]["manual.jpg"]["sha1"]
        shortcut = api.request("POST", "/assets", b"intentionally-not-multipart", {"Content-Type": "application/octet-stream", "x-immich-checksum": checksum})
        assert shortcut == {"id": still_id, "status": "duplicate"}
        api.request("POST", "/assets", b"intentionally-not-multipart", {"Content-Type": "application/octet-stream", "x-imora-checksum": checksum}, expected=(400,))
        passed("official-checksum-header-short-circuits-before-upload-form")
        motion_id = api.upload(local / "manual.mov")["id"]
        assert api.request("GET", "/assets/" + still_id).get("livePhotoVideoId") is None
        reupload = api.upload(local / "manual.jpg", livePhotoVideoId=motion_id)
        assert reupload["status"] == "duplicate"
        assert api.request("GET", "/assets/" + still_id).get("livePhotoVideoId") is None
        passed("duplicate-upload-does-not-repair-existing-still", stillId=still_id, motionId=motion_id)
        api.request("PUT", "/assets/" + still_id, {"livePhotoVideoId": motion_id})
        info = api.request("GET", "/assets/" + still_id)
        assert info["livePhotoVideoId"] == motion_id
        motion = api.request("GET", "/assets/" + motion_id)
        assert info["ownerId"] == owner and motion["ownerId"] == owner
        assert info["type"] == "IMAGE" and motion["type"] == "VIDEO"
        assert not info["isTrashed"] and not motion["isTrashed"] and not info["isOffline"] and not motion["isOffline"]
        passed("existing-still-motion-addition-exact-put-readback", stillId=still_id, motionId=motion_id, motionVisibility=motion["visibility"])
        for name, asset_id in [("manual.jpg", still_id), ("manual.mov", motion_id)]:
            downloaded = api.request("GET", "/assets/" + asset_id + "/original?edited=false", binary=True)
            assert {k: downloaded[k] for k in ("sha1", "bytes")} == report["syntheticMedia"]["files"][name]
            assert base64.b64decode(api.request("GET", "/assets/" + asset_id)["checksum"]).hex() == downloaded["sha1"]
            passed("original-readback-" + name, assetId=asset_id, **downloaded)
        auto_still = api.upload(local / "auto.jpg")["id"]
        auto_motion = api.upload(local / "auto.mov")["id"]
        began = time.monotonic()
        wait_for(lambda: api.request("GET", "/assets/" + auto_still).get("livePhotoVideoId") == auto_motion)
        assert api.request("GET", "/assets/" + auto_motion)["visibility"] == "hidden"
        passed("asynchronous-apple-content-id-auto-pair", stillId=auto_still, motionId=auto_motion, observedWaitSeconds=round(time.monotonic() - began, 3))
        key = api.request("POST", "/api-keys", {"name": "Synthetic read-only " + run_id, "permissions": ["asset.read", "asset.download"]})
        read_only = API(key=key["secret"])
        read_only.request("GET", "/assets/" + still_id)
        read_only.request("PUT", "/assets/" + still_id, {"livePhotoVideoId": motion_id}, expected=(403,))
        passed("missing-asset-update-permission-is-forbidden")
        foreign_email = "other-" + run_id + "@imora-fixture.invalid"
        api.request("POST", "/admin/users", {"email": foreign_email, "password": PASSWORD, "name": "Synthetic other account"})
        foreign_login = public.request("POST", "/auth/login", {"email": foreign_email, "password": PASSWORD})
        foreign = API(token=foreign_login["accessToken"])
        foreign_motion = foreign.upload(local / "manual.mov")["id"]
        api.request("PUT", "/assets/" + still_id, {"livePhotoVideoId": foreign_motion}, expected=(400, 403))
        assert api.request("GET", "/assets/" + still_id)["livePhotoVideoId"] == motion_id
        passed("motion-owned-by-other-account-cannot-be-linked", foreignMotionId=foreign_motion)
        trash = api.upload(local / "trash.jpg")["id"]
        api.request("DELETE", "/assets", {"ids": [trash], "force": False})
        wait_for(lambda: api.request("GET", "/assets/" + trash)["isTrashed"])
        trashed_check = api.request("POST", "/assets/bulk-upload-check", {"assets": [{"id": "trash", "checksum": report["syntheticMedia"]["files"]["trash.jpg"]["sha1"]}]})
        assert trashed_check["results"][0]["isTrashed"] is True
        passed("trashed-duplicate-is-not-current-backup", assetId=trash)
        api.request("POST", "/trash/restore/assets", {"ids": [trash]})
        wait_for(lambda: not api.request("GET", "/assets/" + trash)["isTrashed"])
        passed("restore-clears-trash-state", assetId=trash)
        missing = api.upload(local / "missing.jpg")["id"]
        api.request("DELETE", "/assets", {"ids": [missing], "force": True})
        wait_for(lambda: _is_missing(api, missing))
        missing_check = api.request("POST", "/assets/bulk-upload-check", {"assets": [{"id": "missing", "checksum": report["syntheticMedia"]["files"]["missing.jpg"]["sha1"]}]})
        assert missing_check["results"] == [{"id": "missing", "action": "accept"}]
        passed("permanently-missing-asset-needs-upload", assetId=missing)
        # DB metadata alone remains unchanged if an original is corrupt. Only
        # this run's new synthetic path may be touched; restore in finally.
        corrupt_upload = api.upload(local / "corrupt.jpg")
        assert corrupt_upload["status"] == "created"
        corrupt = corrupt_upload["id"]
        detail = api.request("GET", "/assets/" + corrupt)
        original = detail["originalPath"]
        # Immich allocates an upload file UUID separately from the asset UUID.
        assert detail["ownerId"] == owner
        assert detail["checksum"] == base64.b64encode(bytes.fromhex(report["syntheticMedia"]["files"]["corrupt.jpg"]["sha1"])).decode()
        assert original.startswith("/data/upload/" + owner + "/") and ".." not in Path(original).parts and Path(original).suffix == ".jpg"
        saved = original + ".imora-fixture-preserved"
        docker("exec", SERVER, "cp", original, saved)
        try:
            docker("exec", SERVER, "node", "-e", "require('fs').writeFileSync(process.argv[1], Buffer.from('synthetic-corrupt-original'))", original)
            unchanged = api.request("GET", "/assets/" + corrupt)
            assert unchanged["checksum"] == detail["checksum"] and unchanged["isOffline"] is False
            bad = api.request("GET", "/assets/" + corrupt + "/original?edited=false", binary=True)
            assert bad["sha1"] != report["syntheticMedia"]["files"]["corrupt.jpg"]["sha1"]
            passed("database-checksum-cannot-prove-original-integrity", assetId=corrupt, returnedBytes=bad["bytes"], databaseStillOnline=True)
            docker("exec", SERVER, "rm", original)
            api.request("GET", "/assets/" + corrupt + "/original?edited=false", expected=(404,))
            passed("database-online-original-file-missing-is-rejected", assetId=corrupt)
        finally:
            docker("exec", SERVER, "mv", saved, original)
        restored = api.request("GET", "/assets/" + corrupt + "/original?edited=false", binary=True)
        assert restored["sha1"] == report["syntheticMedia"]["files"]["corrupt.jpg"]["sha1"]
        api.request("DELETE", "/api-keys/" + key["apiKey"]["id"])
        report["limitations"] = ["Exercises official server contract using Python; does not execute the iOS client, PhotoKit, or app generation guards.", "GET-null/PUT/GET is not atomic; 3.4.1 has no conditional pairing update.", "Observed asynchronous automatic pairing is bounded, not a deterministic server-job timing guarantee.", "Synthetic MOV contains matching Apple content identifier; no Apple still-image-time metadata track and no PhotoKit import/export verification."]


def _is_missing(api, asset_id):
    # GET deliberately expects 400 too: Immich's missing-asset access guard may
    # hide existence with 400 rather than returning the media endpoint's 404.
    try:
        api.request("GET", "/assets/" + asset_id)
        return False
    except AssertionError as error:
        if "returned 400;" in str(error) or "returned 404;" in str(error):
            return True
        raise


def start():
    compose = ("compose", "-f", str(ROOT / "compose.yml"), "--project-name", PROJECT)
    docker(*compose, "up", "-d", "database", "redis", timeout=120)
    docker(*compose, "create", "server", timeout=120)
    docker("cp", str(ROOT / "immich-config.json"), SERVER + ":/tmp/imora-immich.json")
    docker(*compose, "start", "server", timeout=45)
    def ready():
        try:
            return API().request("GET", "/server/version")
        except (urllib.error.URLError, AssertionError):
            return False
    wait_for(ready, timeout=60)


def ios_fixture():
    """Separate account/assets reserved for the parent's actual iOS tests."""
    fixture_identity()
    public = API()
    version = public.request("GET", "/server/version")
    assert (version["major"], version["minor"], version["patch"]) == (3, 4, 1)
    admin_login = public.request("POST", "/auth/login", {"email": EMAIL, "password": PASSWORD})
    admin = API(token=admin_login["accessToken"])
    run_id = uuid.uuid4().hex
    email = "ios-" + run_id + "@imora-fixture.invalid"
    password = "Synthetic-Local-Only-" + secrets.token_urlsafe(24)
    admin.request("POST", "/admin/users", {"email": email, "password": password, "name": "Synthetic local iOS fixture"})
    login = public.request("POST", "/auth/login", {"email": email, "password": password})
    api = API(token=login["accessToken"])
    local = Path(tempfile.mkdtemp(prefix="imora-ios-fixture-media-", dir="/private/tmp"))
    media = make_media(local, run_id)
    still_id = api.upload(local / "manual.jpg")["id"]
    motion_id = api.upload(local / "manual.mov")["id"]
    assert api.request("GET", "/assets/" + still_id)["livePhotoVideoId"] is None
    manifest = {"label": "Synthetic local-only iOS fixture; no production credentials/data", "apiURL": BASE,
                "email": email, "password": password, "ownerID": login["userId"],
                "stillID": still_id, "motionID": motion_id,
                "stillChecksum": media["files"]["manual.jpg"]["sha1"], "motionChecksum": media["files"]["manual.mov"]["sha1"],
                "stillBytes": media["files"]["manual.jpg"]["bytes"], "motionBytes": media["files"]["manual.mov"]["bytes"],
                "stillPath": str(local / "manual.jpg"), "motionPath": str(local / "manual.mov")}
    path = Path("/private/tmp/imora-341-ios-fixture.json")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as output:
        os.fchmod(output.fileno(), 0o600)
        json.dump(manifest, output, indent=2)
        output.write("\n")
    print("iOS manifest: " + str(path))
    print("Synthetic owner: " + login["userId"])
    print("Unlinked still: " + still_id + "; motion: " + motion_id)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["start", "run", "ios-fixture"])
    parser.add_argument("--report", type=Path, default=ROOT / "results.json")
    args = parser.parse_args()
    if args.action == "start":
        start()
        return
    if args.action == "ios-fixture":
        ios_fixture()
        return
    report = {"startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "destination": BASE, "status": "failed"}
    try:
        run(report)
        report["status"] = "passed"
    except Exception as error:
        report["failure"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print("Report: " + str(args.report))


if __name__ == "__main__":
    main()
