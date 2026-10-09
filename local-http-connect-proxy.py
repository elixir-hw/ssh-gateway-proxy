#!/usr/bin/env python3
"""Small loopback-only HTTP CONNECT proxy for an SSH reverse tunnel.

This proxy intentionally supports only ports 80 and 443 and rejects private,
loopback, link-local, and other non-public destination addresses. It performs no
TLS interception; HTTPS and WebSocket traffic is passed through as raw bytes.
"""

import argparse
import base64
import hmac
import ipaddress
import logging
import os
import selectors
import socket
import socketserver
import sys
from urllib.parse import urlsplit


MAX_HEADER_BYTES = 64 * 1024
CONNECT_TIMEOUT_SECONDS = 12
IDLE_TIMEOUT_SECONDS = 300
ALLOWED_PORTS = {80, 443}


class ProxyError(Exception):
    pass


def split_authority(authority, default_port):
    parsed = urlsplit("//" + authority)
    if not parsed.hostname:
        raise ProxyError("missing target host")
    try:
        port = parsed.port or default_port
    except ValueError as exc:
        raise ProxyError("invalid target port") from exc
    if port not in ALLOWED_PORTS:
        raise ProxyError("target port is not allowed")
    return parsed.hostname, port


def connect_public_target(host, port, allowed_private_hosts):
    try:
        addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise ProxyError("target name resolution failed") from exc

    last_error = None
    public_address_found = False
    for family, socktype, proto, _canonname, sockaddr in addresses:
        address_text = sockaddr[0].split("%", 1)[0]
        try:
            address = ipaddress.ip_address(address_text)
        except ValueError:
            continue
        if not address.is_global and host.lower().rstrip(".") not in allowed_private_hosts:
            continue

        public_address_found = True
        upstream = socket.socket(family, socktype, proto)
        upstream.settimeout(CONNECT_TIMEOUT_SECONDS)
        try:
            upstream.connect(sockaddr)
            upstream.settimeout(None)
            return upstream
        except OSError as exc:
            last_error = exc
            upstream.close()

    if not public_address_found:
        raise ProxyError("target resolved only to non-public addresses and is not allowlisted")
    raise ProxyError("could not connect to target") from last_error


def read_request_header(client):
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = client.recv(8192)
        if not chunk:
            raise EOFError
        data.extend(chunk)
        if len(data) > MAX_HEADER_BYTES:
            raise ProxyError("request headers are too large")
    marker = data.index(b"\r\n\r\n") + 4
    return bytes(data[:marker]), bytes(data[marker:])


def relay(left, right):
    selector = selectors.DefaultSelector()
    selector.register(left, selectors.EVENT_READ, right)
    selector.register(right, selectors.EVENT_READ, left)
    try:
        while True:
            events = selector.select(IDLE_TIMEOUT_SECONDS)
            if not events:
                return
            for key, _mask in events:
                source = key.fileobj
                destination = key.data
                try:
                    payload = source.recv(65536)
                except OSError:
                    return
                if not payload:
                    return
                destination.sendall(payload)
    finally:
        selector.close()


