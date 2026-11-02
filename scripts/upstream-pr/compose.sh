#!/usr/bin/env sh
# Responsibility: build the package tree of the other line: the branch of
# openwrt/packages of that line with the changed package directories of the
# pull request copied over it, committed as one root commit and pushed as a
# branch of THIS repository (the base builds a tree given as repository + ref,
# and a pull request tree is made for its own base branch). The branch is
# deleted by the cleanup job when the builds are done. Nothing is pushed to
# openwrt/packages. The upstream .github/ is dropped: GITHUB_TOKEN may not
# push workflow files.
#
# Usage: scripts/upstream-pr/compose.sh
# Environment variables:
#   PR_NUMBER, OTHER_BRANCH, HEAD_SHA, OVERLAY_DIRS  from the resolve job
#   TARGET_BRANCH      branch of this repository to push
#   GITHUB_REPOSITORY  this repository; GH_TOKEN authenticates the push
#   PUSH_URL           where to push (default https://github.com/$GITHUB_REPOSITORY.git)
#   GITHUB_OUTPUT, GITHUB_STEP_SUMMARY
set -eu

here=$(dirname "$0")
# shellcheck source=scripts/upstream-pr/lib.sh
. "${here}/lib.sh"

: "${PR_NUMBER:?}" "${OTHER_BRANCH:?}" "${HEAD_SHA:?}" "${OVERLAY_DIRS:?}" "${TARGET_BRANCH:?}"
: "${GITHUB_REPOSITORY:?}" "${GITHUB_OUTPUT:?}" "${GITHUB_STEP_SUMMARY:?}"

check_pr_number "${PR_NUMBER}"
case "${OTHER_BRANCH}" in
master | openwrt-25.12) ;;
*)
	clean "${OTHER_BRANCH}"
	fail "unexpected branch '${cleaned}'"
	exit 1
	;;
esac
case "${HEAD_SHA}" in
*[!0-9a-f]* | '')
	fail "invalid head sha"
	exit 1
	;;
*) ;;
esac
case "${TARGET_BRANCH}" in
upstream-overlay/*) ;;
*)
	fail "the target branch must start with upstream-overlay/"
	exit 1
	;;
esac
for dir in ${OVERLAY_DIRS}; do
	case "${dir}" in
	*[!A-Za-z0-9._+/-]* | /* | .* | */.* | *..*)
		clean "${dir}"
		fail "invalid package directory '${cleaned}'"
		exit 1
		;;
	*) ;;
	esac
done

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
git init -q "${work}/tree"
cd "${work}/tree"
upstream=https://github.com/openwrt/packages.git
git fetch -q --depth=1 "${upstream}" "${OTHER_BRANCH}"
base_sha=$(git rev-parse FETCH_HEAD)
git fetch -q --depth=1 "${upstream}" "refs/pull/${PR_NUMBER}/head"
git checkout -q "${base_sha}"
fetched=$(git rev-parse FETCH_HEAD)
if [ "${fetched}" != "${HEAD_SHA}" ]; then
	fail "the head of pull request ${PR_NUMBER} moved: run again"
	exit 1
fi

# Replace each directory by the one of the PR (a directory the PR removed stays removed).
for dir in ${OVERLAY_DIRS}; do
	git rm -rq --ignore-unmatch -- "${dir}"
	if git cat-file -e "${HEAD_SHA}:${dir}"; then
		git checkout -q "${HEAD_SHA}" -- "${dir}"
	fi
done
git rm -rq --ignore-unmatch -- .github

# A root commit: the clone is shallow, so a child of the upstream commit would
# make the push fail (its parent is missing from the receiving side).
tree=$(git write-tree)
sha=$(GIT_AUTHOR_NAME='github-actions[bot]' GIT_COMMITTER_NAME='github-actions[bot]' \
	GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com' \
	GIT_COMMITTER_EMAIL='41898282+github-actions[bot]@users.noreply.github.com' \
	git commit-tree -m "overlay of ${OVERLAY_DIRS} from openwrt/packages#${PR_NUMBER} (${HEAD_SHA}) on ${OTHER_BRANCH} (${base_sha})" "${tree}")
git -c credential.helper='!gh auth git-credential' push -q \
	"${PUSH_URL:-https://github.com/${GITHUB_REPOSITORY}.git}" "${sha}:refs/heads/${TARGET_BRANCH}"

{
	echo "branch=${TARGET_BRANCH}"
	echo "sha=${sha}"
} >>"${GITHUB_OUTPUT}"
{
	echo "### overlay for the other line"
	echo
	echo "- ${OTHER_BRANCH} @ ${base_sha} + {${OVERLAY_DIRS}} of ${HEAD_SHA}"
	echo "- pushed as ${GITHUB_REPOSITORY} ${TARGET_BRANCH} @ ${sha} (deleted by the cleanup job)"
	echo '- files that differ from the line branch:'
	git diff --stat "${base_sha}" "${sha}" -- . ':!.github' | tail -n 12 | sed 's/^/  - /'
} | tee -a "${GITHUB_STEP_SUMMARY}"
