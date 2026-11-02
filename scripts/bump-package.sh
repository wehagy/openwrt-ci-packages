#!/usr/bin/env sh
# Responsibility: set PKG_VERSION and PKG_HASH of a package Makefile for a new
# version and reset PKG_RELEASE to 1; nothing else changes. The edit is checked
# by reading the three variables back and by comparing the line count of the
# file, so a Makefile this script does not understand fails instead of being
# half edited.
#
# Usage:
#   scripts/bump-package.sh <Makefile> <version> <sha256>
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 3 ] || die "usage: bump-package.sh <Makefile> <version> <sha256>"
makefile=$1
version=$2
hash=$3
check_version "${version}"
case "${hash}" in
*[!0-9a-f]* | '') die "invalid sha256" ;;
*) ;;
esac
[ "${#hash}" -eq 64 ] || die "invalid sha256 (expected 64 hex digits)"

# Each variable must appear exactly once at the start of a line.
for var in PKG_VERSION PKG_RELEASE PKG_HASH; do
	count=$(grep -c "^${var}:=" "${makefile}") || count=0
	[ "${count}" -eq 1 ] || die "${var} is assigned ${count} times in ${makefile}, expected 1"
done

# Abort unless a variable of the Makefile has the expected value.
#
# Arguments:
#   $1  variable name
#   $2  expected value
expect_var() {
	ev_value=$(makefile_var "${makefile}" "$1")
	[ "${ev_value}" = "$2" ] || die "$1 was not set to the expected value"
}

lines_before=$(wc -l <"${makefile}")
tmp="${makefile}.bump"
sed -e "s/^PKG_VERSION:=.*/PKG_VERSION:=${version}/" \
	-e 's/^PKG_RELEASE:=.*/PKG_RELEASE:=1/' \
	-e "s/^PKG_HASH:=.*/PKG_HASH:=${hash}/" "${makefile}" >"${tmp}"
mv "${tmp}" "${makefile}"

lines_after=$(wc -l <"${makefile}")
[ "${lines_before}" -eq "${lines_after}" ] || die "line count of ${makefile} changed"
expect_var PKG_VERSION "${version}"
expect_var PKG_RELEASE 1
expect_var PKG_HASH "${hash}"
