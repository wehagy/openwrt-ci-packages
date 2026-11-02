#!/usr/bin/env sh
# Responsibility: offline tests of the scripts of the update workflow that talk
# to the network, git or gh, with stubs of curl, gh and git (scripts/stubs/)
# first in PATH and a local bare repository in place of the review repository.
# Run by update-selftest.sh. A script is never run against GitHub here.
#
# Usage:
#   scripts/flow-selftest.sh
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/selftest.sh
. "${script_dir}/lib/selftest.sh"

# --- stubs ------------------------------------------------------------------
STUB_REAL_GIT=$(command -v git)
mkdir "${work}/bin"
cp "${script_dir}/stubs/curl-stub.sh" "${work}/bin/curl"
cp "${script_dir}/stubs/gh-stub.sh" "${work}/bin/gh"
cp "${script_dir}/stubs/git-stub.sh" "${work}/bin/git"
PATH="${work}/bin:${PATH}"
STUB_LOG="${work}/stub.log"
STUB_GH_DIR="${work}/gh"
export PATH STUB_LOG STUB_GH_DIR STUB_REAL_GIT
: >"${STUB_LOG}"
# git: no user configuration, and the review repository https://github.com/wehagy/w
# is a local bare repository (see stubs/git-stub.sh).
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="url.${work}/origin.git.insteadOf"
GIT_CONFIG_VALUE_0=https://github.com/wehagy/w
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
: >"${STUB_LOG}"

# Makefile of a package at version $1, with PKG_HASH $2.
#
# Arguments:
#   $1  PKG_VERSION
#   $2  PKG_HASH
#   $3  file to write
write_makefile() {
	cat >"$3" <<MK
include \$(TOPDIR)/rules.mk

PKG_NAME:=netbird
PKG_VERSION:=$1
PKG_RELEASE:=3

PKG_SOURCE:=\$(PKG_NAME)-\$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/netbirdio/netbird/tar.gz/v\$(PKG_VERSION)?
PKG_HASH:=$2

PKG_LICENSE:=BSD-3-Clause
MK
}

# --- source-sha256.sh: a failed download must fail --------------------------
x_hash=$(printf 'x' | sha256sum | cut -d' ' -f1)
write_makefile 0.81.4 "${x_hash}" "${work}/Makefile"
sha_url=$("${script_dir}/source-sha256.sh" --url "${work}/Makefile" 0.82.0)
want_sha=$(printf 'archive of %s\n' "${sha_url}" | sha256sum | cut -d' ' -f1)
got_sha=$("${script_dir}/source-sha256.sh" "${work}/Makefile" 0.82.0) || got_sha="exit $?"
if [ "${got_sha}" = "${want_sha}" ]; then
	record "source-sha256 hashes the downloaded archive" 0 ""
else
	record "source-sha256 hashes the downloaded archive" 1 "got ${got_sha}"
fi

sha_rc=0
sha_out=$(STUB_CURL_EXIT=22 "${script_dir}/source-sha256.sh" "${work}/Makefile" 0.82.0 2>&1) || sha_rc=$?
empty_hash=$(printf '' | sha256sum | cut -d' ' -f1)
case "${sha_rc}:${sha_out}" in
*"${empty_hash}"*) record "source-sha256 fails when the download fails" 1 "printed the hash of an empty stream" ;;
1:*"download of the source archive failed"*) record "source-sha256 fails when the download fails" 0 "" ;;
*) record "source-sha256 fails when the download fails" 1 "exit ${sha_rc}: ${sha_out}" ;;
esac

sha_rc=0
sha_out=$(STUB_CURL_EMPTY=1 "${script_dir}/source-sha256.sh" "${work}/Makefile" 0.82.0 2>&1) || sha_rc=$?
case "${sha_rc}:${sha_out}" in
1:*"archive is empty"*) record "source-sha256 refuses an empty archive" 0 "" ;;
*) record "source-sha256 refuses an empty archive" 1 "exit ${sha_rc}: ${sha_out}" ;;
esac

