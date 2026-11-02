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
  The directory does not exist yet for `netbird`: runtime tests are pending.
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

1. `resolve` (self-test first): the PR's base branch gives the line (`master`:
   `main`, `openwrt-25.12`: `25.12`; any other base fails with `unsupported
   base branch`). The changed packages are the directories that hold a changed
   path and have a `Makefile` in the PR tree (the shallowest one, so `src/Makefile`
   belongs to its package); renames count at both paths. A PR with no package
   or with more than 5 fails; a package the PR only removes has no `Makefile`
   and is not tested. The job summary lists them.
2. Every changed package: `build.yml` on `feed_repository: openwrt/packages`,
   `feed_ref: refs/pull/<n>/head`, then `test.yml` (generic test; a package
   with `packages/<name>/` also gets its `tests/` and `test_secrets` from
   `config.yml`).
3. Packages with `packages/<name>/` here: also `images.yml`, and the whole
   pipeline again on the other line. The base builds one repository and ref, so
   `compose` pushes `upstream-overlay/pr<n>-<run id>-<attempt>` to this
   repository: the other line's `openwrt/packages` branch with the changed
   directories of the PR copied over it (one root commit, upstream `.github/`
   dropped); `cleanup` deletes it when the builds are done. Packages without
   `packages/<name>/` run on the PR's line only.
4. The base is called at `@feat/feed-source` with `ci_ref: feat/feed-source`
   (the branch that adds `feed_repository` and `feed_ref`); both change to `main`
   when it is integrated.

Limits: `test_secrets` is read from `packages/<name>/config.yml` here, while
`ci.yml` still names `NB_SETUP_KEY` itself. One failed build of a package skips
the test jobs of all packages of that line (they need the whole matrix).

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