class ProxyRequestHandler(socketserver.BaseRequestHandler):
    server = None

    def send_error(self, status, message, proxy_authenticate=False):
        headers = [
            "HTTP/1.1 {} {}".format(status, message),
            "Content-Length: 0",
            "Connection: close",
        ]
        if proxy_authenticate:
            headers.append('Proxy-Authenticate: Basic realm="ssh-gateway-proxy"')
        response = "\r\n".join(headers) + "\r\n\r\n"
        try:
            self.request.sendall(response.encode("ascii"))
        except OSError:
            pass

    def authenticate(self, headers):
        if not self.server.expected_authorization:
            return True
        supplied = ""
        for name, value in headers:
            if name.lower() == "proxy-authorization":
                supplied = value.strip()
                break
        return hmac.compare_digest(supplied, self.server.expected_authorization)

    def handle(self):
        upstream = None
        try:
            self.request.settimeout(CONNECT_TIMEOUT_SECONDS)
            raw_header, buffered_body = read_request_header(self.request)
            lines = raw_header.decode("iso-8859-1").split("\r\n")
            request_parts = lines[0].split(" ", 2)
            if len(request_parts) != 3:
                raise ProxyError("invalid request line")
            method, target, version = request_parts

            headers = []
            for line in lines[1:]:
                if not line:
                    continue
                if ":" not in line:
                    raise ProxyError("invalid request header")
                name, value = line.split(":", 1)
                headers.append((name.strip(), value.strip()))

            if not self.authenticate(headers):
                self.send_error(407, "Proxy Authentication Required", True)
                return

            if method.upper() == "CONNECT":
                host, port = split_authority(target, 443)
                upstream = connect_public_target(host, port, self.server.allowed_private_hosts)
                logging.info("CONNECT %s:%s", host, port)
                self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                if buffered_body:
                    upstream.sendall(buffered_body)
                self.request.settimeout(None)
                relay(self.request, upstream)
                return

            parsed_target = urlsplit(target)
            if parsed_target.scheme and parsed_target.hostname:
                if parsed_target.scheme.lower() != "http":
                    raise ProxyError("non-CONNECT requests must use HTTP")
                host = parsed_target.hostname
                port = parsed_target.port or 80
                path = parsed_target.path or "/"
                if parsed_target.query:
                    path += "?" + parsed_target.query
            else:
                host_header = next((value for name, value in headers if name.lower() == "host"), None)
                if not host_header:
                    raise ProxyError("missing Host header")
                host, port = split_authority(host_header, 80)
                path = target

            if port not in ALLOWED_PORTS:
                raise ProxyError("target port is not allowed")
            upstream = connect_public_target(host, port, self.server.allowed_private_hosts)
            logging.info("%s %s:%s%s", method.upper(), host, port, path)

            forwarded_headers = []
            for name, value in headers:
                if name.lower() in {"proxy-authorization", "proxy-connection", "connection"}:
                    continue
                forwarded_headers.append("{}: {}".format(name, value))
            forwarded_headers.append("Connection: close")
            forwarded_request = (
                "{} {} {}\r\n{}\r\n\r\n".format(
                    method, path, version, "\r\n".join(forwarded_headers)
                ).encode("iso-8859-1")
                + buffered_body
            )
            upstream.sendall(forwarded_request)
            self.request.settimeout(None)
            relay(self.request, upstream)
        except EOFError:
            # A TCP-only health check opens and closes without an HTTP request.
            return
        except ProxyError as exc:
            logging.warning("Rejected proxy request from %s: %s", self.client_address[0], exc)
            self.send_error(502, "Bad Gateway")
        except (ConnectionError, OSError) as exc:
            logging.warning("Proxy connection failed: %s", exc)
            self.send_error(502, "Bad Gateway")
        finally:
            if upstream is not None:
                try:
                    upstream.close()
                except OSError:
                    pass


class ThreadingProxyServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def parse_arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=7890)
    parser.add_argument("--username", default="")
    parser.add_argument("--log-file", default="")
    parser.add_argument("--allow-private-host", action="append", default=[])
    return parser.parse_args()


def main():
    args = parse_arguments()
    password = os.environ.get("LOCAL_CONNECT_PROXY_PASSWORD", "")
    if bool(args.username) != bool(password):
        print("Both --username and LOCAL_CONNECT_PROXY_PASSWORD are required for authentication.", file=sys.stderr)
        return 2

    log_handlers = [logging.StreamHandler(sys.stderr)]
    if args.log_file:
        log_handlers.append(logging.FileHandler(args.log_file, encoding="utf-8"))
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=log_handlers,
    )

    expected = ""
    if args.username:
        raw_credentials = "{}:{}".format(args.username, password).encode("utf-8")
        expected = "Basic " + base64.b64encode(raw_credentials).decode("ascii")

    with ThreadingProxyServer((args.bind, args.port), ProxyRequestHandler) as server:
        server.expected_authorization = expected
        server.allowed_private_hosts = {
            host.lower().rstrip(".") for host in args.allow_private_host
        }
        logging.info("HTTP CONNECT proxy listening on %s:%s", args.bind, args.port)
        if server.allowed_private_hosts:
            logging.info(
                "Private-address allowlist: %s",
                ", ".join(sorted(server.allowed_private_hosts)),
            )
        server.serve_forever(poll_interval=0.5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