# --- fixtures ---------------------------------------------------------------
current_version=0.81.4
current_url=$("${script_dir}/source-sha256.sh" --url "${work}/Makefile" "${current_version}")
current_hash=$(printf 'archive of %s\n' "${current_url}" | sha256sum | cut -d' ' -f1)
update_branch=ci/netbird-update-0.82.0
base_branch=ci/netbird-base-0.82.0

# Reset the fixtures of the gh stub: the review repository has ${current_version}
# and no branch or pull request; the latest upstream release is $1.
#
# Arguments:
#   $1  tag_name of the latest release
gh_fixtures() {
	rm -rf "${STUB_GH_DIR}"
	mkdir "${STUB_GH_DIR}"
	write_makefile "${current_version}" "${current_hash}" "${STUB_GH_DIR}/makefile"
	printf '0123456789abcdef0123456789abcdef01234567\n' >"${STUB_GH_DIR}/head_sha"
	printf '%s\n' "$1" >"${STUB_GH_DIR}/tag"
	: >"${STUB_GH_DIR}/branches"
	: >"${STUB_GH_DIR}/prs"
	printf 'https://example.invalid/pull/9\n' >"${STUB_GH_DIR}/pr_url"
	printf 'true\n' >"${STUB_GH_DIR}/permissions"
	printf '422\n' >"${STUB_GH_DIR}/probe_status"
	: >"${STUB_LOG}"
}

# --- plan-update.sh ---------------------------------------------------------
# Run plan-update.sh; sets plan_rc and the files plan.out (stdout, the lines
# for $GITHUB_OUTPUT) and plan.err (the log and the annotations).
#
# Arguments:
#   $1  FORCE_VERSION (may be empty)
run_plan() {
	plan_rc=0
	UPSTREAM_REPOSITORY=netbirdio/netbird REVIEW_REPOSITORY=wehagy/w REVIEW_BRANCH=master \
		PACKAGE=netbird PACKAGE_PATH=net/netbird FORCE_VERSION=$1 \
		"${script_dir}/plan-update.sh" >"${work}/plan.out" 2>"${work}/plan.err" || plan_rc=$?
}

gh_fixtures v0.82.0
run_plan ""
check "plan: newer release, no branch, no pull request: needed" "${work}/plan.out" has "${work}/plan.out" needed=true
check "plan: needed run exits 0" "exit ${plan_rc}" same "${plan_rc}" 0
check "plan: the outputs carry the branches" "${work}/plan.out" has "${work}/plan.out" "update_branch=${update_branch}"
check "plan: the outputs carry the versions" "${work}/plan.out" has "${work}/plan.out" "target=0.82.0"

gh_fixtures v0.81.4
run_plan ""
check "plan: same version: not needed" "${work}/plan.out" has "${work}/plan.out" needed=false
check "plan: same version exits 0" "exit ${plan_rc}" same "${plan_rc}" 0

gh_fixtures v0.81.4
run_plan 0.82.0
check "plan: a forced version wins over the release" "${work}/plan.out" has "${work}/plan.out" needed=true

gh_fixtures v0.82.0
printf '%s\n' "${update_branch}" >"${STUB_GH_DIR}/branches"
run_plan ""
check "plan: the update branch exists: not needed" "${work}/plan.out" has "${work}/plan.out" needed=false

gh_fixtures v0.82.0
printf '%s closed\n' "${update_branch}" >"${STUB_GH_DIR}/prs"
run_plan ""
check "plan: a closed pull request: not needed" "${work}/plan.out" has "${work}/plan.out" needed=false
check "plan: a closed pull request exits 0" "exit ${plan_rc}" same "${plan_rc}" 0

# A hostile tag is refused and never echoed.
gh_fixtures "v0.82.0
::error::forged"
run_plan ""
check "plan: a hostile tag fails" "exit ${plan_rc}" same "${plan_rc}" 1
check "plan: a hostile tag is not echoed" "${work}/plan.err" lacks "${work}/plan.err" forged
check "plan: a hostile tag prints no output line" "${work}/plan.out" empty "${work}/plan.out"

