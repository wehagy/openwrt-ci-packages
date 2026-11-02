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
  6. after `/etc/init.d/netbird stop` the table and wt0 are gone.

Environment variables:
  NB_SETUP_KEY             setup key (test_secrets); absent or empty: every
                           test is skipped with a reason
  HARNESS_PACKAGE_VERSION  package version, e.g. 0.82.0-r1 (the container tag
                           is the upstream part, 0.82.0)
  GITHUB_RUN_ID            used in the peer names (optional)

Ephemeral peers: the key creates peers that NetBird Cloud deletes after they
stay disconnected. The reference peer runs `netbird down`; the VM peer leaves
when the service stops (test 6), and a teardown `netbird down` covers a run
that failed before that.
"""

import logging
import os
import uuid

import pytest
from harness_util import env, poll
from netbird_ref_peer import RefPeer, Secret, upstream_version
from netbird_vm import Vm

log = logging.getLogger("netbird")

CONNECT_TIMEOUT = 120
PING_TIMEOUT = 90
STOP_TIMEOUT = 120
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
    yield client
    # A run that failed before the stop test leaves the VM connected.
    client.run("netbird down", timeout=60)


class State:
    """Facts the later tests need from the earlier ones (file order)."""

    connected = False
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


def test_stop_removes_table_and_wt0(vm):
    _require_connected()
    # The cleanup is only proved if the objects existed before the stop.
    assert State.nft_table_seen and State.wt0_seen, (
        "table netbird and wt0 were not both seen before the stop"
    )
    _, _, rc = vm.run("/etc/init.d/netbird stop", timeout=120)
    assert rc == 0, f"/etc/init.d/netbird stop failed with rc={rc}"

    def cleaned():
        table = vm.has_netbird_table()
        wt0 = vm.link_details()[0] == 0
        return (
            not table and not wt0,
            f"table netbird present: {table}; wt0 present: {wt0}",
        )

    ok, detail = poll(cleaned, STOP_TIMEOUT)
    assert ok, f"not cleaned up {STOP_TIMEOUT} s after stop: {detail}"
