"""Reference NetBird peer on the CI runner (not a test file).

Responsibility: start the official NetBird client container (same version as
the package under test) with the repository setup key, wait until it is
connected to NetBird Cloud, and stop it again. The VM under test pings this
peer over the NetBird network and the peer pings the VM back.

The setup key is never written to a command line, a file or a message: the
container gets it through the environment of the `docker` process
(`-e NB_SETUP_KEY` without a value), and every text that may reach a log goes
through `redact()`.

Imported by test_package_netbird.py (copied next to it by test.yml).
"""

import json
import os
import re
import subprocess

from harness_util import poll

# GHCR, not Docker Hub: anonymous Docker Hub pulls from shared runner IPs are
# rate limited.
IMAGE = "ghcr.io/netbirdio/netbird"
DOCKER_TIMEOUT = 300
QUERY_TIMEOUT = 30
CONNECT_TIMEOUT = 120


class Secret(str):
    """A string whose repr hides the value (pytest prints reprs on failure)."""

    def __repr__(self):
        return "<secret>"


def redact(text, secret):
    """Replace the secret in text, so a message can be logged safely."""
    return text.replace(str(secret), "***") if secret else text


def upstream_version(package_version):
    """'0.82.0-r1' (apk version) -> '0.82.0' (tag of the container image)."""
    match = re.match(r"^(\d+\.\d+\.\d+)(?:-r\d+)?$", package_version)
    assert match, f"unexpected package version {package_version!r}"
    return match.group(1)


def peer_ip(address):
    """'100.64.0.7/16' -> '100.64.0.7'."""
    return address.split("/", 1)[0]


class RefPeer:
    """One NetBird client container; the setup key is passed by environment."""

    def __init__(self, version, name, setup_key):
        self.image = f"{IMAGE}:{version}"
        self.name = name
        self._key = setup_key
        self.ip = None

    def _docker(self, *args, timeout=QUERY_TIMEOUT, secret_env=False):
        env = None
        if secret_env:
            env = {**os.environ, "NB_SETUP_KEY": str(self._key)}
        proc = subprocess.run(
            ["docker", *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            check=False,
        )
        return proc.returncode, redact(proc.stdout + proc.stderr, self._key)

    def start(self):
        """Pull the image and run the container; fails with docker's message."""
        rc, out = self._docker("pull", "-q", self.image, timeout=DOCKER_TIMEOUT)
        assert rc == 0, f"docker pull {self.image} failed with {rc}: {out}"
        rc, out = self._docker(
            "run",
            "-d",
            "--name",
            self.name,
            "--hostname",
            self.name,
            "--cap-add=NET_ADMIN",
            "--cap-add=SYS_ADMIN",
            "--cap-add=SYS_RESOURCE",
            "--device=/dev/net/tun",
            "-e",
            "NB_SETUP_KEY",
            "-e",
            f"NB_HOSTNAME={self.name}",
            self.image,
            timeout=DOCKER_TIMEOUT,
            secret_env=True,
        )
        assert rc == 0, f"docker run {self.image} failed with {rc}: {out}"

    def status(self):
        """`netbird status --json` inside the container, or None."""
        rc, out = self._docker("exec", self.name, "netbird", "status", "--json")
        if rc != 0:
            return None
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            return None

    def wait_connected(self):
        """Wait for management, signal and an address; returns the peer IP."""

        def connected():
            status = self.status()
            if not status:
                return False, "no status yet"
            ok = (
                status.get("management", {}).get("connected")
                and status.get("signal", {}).get("connected")
                and status.get("netbirdIp")
            )
            return bool(ok), json.dumps(
                {k: status.get(k) for k in ("management", "signal", "netbirdIp")}
            )

        ok, detail = poll(connected, CONNECT_TIMEOUT)
        assert ok, (
            f"reference peer {self.name} not connected after {CONNECT_TIMEOUT} s:"
            f" {detail}\n{self.logs()}"
        )
        status = self.status() or {}
        self.ip = peer_ip(status.get("netbirdIp", ""))
        assert self.ip, f"reference peer {self.name} lost its address"
        return self.ip

    def ping(self, ip):
        """One ping attempt of 2 packets from the container; (ok, output)."""
        rc, out = self._docker(
            "exec", self.name, "ping", "-c", "2", "-W", "3", ip, timeout=30
        )
        return rc == 0, out

    def logs(self, tail=40):
        _, out = self._docker("logs", "--tail", str(tail), self.name)
        return out

    def stop(self):
        """`netbird down` (leave the network cleanly), then remove the container."""
        try:
            self._docker("exec", self.name, "netbird", "down", timeout=60)
        finally:
            # A hung `netbird down` (TimeoutExpired) must not leak the container.
            self._docker("rm", "-f", self.name, timeout=60)
