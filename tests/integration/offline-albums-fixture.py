#!/usr/bin/env python3
"""Owned loopback-only synthetic server for offline album UI acceptance."""
import argparse
import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import struct
import threading
from urllib.parse import urlsplit
import zlib

PORT = 43891
OWNER = '0d685e47-ddcb-4477-b3cc-199cf85f1100'
ALBUM = '0d685e47-ddcb-4477-b3cc-199cf85f1101'
STILL, LIVE, VIDEO, MOTION = [f'0d685e47-ddcb-4477-b3cc-199cf85f11{i:02d}' for i in range(2, 6)]
SIMULATOR = '8F6070E7-63F5-4128-AD09-27518349CD0C'
API = f'http://127.0.0.1:{PORT}/api'
ROOT = Path('/Users/achilles/mjora/execution/batch1-20261117/offline')
MOTION_PATH = Path('/Users/achilles/mjora/execution/photos-phase4/services/video-media/live-motion.mov')


def image():
    width, height = 600, 400
    pixels = b''.join(b'\0' + b''.join(bytes((int(80 + x * 120 / width), int(40 + y * 100 / height), 170))
                                      for x in range(width)) for y in range(height))
    def chunk(kind, value):
        return struct.pack('!I', len(value)) + kind + value + struct.pack('!I', zlib.crc32(kind + value))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')


USER = dict(id=OWNER, email='offline@imora-offline-fixture.invalid', name='Offline Fixture', isAdmin=False)
DETAILS = {}
for i, identifier in enumerate([STILL, LIVE, VIDEO, MOTION]):
    DETAILS[identifier] = dict(id=identifier, ownerId=OWNER, type='VIDEO' if identifier in [VIDEO, MOTION] else 'IMAGE',
        originalFileName=f'offline-fixture-{i}', originalMimeType='video/quicktime' if identifier in [VIDEO, MOTION] else 'image/png',
        fileCreatedAt=f'2026-01-0{i + 1}T12:00:00Z', localDateTime=f'2026-01-0{i + 1}T12:00:00Z',
        isFavorite=False, isTrashed=False, visibility='timeline', thumbhash=None, width=600, height=400,
        duration=2000 if identifier in [VIDEO, MOTION] else None)
DETAILS[LIVE]['livePhotoVideoId'] = MOTION
DETAILS[MOTION]['visibility'] = 'hidden'
ALBUM_DATA = dict(id=ALBUM, albumName='Offline acceptance', description='Synthetic still, video and Live Photo',
    albumThumbnailAssetId=STILL, assetCount=3, albumUsers=[dict(user=USER, role='owner')], shared=False,
    hasSharedLink=False, createdAt='2026-01-01T12:00:00Z', updatedAt='2026-01-01T12:00:00Z', order='desc')
IMAGE = image()
VIDEO_BYTES = MOTION_PATH.read_bytes()


