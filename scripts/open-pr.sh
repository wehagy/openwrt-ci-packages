#!/usr/bin/env sh
# Responsibility: open the DRAFT pull request from the update branch to the base
# branch inside the review repository, unless an open pull request for the
# update branch already exists there. The repository is always passed to gh with
# --repo, after check_review_repository, so no other repository can be written.
# Prints the URL of the pull request (new or existing) on the last line.
#
# Usage:
#   scripts/open-pr.sh
#
# Environment variables:
#   REVIEW_REPOSITORY  <owner>/<name> of the review repository (never openwrt)
#   BASE_BRANCH, UPDATE_BRANCH  head and base of the pull request
#   PR_TITLE, PR_BODY_FILE      title and description
#   GH_TOKEN                    token with Pull requests: write on that repository

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

: "${REVIEW_REPOSITORY:?}" "${BASE_BRANCH:?}" "${UPDATE_BRANCH:?}" "${PR_TITLE:?}" "${PR_BODY_FILE:?}"
check_review_repository "${REVIEW_REPOSITORY}"
check_branch "${BASE_BRANCH}"
check_branch "${UPDATE_BRANCH}"
[ -s "${PR_BODY_FILE}" ] || die "the pull request description is empty"

existing=$(gh pr list --repo "${REVIEW_REPOSITORY}" --head "${UPDATE_BRANCH}" --state open \
	--json url --jq '.[0].url // empty')
if [ -n "${existing}" ]; then
	printf 'a pull request for %s is already open; not opening another\n' "${UPDATE_BRANCH}" >&2
	printf '%s\n' "${existing}"
	exit 0
fi
gh pr create --repo "${REVIEW_REPOSITORY}" --draft \
	--base "${BASE_BRANCH}" --head "${UPDATE_BRANCH}" \
	--title "${PR_TITLE}" --body-file "${PR_BODY_FILE}"
