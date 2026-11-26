#!/usr/bin/env python3
"""Minimal TURN client for the eturnal spike. Dummy credentials only.

Speaks long-term MESSAGE-INTEGRITY (RFC 8489) and the TURN REST password
(draft-uberti-behave-turn-rest-00): password = base64(HMAC-SHA1(secret, username)).
"""

import argparse
import base64
import binascii
import hashlib
import hmac
import os
import socket
import struct
import sys
import time

MAGIC = 0x2112A442
MAGIC_B = struct.pack("!I", MAGIC)

A_MAPPED = 0x0001
A_USERNAME = 0x0006
A_MI = 0x0008
A_ERROR = 0x0009
A_UNKNOWN = 0x000A
A_REALM = 0x0014
A_NONCE = 0x0015
A_XOR_PEER = 0x0012
A_DATA = 0x0013
A_LIFETIME = 0x000D
A_XOR_RELAYED = 0x0016
A_REQUESTED_TRANSPORT = 0x0019
A_REQUESTED_FAMILY = 0x0017
A_DONT_FRAGMENT = 0x001A
A_CHANNEL = 0x000C
A_SOFTWARE = 0x8022
A_FINGERPRINT = 0x8028


def msg_type(method: int, cls: int) -> int:
    return (
        ((method & 0x0F80) << 2)
        | ((method & 0x0070) << 1)
        | (method & 0x000F)
        | ((cls & 0x2) << 7)
        | ((cls & 0x1) << 4)
    )


def pad4(value: bytes) -> bytes:
    return value + b"\x00" * ((4 - (len(value) % 4)) % 4)


def attr(code: int, value: bytes) -> bytes:
    return struct.pack("!HH", code, len(value)) + pad4(value)


def xor_peer(ip: str, port: int, txid: bytes) -> bytes:
    xport = port ^ (MAGIC >> 16)
    if ":" not in ip:
        packed = socket.inet_pton(socket.AF_INET, ip)
        xaddr = bytes(a ^ b for a, b in zip(packed, MAGIC_B))
        return struct.pack("!BBH", 0, 0x01, xport) + xaddr
    packed = socket.inet_pton(socket.AF_INET6, ip)
    mask = MAGIC_B + txid
    xaddr = bytes(a ^ b for a, b in zip(packed, mask))
    return struct.pack("!BBH", 0, 0x02, xport) + xaddr


