#!/usr/bin/env sh
# Responsibility: delete the overlay branch that compose.sh pushed to this
# repository, once the builds that read it are done. Shared by
# .github/workflows/upstream-pr.yml and custom-image.yml. Refuses a branch
# that is not under upstream-overlay/.
#
# Usage: scripts/upstream-pr/cleanup.sh
# Environment variables:
#   BRANCH             the branch to delete (the `branch` output of compose)
#   GITHUB_REPOSITORY  this repository; GH_TOKEN authenticates the deletion
#   GITHUB_STEP_SUMMARY file the result is appended to
set -eu

: "${BRANCH:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_STEP_SUMMARY:?}"
case "${BRANCH}" in
upstream-overlay/*) ;;
*)
	echo "::error::refusing to delete '${BRANCH}'"
	exit 1
	;;
esac
gh api -X DELETE "repos/${GITHUB_REPOSITORY}/git/refs/heads/${BRANCH}"
echo "deleted ${GITHUB_REPOSITORY} ${BRANCH}" | tee -a "${GITHUB_STEP_SUMMARY}"
