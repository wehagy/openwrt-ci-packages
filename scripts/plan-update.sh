#!/usr/bin/env sh
# Responsibility: decide whether a new upstream release has to become a pull
# request. It compares the version of the package Makefile on the review
# repository (the starting point of the bump) with the target version (the
# latest GitHub release of the upstream project, or FORCE_VERSION) and refuses
# to repeat work: no run when the review repository is not older than the
# target, or when the update branch exists or has ever had a pull request there
# (open, closed or merged: a closed one is a rejection and is not reopened).
# Read only. Prints KEY=value lines (safe for $GITHUB_OUTPUT) and logs to stderr.
#
# Usage:
#   scripts/plan-update.sh >> "$GITHUB_OUTPUT"
#
# Environment variables:
#   UPSTREAM_REPOSITORY  GitHub project whose latest release is the target
#   REVIEW_REPOSITORY    repository holding the starting point (read only here)
#   REVIEW_BRANCH        branch of REVIEW_REPOSITORY the bump starts from
#   PACKAGE, PACKAGE_PATH  package name and its directory in the review repository
#   FORCE_VERSION        optional; use this version instead of the latest release
#   GH_TOKEN             token for gh (reads public repositories only)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

: "${UPSTREAM_REPOSITORY:?}" "${REVIEW_REPOSITORY:?}" "${REVIEW_BRANCH:?}"
: "${PACKAGE:?}" "${PACKAGE_PATH:?}"
check_upstream_repository "${UPSTREAM_REPOSITORY}"
check_review_repository "${REVIEW_REPOSITORY}"
check_branch "${REVIEW_BRANCH}"
check_package "${PACKAGE}"
check_package_path "${PACKAGE_PATH}"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

gh api -H 'Accept: application/vnd.github.raw' \
	"repos/${REVIEW_REPOSITORY}/contents/${PACKAGE_PATH}/Makefile?ref=${REVIEW_BRANCH}" >"${work}/Makefile" ||
	die "cannot read ${PACKAGE_PATH}/Makefile of ${REVIEW_REPOSITORY} at ${REVIEW_BRANCH}"
current=$(makefile_var "${work}/Makefile" PKG_VERSION)
check_version "${current}"
base_sha=$(gh api "repos/${REVIEW_REPOSITORY}/commits/${REVIEW_BRANCH}" --jq .sha) ||
	die "cannot read the head of ${REVIEW_BRANCH} in ${REVIEW_REPOSITORY}"

if [ -n "${FORCE_VERSION:-}" ]; then
	target=${FORCE_VERSION#v}
	origin="forced by the version input"
else
	tag=$(gh api "repos/${UPSTREAM_REPOSITORY}/releases/latest" --jq .tag_name) ||
		die "cannot read the latest release of ${UPSTREAM_REPOSITORY}"
	target=${tag#v}
	origin="latest release of ${UPSTREAM_REPOSITORY}"
fi
check_version "${target}"

update_branch="ci/${PACKAGE}-update-${target}"
base_branch="ci/${PACKAGE}-base-${target}"
check_branch "${update_branch}"
check_branch "${base_branch}"

needed=false
order=$(version_cmp "${target}" "${current}")
if [ "${order}" != gt ]; then
	reason="the review repository has ${current}, not older than ${target}"
else
	branch_rc=0
	branch_out=$(gh api "repos/${REVIEW_REPOSITORY}/branches/${update_branch}" --jq .name 2>&1) || branch_rc=$?
	if [ "${branch_rc}" -eq 0 ]; then
		reason="branch ${update_branch} already exists in ${REVIEW_REPOSITORY}"
	else
		case "${branch_out}" in
		*'HTTP 404'*) ;;
		*) die "cannot look for branch ${update_branch}: ${branch_out}" ;;
		esac
		prs=$(gh pr list --repo "${REVIEW_REPOSITORY}" --head "${update_branch}" --state all \
			--json number --jq length) || die "cannot list the pull requests of ${REVIEW_REPOSITORY}"
		if [ "${prs}" -gt 0 ]; then
			reason="${prs} pull request(s) of ${update_branch} already exist in ${REVIEW_REPOSITORY}"
		else
			needed=true
			reason="${PACKAGE} ${current} -> ${target} (${origin})"
		fi
	fi
fi

printf 'plan: needed=%s: %s\n' "${needed}" "${reason}" >&2
printf 'needed=%s\n' "${needed}"
printf 'reason=%s\n' "${reason}"
printf 'current=%s\n' "${current}"
printf 'target=%s\n' "${target}"
printf 'base_sha=%s\n' "${base_sha}"
printf 'update_branch=%s\n' "${update_branch}"
printf 'base_branch=%s\n' "${base_branch}"
