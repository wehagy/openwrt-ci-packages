"""NetBird runtime tests in the OpenWrt VM (package-specific, caller side).

test.yml copies this file next to the generic test (tests_path). It runs
after test_package.py (file order), which installs the package.

What it proves, against NetBird Cloud and a reference peer on the runner (the
official client container, same version as the package, same setup key):
  1. `netbird up` with the setup key works in the VM;
  2. `netbird status --json`: management and signal connected, the reference
     peer listed as Connected (the connection type is recorded, not required);
  3. ping works in both directions over the NetBird addresses;
  4. the daemon created the nftables table `netbird` and says so in its log;
  5. wt0 is a wireguard link (sysfs DEVTYPE: BusyBox `ip` has no `-d`);
  6. the daemon's memory use is logged and recorded (never required);
  7. after `/etc/init.d/netbird stop` the table and wt0 are gone; the time the
     daemon needs to exit and whether procd had to SIGKILL it are recorded.

procd term_timeout (read this before changing the stop test): the init script
of the package has no `procd_set_param term_timeout`, so procd waits 5 s for
SIGTERM and then sends SIGKILL, which leaves the nftables table `netbird` and
wt0 behind. The daemon needs more than 5 s on the emulated CPUs of this CI
(it closes up to ~70 peers: the test's own peer mesh). THE TEST, NOT THE
PACKAGE, applies `procd_set_param term_timeout 60` in the VM before anything
else (TERM_TIMEOUT below) and fails if procd does not report it. Measured on
the 25.12 line (netbird 0.78.1, 10 runs per arm, emulated targets): as shipped
the stop test failed in 7 of 30 jobs (10 procd SIGKILLs); with 60 s, 0 of 30
and no SIGKILL, longest shutdown 24.29 s (malta-be). The measurement is in
the README ("procd term_timeout"). When the package gets a term_timeout of
its own, or the upstream init script changes, remove or revisit
TERM_TIMEOUT: a stop that takes more than 5 s is reported as a warning in the
job summary, because the package as shipped would have been SIGKILLed.

Environment variables:
  NB_SETUP_KEY             setup key (test_secrets); absent or empty: every
                           test is skipped with a reason
  HARNESS_PACKAGE_VERSION  package version, e.g. 0.82.0-r1 (the container tag
                           is the upstream part, 0.82.0)
  GITHUB_RUN_ID            used in the peer names (optional)

Ephemeral peers: the key creates peers that NetBird Cloud deletes after they
stay disconnected. The reference peer runs `netbird down`; the VM peer is not
taken down before the stop test (that would remove the objects the test must
prove): a daemon that exits on SIGTERM leaves on its own, one that procd
SIGKILLs does not, and `netbird down` in the teardown cannot reach a dead
daemon. Either way NetBird Cloud deletes the peer after its inactivity period.
"""

import logging
import os
import uuid
from pathlib import Path

import pytest
from harness_util import env, poll
from netbird_ref_peer import RefPeer, Secret, upstream_version
from netbird_vm import Vm

log = logging.getLogger("netbird")

CONNECT_TIMEOUT = 120
PING_TIMEOUT = 90
STOP_TIMEOUT = 120
# Applied by this test, NOT by the package (see the module docstring).
TERM_TIMEOUT = 60
# procd's term_timeout when the init script sets none: the package as shipped.
PROCD_DEFAULT_TERM_TIMEOUT = 5
FIREWALL_LOG = "creating an nftables firewall manager"


@pytest.fixture(scope="module")
def setup_key():
    key = os.environ.get("NB_SETUP_KEY", "")
    if not key:
        pytest.skip(
            "NB_SETUP_KEY is not set: the caller passes it with test_secrets"
            " (a repository secret; pull requests from forks do not get it)"
        )
    return Secret(key)


@pytest.fixture(scope="module")
def names():
    suffix = f"{os.environ.get('GITHUB_RUN_ID', 'local')}-{uuid.uuid4().hex[:6]}"
    return {"ref": f"nbci-ref-{suffix}", "vm": f"nbci-vm-{suffix}"}


@pytest.fixture(scope="module")
def ref_peer(setup_key, names):
    """The reference peer: container on the runner, connected before the VM."""
    peer = RefPeer(
        upstream_version(env("HARNESS_PACKAGE_VERSION")), names["ref"], setup_key
    )
    try:
        peer.start()
        peer.wait_connected()
        log.info("reference peer %s has NetBird IP %s", peer.name, peer.ip)
        yield peer
    finally:
        peer.stop()


