#!/usr/bin/env sh
# Responsibility: print the sha256 of the source archive a package Makefile
# downloads for a given version, which is the value of PKG_HASH. It expands
# PKG_SOURCE_URL (and PKG_SOURCE when the URL ends with "?", as OpenWrt does)
# for that version, downloads the archive and hashes it. This replaces
# `make package/<name>/check FIXUP=1` of the SDK without needing an SDK; the
# build then verifies the hash again when the SDK downloads the same archive.
#
# Usage:
#   scripts/source-sha256.sh <Makefile> <version>
#   scripts/source-sha256.sh --url <Makefile> <version>   print the URL only
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

url_only=false
if [ "${1:-}" = --url ]; then
	url_only=true
	shift
fi
[ "$#" -eq 2 ] || die "usage: source-sha256.sh [--url] <Makefile> <version>"
makefile=$1
version=$2
check_version "${version}"

name=$(makefile_var "${makefile}" PKG_NAME)
url=$(makefile_var "${makefile}" PKG_SOURCE_URL)
source_file=$(makefile_var "${makefile}" PKG_SOURCE)

# Only the variables of the three assignments above are expanded; anything
# else left in the result is a Makefile this script does not understand.
expand() {
	ex_value=$1
	ex_out=
	while :; do
		case "${ex_value}" in
		*"\$(PKG_NAME)"*)
			ex_out=${ex_out}${ex_value%%"\$(PKG_NAME)"*}${name}
			ex_value=${ex_value#*"\$(PKG_NAME)"}
			;;
		*"\$(PKG_VERSION)"*)
			ex_out=${ex_out}${ex_value%%"\$(PKG_VERSION)"*}${version}
			ex_value=${ex_value#*"\$(PKG_VERSION)"}
			;;
		*)
			printf '%s\n' "${ex_out}${ex_value}"
			return 0
			;;
		esac
	done
}

url=$(expand "${url}")
source_file=$(expand "${source_file}")
case "${url}${source_file}" in
*"\$("* | *" "*) die "PKG_SOURCE_URL or PKG_SOURCE uses a variable this script cannot expand" ;;
*) ;;
esac
case "${url}" in
https://*'?') url=${url}${source_file} ;;
https://*) ;;
*) die "PKG_SOURCE_URL is not an https URL" ;;
esac

if [ "${url_only}" = true ]; then
	printf '%s\n' "${url}"
	exit 0
fi
hash=$(curl --fail --silent --show-error --location --retry 3 --retry-all-errors "${url}" | sha256sum) ||
	die "download of the source archive failed"
printf '%s\n' "${hash%% *}"
