#!/usr/bin/env sh
# Responsibility: decide how the pull request of custom-image.yml reaches the
# build, from what scripts/upstream-pr/resolve.sh found. The line of the form
# is independent of the pull request:
#   - the base branch of the PR belongs to the chosen line (the line whose
#     packages_branch is that branch): build the head of the PR from
#     openwrt/packages as it is;
#   - otherwise: overlay the changed package
#     directories of the PR on the branch of the chosen line, with
#     scripts/upstream-pr/compose.sh (the job `compose` runs it and needs
#     base_branch, overlay_dirs, head_sha and pr_number from here).
# The package of the form must be one the PR changes (otherwise the build
# would not contain the PR at all).
#
# Output (safe for $GITHUB_OUTPUT): overlay (true or false), feed_repository
# and feed_ref (set only when no overlay is needed), base_branch (the branch of
# the chosen line, used by the overlay), head_sha, pr_number, pr_line, and
# overlay_dirs.
#
# Usage:
#   scripts/images/pr-source.sh >> "$GITHUB_OUTPUT"
#
# Environment variables (from the form and from resolve.sh):
#   LINE           the line of the form
#   PACKAGE        the package of the form
#   PR_NUMBER, PR_LINE (the `line` output of resolve.sh), HEAD_SHA,
#   MATRIX_ALL (the testable changed packages as JSON), OVERLAY_DIRS
#   BASE_LINES_FILE  harness/lines.yml of the base (default ci-base/harness/lines.yml)

set -eu

here=$(dirname "$0")
# shellcheck source=scripts/upstream-pr/lib.sh
. "${here}/../upstream-pr/lib.sh"
# shellcheck source=scripts/lib/lines.sh
. "${here}/../lib/lines.sh"

: "${LINE:?}" "${PACKAGE:?}" "${PR_NUMBER:?}" "${PR_LINE:?}" "${HEAD_SHA:?}" "${MATRIX_ALL:?}" "${OVERLAY_DIRS:?}"

check_pr_number "${PR_NUMBER}"
case "${HEAD_SHA}" in
*[!0-9a-f]* | '')
	fail "invalid head sha"
	exit 1
	;;
*) ;;
esac
lines_check_file
base_branch=$(branch_for_line "${LINE}")

# The package must be one of the changed, testable packages of the PR.
names=$(printf '%s' "${MATRIX_ALL}" | jq -r '.include[].package') || {
	fail "cannot read the changed packages"
	exit 1
}
if ! printf '%s\n' "${names}" | grep -qxF -- "${PACKAGE}"; then
	list=$(printf '%s' "${names}" | tr '\n' ' ')
	clean "${list}"
	clean "${PACKAGE}"
	pkg_clean=${cleaned}
	fail "pull request ${PR_NUMBER} does not change the package ${pkg_clean}; the packages it changes: ${list}"
	exit 1
fi

if [ "${PR_LINE}" = "${LINE}" ]; then
	overlay=false
	feed_repository=openwrt/packages
	feed_ref=${HEAD_SHA}
else
	overlay=true
	feed_repository=
	feed_ref=
fi

printf 'overlay=%s\n' "${overlay}"
printf 'feed_repository=%s\n' "${feed_repository}"
printf 'feed_ref=%s\n' "${feed_ref}"
printf 'base_branch=%s\n' "${base_branch}"
printf 'head_sha=%s\n' "${HEAD_SHA}"
printf 'pr_number=%s\n' "${PR_NUMBER}"
printf 'pr_line=%s\n' "${PR_LINE}"
printf 'overlay_dirs=%s\n' "${OVERLAY_DIRS}"
