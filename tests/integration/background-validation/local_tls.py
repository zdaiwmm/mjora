"""Private IPv4 bindings and explicit, verified TLS for disposable test listeners."""
from __future__ import annotations

import ipaddress
import http.server
import ssl
import sys
from urllib.parse import urlsplit

from validation import require


LAN = tuple(ipaddress.IPv4Network(network) for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))


class PrivateHTTPServer(http.server.ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        if not isinstance(sys.exception(), (ssl.SSLError, ConnectionError)):
            super().handle_error(request, client_address)


def private_bind(host: str) -> str:
    address = ipaddress.IPv4Address(host)
    require(address == ipaddress.IPv4Address("127.0.0.1") or any(address in network for network in LAN),
            "Bind only to loopback or a dedicated private IPv4 interface")
    return str(address)


def server_context(cert, key):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certfile=cert, keyfile=key)
    return context


def relay_context(url, *, host, port, cert, key):
    private_bind(host)
    parsed = urlsplit(url)
    effective_port = parsed.port or (443 if parsed.scheme == "https" else 80)
    require((parsed.hostname, effective_port) == (host, port), "Relay must listen on the exact request endpoint")
    require(bool(cert) == bool(key), "Supply both the certificate and its key")
    require((parsed.scheme == "https") == bool(cert), "Relay listener must match the request scheme")
    require(cert is not None or host == "127.0.0.1", "LAN relay requires TLS")
    return server_context(cert, key) if cert else None


def wrap_listener(server, context):
    if context is not None:
        # Handshake runs in the request handler thread, not on the accept loop.
        server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    return server
