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
#   - a result file is believed only when the job `result` of its leg is in the
#     job list of the run with conclusion success (an artifact that was there
#     before, or that another job uploaded, has no such job) and its content
#     is well formed (the three job results are known words, feed_sha is a
#     full SHA or empty, line and package are the ones asked for); otherwise
#     the line has "no result". `passed` is never read from the file: it is
#     computed here from build, test and image;
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
#   JOBS_FILE    the jobs of the run, one JSON object per line ({name, conclusion})
#   MATRIX       {"include": [{"line", "feed_ref"}]}: what each line was asked to build
#   REPORT_PASSED  the verdict of report.py on the reference line (true/false)
# Output: open=true|false on stdout; the per-line summary on stderr.
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/lib/lines.sh
. "${script_dir}/lib/lines.sh"

: "${PACKAGE:?}" "${LINES:?}" "${REFERENCE:?}" "${RESULTS_DIR:?}" "${MATRIX:?}" "${JOBS_FILE:?}"
[ -f "${JOBS_FILE}" ] || {
	echo "::error::the job list ${JOBS_FILE} is missing: no result file can be believed" >&2
	exit 1
}

# Print true when the job `result` of the leg of a line is in the job list and
# every job of that name succeeded, false otherwise. The name is
# "<matrix job> (<line>[, <feed values>]) / result".
#
# Arguments:
#   $1  line (it passed check_line_name)
result_job_ok() {
	jq -s -r --arg line "$1" '
		[.[] | select((.name // "") | test("\\A[^ ]+ \\(" + ($line | gsub("[.]"; "[.]")) + "(, [^)]*)?\\) / result\\z"))]
		| (length > 0) and all(.conclusion == "success")' "${JOBS_FILE}"
}

tab=$(printf '\t')
reference_passed=false
for line in ${LINES}; do
	check_line_name "${line}"
	file="${RESULTS_DIR}/line-result-${PACKAGE}-${line}/result.json"
	build="no result"
	test_result="no result"
	image="no result"
	fed=''
	if [ -f "${file}" ]; then
		job_ok=$(result_job_ok "${line}")
		if [ "${job_ok}" != true ]; then
			echo "::warning::line ${line}: its result file is not believed: the job result of its leg did not succeed" >&2
		# Well formed: "<build> <test> <image> <feed_sha>" separated by tabs, else nothing.
		elif values=$(jq -r --arg line "${line}" --arg package "${PACKAGE}" '
	def known: . as $v | ["success", "failure", "cancelled", "skipped", "not requested"] | index($v) != null;
	if type == "object" and .line == $line and .package == $package
		and (.build | known) and (.test | known) and (.image | known)
		and ((.feed_sha // "") | type == "string" and test("\\A([0-9a-f]{40})?\\z"))
	then [.build, .test, .image, (.feed_sha // "")] | @tsv else empty end' "${file}") && [ -n "${values}" ]; then
			IFS=${tab} read -r build test_result image fed <<EOF
${values}
EOF
		else
			echo "::warning::line ${line}: its result file is not believed: it is malformed" >&2
		fi
	fi
	if [ "${build}" = success ] && [ "${test_result}" = success ] && { [ "${image}" = success ] || [ "${image}" = "not requested" ]; }; then
		passed=true
	else
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
