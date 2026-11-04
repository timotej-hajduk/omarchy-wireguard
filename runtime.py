#!/usr/bin/env python3
"""Private widget state and interface-bound probes; no privileged operations."""
import contextlib
import fcntl
import html
import ipaddress
import os
from pathlib import Path
import re
import secrets
import selectors
import signal
import stat
import subprocess
import sys
import time
import json

LIMIT = 131072
NAME = re.compile(r"[A-Za-z0-9_=+][A-Za-z0-9_=+.-]{0,14}")


def name(value):
    if not NAME.fullmatch(value):
        raise ValueError("invalid interface name")
    return value


class PrivateState:
    def __init__(self):
        base = os.environ.get("XDG_RUNTIME_DIR") or str(Path.home() / ".cache")
        path = Path(base) / "omarchy-wireguard"
        if not path.is_absolute() or ".." in path.parts:
            raise ValueError("unsafe runtime directory")
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in path.parts[1:]:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = child
                info = os.fstat(fd)
                sticky_root = info.st_uid == 0 and info.st_mode & stat.S_ISVTX
                if not sticky_root and (info.st_uid not in (0, os.getuid()) or info.st_mode & 0o022):
                    raise ValueError("unsafe runtime ancestor")
            info = os.fstat(fd)
            if info.st_uid != os.getuid() or info.st_mode & 0o022:
                raise ValueError("runtime directory must be privately owned")
            os.fchmod(fd, 0o700)
            self.fd = fd
        except BaseException:
            os.close(fd)
            raise

    def close(self):
        os.close(self.fd)

    def check(self, filename):
        if not re.fullmatch(r"[A-Za-z0-9_=+][A-Za-z0-9_=+.-]{0,95}", filename):
            raise ValueError("invalid state filename")
        try:
            info = os.stat(filename, dir_fd=self.fd, follow_symlinks=False)
        except FileNotFoundError:
            return None
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or info.st_mode & 0o022):
            raise ValueError("unsafe state file")
        return info

    def stamp(self, filename):
        self.check(filename)
        temporary = ".stamp-" + secrets.token_hex(16)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.fd)
        try:
            os.close(fd)
            os.replace(temporary, filename, src_dir_fd=self.fd, dst_dir_fd=self.fd)
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary, dir_fd=self.fd)

    @contextlib.contextmanager
    def lock(self, filename):
        self.check(filename)
        fd = os.open(filename, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=self.fd)
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_nlink != 1 or info.st_mode & 0o022):
                raise ValueError("unsafe state lock")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        finally:
            os.close(fd)


def run(command, seconds=4):
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             start_new_session=True, env=dict(os.environ, LC_ALL="C"))
    finished = False
    output = bytearray()
    until = time.monotonic() + seconds
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            while selector.get_map():
                remaining = until - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("probe command timed out")
                for key, _ in selector.select(min(0.1, remaining)):
                    chunk = os.read(key.fileobj.fileno(), 4096)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        output.extend(chunk)
                        if len(output) > LIMIT:
                            raise ValueError("probe output exceeded limit")
            code = child.wait(timeout=max(0.01, until - time.monotonic()))
            finished = True
            return code, output.decode("utf-8")
    finally:
        if not finished:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        child.stdout.close()


def probe(interface, host):
    interface = name(interface)
    code, output = run(["ip", "-j", "link", "show", "type", "wireguard"])
    links = json.loads(output) if code == 0 else []
    if not isinstance(links, list) or not any(
            isinstance(link, dict) and link.get("ifname") == interface and "UP" in link.get("flags", [])
            for link in links):
        raise ValueError("WireGuard interface is not up")
    try:
        if "%" in host:
            raise ValueError("zone suffix")
        address = str(ipaddress.ip_address(host))
    except ValueError:
        if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?\.?", host) or ".." in host:
            raise ValueError("invalid probe host")
        # Never resolve using the physical connection as a fallback.
        code, output = run(["resolvectl", "--interface=" + interface, "--protocol=dns",
                            "--cache=no", "--legend=no", "query", host])
        addresses = []
        if code == 0:
            for token in output.split():
                try:
                    addresses.append(str(ipaddress.ip_address(token.strip("[](),"))))
                except ValueError:
                    pass
        if not addresses:
            raise ValueError("cannot resolve probe host through " + interface)
        address = addresses[0]
    code, output = run(["ping", "-n", "-I", interface, "-c", "1", "-W", "1", "--", address])
    if code not in (0, 1):
        raise ValueError("interface-bound ping unavailable")
    match = re.search(r"\btime[=<]([0-9.]+)\s*ms", output) if code == 0 else None
    return {"ok": True, "host": host, "interface": interface, "ms": float(match[1]) if match else None}


def main():
    action, *args = sys.argv[1:]
    if action == "probe" and len(args) == 2:
        print(json.dumps(probe(*args)))
        return 0
    with contextlib.closing(PrivateState()) as store:
        if action == "demo" and not args:
            print("true" if store.check("demo") else "false")
        elif action in ("mark", "driven") and len(args) == 1:
            filename = name(args[0]) + ".driven"
            if action == "mark":
                store.stamp(filename)
            else:
                info = store.check(filename)
                print(int(info.st_mtime) if info else "null")
        elif action == "notify" and len(args) in (3, 4):
            interface, state, summary, *body = args
            name(interface)
            if not re.fullmatch(r"[a-z]{1,20}", state):
                raise ValueError("invalid notification state")
            driven = store.check(interface + ".driven")
            if driven and 0 <= time.time() - driven.st_mtime < 20:
                return 0
            with store.lock(interface + ".lock"):
                marker = interface + "." + state + ".notified"
                info = store.check(marker)
                if info and 0 <= time.time() - info.st_mtime < 30:
                    return 0
                store.stamp(marker)
                run(["notify-send", "-a", "WireGuard", "--", html.escape(summary), html.escape(body[0] if body else "")])
        else:
            raise ValueError("invalid runtime action")
    return 0


def interrupted(*_):
    raise SystemExit(143)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        sys.exit(main())
    except BlockingIOError:
        sys.exit(0)
    except (OSError, ValueError, IndexError, TypeError, TimeoutError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"ok": False, "error": str(error)[:256]}))
        sys.exit(1)