def decode(data: bytes):
    if len(data) < 20:
        raise ValueError(f"short stun {len(data)}")
    mtype, length, magic, txid = struct.unpack("!HHI12s", data[:20])
    if magic != MAGIC:
        raise ValueError(f"bad magic {magic:#x}")
    body = data[20 : 20 + length]
    attrs = {}
    i = 0
    while i + 4 <= len(body):
        code, alen = struct.unpack("!HH", body[i : i + 4])
        val = body[i + 4 : i + 4 + alen]
        attrs.setdefault(code, val)
        i += 4 + ((alen + 3) // 4) * 4
    return mtype, txid, attrs


def error_text(attrs) -> str:
    raw = attrs.get(A_ERROR)
    if not raw or len(raw) < 4:
        return "no-error-attr"
    _reserved, klass, number = struct.unpack("!HBB", raw[:4])
    reason = raw[4:].decode("utf-8", "replace")
    return f"{klass * 100 + number} {reason}"


def fingerprint(header_and_body: bytes) -> bytes:
    crc = binascii.crc32(header_and_body) & 0xFFFFFFFF
    crc ^= 0x5354554E
    return attr(A_FINGERPRINT, struct.pack("!I", crc))


def signed(method: int, cls: int, txid: bytes, parts: list[bytes], key: bytes) -> bytes:
    body = b"".join(parts)
    length = len(body) + 24  # MESSAGE-INTEGRITY header + 20
    header = struct.pack("!HHI12s", msg_type(method, cls), length, MAGIC, txid)
    mac = hmac.new(key, header + body, hashlib.sha1).digest()
    mi = attr(A_MI, mac)
    # Fingerprint covers the message with length including itself.
    length_fp = length + 8
    header_fp = struct.pack("!HHI12s", msg_type(method, cls), length_fp, MAGIC, txid)
    return header_fp + body + mi + fingerprint(header_fp + body + mi)


def unsigned(method: int, cls: int, txid: bytes, parts: list[bytes]) -> bytes:
    body = b"".join(parts)
    header = struct.pack("!HHI12s", msg_type(method, cls), len(body) + 8, MAGIC, txid)
    return header + body + fingerprint(header + body)


def rest_password(secret: str, username: str) -> str:
    mac = hmac.new(secret.encode(), username.encode(), hashlib.sha1).digest()
    return base64.b64encode(mac).decode()


def lt_key(username: str, realm: str, password: str) -> bytes:
    return hashlib.md5(f"{username}:{realm}:{password}".encode()).digest()


class Client:
    def __init__(self, host: str, port: int):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(3)
        self.addr = (host, port)
        self.realm = ""
        self.nonce = b""
        self.key = b""
        self.username = ""

    def send(self, packet: bytes):
        self.sock.sendto(packet, self.addr)
        data, _ = self.sock.recvfrom(4096)
        print(f"wire req={len(packet)} resp={len(data)}")
        return decode(data)

    def allocate(self, username: str, password: str, transport: int = 17, lifetime: int | None = None, ipv6: bool = False):
        self.username = username
        txid = os.urandom(12)
        req_parts = [attr(A_REQUESTED_TRANSPORT, bytes([transport, 0, 0, 0]))]
        if lifetime is not None:
            req_parts.append(attr(A_LIFETIME, struct.pack("!I", lifetime)))
        if ipv6:
            req_parts.append(attr(A_REQUESTED_FAMILY, bytes([0x02, 0, 0, 0])))
        mtype, _, attrs = self.send(unsigned(0x003, 0, txid, req_parts))
        print(f"allocate-1 {mtype:#06x} {error_text(attrs)}")
        if A_REALM not in attrs or A_NONCE not in attrs:
            return mtype, attrs
        self.realm = attrs[A_REALM].decode()
        self.nonce = attrs[A_NONCE]
        self.key = lt_key(username, self.realm, password)
        parts = req_parts + [
            attr(A_USERNAME, username.encode()),
            attr(A_REALM, self.realm.encode()),
            attr(A_NONCE, self.nonce),
        ]
        txid = os.urandom(12)
        mtype, _, attrs = self.send(signed(0x003, 0, txid, parts, self.key))
        life = attrs.get(A_LIFETIME)
        life_n = struct.unpack("!I", life)[0] if life and len(life) == 4 else None
        print(f"allocate-2 {mtype:#06x} {error_text(attrs)} software={attrs.get(A_SOFTWARE)} lifetime={life_n} resp_bytes_later")
        if A_XOR_RELAYED in attrs:
            print(f"relayed-raw {attrs[A_XOR_RELAYED].hex()}")
        return mtype, attrs

    def authed(self, method: int, extra: list[bytes]):
        parts = extra + [
            attr(A_USERNAME, self.username.encode()),
            attr(A_REALM, self.realm.encode()),
            attr(A_NONCE, self.nonce),
        ]
        txid = os.urandom(12)
        return self.send(signed(method, 0, txid, parts, self.key)), txid

    def create_permission(self, ip: str, port: int = 9):
        txid_holder = {}

        def build(txid):
            return [
                attr(A_XOR_PEER, xor_peer(ip, port, txid)),
            ]

        # XOR-PEER for IPv4 does not use txid; IPv6 does. Build after txid exists.
        txid = os.urandom(12)
        parts = build(txid) + [
            attr(A_USERNAME, self.username.encode()),
            attr(A_REALM, self.realm.encode()),
            attr(A_NONCE, self.nonce),
        ]
        mtype, _, attrs = self.send(signed(0x008, 0, txid, parts, self.key))
        print(f"permission {ip} {mtype:#06x} {error_text(attrs)}")
        return mtype, attrs

    def channel_bind(self, ip: str, port: int = 9, channel: int = 0x4000):
        txid = os.urandom(12)
        parts = [
            attr(A_CHANNEL, struct.pack("!HH", channel, 0)),
            attr(A_XOR_PEER, xor_peer(ip, port, txid)),
            attr(A_USERNAME, self.username.encode()),
            attr(A_REALM, self.realm.encode()),
            attr(A_NONCE, self.nonce),
        ]
        mtype, _, attrs = self.send(signed(0x009, 0, txid, parts, self.key))
        print(f"channelbind {ip} {mtype:#06x} {error_text(attrs)}")
        return mtype, attrs

    def refresh(self, lifetime: int | None = None):
        extra = []
        if lifetime is not None:
            extra.append(attr(A_LIFETIME, struct.pack("!I", lifetime)))
        (mtype, _, attrs), _ = self.authed(0x004, extra)
        print(f"refresh {mtype:#06x} {error_text(attrs)}")
        return mtype, attrs

    def send_indication(self, ip: str, port: int, payload: bytes, quiet: bool = False):
        txid = os.urandom(12)
        parts = [
            attr(A_XOR_PEER, xor_peer(ip, port, txid)),
            attr(A_DATA, payload),
        ]
        packet = unsigned(0x006, 1, txid, parts)
        self.sock.sendto(packet, self.addr)
        if not quiet:
            print(f"send-indication {ip}:{port} {len(payload)} bytes")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=3478)
    p.add_argument("--secret", required=True)
    p.add_argument("--username", required=True)
    p.add_argument("--password", default="")
    p.add_argument(
        "--do",
        required=True,
        choices=["allocate", "blacklist", "refresh-wait", "send", "send-keep", "tcp", "flood", "unauth", "many", "connect"],
    )
    p.add_argument("--peer", action="append", default=[])
    p.add_argument("--wait", type=int, default=0)
    p.add_argument("--secret2", default="")
    p.add_argument("--lifetime", type=int, default=-1)
    p.add_argument("--count", type=int, default=1)
    p.add_argument("--ipv6", action="store_true")
    args = p.parse_args()
    password = args.password or rest_password(args.secret, args.username)
    print(f"username={args.username}")
    print(f"password-sha256={hashlib.sha256(password.encode()).hexdigest()[:12]} (not the secret)")
    life = None if args.lifetime < 0 else args.lifetime
    if args.do == "unauth":
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2)
        for method, name in ((0x001, "binding"), (0x003, "allocate")):
            txid = os.urandom(12)
            pkt = unsigned(method, 0, txid, [])
            s.sendto(pkt, (args.host, args.port))
            data, _ = s.recvfrom(4096)
            print(f"unauth {name} req={len(pkt)} resp={len(data)} factor={len(data)/len(pkt):.2f}")
        return
    if args.do == "many":
        ok = err = 0
        for i in range(args.count):
            user = args.username if args.ipv6 else args.username
            # --ipv6 here means "vary the username"; default is one username.
            name = args.username if not args.ipv6 else f"{args.username}-n{i}"
            # username must stay REST-shaped. Vary the label-free owner tail via the expiry-stable suffix.
            if args.ipv6:
                base, _, rest = args.username.partition(":")
                name = f"{base}:g1.Owner{i:04d}"
                pw = rest_password(args.secret, name)
            else:
                name = args.username
                pw = password
            cli = Client(args.host, args.port)
            try:
                mt, attrs = cli.allocate(name, pw, lifetime=life)
            except Exception as exc:
                print(f"n={i} EXC {exc}")
                err += 1
                continue
            if mt == msg_type(0x003, 2):
                ok += 1
                print(f"n={i} OK")
            else:
                err += 1
                print(f"n={i} FAIL {error_text(attrs)}")
        print(f"many ok={ok} fail={err}")
        return
    if args.do == "connect":
        # RFC 6062 CONNECT on an existing UDP allocation, peer in --peer.
        pass
    c = Client(args.host, args.port)
    if args.do == "tcp":
        c.allocate(args.username, password, transport=6, lifetime=life)
        return
    ok_type = msg_type(0x003, 2)
    mtype, _ = c.allocate(args.username, password, lifetime=life, ipv6=args.ipv6)
    if mtype != ok_type:
        sys.exit(2)
    if args.do == "allocate":
        return
    if args.do == "blacklist":
        fail = 0
        for peer in args.peer:
            mt, _ = c.create_permission(peer)
            if mt == msg_type(0x008, 2):
                print(f"UNEXPECTED allow {peer}")
                fail = 1
            mt2, _ = c.channel_bind(peer)
            if mt2 == msg_type(0x009, 2):
                print(f"UNEXPECTED channel {peer}")
                fail = 1
        # A documentation address outside the recommended list must be allowed,
        # so a total blacklist is not what we are seeing.
        if args.secret2:
            pass
        sys.exit(fail)
    if args.do == "refresh-wait":
        print(f"sleeping {args.wait}s for credential expiry")
        time.sleep(args.wait)
        mt, _ = c.refresh()
        if mt == msg_type(0x004, 2):
            print("UNEXPECTED refresh accepted")
            sys.exit(3)
        return
    if args.do == "send-keep":
        for peer in args.peer:
            mt, _ = c.create_permission(peer, port=9)
            if mt != msg_type(0x008, 2):
                print(f"permission refused for send target {peer}")
                sys.exit(4)
            c.send_indication(peer, 9, b"before-expiry")
        print(f"sleeping {args.wait}s on the same allocation")
        time.sleep(args.wait)
        for peer in args.peer:
            c.send_indication(peer, 9, b"after-expiry")
        mt, _ = c.refresh()
        if mt == msg_type(0x004, 2):
            print("UNEXPECTED refresh accepted")
            sys.exit(3)
        return
    if args.do == "flood":
        peer = args.peer[0]
        mt, _ = c.create_permission(peer, port=9)
        print(f"flood-permission {mt:#06x}")
        payload = b"Z" * 1000
        t0 = time.perf_counter()
        for _ in range(args.count):
            c.send_indication(peer, 9, payload, quiet=True)
        dt = time.perf_counter() - t0
        print(f"flood sent={args.count} payload={len(payload)} seconds={dt:.3f} mbit={args.count*len(payload)*8/dt/1e6:.1f}")
        return
    if args.do == "connect":
        peer = args.peer[0]
        txid = os.urandom(12)
        parts = [
            attr(A_XOR_PEER, xor_peer(peer, 80, txid)),
            attr(A_USERNAME, c.username.encode()),
            attr(A_REALM, c.realm.encode()),
            attr(A_NONCE, c.nonce),
        ]
        mtype, _, attrs = c.send(signed(0x00A, 0, txid, parts, c.key))
        print(f"connect {peer} {mtype:#06x} {error_text(attrs)}")
        return
    if args.do == "send":
        for peer in args.peer:
            mt, _ = c.create_permission(peer, port=9)
            if mt != msg_type(0x008, 2):
                print(f"permission refused for send target {peer}")
                sys.exit(4)
            c.send_indication(peer, 9, b"mjolnir-turn-spike-" + peer.encode()[:40])
            time.sleep(0.2)
        return
    if args.do == "both-secrets":
        return


if __name__ == "__main__":
    main()