# --- prepare-branches.sh ----------------------------------------------------
# A fresh bare repository (the review repository) with the package at
# ${current_version} on master, cloned into review/ with the GitHub URL.
fresh_review() {
	rm -rf "${work}/origin.git" "${work}/review" "${work}/seed"
	"${STUB_REAL_GIT}" init -q --bare -b master "${work}/origin.git"
	"${STUB_REAL_GIT}" init -q -b master "${work}/seed"
	mkdir -p "${work}/seed/net/netbird"
	write_makefile "${current_version}" "${current_hash}" "${work}/seed/net/netbird/Makefile"
	"${STUB_REAL_GIT}" -C "${work}/seed" add .
	"${STUB_REAL_GIT}" -C "${work}/seed" -c user.name=seed -c user.email=seed@example.invalid commit -q -m seed
	"${STUB_REAL_GIT}" -C "${work}/seed" push -q "${work}/origin.git" master
	"${STUB_REAL_GIT}" clone -q "${work}/origin.git" "${work}/review"
	"${STUB_REAL_GIT}" -C "${work}/review" remote set-url origin https://github.com/wehagy/w
	start_sha=$("${STUB_REAL_GIT}" -C "${work}/review" rev-parse HEAD)
	: >"${STUB_LOG}"
}

# Run prepare-branches.sh in ${work}; sets prep_rc and prep.out / prep.err.
run_prepare() {
	prep_rc=0
	(
		cd "${work}"
		REVIEW_DIR=review REVIEW_REPOSITORY=wehagy/w PACKAGE=netbird PACKAGE_PATH=net/netbird \
			UPSTREAM_REPOSITORY=netbirdio/netbird TARGET_VERSION=0.82.0 \
			BASE_BRANCH="${base_branch}" UPDATE_BRANCH="${update_branch}" \
			COMMIT_NAME="Test Author" COMMIT_EMAIL=author@example.invalid \
			"${script_dir}/prepare-branches.sh"
	) >"${work}/prep.out" 2>"${work}/prep.err" || prep_rc=$?
}

# Succeed when the bare review repository has the branch.
#
# Arguments:
#   $1  branch
bare_has() {
	"${STUB_REAL_GIT}" -C "${work}/origin.git" rev-parse --verify -q "refs/heads/$1" >/dev/null
}

# Succeed when the bare review repository has no such branch.
#
# Arguments:
#   $1  branch
bare_lacks() {
	! "${STUB_REAL_GIT}" -C "${work}/origin.git" rev-parse --verify -q "refs/heads/$1" >/dev/null
}

# Print a git log field of a branch of the bare repository.
#
# Arguments:
#   $1  branch
#   $2  --format value
bare_log() {
	"${STUB_REAL_GIT}" -C "${work}/origin.git" log -1 --format="$2" "refs/heads/$1"
}

fresh_review
run_prepare
check "prepare: succeeds" "${work}/prep.err" same "${prep_rc}" 0
check "prepare: pushes the base branch" "missing" bare_has "${base_branch}"
check "prepare: pushes the update branch" "missing" bare_has "${update_branch}"
got=$(bare_log "${base_branch}" %H)
check "prepare: the base branch is the starting commit" "${got}" same "${got}" "${start_sha}"
got=$(bare_log "${update_branch}" %P)
check "prepare: the update commit sits on the base" "${got}" same "${got}" "${start_sha}"
got=$("${STUB_REAL_GIT}" -C "${work}/origin.git" diff --name-only "${base_branch}" "${update_branch}")
check "prepare: the update commit changes only the Makefile" "${got}" same "${got}" "net/netbird/Makefile"
got=$(bare_log "${update_branch}" %s)
check "prepare: the subject names the package and version" "${got}" same "${got}" "netbird: update to 0.82.0"
bare_log "${update_branch}" %B >"${work}/message"
check "prepare: the commit is signed off" "${work}/message" has "${work}/message" "Signed-off-by: Test Author <author@example.invalid>"
got=$(bare_log "${update_branch}" %H)
check "prepare: prints the sha of the update commit" "${work}/prep.out" has "${work}/prep.out" "sha=${got}"
check "prepare: downloads the current and the target archive" "${STUB_LOG}" has "${STUB_LOG}" "v0.82.0"

