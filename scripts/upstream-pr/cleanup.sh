#!/usr/bin/env sh
# Responsibility: delete the overlay branch that compose.sh pushed to THIS
# repository, once the builds that read it are done. Shared by
# .github/workflows/upstream-pr.yml, custom-image.yml and update.yml. Only a
# branch under upstream-overlay/ is ever deleted. A branch that does not exist
# is not an error (the compose job may have failed before its push, and the
# cleanup job runs on every path); a delete that fails while the branch is
# still there is.
#
# Usage: scripts/upstream-pr/cleanup.sh
# Environment variables:
#   BRANCH             the branch to delete (the `branch` output of compose)
#   GITHUB_REPOSITORY  this repository; GH_TOKEN authenticates the deletion
#   REMOTE_URL         where to look for the branch after a failed delete
#                      (default https://github.com/$GITHUB_REPOSITORY.git)
#   GITHUB_STEP_SUMMARY  optional: also receives the result line
set -eu

here=$(dirname "$0")
# shellcheck source=scripts/upstream-pr/lib.sh
. "${here}/lib.sh"

: "${BRANCH:?}" "${GITHUB_REPOSITORY:?}"

# Report a refusal or a failure as a workflow command on stdout and stop.
#
# Arguments:
#   $@  the message (values taken from the caller go through clean() first)
die() {
	printf '::error::%s\n' "$*"
	exit 1
}

case "${BRANCH}" in
upstream-overlay/?*) ;;
*)
	clean "${BRANCH}"
	die "refusing to delete '${cleaned}'"
	;;
esac
case "${BRANCH}" in
*[!A-Za-z0-9._/+-]* | *..*)
	clean "${BRANCH}"
	die "refusing to delete '${cleaned}'"
	;;
*) ;;
esac

# The result line, to stdout and to the job summary when there is one.
#
# Arguments:
#   $1  the text
say() {
	printf '%s\n' "$1"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		printf '%s\n' "$1" >>"${GITHUB_STEP_SUMMARY}"
	fi
}

if gh api -X DELETE "repos/${GITHUB_REPOSITORY}/git/refs/heads/${BRANCH}"; then
	say "deleted ${GITHUB_REPOSITORY} ${BRANCH}"
	exit 0
fi
# The delete failed: that is fine only when the branch is not there.
url=${REMOTE_URL:-https://github.com/${GITHUB_REPOSITORY}.git}
present=$(git ls-remote --heads "${url}" "refs/heads/${BRANCH}") ||
	die "could not delete ${GITHUB_REPOSITORY} ${BRANCH} nor list the remote"
[ -z "${present}" ] || die "could not delete ${GITHUB_REPOSITORY} ${BRANCH}"
say "${GITHUB_REPOSITORY} ${BRANCH} does not exist: nothing to delete"
