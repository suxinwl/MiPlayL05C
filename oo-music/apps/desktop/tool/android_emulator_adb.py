"""ADB-server client for an isolated oo music emulator test.

Uses the standard ADB smart-socket/sync protocols on localhost:5037; no new ADB
server, authentication keys, root, or device settings. Only emulator-* targets
are accepted, so the connected user's physical phone cannot be selected.
"""

from __future__ import annotations

import argparse
import socket
import struct
from pathlib import Path


def read_exact(sock: socket.socket, size: int) -> bytes:
    result = bytearray()
    while len(result) < size:
        chunk = sock.recv(size - len(result))
        if not chunk:
            raise RuntimeError("ADB connection closed")
        result.extend(chunk)
    return bytes(result)


def send_service(sock: socket.socket, service: str) -> None:
    encoded = service.encode()
    sock.sendall(f"{len(encoded):04x}".encode() + encoded)
    status = read_exact(sock, 4)
    if status == b"FAIL":
        detail = read_exact(sock, int(read_exact(sock, 4), 16)).decode(errors="replace")
        raise RuntimeError(f"ADB request failed: {detail}")
    if status != b"OKAY":
        raise RuntimeError(f"Unexpected ADB response: {status!r}")


class Emulator:
    def __init__(self, serial: str = "emulator-5560") -> None:
        if not serial.startswith("emulator-") or not serial[9:].isdigit():
            raise ValueError("Only an emulator serial is accepted; never target a phone")
        self.serial = serial

    def connection(self) -> socket.socket:
        sock = socket.create_connection(("127.0.0.1", 5037), timeout=120)
        try:
            send_service(sock, "host:transport:" + self.serial)
        except Exception:
            sock.close()
            raise
        return sock

    def shell(self, command: str) -> str:
        # shell,v2 carries exit status separately, unlike legacy shell output.
        with self.connection() as sock:
            send_service(sock, "shell,v2,raw:" + command)
            output = bytearray()
            errors = bytearray()
            exit_code = None
            while exit_code is None:
                channel, count = struct.unpack("<BI", read_exact(sock, 5))
                data = read_exact(sock, count)
                if channel == 1:
                    output.extend(data)
                elif channel == 2:
                    errors.extend(data)
                elif channel == 3:
                    exit_code = data[0] if data else 0
            if exit_code:
                detail = errors.decode(errors="replace").strip()
                raise RuntimeError(f"Android shell exit {exit_code}: {detail}")
            return output.decode(errors="replace").strip()

    def exec_bytes(self, command: str) -> bytes:
        with self.connection() as sock:
            send_service(sock, "exec:" + command)
            output = bytearray()
            while chunk := sock.recv(65536):
                output.extend(chunk)
            return bytes(output)

    def push(self, source: Path, destination: str) -> None:
        if not destination.startswith("/data/local/tmp/oo-music-"):
            raise ValueError("Test files may only be pushed into oo-music-* temp paths")
        with self.connection() as sock:
            send_service(sock, "sync:")
            target = f"{destination},33188".encode()  # ordinary 0644 file
            sock.sendall(b"SEND" + struct.pack("<I", len(target)) + target)
            with source.open("rb") as stream:
                while chunk := stream.read(65536):
                    sock.sendall(b"DATA" + struct.pack("<I", len(chunk)) + chunk)
            sock.sendall(b"DONE" + struct.pack("<I", 0))
            status, count = struct.unpack("<4sI", read_exact(sock, 8))
            if status == b"FAIL":
                raise RuntimeError(read_exact(sock, count).decode(errors="replace"))
            if status != b"OKAY":
                raise RuntimeError(f"ADB push failed: {status!r}")

    def reverse_local_backend(self) -> None:
        """Forward only emulator loopback:8787 to the local development backend."""
        with self.connection() as sock:
            send_service(sock, "reverse:forward:tcp:8787;tcp:8787")
            status = read_exact(sock, 4)
            if status == b"FAIL":
                raise RuntimeError(read_exact(sock, int(read_exact(sock, 4), 16)).decode())
            if status != b"OKAY":
                raise RuntimeError("Emulator reverse forwarding failed")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", default="emulator-5560")
    subparsers = parser.add_subparsers(dest="action", required=True)
    shell = subparsers.add_parser("shell")
    shell.add_argument("command")
    screenshot = subparsers.add_parser("screenshot")
    screenshot.add_argument("output", type=Path)
    push = subparsers.add_parser("push")
    push.add_argument("source", type=Path)
    push.add_argument("destination")
    subparsers.add_parser("reverse-backend")
    args = parser.parse_args()
    emulator = Emulator(args.serial)
    if args.action == "shell":
        print(emulator.shell(args.command))
    elif args.action == "push":
        emulator.push(args.source, args.destination)
        print("Pushed test file to isolated emulator")
    elif args.action == "reverse-backend":
        emulator.reverse_local_backend()
        print("Emulator loopback:8787 forwards to host loopback:8787")
    else:
        data = emulator.exec_bytes("screencap -p")
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise RuntimeError("Emulator did not return a PNG screenshot")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(data)
        print(args.output)


if __name__ == "__main__":
    main()
