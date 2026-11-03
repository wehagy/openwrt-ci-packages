#!/usr/bin/env sh
# Responsibility: the production guard of the upstream link. When the review
# repository is a fork of openwrt/packages, the pull request the owner opens by
# hand is the update branch against openwrt/packages master, so the branch the
# bump starts from must not carry commits that master does not have: they
# would travel into the upstream pull request. The script compares that branch
# with openwrt/packages master (read only) BEFORE anything is pushed, fails on
# extra commits and otherwise prints, for the description, the relation and the
# base commit. A fork that is only behind master is accepted (the pull request
# still holds the bump alone) and the description says by how much. A review
# repository that is not a fork (the test copy) has no working upstream link;
# that is reported as it is, with no call.
#
# Usage:
#   scripts/check-fork-base.sh >> "$GITHUB_OUTPUT"
#
# Environment variables:
#   REVIEW_REPOSITORY  <owner>/<name> of the review repository
#   REVIEW_BRANCH      branch of it the bump starts from
#   REVIEW_IS_FORK     true or false (repos/<review repository> .fork)
#   GH_TOKEN           token for gh (reads public repositories only)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

: "${REVIEW_REPOSITORY:?}" "${REVIEW_BRANCH:?}" "${REVIEW_IS_FORK:?}"
check_review_repository "${REVIEW_REPOSITORY}"
check_branch "${REVIEW_BRANCH}"

upstream=openwrt/packages
upstream_branch=master

case "${REVIEW_IS_FORK}" in
false)
	printf 'upstream_base=%s\n' "not a fork: upstream link not functional"
	exit 0
	;;
true) ;;
*) die "REVIEW_IS_FORK must be true or false" ;;
esac

owner=${REVIEW_REPOSITORY%%/*}
# status, commits of the review branch that master lacks, commits of master
# that it lacks, head of master, and the last commit they share (the base of
# the update branch when the fork is behind).
compare=$(gh api "repos/${upstream}/compare/${upstream_branch}...${owner}:${REVIEW_BRANCH}" \
	--jq '[.status, .ahead_by, .behind_by, .base_commit.sha, .merge_base_commit.sha] | @tsv') ||
	die "cannot compare ${REVIEW_REPOSITORY}:${REVIEW_BRANCH} with ${upstream}:${upstream_branch}"
tab=$(printf '\t')
IFS=${tab} read -r status ahead behind master_sha base_sha <<EOT
${compare}
EOT
case "${ahead}:${behind}" in
*[!0-9:]* | : | :* | *:) die "the comparison with ${upstream} returned no commit counts" ;;
*) ;;
esac
for sha in "${master_sha}" "${base_sha}"; do
	case "${sha}" in
	*[!0-9a-f]*) die "the comparison with ${upstream} returned no commit" ;;
	*) [ "${#sha}" -eq 40 ] || die "the comparison with ${upstream} returned no commit" ;;
	esac
done

if [ "${ahead}" -ne 0 ]; then
	printf '::error::%s:%s has %s commit(s) that %s %s does not have (%s): the upstream pull request would carry them. Reset the branch to %s, then run again\n' \
		"${REVIEW_REPOSITORY}" "${REVIEW_BRANCH}" "${ahead}" "${upstream}" "${upstream_branch}" "${status}" "${upstream}" >&2
	die "${REVIEW_REPOSITORY}:${REVIEW_BRANCH} is not based on ${upstream} ${upstream_branch}"
fi
if [ "${behind}" -eq 0 ]; then
	note="identical to ${upstream} ${upstream_branch} @ \`${master_sha}\`"
else
	note="base commit \`${base_sha}\`, ${behind} commit(s) behind ${upstream} ${upstream_branch} (\`${master_sha}\`); the upstream pull request holds only the bump"
fi
printf 'check: %s\n' "${note}" >&2
printf 'upstream_base=%s\n' "${note}"