@pytest.fixture(scope="module")
def vm(vm_ssh, setup_key, names, ref_peer):
    client = Vm(vm_ssh, setup_key, names["vm"])
    assert client.installed(), (
        "/usr/bin/netbird is missing: test_package.py installs the package"
        " and runs before this file"
    )
    # Before `netbird up`, so the daemon of the whole module runs under it.
    reported = client.apply_term_timeout(TERM_TIMEOUT)
    log.info("procd term_timeout reported for netbird: %s", reported)
    assert reported and all(value == TERM_TIMEOUT for value in reported.values()), (
        f"procd does not report term_timeout {TERM_TIMEOUT} for the netbird"
        f" instance after the restart: {reported}"
    )
    State.term_timeout = TERM_TIMEOUT
    yield client
    # A run that failed before the stop test leaves the VM connected.
    client.run("netbird down", timeout=60)


class State:
    """Facts the later tests need from the earlier ones (file order)."""

    connected = False
    term_timeout = None
    nft_table_seen = False
    wt0_seen = False


def _require_connected():
    if not State.connected:
        pytest.fail("the VM is not connected: test_netbird_up failed", pytrace=False)


def test_netbird_up(vm, ref_peer, record_property):
    """The VM registers with the setup key and sees the reference peer."""
    # State before anything of this test runs (the generic test restarted the
    # service): a starved VM shows here.
    before, _, _ = vm.run("date -u; free; cat /proc/pressure/memory", timeout=20)
    log.info("VM clock and memory before the test: %s", " | ".join(before))
    log.info("VM memory after freeing the test files: %s", vm.free_memory())
    ok, detail = vm.start_daemon()
    assert ok, f"netbird daemon does not answer: {detail}\n{vm.diagnostics()}"

    rc, output = vm.up()
    assert rc == 0, f"netbird up failed with rc={rc}: " + " | ".join(output[-10:])
    log.info("VM after `netbird up`: %s", vm.diagnostics().replace("\n", " | "))

    def peer_connected():
        status = vm.status() or {}
        entry = vm.peer_entry(ref_peer.ip)
        ok = (
            status.get("management", {}).get("connected")
            and status.get("signal", {}).get("connected")
            and entry is not None
            and entry.get("status") == "Connected"
        )
        return bool(ok), (
            f"management={status.get('management')} signal={status.get('signal')}"
            f" peer={entry}"
        )

    ok, detail = poll(peer_connected, CONNECT_TIMEOUT)
    assert ok, (
        f"management, signal and the reference peer ({ref_peer.ip}) not all"
        f" connected after {CONNECT_TIMEOUT} s: {detail}\n{vm.diagnostics()}"
        f"\n{vm.log_tail()}"
    )
    State.connected = True

    status = vm.status() or {}
    entry = vm.peer_entry(ref_peer.ip) or {}
    conn_type = entry.get("connectionType") or "unknown"
    # Recorded, never required: P2P or Relayed both prove the tunnel.
    log.info(
        "connection type VM -> reference peer: %s (ice local %s, remote %s,"
        " relay %s, kernel interface %s, netbird %s)",
        conn_type,
        entry.get("iceCandidateType", {}).get("local"),
        entry.get("iceCandidateType", {}).get("remote"),
        entry.get("relayAddress"),
        status.get("usesKernelInterface"),
        status.get("daemonVersion"),
    )
    record_property("netbird_connection_type", conn_type)
    record_property("netbird_daemon_version", status.get("daemonVersion", ""))
    record_property("netbird_kernel_interface", str(status.get("usesKernelInterface")))


def test_ping_vm_to_reference_peer(vm, ref_peer):
    _require_connected()
    ok, detail = poll(lambda: vm.ping(ref_peer.ip), PING_TIMEOUT)
    assert ok, f"VM cannot ping {ref_peer.ip} after {PING_TIMEOUT} s: {detail}"


def test_ping_reference_peer_to_vm(vm, ref_peer):
    _require_connected()
    vm_ip = (vm.status() or {}).get("netbirdIp", "").split("/", 1)[0]
    assert vm_ip, "the VM has no NetBird IP in its status"
    ok, detail = poll(lambda: ref_peer.ping(vm_ip), PING_TIMEOUT)
    assert ok, (
        f"{ref_peer.name} cannot ping the VM {vm_ip} after {PING_TIMEOUT} s: {detail}"
    )


def test_nftables_table_and_log(vm):
    _require_connected()
    assert vm.has_netbird_table(), f"no table netbird in: {vm.tables()}"
    State.nft_table_seen = True
    assert vm.log_has(FIREWALL_LOG), (
        f"log line {FIREWALL_LOG!r} not found; log tail:\n{vm.log_tail()}"
    )


