"""NetBird inside the OpenWrt VM (not a test file).

Responsibility: the commands the runtime tests run in the VM over ssh (start
the daemon, `netbird up`, status, nftables, wt0, log, stop) and the parsing of
their output. No assertions about NetBird behaviour live here; the tests do
that.

The setup key reaches the VM as a file (`--setup-key-file`) that exists only
for the duration of `netbird up`: a command line would be written to the
labgrid logs that the job uploads as an artifact.
"""

import json
import os
import re
import shlex
import subprocess
import tempfile

from harness_util import poll
from netbird_ref_peer import redact

CMD_TIMEOUT = 600
QUERY_TIMEOUT = 30
# Status of a daemon on the 128 MB x86-64 VM took more than 30 s (memory pressure).
STATUS_TIMEOUT = 120
UP_TIMEOUT = 180
REMOTE_KEY = "/tmp/nb-setup-key"
APK_LEFTOVER = "/tmp/package-under-test.apk"  # test_package.py REMOTE_APK
LOG_FILE = "/var/log/netbird/client.log"
TABLE = re.compile(r"^table\s+\S+\s+netbird$")


class Vm:
    """The VM's NetBird client, driven through the labgrid SSH driver."""

    def __init__(self, ssh, setup_key, hostname):
        self.ssh = ssh
        self._key = setup_key
        self.hostname = hostname

    def run(self, command, timeout=QUERY_TIMEOUT):
        """(stdout lines, stderr lines, rc); the key is redacted.

        A command that outlives its timeout (a hung VM or daemon) is rc 124,
        so the caller can report the state instead of aborting on the
        exception.
        """
        try:
            out, err, rc = self.ssh.run(command, timeout=timeout)
        except subprocess.TimeoutExpired:
            out, err, rc = [], [f"timed out after {timeout} s: {command}"], 124
        return (
            [redact(line, self._key) for line in out],
            [redact(line, self._key) for line in err],
            rc,
        )

    def free_memory(self):
        """Release what the generic test left in RAM; returns `free` output.

        The generic test copies the .apk to /tmp (tmpfs, so RAM) and leaves
        it there. The x86-64 VM has 128 MB, of which about 104 MB are usable:
        with the file kept the kernel OOM-killed `netbird` (run 41478332303:
        `Out of memory: Killed process ... (netbird)`).
        """
        out, err, _ = self.run(
            f"rm -f {APK_LEFTOVER}; sync; echo 3 > /proc/sys/vm/drop_caches; free",
            timeout=60,
        )
        return "\n".join(out + err)

    def memory_kb(self):
        """RSS and peak RSS of the netbird daemon and system memory, in kB."""
        out, _, _ = self.run(
            "pid=$(pidof netbird | cut -d' ' -f1);"
            " grep -E '^(VmRSS|VmHWM):' /proc/$pid/status;"
            " grep -E '^(MemTotal|MemAvailable):' /proc/meminfo"
        )
        values = {}
        for line in out:
            match = re.match(r"^(\w+):\s+(\d+)", line)
            if match:
                values[match.group(1)] = int(match.group(2))
        return values

    def installed(self):
        _, _, rc = self.run("test -x /usr/bin/netbird")
        return rc == 0

    def status(self):
        """Parsed `netbird status --json` of the VM, or None."""
        out, _, rc = self.run("netbird status --json", timeout=STATUS_TIMEOUT)
        if rc != 0:
            return None
        try:
            return json.loads("\n".join(out))
        except json.JSONDecodeError:
            return None

    def start_daemon(self, timeout=60):
        """Make sure the procd service answers on its socket."""
        self.run("/etc/init.d/netbird start", timeout=CMD_TIMEOUT)
        ok, detail = poll(
            lambda: (self.status() is not None, "no `netbird status --json` yet"),
            timeout,
        )
        return ok, detail

    def up(self):
        """`netbird up` with the setup key; returns (rc, output lines)."""
        with tempfile.NamedTemporaryFile("w", suffix=".key") as key_file:
            os.chmod(key_file.name, 0o600)
            key_file.write(str(self._key))
            key_file.flush()
            self.ssh.put(key_file.name, REMOTE_KEY)
        try:
            out, err, rc = self.run(
                f"chmod 600 {REMOTE_KEY} && netbird up"
                f" --setup-key-file {REMOTE_KEY} --hostname {self.hostname}",
                timeout=UP_TIMEOUT,
            )
        finally:
            self.run(f"rm -f {REMOTE_KEY}")
        return rc, out + err

    def peer_entry(self, ip):
        """The entry for the peer with this NetBird IP in the VM's status."""
        status = self.status() or {}
        # `details` is JSON null while the VM has no peers.
        for entry in (status.get("peers") or {}).get("details") or []:
            if entry.get("netbirdIp", "").split("/", 1)[0] == ip:
                return entry
        return None

    def ping(self, ip):
        """One ping attempt of 2 packets from the VM; (ok, output)."""
        out, err, rc = self.run(f"ping -c 2 -W 3 {ip}", timeout=30)
        return rc == 0, "\n".join(out + err)

    def tables(self):
        out, _, rc = self.run("nft list tables")
        assert rc == 0, f"nft list tables failed with {rc}"
        return [line.strip() for line in out]

    def has_netbird_table(self):
        return any(TABLE.match(line) for line in self.tables())

    def link_details(self):
        """(rc, `ip link show wt0`, sysfs device type); rc != 0: no wt0.

        BusyBox `ip` (the one in OpenWrt images) has no `-d`, so the link
        type is read from sysfs, where the kernel states it (DEVTYPE).
        """
        out, err, rc = self.run("ip link show wt0")
        devtype, _, _ = self.run("grep DEVTYPE /sys/class/net/wt0/uevent")
        return rc, "\n".join(out + err), "\n".join(devtype)

    def diagnostics(self):
        """Memory, load and the kernel log tail, for a failure message."""
        out, err, _ = self.run(
            "free; uptime; dmesg | grep -i -E 'oom|killed process'; dmesg | tail -n 15;"
            " top -bn1 | head -n 12",
            timeout=20,
        )
        return "\n".join(out + err)

    def log_has(self, text):
        """True if the netbird client log (file, else syslog) has the text."""
        _, _, rc = self.run(f"grep -F {shlex.quote(text)} {LOG_FILE}")
        if rc == 0:
            return True
        _, _, rc = self.run(f"logread | grep -F {shlex.quote(text)}")
        return rc == 0

    def syslog_tail(self, lines=15):
        """Last syslog lines (procd reports how the daemon ended)."""
        out, _, _ = self.run(f"logread | tail -n {lines}")
        return "\n".join(out)

    def log_tail(self, lines=30):
        out, _, _ = self.run(f"tail -n {lines} {LOG_FILE}")
        return "\n".join(out)
