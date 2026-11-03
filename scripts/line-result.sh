#!/usr/bin/env sh
# Responsibility: write the result of ONE line of ONE package as a small JSON
# file, the artifact line-result-<package>-<line> of .github/workflows/line.yml.
# The legs of a matrix share `needs.<job>.result` (one aggregate for all legs)
# and their job outputs overwrite each other, so the per-line outcome has to
# leave the leg as a file of its own: this is that file. publish (update.yml)
# and the reports read it back.
#
# Usage: scripts/line-result.sh <output file>
# Environment variables:
#   LINE, PACKAGE   the line and the package of the leg
#   BUILD, TEST, IMAGE  the `result` of the three jobs of the leg: success,
#                   failure, cancelled, skipped, or `not requested`
#                   (images that this run does not build)
#   FEED_SHA        the commit the build reports having built (may be empty)
# Output: the file, {line, package, build, test, image, feed_sha, passed};
# passed is true when build and test succeeded and the image succeeded or was
# not requested.
set -eu

here=$(dirname "$0")
# shellcheck source=scripts/lib/lines.sh
. "${here}/lib/lines.sh"

[ "$#" -eq 1 ] || {
	echo "usage: line-result.sh <output file>" >&2
	exit 1
}
: "${LINE:?}" "${PACKAGE:?}" "${BUILD:?}" "${TEST:?}" "${IMAGE:?}"
check_line_name "${LINE}"
case "${PACKAGE}" in
'' | [!a-z0-9]* | *[!a-z0-9._+-]*)
	echo "error: invalid package name" >&2
	exit 1
	;;
*) ;;
esac
for result in "${BUILD}" "${TEST}" "${IMAGE}"; do
	case "${result}" in
	success | failure | cancelled | skipped | "not requested") ;;
	*)
		echo "error: unexpected job result" >&2
		exit 1
		;;
	esac
done
case "${FEED_SHA:-}" in
*[!0-9a-f]*)
	echo "error: the reported commit is not a SHA" >&2
	exit 1
	;;
*) ;;
esac
mkdir -p "$(dirname "$1")"
jq -n --arg line "${LINE}" --arg package "${PACKAGE}" --arg build "${BUILD}" --arg test "${TEST}" \
	--arg image "${IMAGE}" --arg feed_sha "${FEED_SHA:-}" '{
	line: $line, package: $package, build: $build, test: $test, image: $image,
	feed_sha: $feed_sha,
	passed: ($build == "success" and $test == "success" and ($image == "success" or $image == "not requested"))
}' >"$1"
printf 'line %s: build=%s test=%s image=%s feed_sha=%s\n' "${LINE}" "${BUILD}" "${TEST}" "${IMAGE}" "${FEED_SHA:-}"
