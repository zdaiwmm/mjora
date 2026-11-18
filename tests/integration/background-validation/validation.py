"""Offline contracts for synthetic background acceptance. No device or account access."""
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import urlsplit

SCHEMA = 2
SCENARIOS = {"transport-stable", "transport-interrupted", "photokit-pipeline"}
PAYLOAD_BYTES = 512 * 1024 * 1024
RUN_PATTERN = re.compile(r"b2-bg-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}")
HEX64 = re.compile(r"[0-9a-f]{64}")
FORBIDDEN = {"authorization", "cookie", "password", "accesstoken", "refreshtoken", "token", "capability", "key", "aeskey", "privatekey", "credential",
             "xuploadcapability", "xapikey", "proxyauthorization", "setcookie"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def reject_secrets(value) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            normalized = re.sub(r"[^a-z]", "", str(key).lower())
            require(normalized not in FORBIDDEN, "Credential-shaped field is not allowed")
            reject_secrets(item)
    elif isinstance(value, list):
        for item in value:
            reject_secrets(item)
    elif isinstance(value, str):
        require(not re.search(r"(?i)\b(?:bearer|basic)\s+[A-Za-z0-9+/=._-]+", value), "Credential-shaped value is not allowed")


def exact_keys(value: dict, keys: set[str]) -> None:
    require(isinstance(value, dict) and set(value) == keys, "Unsupported or missing fields")


def utc(value: str) -> float:
    require(isinstance(value, str) and value.endswith("Z"), "UTC timestamp required")
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed.timestamp()


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def integer(value, minimum=0) -> bool:
    return type(value) is int and value >= minimum


def atomic_json(path: Path, value) -> None:
    reject_secrets(value)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=".validation-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def digests(path: Path) -> dict:
    sha1, sha256, size = hashlib.sha1(), hashlib.sha256(), 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha1.update(chunk)
            sha256.update(chunk)
            size += len(chunk)
    return {"byteCount": size, "sha1": base64.b64encode(sha1.digest()).decode(), "sha256": sha256.hexdigest()}


def validate_manifest(manifest: dict) -> dict:
    reject_secrets(manifest)
    exact_keys(manifest, {"schemaVersion", "runID", "scenario", "sourceRevision", "targetFingerprint", "createdAt", "syntheticOnly", "media"})
    require(manifest["schemaVersion"] == SCHEMA and type(manifest["schemaVersion"]) is int, "Unsupported schema")
    require(RUN_PATTERN.fullmatch(manifest["runID"]) is not None, "Invalid runID")
    require(manifest["scenario"] in SCENARIOS, "Unknown scenario")
    require(re.fullmatch(r"[0-9a-f]{40}", manifest["sourceRevision"]) is not None, "Invalid source revision")
    require(HEX64.fullmatch(manifest["targetFingerprint"]) is not None, "Missing target fingerprint")
    require(manifest["syntheticOnly"] is True, "Synthetic-only manifest required")
    utc(manifest["createdAt"])
    require(isinstance(manifest["media"], list) and 0 < len(manifest["media"]) <= 16, "Invalid media list")
    ids = set()
    for media in manifest["media"]:
        exact_keys(media, {"mediaID", "role", "filename", "byteCount", "sha1", "sha256"})
        require(media["mediaID"] not in ids and re.fullmatch(r"[a-z][a-z0-9-]{0,63}", media["mediaID"]) is not None, "Invalid or duplicate media ID")
        ids.add(media["mediaID"])
        require(media["role"] in {"transportVideo", "photo", "video", "liveStill", "liveMotion"}, "Invalid media role")
        require(Path(media["filename"]).name == media["filename"] and media["filename"] not in {"", ".", ".."}, "Unsafe filename")
        require(integer(media["byteCount"], 1), "Invalid byte count")
        require(len(base64.b64decode(media["sha1"], validate=True)) == 20, "Invalid SHA-1")
        require(HEX64.fullmatch(media["sha256"]) is not None, "Invalid SHA-256")
    return manifest


def endpoint(value: str, *, relay=False) -> str:
    parsed = urlsplit(value)
    require(parsed.scheme in {"http", "https"} and parsed.hostname is not None, "Invalid endpoint")
    require(not parsed.username and not parsed.password and not parsed.query and not parsed.fragment, "Endpoint cannot contain credentials/query/fragment")
    require(parsed.path == "/api", "Endpoint must have the fixed /api root")
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError:
        address = None
    loopback = address is not None and address.is_loopback
    require(parsed.scheme == "https" or loopback, "HTTP is only permitted on loopback")
    require(parsed.hostname not in {"0.0.0.0", "::"}, "Unspecified target is forbidden")
    require(parsed.port is None or 1 <= parsed.port <= 65535, "Invalid target port")
    if relay:
        require(loopback or parsed.scheme == "https", "Relay must use loopback or trusted HTTPS")
    return value.rstrip("/")


def validate_request(config: dict) -> dict:
    reject_secrets(config)
    exact_keys(config, {"schemaVersion", "runID", "scenario", "sourceRevision", "backendURL", "relayURL", "fixtureID", "accountID", "accountEmail", "payloadBytes"})
    require(config["schemaVersion"] == SCHEMA and type(config["schemaVersion"]) is int, "Unsupported request schema")
    require(RUN_PATTERN.fullmatch(config["runID"]) is not None and config["scenario"] in SCENARIOS, "Invalid run/scenario")
    require(re.fullmatch(r"[0-9a-f]{40}", config["sourceRevision"]) is not None, "Invalid source revision")
    endpoint(config["backendURL"])
    endpoint(config["relayURL"], relay=True)
    require(re.fullmatch(r"[0-9a-f-]{36}", config["fixtureID"]) is not None, "Invalid fixture ID")
    require(re.fullmatch(r"[0-9a-f-]{36}", config["accountID"]) is not None, "Invalid synthetic account ID")
    require(re.fullmatch(r"[a-z0-9._+-]+@background-fixture\.invalid", config["accountEmail"]) is not None, "Synthetic account email required")
    require(integer(config["payloadBytes"], 4096) and config["payloadBytes"] <= PAYLOAD_BYTES, "Invalid payload budget")
    require(config["scenario"] != "photokit-pipeline", "PhotoKit pipeline entry is not provided by the transport harness")
    return config


def target_fingerprint(config: dict) -> str:
    identity = {key: config[key] for key in ("backendURL", "fixtureID", "accountID")}
    return hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def review(manifest: dict, record: dict, relay: dict, *, minimum_locked_seconds=1800) -> dict:
    """Only checks evidence consistency; never turns supplied JSON into product PASS."""
    require(minimum_locked_seconds >= 1800, "The lock threshold cannot be lowered")
    validate_manifest(manifest)
    reject_secrets(record)
    reject_secrets(relay)
    checks = {}
    run = manifest["runID"]
    for label, value in (("record", record), ("relay", relay)):
        checks[label + "Schema"] = value.get("schemaVersion") == SCHEMA and type(value.get("schemaVersion")) is int
        checks[label + "Run"] = value.get("runID") == run
        checks[label + "Target"] = value.get("targetFingerprint") == manifest["targetFingerprint"]
    checks["scenario"] = record.get("scenario") == manifest["scenario"]
    checks["source"] = record.get("sourceRevision") == manifest["sourceRevision"]
    checks["lifecycle"] = record.get("appLifecycle") == "unaltered"
    checks["physicalDevice"] = record.get("physicalDevice") is True
    checks["noAccountCredentialsAtRelay"] = relay.get("rejectedCredentialRequests") == 0
    events, requests = record.get("events", []), relay.get("requests", [])
    require(isinstance(events, list) and isinstance(requests, list), "Invalid evidence list")
    lock = record.get("physicalLock", {})
    try:
        lock_start, lock_end = utc(lock["startedAt"]), utc(lock["endedAt"])
        checks["externalLockObservation"] = lock.get("observer") == "external" and lock_end - lock_start >= minimum_locked_seconds
    except (KeyError, ValueError, TypeError):
        lock_start = lock_end = 0
        checks["externalLockObservation"] = False
    known_media = {item["mediaID"]: item for item in manifest["media"]}
    uploads = record.get("uploads", [])
    require(isinstance(uploads, list), "Invalid upload evidence")
    checks["exactUploadSet"] = len(uploads) == len(known_media) and {u.get("mediaID") for u in uploads} == set(known_media)
    checks["requestSet"] = bool(requests) and all(r.get("mediaID") in known_media and r.get("runID") == run for r in requests)
    checks["transportPayload"] = manifest["scenario"] == "photokit-pipeline" or (len(known_media) == 1 and next(iter(known_media.values()))["byteCount"] == PAYLOAD_BYTES)
    valid_requests = []
    requests_valid = bool(requests)
    for item in requests:
        try:
            media = known_media[item["mediaID"]]
            started, finished = utc(item["startedAt"]), utc(item["finishedAt"])
            status = item.get("upstreamStatus")
            valid = (item["runID"] == run and integer(item.get("offset")) and integer(item.get("plainLength"), 1)
                     and item["plainLength"] <= 8 * 1024 * 1024
                     and type(item.get("cipherLength")) is int and item["cipherLength"] == item["plainLength"] + 28
                     and item["offset"] + item["plainLength"] <= media["byteCount"] and started <= finished
                     and (status is None or type(status) is int and 100 <= status <= 599)
                     and type(item.get("responseDropped")) is bool)
            if status is not None:
                valid = valid and started <= utc(item["upstreamCompletedAt"]) <= finished
            if item.get("responseDropped"):
                valid = valid and status == 204
            if valid:
                valid_requests.append(item)
            requests_valid = requests_valid and valid
        except (KeyError, ValueError, TypeError):
            requests_valid = False
    checks["requestShapeAndTimeline"] = requests_valid
    checks["requestOrder"] = all(
        [utc(r["startedAt"]) for r in valid_requests if r["mediaID"] == media_id]
        == sorted(utc(r["startedAt"]) for r in valid_requests if r["mediaID"] == media_id)
        for media_id in known_media)
    progress_windows = []
    for media_id, media in known_media.items():
        accepted = [r for r in valid_requests if r["mediaID"] == media_id and r["upstreamStatus"] == 204]
        covered = 0
        for item in sorted(accepted, key=lambda r: r["offset"]):
            if item["offset"] > covered:
                break
            covered = max(covered, item["offset"] + item["plainLength"])
        checks[media_id + ".acceptedCoverage"] = covered == media["byteCount"]
        item_events = [e for e in events if e.get("mediaID") == media_id]
        committed = [e for e in item_events if e.get("phase") == "committed-part"]
        offsets = [e.get("confirmedOffset") for e in committed]
        checks[media_id + ".offsets"] = bool(offsets) and all(integer(o) and o <= media["byteCount"] for o in offsets) and offsets == sorted(offsets)
        locked_progress = []
        for event in committed:
            try:
                timestamp = utc(event["at"])
                offset = event.get("confirmedOffset")
                confirmed_by_request = any(r["offset"] + r["plainLength"] == offset and utc(r["upstreamCompletedAt"]) <= timestamp for r in accepted)
                if event.get("locked") is True and event.get("authenticated") is True and confirmed_by_request and lock_start <= timestamp <= lock_end:
                    locked_progress.append((timestamp, offset))
            except (ValueError, KeyError, TypeError):
                pass
        progress_windows.append(any(end[0] - start[0] >= minimum_locked_seconds and end[1] > start[1]
                                    for start in locked_progress for end in locked_progress))
        upload = next((u for u in uploads if u.get("mediaID") == media_id), {})
        readback = upload.get("readback", {})
        created = upload.get("createdAssetIDs", [])
        cleaned = upload.get("cleanup", {})
        checks[media_id + ".finalOffset"] = upload.get("finalOffset") == media["byteCount"]
        checks[media_id + ".readback"] = readback.get("authenticated") is True and all(readback.get(k) == media[k] for k in ("byteCount", "sha1", "sha256")) and readback.get("assetID") in created
        checks[media_id + ".cleanup"] = bool(created) and len(set(created)) == len(created) and cleaned.get("complete") is True and set(cleaned.get("assetIDs", [])) == set(created) and cleaned.get("uploadRef") == upload.get("uploadRef") and bool(upload.get("uploadRef"))
    checks["lockedProgressWindow"] = any(progress_windows)
    drops = [r for r in requests if r.get("responseDropped") is True]
    if manifest["scenario"] == "transport-stable":
        checks["stableHasNoInjectedDrop"] = not drops
    elif manifest["scenario"] == "transport-interrupted":
        checks["singleCommittedResponseDrop"] = len(drops) == 1 and drops[0].get("upstreamStatus") == 204
        resume_proved = False
        for drop in drops:
            media = known_media.get(drop.get("mediaID"), {})
            offset, length = drop.get("offset"), drop.get("plainLength")
            if not (integer(offset, 1) and integer(length, 1) and offset + length < media.get("byteCount", 0)):
                continue
            for event in events:
                try:
                    if event.get("phase") != "resumed-from-server" or event.get("mediaID") != drop.get("mediaID") or event.get("authenticated") is not True:
                        continue
                    confirmed = event.get("confirmedOffset")
                    if not integer(confirmed) or confirmed < offset + length or utc(event["at"]) <= utc(drop["upstreamCompletedAt"]):
                        continue
                    # No upload may start between the lost response and its authenticated status.
                    # Use relay order as well as timestamps so equal-time requests cannot disappear.
                    drop_index = requests.index(drop)
                    later = [r for r in requests[drop_index + 1:] if r.get("mediaID") == drop.get("mediaID")]
                    if later and all(utc(r["startedAt"]) >= utc(event["at"])
                                     and integer(r.get("offset")) and r["offset"] >= confirmed for r in later):
                        resume_proved = True
                except (ValueError, KeyError, TypeError):
                    continue
        checks["resumeBeforeSendingUnconfirmedBytes"] = resume_proved
    else:
        needed = {"product-backup-start", "photokit-scan", "photokit-hash", "photokit-resource", "system-handoff", "next-asset-scheduled", "index-persisted"}
        checks["pipelineStages"] = needed.issubset({e.get("phase") for e in events}) and record.get("syntheticOnlyLibraryVerified") is True
    complete = all(checks.values())
    return {"status": "EVIDENCE_COMPLETE_REVIEW_REQUIRED" if complete else "INCOMPLETE", "runID": run, "checks": checks,
            "limitations": ["Supplied evidence still requires physical observation and authenticated readback review.", "Transport scenarios do not establish PhotoKit or BackupManager whole-library scheduling."]}