# A branch of another run is never overwritten, even at the same commit.
fresh_review
"${STUB_REAL_GIT}" -C "${work}/review" push -q origin "${start_sha}:refs/heads/${base_branch}"
run_prepare
check "prepare: refuses an existing base branch" "exit ${prep_rc}" same "${prep_rc}" 1
check "prepare: names the existing branch" "${work}/prep.err" has "${work}/prep.err" "already exists"
check "prepare: pushes no update branch after refusing" "pushed" bare_lacks "${update_branch}"

fresh_review
"${STUB_REAL_GIT}" -C "${work}/review" push -q origin "${start_sha}:refs/heads/${update_branch}"
run_prepare
check "prepare: refuses an existing update branch" "exit ${prep_rc}" same "${prep_rc}" 1
check "prepare: leaves no base branch after refusing" "pushed" bare_lacks "${base_branch}"

# The method must reproduce the recorded hash of the current version.
fresh_review
printf 'archive of something else\n' >"${work}/other"
other_hash=$(sha256sum "${work}/other" | cut -d' ' -f1)
sed -i "s|^PKG_HASH:=.*|PKG_HASH:=${other_hash}|" "${work}/review/net/netbird/Makefile"
"${STUB_REAL_GIT}" -C "${work}/review" -c user.name=t -c user.email=t@example.invalid commit -q -a -m "wrong hash"
"${STUB_REAL_GIT}" -C "${work}/review" push -q origin master
run_prepare
check "prepare: a hash method that does not match fails" "exit ${prep_rc}" same "${prep_rc}" 1
check "prepare: says the method check failed" "${work}/prep.err" has "${work}/prep.err" "hash method check failed"
check "prepare: pushes nothing when the method check fails" "pushed" bare_lacks "${base_branch}"

fresh_review
STUB_CURL_EXIT=22 run_prepare
check "prepare: a failed download fails" "exit ${prep_rc}" same "${prep_rc}" 1
check "prepare: pushes nothing when the download fails" "pushed" bare_lacks "${base_branch}"

# The origin must be the review repository.
fresh_review
"${STUB_REAL_GIT}" -C "${work}/review" remote set-url origin https://github.com/other/x
run_prepare
check "prepare: refuses an origin that is not the review repository" "exit ${prep_rc}" same "${prep_rc}" 1
check "prepare: says which check failed" "${work}/prep.err" has "${work}/prep.err" "origin of the checkout is not"

# The update push fails: the base branch is removed again.
fresh_review
cat >"${work}/origin.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
while read -r old new ref; do
	case "$ref" in
	*-update-*)
		echo "rejected" >&2
		exit 1
		;;
	esac
done
HOOK
chmod +x "${work}/origin.git/hooks/pre-receive"
run_prepare
check "prepare: a rejected update push fails" "exit ${prep_rc}" same "${prep_rc}" 1
check "prepare: removes the base branch again" "still there" bare_lacks "${base_branch}"
check "prepare: says the base was removed" "${work}/prep.err" has "${work}/prep.err" "was removed again"

# --- open-pr.sh -------------------------------------------------------------
# Run open-pr.sh; sets pr_rc and pr.out / pr.err.
#
# Arguments:
#   $1  REVIEW_REPOSITORY
run_open_pr() {
	pr_rc=0
	printf 'description\n' >"${work}/body.md"
	REVIEW_REPOSITORY=$1 BASE_BRANCH="${base_branch}" UPDATE_BRANCH="${update_branch}" \
		PR_TITLE="netbird: update to 0.82.0" PR_BODY_FILE="${work}/body.md" \
		"${script_dir}/open-pr.sh" >"${work}/pr.out" 2>"${work}/pr.err" || pr_rc=$?
}

gh_fixtures v0.82.0
printf '%s open\n' "${update_branch}" >"${STUB_GH_DIR}/prs"
run_open_pr wehagy/w
check "open-pr: an open pull request exists: exits 0" "exit ${pr_rc}" same "${pr_rc}" 0
check "open-pr: an open pull request exists: creates none" "${STUB_LOG}" lacks "${STUB_LOG}" "pr create"
check "open-pr: an open pull request exists: prints its URL" "${work}/pr.out" has "${work}/pr.out" "https://example.invalid/pull/1"

