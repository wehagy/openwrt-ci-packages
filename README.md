# openwrt-ci-packages

OpenWrt packages built, tested in QEMU and turned into firmware images by the
reusable base [wehagy/openwrt-ci](https://github.com/wehagy/openwrt-ci). This
repository holds the packages (`packages/<name>/`: configuration and
package-specific tests); the base holds the workflows, scripts and the generic
package test.

## Layout

- `packages/<name>/config.yml`: data of the package. Today only `package`, the
  name of a directory of `openwrt/packages` (read by the `config` job).
- `packages/<name>/tests/` (optional): pytest files that run next to the
  generic test in the QEMU VM. Missing directory: only the generic test runs.
  For `netbird` they are the runtime tests described in "NetBird runtime
  tests" below.
- `.github/workflows/ci.yml`: calls the base for `netbird` on push to
  `feat/**` and on `workflow_dispatch` (`refresh_sdk`, `lines`).
- `.github/workflows/upstream-pr.yml`: tests a pull request of `openwrt/packages`
  by number, `workflow_dispatch` only (see "Testing an upstream pull request").
- `scripts/upstream-pr/`: its shell (`lib.sh`, `resolve.sh`, `compose.sh`) and
  `selftest.sh`, which the workflow runs first.
- `.github/actionlint.yaml`: declares the `ubuntu-26.04` label for actionlint.

## How `ci.yml` uses the base

| Job                          | Calls                         | Notes                                              |
|------------------------------|-------------------------------|----------------------------------------------------|
| `config`                     | -                             | reads `packages/netbird/config.yml`                |
| `build-25-12`, `build-main`  | `build.yml`                   | `packages: write`: may rebuild the SDK image       |
| `test-25-12`, `test-main`    | `test.yml`, `source: artifact` | `tests_path`, `test_secrets: NB_SETUP_KEY`, `secrets: inherit` |
| `image-25-12`, `image-main`  | `images.yml`                  | profiles of the base                               |

- Each call passes `ci_ref`: the ref of `wehagy/openwrt-ci` the scripts are
  checked out from. It must equal the ref after `@` in `uses:`. No tags are
  used. Both are `main` (`ci_ref` defaults to `main` in the base; it is kept
  explicit so that it visibly matches `@main`).
- The job logs print `harness: wehagy/openwrt-ci ref <ref> -> <sha>` and
  `caller: wehagy/openwrt-ci-packages run commit <sha>, checkout HEAD <sha>`.

## Testing an upstream pull request (`upstream-pr.yml`)

Run by hand with `pr_number` (digits only, at most 7, no leading zero; optional
`refresh_sdk`). It never writes to `openwrt/packages` (a `GET`, a `git fetch`).
It is `workflow_dispatch` only, never `pull_request_target`.

**No secret reaches an upstream pull request.** Its code is untrusted: the
built `.apk` runs in the QEMU VM and the tests run on the runner. So the jobs
have no `secrets:` and no `test_secrets`; the NetBird runtime tests that need
`NB_SETUP_KEY` skip, which is expected. The `tests/` of `packages/<name>/` of
this repository still run (that code is ours, not the PR's).

1. `resolve` (self-test first): the PR's base branch gives the line (`master`:
   `main`, `openwrt-25.12`: `25.12`; any other base fails with `unsupported
   base branch`). The changed packages are the directories that hold a changed
   path and have a `Makefile` in the PR tree (the shallowest one, so `src/Makefile`
   belongs to its package); renames count at both paths. A PR with no package
   or with more than 5 fails; a package the PR only removes has no `Makefile`
   and is not tested. The job summary lists them.
   The base builds one package by name and takes the `.apk` of that name, so a
   package whose Makefile has no `define Package/<directory name>` (`udns`
   builds `libudns`, `python-yaml` builds `python3-yaml`) is reported as `NOT
   TESTED` with the names it defines (summary and a warning), and the run fails
   if no package is left.
2. Every testable package: `build.yml` with `feed_repository: openwrt/packages`
   and `feed_ref` the head commit SHA that `resolve` read, then `test.yml`
   (generic test; a package with `packages/<name>/` also gets its `tests/`).
   The head of the PR is built as it is: the base branch is not merged into it
   and `refs/pull/<n>/merge` is not used (the base refuses that ref).
3. Packages with `packages/<name>/` here: also `images.yml`, and the whole
   pipeline again on the other line. The base builds one repository and ref, so
   `compose` pushes `upstream-overlay/pr<n>-<run id>-<attempt>` to this
   repository: the other line's `openwrt/packages` branch with the changed
   directories of the PR copied over it (one root commit, upstream `.github/`
   dropped), and `build.yml` builds its commit SHA; `cleanup` deletes the branch
   when the builds are done. Packages without `packages/<name>/` run on the
   PR's line only.
4. The base is called at `@main` with `ci_ref: main`.

Limit: one failed build of a package skips the test jobs of all packages of
that line (they need the whole matrix).

## Secrets

`secrets: inherit` hands the repository secrets to `test.yml`. The names in
`test_secrets` (`NB_SETUP_KEY` for netbird) are exported as environment
variables of `pytest`, and no process above `pytest` keeps the JSON with all
the secrets of this repository in its environment. Values are never printed; a
missing secret is an empty variable, so a test can skip with a reason.

This is hygiene, not isolation: the tests in `tests_path` are code of this
repository, and so is the workflow that passes the secrets; a test could read
anything this repository's own workflow can. Do not put code you do not trust
in `tests_path`.

The log of the `Run tests` step lists the names of all secrets of this
repository (`"NAME": "***"`), never their values.

## NetBird runtime tests (`packages/netbird/tests/`)

Files (copied by the base next to the generic test; `test_package_netbird.py`
sorts after `test_package.py`, which installs the package):

- `test_package_netbird.py`: the tests and their module fixtures.
- `netbird_ref_peer.py`: the reference peer on the runner.
- `netbird_vm.py`: the commands run in the VM.

Setup: the repository secret `NB_SETUP_KEY` is a reusable, ephemeral setup key
of NetBird Cloud (management URL: the client default). It is listed in
`test_secrets` of `ci.yml`. The tests start the official client container
`ghcr.io/netbirdio/netbird:<upstream version of the package>` on the runner
with the same key (`docker run -e NB_SETUP_KEY`: the value is not on a command
line) and wait until it is connected; the base needs no hook for that, because
pytest runs on the runner. In the VM the key is a file given to
`netbird up --setup-key-file`, removed right after (a command line would reach
the labgrid logs uploaded as artifacts). Peer names: `nbci-ref-<run id>-<rand>`
and `nbci-vm-<run id>-<rand>`.

| Test                                  | Proves                                                                 |
|---------------------------------------|------------------------------------------------------------------------|
| `test_netbird_up`                     | `netbird up` works; `netbird status --json`: management and signal connected, the reference peer `Connected`; the connection type (`P2P` or `Relayed`) is logged and recorded as junit property `netbird_connection_type`, never required |
| `test_ping_vm_to_reference_peer`      | VM pings the reference peer over its NetBird IP                        |
| `test_ping_reference_peer_to_vm`      | the reference peer pings the VM over its NetBird IP                    |
| `test_nftables_table_and_log`         | `nft list tables` has a table `netbird`; the client log has `creating an nftables firewall manager` |
| `test_wt0_is_a_wireguard_link`        | `wt0` exists and sysfs says `DEVTYPE=wireguard` (BusyBox `ip` has no `-d`) |
| `test_stop_removes_table_and_wt0`     | after `/etc/init.d/netbird stop` the table and `wt0` are gone (only if both were seen before) |

- Without the secret (a fork, or a caller that does not pass it) every test is
  skipped with the reason `NB_SETUP_KEY is not set`; the generic test is not
  affected and no container is started.
- Cleanup: the reference peer runs `netbird down` and its container is
  removed at the end of the module. The VM peer leaves when the service stops
  (`test_stop_removes_table_and_wt0`; a stop before `netbird down` is the point of
  that test), and a teardown `netbird down` covers a run that failed earlier.
  Ephemeral peers that stay disconnected are deleted by NetBird Cloud after
  its inactivity period.
- Memory: `test_memory_is_recorded` logs the daemon's `VmRSS` and `VmHWM` and
  the VM's `MemAvailable` (junit properties `netbird_*_kb`), never required.
  The tests free the `.apk` that the generic test leaves in `/tmp` (RAM)
  before they start the daemon. With the 128 MB x86-64 VM of an earlier base
  the kernel OOM-killed `netbird` (`Out of memory: Killed process ...
  (netbird)`); the base now gives that target 256 MB.
- The assertions and messages never print the key: it is a `Secret` object and
  command output goes through `redact()`.

## SDK image access (once, by the owner)

The base reuses the public SDK image `ghcr.io/wehagy/openwrt-sdk` when it is
fresh (less than a day old). When it must rebuild it, the push uses this
repository's `GITHUB_TOKEN`, which needs: GitHub > Packages > `openwrt-sdk` >
Package settings > Manage Actions access > Add Repository >
`wehagy/openwrt-ci-packages`, role Write (Admin to also delete the superseded
`-prev` version). Without it the job fails with `push of ... denied`.

## Adding a package

1. Create `packages/<name>/config.yml` with `package: <name>` (a directory of
   `openwrt/packages`).
2. Add the jobs of `ci.yml` for it (the `config` job reads one package today).
3. Optional: put pytest files in `packages/<name>/tests/` and pass
   `tests_path: packages/<name>/tests`. They may import `harness_util` and use
   the `vm_ssh` fixture of the base; they must not be named `conftest.py`,
   `harness_util.py` or `test_package.py`.
