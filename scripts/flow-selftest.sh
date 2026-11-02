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
# shellcheck source=lib/selftest.sh
. "${script_dir}/lib/selftest.sh"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

# --- stubs ------------------------------------------------------------------
mkdir "${work}/bin"
cp "${script_dir}/stubs/curl-stub.sh" "${work}/bin/curl"
PATH="${work}/bin:${PATH}"
STUB_LOG="${work}/stub.log"
export PATH STUB_LOG
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
write_makefile 0.81.4 "$(printf 'x' | sha256sum | cut -d' ' -f1)" "${work}/Makefile"
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

finish
