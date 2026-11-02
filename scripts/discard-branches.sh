#!/usr/bin/env sh
# Responsibility: delete the two branches of a bump from the review repository
# unless a pull request of the update branch is open (it is then left alone,
# exit 0), and check that both are gone. A
# branch that does not exist is fine (it was never pushed). Only the exact
# names given are touched, in REVIEW_REPOSITORY, after check_review_repository.
#
# Usage:
#   scripts/discard-branches.sh
#
# Environment variables:
#   REVIEW_REPOSITORY  <owner>/<name> of the review repository (never openwrt)
#   BASE_BRANCH, UPDATE_BRANCH  branches to delete
#   GH_TOKEN                    token with Contents: write on that repository

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

: "${REVIEW_REPOSITORY:?}" "${BASE_BRANCH:?}" "${UPDATE_BRANCH:?}"
check_review_repository "${REVIEW_REPOSITORY}"
check_branch "${BASE_BRANCH}"
check_branch "${UPDATE_BRANCH}"

# Deleting the head branch of an open pull request closes it: never do that.
open_prs=$(gh pr list --repo "${REVIEW_REPOSITORY}" --head "${UPDATE_BRANCH}" --state open \
	--json number --jq length) || die "cannot list the pull requests of ${REVIEW_REPOSITORY}"
if [ "${open_prs}" -gt 0 ]; then
	printf 'a pull request of %s is open: the branches stay\n' "${UPDATE_BRANCH}"
	exit 0
fi

for branch in "${UPDATE_BRANCH}" "${BASE_BRANCH}"; do
	rc=0
	out=$(gh api --method DELETE "repos/${REVIEW_REPOSITORY}/git/refs/heads/${branch}" 2>&1) || rc=$?
	if [ "${rc}" -eq 0 ]; then
		printf 'deleted branch %s\n' "${branch}"
		continue
	fi
	case "${out}" in
	*'Reference does not exist'* | *'HTTP 404'*) printf 'branch %s does not exist\n' "${branch}" ;;
	*) die "cannot delete branch ${branch}: ${out}" ;;
	esac
done
for branch in "${UPDATE_BRANCH}" "${BASE_BRANCH}"; do
	rc=0
	out=$(gh api "repos/${REVIEW_REPOSITORY}/branches/${branch}" --jq .name 2>&1) || rc=$?
	if [ "${rc}" -eq 0 ]; then
		die "branch ${branch} is still there"
	fi
	case "${out}" in
	*'HTTP 404'*) ;;
	*) die "cannot check branch ${branch}: ${out}" ;;
	esac
done
printf 'branches %s and %s are gone from %s\n' "${UPDATE_BRANCH}" "${BASE_BRANCH}" "${REVIEW_REPOSITORY}"