def test_wt0_is_a_wireguard_link(vm):
    _require_connected()
    rc, details, devtype = vm.link_details()
    assert rc == 0, f"ip link show wt0 failed with rc={rc}: {details}"
    State.wt0_seen = True
    log.info("wt0: %s | %s", details.replace("\n", " "), devtype)
    assert "DEVTYPE=wireguard" in devtype, (
        f"wt0 is not a wireguard link (sysfs DEVTYPE):\n{details}\n{devtype}"
    )


def test_memory_is_recorded(vm, record_property):
    """Record the daemon's memory while connected; never required.

    Small routers matter: VmHWM is the peak RSS of the daemon since it
    started (the VM has connected, answered status calls and pings).
    """
    _require_connected()
    memory = vm.memory_kb()
    log.info("netbird memory in the VM (kB): %s", memory)
    for name, value in memory.items():
        record_property(f"netbird_{name}_kb", str(value))
    assert "VmRSS" in memory, f"cannot read the daemon memory: {memory}"


def stop_report(duration_s, sigkill, term_timeout):
    """The stop measurement as (summary lines, warning text or None)."""
    warning = None
    if sigkill:
        warning = (
            f"procd sent SIGKILL although term_timeout is {term_timeout} s:"
            " the daemon did not exit on SIGTERM in time"
        )
    elif duration_s is not None and duration_s > PROCD_DEFAULT_TERM_TIMEOUT:
        warning = (
            f"the daemon needed {duration_s} s to exit (> {PROCD_DEFAULT_TERM_TIMEOUT}"
            " s): the package as shipped (procd default term_timeout"
            f" {PROCD_DEFAULT_TERM_TIMEOUT} s) would have sent SIGKILL"
        )
    lines = [
        (
            f"- netbird stop: {duration_s} s from the stop call to the process exit;"
            f" procd SIGKILL: {'yes' if sigkill else 'no'}"
        ),
        (
            f"- term_timeout {term_timeout} s is applied by the test, not by the"
            ' package (see the README, "procd term_timeout")'
        ),
    ]
    if warning:
        lines += ["", "> [!WARNING]", f"> WARNING: {warning}"]
    return lines, warning


def write_summary(lines):
    """Append to the job summary; there is none outside GitHub Actions."""
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    title = f"{os.environ.get('HARNESS_LINE', '?')} / {os.environ.get('HARNESS_TARGET', '?')}"
    with Path(path).open("a", encoding="utf-8") as handle:
        handle.write(f"\n### netbird stop ({title})\n" + "\n".join(lines) + "\n")


def test_stop_removes_table_and_wt0(vm, record_property):
    _require_connected()
    # The cleanup is only proved if the objects existed before the stop.
    assert State.nft_table_seen and State.wt0_seen, (
        "table netbird and wt0 were not both seen before the stop"
    )
    assert State.term_timeout == TERM_TIMEOUT, "procd term_timeout was not applied"
    measured = vm.stop_measured(STOP_TIMEOUT)
    lines, warning = stop_report(
        measured["duration_s"], measured["sigkill"], State.term_timeout
    )
    log.info(
        "netbird stop measured: %s",
        {k: v for k, v in measured.items() if k != "output"},
    )
    write_summary(lines)
    record_property("netbird_stop_duration_s", str(measured["duration_s"]))
    record_property("netbird_stop_sigkill", str(measured["sigkill"]).lower())
    record_property("netbird_term_timeout_s", str(State.term_timeout))
    if warning:
        log.warning("%s", warning)
        record_property("netbird_stop_warning", warning)

    assert measured["stop_rc"] == 0, (
        f"/etc/init.d/netbird stop failed with rc={measured['stop_rc']}:"
        f" {measured['output']}"
    )
    assert measured["duration_s"] is not None, (
        f"the stop duration was not measured: {measured['output']}"
    )
    assert not measured["still_running"], (
        f"the daemon (pid {measured['pid']}) still runs {STOP_TIMEOUT} s after the stop"
    )

    def cleaned():
        table = vm.has_netbird_table()
        wt0 = vm.link_details()[0] == 0
        return (
            not table and not wt0,
            f"table netbird present: {table}; wt0 present: {wt0}",
        )

    ok, detail = poll(cleaned, STOP_TIMEOUT)
    assert ok, (
        f"not cleaned up {STOP_TIMEOUT} s after stop: {detail}\n"
        f"measured: {measured}\n"
        f"netbird processes: {vm.run('pidof netbird')[0]}\n"
        f"daemon log tail:\n{vm.log_tail(10)}\n"
        f"syslog tail:\n{vm.syslog_tail()}\n{vm.diagnostics()}"
    )
