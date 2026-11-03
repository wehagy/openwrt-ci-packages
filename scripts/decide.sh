#!/usr/bin/env sh
# Responsibility: the decision of the publish job of update.yml: open the draft
# pull request or not. Per-line outcomes come from the artifacts
# line-result-<package>-<line> (scripts/line-result.sh), never from
# `needs.<job>.result`, which is one aggregate for all the legs of a matrix.
#
# Rules:
#   - the pull request opens only when the reference line passed (build, QEMU
#     test and images, as its own result file says) AND the description built
#     from the job list of the run agrees (REPORT_PASSED=true): two views;
#   - every other line may fail, or have no result at all: it is reported in
#     the description and does not stop the pull request;
#   - for every line whose build succeeded, the commit the base reports having
#     built must be the one this run made for it (MATRIX feed_ref: the bump
#     commit on the reference line, the overlay commit on the others); a
#     difference is an error (exit 1) whatever the line.
#
# Usage: scripts/decide.sh >> "$GITHUB_OUTPUT"
# Environment variables:
#   PACKAGE      the package
#   LINES        the lines of the package, separated by spaces
#   REFERENCE    the reference line
#   RESULTS_DIR  where the artifacts were downloaded (line-result-*/result.json)
#   MATRIX       {"include": [{"line", "feed_ref"}]}: what each line was asked to build
#   REPORT_PASSED  the verdict of report.py on the reference line (true/false)
# Output: open=true|false on stdout; the per-line summary on stderr.
set -eu

: "${PACKAGE:?}" "${LINES:?}" "${REFERENCE:?}" "${RESULTS_DIR:?}" "${MATRIX:?}"
reference_passed=false
for line in ${LINES}; do
	file="${RESULTS_DIR}/line-result-${PACKAGE}-${line}/result.json"
	if [ -f "${file}" ]; then
		build=$(jq -r '.build' "${file}")
		test_result=$(jq -r '.test' "${file}")
		image=$(jq -r '.image' "${file}")
		fed=$(jq -r '.feed_sha' "${file}")
		passed=$(jq -r '.passed' "${file}")
	else
		build="no result"
		test_result="no result"
		image="no result"
		fed=''
		passed=false
	fi
	want=$(printf '%s' "${MATRIX}" | jq -r --arg line "${line}" '[.include[] | select(.line == $line) | .feed_ref] | first // ""')
	if [ "${build}" = success ] && [ "${fed}" != "${want}" ]; then
		echo "::error::line ${line} built ${fed}, not the commit this run made for it (${want})" >&2
		exit 1
	fi
	echo "line ${line}: build=${build} test=${test_result} image=${image} passed=${passed}" >&2
	if [ "${line}" = "${REFERENCE}" ]; then reference_passed=${passed}; fi
done
if [ "${reference_passed}" = true ] && [ "${REPORT_PASSED:-}" = true ]; then
	open=true
else
	open=false
fi
echo "reference line ${REFERENCE}: result=${reference_passed} report=${REPORT_PASSED:-} -> open pull request: ${open}" >&2
echo "open=${open}"
