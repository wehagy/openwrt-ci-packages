#!/usr/bin/env sh
# Responsibility: in a checkout of the review repository, create the commit
# "<package>: update to <version>" (Signed-off-by) on top of the starting point
# and push two branches there: the base branch at the starting commit and the
# update branch with the commit, so a pull request between them shows only the
# bump. It first proves the hash method on the current version (the archive of
# PKG_VERSION must hash to the PKG_HASH already in the Makefile). It pushes to
# `origin` of REVIEW_DIR only, after checking that origin is REVIEW_REPOSITORY,
# never forces, and removes the base branch again if the update push fails.
# Prints KEY=value lines (safe for $GITHUB_OUTPUT); the log goes to stderr.
#
# Usage:
#   scripts/prepare-branches.sh >> "$GITHUB_OUTPUT"
#
# Environment variables:
#   REVIEW_DIR           checkout of the review repository, at the starting point
#   REVIEW_REPOSITORY    <owner>/<name> of that repository (never openwrt)
#   PACKAGE, PACKAGE_PATH  package name and its directory in the checkout
#   UPSTREAM_REPOSITORY  GitHub project of the release (for the release notes URL)
#   TARGET_VERSION       version to bump to
#   BASE_BRANCH, UPDATE_BRANCH  branches to create
#   COMMIT_NAME, COMMIT_EMAIL   author, committer and Signed-off-by

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

: "${REVIEW_DIR:?}" "${REVIEW_REPOSITORY:?}" "${PACKAGE:?}" "${PACKAGE_PATH:?}"
: "${UPSTREAM_REPOSITORY:?}" "${TARGET_VERSION:?}" "${BASE_BRANCH:?}" "${UPDATE_BRANCH:?}"
: "${COMMIT_NAME:?}" "${COMMIT_EMAIL:?}"
check_review_repository "${REVIEW_REPOSITORY}"
check_upstream_repository "${UPSTREAM_REPOSITORY}"
check_package "${PACKAGE}"
check_package_path "${PACKAGE_PATH}"
check_version "${TARGET_VERSION}"
check_branch "${BASE_BRANCH}"
check_branch "${UPDATE_BRANCH}"

cd "${REVIEW_DIR}"
makefile="${PACKAGE_PATH}/Makefile"

# Every push below goes to origin: it must be the review repository.
origin_url=$(git remote get-url origin)
origin_lower=$(printf '%s' "${origin_url}" | tr '[:upper:]' '[:lower:]')
review_lower=$(printf '%s' "${REVIEW_REPOSITORY}" | tr '[:upper:]' '[:lower:]')
[ "${origin_lower}" = "https://github.com/${review_lower}" ] ||
	[ "${origin_lower}" = "https://github.com/${review_lower}.git" ] ||
	die "origin of the checkout is not ${REVIEW_REPOSITORY}"

dirty=$(git status --porcelain)
[ -z "${dirty}" ] || die "the checkout of the review repository is not clean"
base_sha=$(git rev-parse HEAD)
current=$(makefile_var "${makefile}" PKG_VERSION)
order=$(version_cmp "${TARGET_VERSION}" "${current}")
[ "${order}" = gt ] || die "target ${TARGET_VERSION} is not newer than ${current} in ${REVIEW_REPOSITORY}"

# Neither branch may exist: a leftover of another run is never overwritten.
for branch in "${BASE_BRANCH}" "${UPDATE_BRANCH}"; do
	rc=0
	git ls-remote --exit-code --heads origin "refs/heads/${branch}" >&2 || rc=$?
	# Exit 2: no such ref on the remote. Anything else is an error.
	case "${rc}" in
	0) die "branch ${branch} already exists in ${REVIEW_REPOSITORY}" ;;
	2) ;;
	*) die "cannot look for branch ${branch} in ${REVIEW_REPOSITORY}" ;;
	esac
done

# The method must give the PKG_HASH the Makefile already has for ${current}.
recorded=$(makefile_var "${makefile}" PKG_HASH)
computed=$("${script_dir}/source-sha256.sh" "${makefile}" "${current}")
[ "${computed}" = "${recorded}" ] || die "hash method check failed: ${current} hashes to ${computed}, Makefile has ${recorded}"
printf 'method check: the archive of %s hashes to the recorded PKG_HASH\n' "${current}" >&2

new_hash=$("${script_dir}/source-sha256.sh" "${makefile}" "${TARGET_VERSION}")
"${script_dir}/bump-package.sh" "${makefile}" "${TARGET_VERSION}" "${new_hash}"

changed=$(git diff --name-only)
[ "${changed}" = "${makefile}" ] || die "the bump changed files other than ${makefile}"
git diff --stat >&2

message="${PACKAGE}: update to ${TARGET_VERSION}

Update NetBird from ${current} to ${TARGET_VERSION}.

Release notes:
https://github.com/${UPSTREAM_REPOSITORY}/releases/tag/v${TARGET_VERSION}

Signed-off-by: ${COMMIT_NAME} <${COMMIT_EMAIL}>"
git add -- "${makefile}"
git -c user.name="${COMMIT_NAME}" -c user.email="${COMMIT_EMAIL}" commit --quiet -m "${message}"
head_sha=$(git rev-parse HEAD)
parent_sha=$(git rev-parse HEAD^)
[ "${parent_sha}" = "${base_sha}" ] || die "the bump commit is not on top of the starting point"

git push origin "${base_sha}:refs/heads/${BASE_BRANCH}" >&2
if ! git push origin "${head_sha}:refs/heads/${UPDATE_BRANCH}" >&2; then
	git push origin --delete "${BASE_BRANCH}" >&2
	die "push of ${UPDATE_BRANCH} failed; ${BASE_BRANCH} was removed again"
fi

printf 'base_sha=%s\n' "${base_sha}"
printf 'sha=%s\n' "${head_sha}"
