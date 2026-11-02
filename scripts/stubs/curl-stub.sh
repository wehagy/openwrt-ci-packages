#!/usr/bin/env sh
# Responsibility: stand-in for curl in the offline tests of the update scripts
# (copied as `curl` into a directory at the front of PATH). It never touches the
# network: it writes a fixed archive for the URL, or fails like curl does.
#
# Usage:
#   curl-stub.sh [curl options] --output <file> <url>
#
# Environment variables:
#   STUB_CURL_EXIT   exit status to fail with, with curl's message (default: 0)
#   STUB_CURL_EMPTY  "1": succeed but write an empty file
#   STUB_LOG         file that receives one line "curl <url>" per call

set -eu

output=
url=
while [ "$#" -gt 0 ]; do
	case "$1" in
	--output)
		output=$2
		shift
		;;
	-*) ;;
	*) url=$1 ;;
	esac
	shift
done
printf 'curl %s\n' "${url}" >>"${STUB_LOG:?}"
if [ "${STUB_CURL_EXIT:-0}" -ne 0 ]; then
	printf 'curl: (22) The requested URL returned error: 404\n' >&2
	exit "${STUB_CURL_EXIT}"
fi
[ -n "${output}" ] || {
	printf 'curl-stub: no --output\n' >&2
	exit 2
}
if [ "${STUB_CURL_EMPTY:-0}" = 1 ]; then
	: >"${output}"
else
	printf 'archive of %s\n' "${url}" >"${output}"
fi