class Handler(BaseHTTPRequestHandler):
    offline = False
    request_counts = {}
    counts_lock = threading.Lock()

    def log_message(self, *_):
        pass

    def reply(self, value, status=200, mime='application/json'):
        body = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        size = int(self.headers.get('Content-Length', 0))
        self.rfile.read(size)
        path = urlsplit(self.path).path
        if path == '/control/reset-counts':
            with Handler.counts_lock:
                Handler.request_counts = {}
            return self.reply({'reset': True})
        if path == '/control/motion-visible-v1':
            DETAILS[MOTION]['visibility'] = 'timeline'
            DETAILS[MOTION]['thumbhash'] = 'motion-v1'
            DETAILS[LIVE]['thumbhash'] = 'parent-v1'
            return self.reply({'motionVersion': 'motion-v1'})
        if path == '/control/motion-v2':
            DETAILS[MOTION]['thumbhash'] = 'motion-v2'
            return self.reply({'motionVersion': 'motion-v2'})
        if path == '/control/offline':
            Handler.offline = True
            return self.reply({'offline': True})
        if path == '/control/online':
            Handler.offline = False
            return self.reply({'offline': False})
        if Handler.offline:
            return self.reply({}, 503)
        if path == '/api/auth/login':
            return self.reply(dict(accessToken='synthetic-offline-ui-token', userId=OWNER, userEmail=USER['email'],
                name=USER['name'], isAdmin=False, profileImagePath='', shouldChangePassword=False))
        if path == '/api/search/metadata':
            return self.reply({'assets': {'items': [DETAILS[i] for i in [STILL, LIVE, VIDEO]]}})
        return self.reply({}, 404)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/control/status':
            with Handler.counts_lock:
                counts = dict(Handler.request_counts)
            return self.reply({'offline': Handler.offline, 'ownerID': OWNER, 'requestCounts': counts})
        with Handler.counts_lock:
            Handler.request_counts[path] = Handler.request_counts.get(path, 0) + 1
        if Handler.offline:
            return self.reply({}, 503)
        if path.endswith('/server/ping'):
            return self.reply({'res': 'pong'})
        if path == '/api/server/version':
            return self.reply(dict(major=3, minor=4, patch=1))
        if path == '/api/server/features':
            return self.reply(dict(smartSearch=False, facialRecognition=False, map=False, trash=True,
                oauth=False, oauthAutoLaunch=False, passwordLogin=True))
        if path == '/api/config':
            return self.reply({'config': {}, 'passwordLogin': {'enabled': True}, 'oauth': {'enabled': False}})
        if path == '/api/server/config':
            return self.reply({})
        if path == '/api/users/me':
            return self.reply(USER)
        if path == '/api/albums':
            return self.reply([ALBUM_DATA])
        if path == '/api/albums/' + ALBUM:
            return self.reply(ALBUM_DATA)
        if path == '/api/timeline/buckets':
            return self.reply([{'timeBucket': '2026-01-01T00:00:00Z', 'count': 3}])
        if path == '/api/timeline/bucket':
            values = [DETAILS[i] for i in [STILL, LIVE, VIDEO]]
            return self.reply(dict(id=[d['id'] for d in values], ownerId=[OWNER] * 3, isImage=[True, True, False],
                isFavorite=[False] * 3, isTrashed=[False] * 3, visibility=['timeline'] * 3,
                thumbhash=[None] * 3, fileCreatedAt=[d['fileCreatedAt'] for d in values], localOffsetHours=[0] * 3,
                duration=[None, None, 2000], livePhotoVideoId=[None, MOTION, None], ratio=[1.5] * 3))
        if path in ['/api/memories', '/api/people', '/api/notifications', '/api/tags', '/api/search/places']:
            return self.reply([])
        parts = path.split('/')
        if len(parts) >= 4 and parts[2] == 'assets' and parts[3] in DETAILS:
            if len(parts) == 4:
                return self.reply(DETAILS[parts[3]])
            if parts[4] in ['thumbnail', 'original']:
                return self.reply(IMAGE, mime='image/png')
            if parts[4:] == ['video', 'playback']:
                return self.reply(VIDEO_BYTES, mime='video/quicktime')
        return self.reply({}, 404)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serve', action='store_true', required=True)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--simulator-udid', required=True)
    parser.add_argument('--evidence-root', type=Path, required=True)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error('Use an unprivileged loopback port')
    PORT, SIMULATOR, ROOT = args.port, args.simulator_udid, args.evidence_root.resolve()
    API = f'http://127.0.0.1:{PORT}/api'
    ROOT.mkdir(parents=True, exist_ok=True)
    manifest = ROOT / 'ui-fixture.json'
    manifest.write_text(json.dumps(dict(apiURL=API, ownerID=OWNER, simulatorUDID=SIMULATOR,
        albumID=ALBUM, stillID=STILL, liveID=LIVE, videoID=VIDEO, motionID=MOTION,
        motionSHA256=hashlib.sha256(VIDEO_BYTES).hexdigest())))
    manifest.chmod(0o600)
    print('Serving the owned offline album UI fixture on loopback', flush=True)
    ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