# A closed pull request does not count: only an open one stops a new one.
gh_fixtures v0.82.0
printf '%s closed\n' "${update_branch}" >"${STUB_GH_DIR}/prs"
run_open_pr wehagy/w
check "open-pr: only a closed pull request: opens a new one" "${STUB_LOG}" has "${STUB_LOG}" "pr create"

gh_fixtures v0.82.0
run_open_pr wehagy/w
check "open-pr: no pull request: exits 0" "exit ${pr_rc}" same "${pr_rc}" 0
check "open-pr: no pull request: creates a draft" "${STUB_LOG}" has "${STUB_LOG}" "--draft"
check "open-pr: no pull request: names the review repository" "${STUB_LOG}" has "${STUB_LOG}" "pr create --repo wehagy/w"
check "open-pr: no pull request: heads and bases" "${STUB_LOG}" has "${STUB_LOG}" "--base ${base_branch} --head ${update_branch}"
check "open-pr: no pull request: prints the URL" "${work}/pr.out" has "${work}/pr.out" "https://example.invalid/pull/9"

gh_fixtures v0.82.0
run_open_pr openwrt/packages
check "open-pr: refuses openwrt/packages" "exit ${pr_rc}" same "${pr_rc}" 1
check "open-pr: calls gh not at all for openwrt/packages" "${STUB_LOG}" empty "${STUB_LOG}"

# --- discard-branches.sh ----------------------------------------------------
# Run discard-branches.sh; sets dis_rc and dis.out / dis.err.
#
# Arguments:
#   $1  REVIEW_REPOSITORY
run_discard() {
	dis_rc=0
	REVIEW_REPOSITORY=$1 BASE_BRANCH="${base_branch}" UPDATE_BRANCH="${update_branch}" \
		"${script_dir}/discard-branches.sh" >"${work}/dis.out" 2>"${work}/dis.err" || dis_rc=$?
}

gh_fixtures v0.82.0
printf '%s\n%s\n%s\n' "${update_branch}" "${base_branch}" "unrelated" >"${STUB_GH_DIR}/branches"
run_discard wehagy/w
check "discard: both branches: exits 0" "${work}/dis.err" same "${dis_rc}" 0
got=$(cat "${STUB_GH_DIR}/branches")
check "discard: both branches are deleted" "${got}" same "${got}" "unrelated"
check "discard: says both are gone" "${work}/dis.out" has "${work}/dis.out" "are gone from wehagy/w"

gh_fixtures v0.82.0
run_discard wehagy/w
check "discard: no branch: exits 0" "${work}/dis.err" same "${dis_rc}" 0
check "discard: no branch: says so" "${work}/dis.out" has "${work}/dis.out" "does not exist"

gh_fixtures v0.82.0
printf '%s\n' "${update_branch}" >"${STUB_GH_DIR}/branches"
: >"${STUB_GH_DIR}/delete_fail"
run_discard wehagy/w
check "discard: a failing delete fails" "exit ${dis_rc}" same "${dis_rc}" 1
check "discard: a failing delete says so" "${work}/dis.err" has "${work}/dis.err" "cannot delete branch"

gh_fixtures v0.82.0
printf '%s\n' "${update_branch}" >"${STUB_GH_DIR}/branches"
: >"${STUB_GH_DIR}/delete_noop"
run_discard wehagy/w
check "discard: a branch that is still there fails" "exit ${dis_rc}" same "${dis_rc}" 1
check "discard: says the branch is still there" "${work}/dis.err" has "${work}/dis.err" "is still there"

gh_fixtures v0.82.0
run_discard openwrt/packages
check "discard: refuses openwrt/packages" "exit ${dis_rc}" same "${dis_rc}" 1
check "discard: calls gh not at all for openwrt/packages" "${STUB_LOG}" empty "${STUB_LOG}"

finish
