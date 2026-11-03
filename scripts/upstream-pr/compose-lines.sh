#!/usr/bin/env sh
# Responsibility: build the overlay tree of every line in a list: for each
# line, compose.sh puts the changed package directories on the packages_branch
# of that line (scripts/lib/lines.sh) and pushes the result as the branch
# <TARGET_PREFIX>-<line> of THIS repository. One job, one JSON per output: the
# outputs of the legs of a matrix overwrite each other, so a matrix of compose
# jobs could not say which commit belongs to which line.
#
# Outputs (GITHUB_OUTPUT):
#   overlays  {"<line>": {"branch", "sha", "base_sha", "base_branch"}} of the
#             lines that were composed ({} when none)
#   matrix    {"include": [{"line", "feed_repository", "feed_ref"}]} when
#             REFERENCE_LINE is set: the reference line first, built from
#             REFERENCE_FEED_REPOSITORY @ REFERENCE_FEED_REF, then every composed
#             line, built from this repository @ its overlay commit
#   failed    the lines whose overlay could not be composed, separated by spaces
#
# A line that fails is reported with ::error:: and left out of the outputs;
# the script exits 1 at the end unless TOLERATE_FAILURE=true (update.yml: the
# other lines never stop the reference line).
#
# Usage: scripts/upstream-pr/compose-lines.sh
# Environment variables:
#   OTHER_LINES        lines to compose, separated by spaces (may be empty)
#   TARGET_PREFIX      branch prefix, upstream-overlay/... (the line is appended)
#   HEAD_SHA, OVERLAY_DIRS, PR_NUMBER, SOURCE_URL, SOURCE_REF, SOURCE_LABEL
#                      as for compose.sh
#   REFERENCE_LINE, REFERENCE_FEED_REPOSITORY, REFERENCE_FEED_REF  optional
#   TOLERATE_FAILURE   true: exit 0 even when a line failed
#   COMPOSE            the compose script (default: compose.sh next to this one)
#   GITHUB_REPOSITORY, GH_TOKEN, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, BASE_LINES_FILE
set -eu

here=$(dirname "$0")
# shellcheck source=scripts/lib/lines.sh
. "${here}/../lib/lines.sh"

: "${TARGET_PREFIX:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_OUTPUT:?}" "${GITHUB_STEP_SUMMARY:?}"
compose=${COMPOSE:-${here}/compose.sh}
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

lines_check_file
overlays='{}'
matrix='[]'
failed=
if [ -n "${REFERENCE_LINE:-}" ]; then
	check_line_name "${REFERENCE_LINE}"
	matrix=$(jq -cn --arg line "${REFERENCE_LINE}" --arg repo "${REFERENCE_FEED_REPOSITORY:?}" --arg ref "${REFERENCE_FEED_REF:?}" \
		'[{line: $line, feed_repository: $repo, feed_ref: $ref}]')
fi
for line in ${OTHER_LINES:-}; do
	check_line_name "${line}"
	branch=$(branch_for_line "${line}")
	: >"${work}/out"
	if env OTHER_BRANCH="${branch}" TARGET_BRANCH="${TARGET_PREFIX}-${line}" GITHUB_OUTPUT="${work}/out" "${compose}"; then
		sha=$(sed -n -e 's/^sha=//p' "${work}/out")
		base_sha=$(sed -n -e 's/^base_sha=//p' "${work}/out")
		overlays=$(printf '%s' "${overlays}" | jq -c --arg line "${line}" --arg branch "${TARGET_PREFIX}-${line}" \
			--arg sha "${sha}" --arg base_sha "${base_sha}" --arg base_branch "${branch}" \
			'. + {($line): {branch: $branch, sha: $sha, base_sha: $base_sha, base_branch: $base_branch}}')
		matrix=$(printf '%s' "${matrix}" | jq -c --arg line "${line}" --arg repo "${GITHUB_REPOSITORY}" --arg ref "${sha}" \
			'. + [{line: $line, feed_repository: $repo, feed_ref: $ref}]')
	else
		echo "::error::the overlay of line ${line} could not be composed"
		failed="${failed:+${failed} }${line}"
	fi
done
matrix=$(printf '%s' "${matrix}" | jq -c '{include: .}')
{
	echo "overlays=${overlays}"
	echo "matrix=${matrix}"
	echo "failed=${failed}"
} >>"${GITHUB_OUTPUT}"
if [ -n "${failed}" ] && [ "${TOLERATE_FAILURE:-false}" != true ]; then
	exit 1
fi
