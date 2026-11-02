#!/usr/bin/env sh
# Responsibility: turn the PR number of the dispatch into what the jobs of
# .github/workflows/upstream-pr.yml need: the line of the PR's base branch, the
# changed packages (from the files of the PR and the Makefiles of its tree),
# which of them have packages/<name>/ in this repository, and the job matrices.
# Nothing is written to GITHUB_OUTPUT before every check passed. Read-only
# towards openwrt/packages (GET requests and a git fetch).
#
# Usage: scripts/upstream-pr/resolve.sh   (run from the root of the repository)
# Environment variables:
#   PR_NUMBER          the dispatch input, validated here
#   GH_TOKEN           token for the GitHub API (rate limit only; nothing private)
#   GITHUB_OUTPUT      file the outputs are appended to
#   GITHUB_STEP_SUMMARY file the summary is appended to
#   MAX_PACKAGES       most changed packages accepted (default 5)
#   UPSTREAM_REPOSITORY  the feed repository (default openwrt/packages)
#   API_URL            GitHub API root (default https://api.github.com)
set -eu

here=$(dirname "$0")
# shellcheck source=scripts/upstream-pr/lib.sh
. "${here}/lib.sh"

: "${PR_NUMBER:?}" "${GITHUB_OUTPUT:?}" "${GITHUB_STEP_SUMMARY:?}"
max_packages=${MAX_PACKAGES:-5}
upstream=${UPSTREAM_REPOSITORY:-openwrt/packages}
api=${API_URL:-https://api.github.com}

# 1. The only input, before any request.
check_pr_number "${PR_NUMBER}"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

# GET ${api}/<path> into $2; a 404 is a message, any other non-200 is an error.
# Arguments: $1 path, $2 output file.
api_get() {
	code=$(curl -sS --retry 3 -o "$2" -w '%{http_code}' \
		-H "Authorization: Bearer ${GH_TOKEN:-}" \
		-H 'Accept: application/vnd.github+json' \
		-H 'X-GitHub-Api-Version: 2022-11-28' \
		"${api}/$1")
	case "${code}" in
	200) ;;
	404)
		fail "pull request ${PR_NUMBER} not found in ${upstream}"
		return 1
		;;
	*)
		fail "GET $1 answered HTTP ${code}"
		return 1
		;;
	esac
}

# 2. The pull request and its base line.
api_get "repos/${upstream}/pulls/${PR_NUMBER}" "${work}/pr.json"
base_ref=$(jq -r '.base.ref' "${work}/pr.json")
head_sha=$(jq -r '.head.sha' "${work}/pr.json")
state=$(jq -r 'if .merged then "merged" else .state end' "${work}/pr.json")
changed_files=$(jq -r '.changed_files' "${work}/pr.json")
title=$(jq -r '.title' "${work}/pr.json" | tr -cd '[:print:]' | cut -c1-120)
line=$(line_for_base "${base_ref}")
other=$(other_line "${line}")
other_branch=$(branch_for_line "${other}")
case "${head_sha}" in
*[!0-9a-f]* | '') fail "the API returned no valid head sha" ;;
*) ;;
esac
if [ "${changed_files}" -gt 300 ]; then
	fail "pull request ${PR_NUMBER} changes ${changed_files} files, the limit is 300"
	exit 1
fi

# 3. Files of the diff against the base (renames count at both paths).
: >"${work}/files.txt"
page=1
while [ $(((page - 1) * 100)) -lt "${changed_files}" ]; do
	api_get "repos/${upstream}/pulls/${PR_NUMBER}/files?per_page=100&page=${page}" "${work}/page.json"
	jq -r '.[] | .filename, (.previous_filename // empty)' "${work}/page.json" >>"${work}/files.txt"
	page=$((page + 1))
done

# 4. Makefile directories of the PR tree (trees only: no blob is downloaded).
git init -q "${work}/feed"
git -C "${work}/feed" fetch -q --depth=1 --filter=blob:none \
	"https://github.com/${upstream}.git" "refs/pull/${PR_NUMBER}/head"
fetched=$(git -C "${work}/feed" rev-parse FETCH_HEAD)
if [ "${fetched}" != "${head_sha}" ]; then
	fail "the head of pull request ${PR_NUMBER} moved during the run (${head_sha} -> ${fetched}): run again"
	exit 1
fi
git -C "${work}/feed" -c core.quotepath=off ls-tree -r --name-only FETCH_HEAD |
	makefile_dirs >"${work}/dirs.txt"
detect_packages "${work}/dirs.txt" <"${work}/files.txt" >"${work}/pkgdirs.txt"

count=$(wc -l <"${work}/pkgdirs.txt")
if [ "${count}" -eq 0 ]; then
	fail "pull request ${PR_NUMBER} changes no package (no changed file is below a directory with a Makefile in its tree; a package the PR only removes has none)"
	exit 1
fi
if [ "${count}" -gt "${max_packages}" ]; then
	fail "pull request ${PR_NUMBER} changes ${count} packages, the limit is ${max_packages}"
	exit 1
fi

# 5. One row per package: name, directory, local (packages/<name>/ exists) and
# the secrets of its tests (packages/<name>/config.yml, key test_secrets).
: >"${work}/rows.tsv"
while read -r dir; do
	name=${dir##*/}
	check_package_name "${name}"
	case "${dir}" in
	*[!A-Za-z0-9._+/-]*)
		clean "${dir}"
		fail "package directory '${cleaned}' has unexpected characters"
		exit 1
		;;
	*) ;;
	esac
	if [ -d "packages/${name}" ]; then
		is_local=true
		secrets=""
		if [ -f "packages/${name}/config.yml" ]; then
			secrets=$(yq -r '.test_secrets // ""' "packages/${name}/config.yml")
		fi
		case "${secrets}" in
		*[!A-Z0-9_\ ,]*)
			fail "packages/${name}/config.yml: test_secrets has unexpected characters"
			exit 1
			;;
		*) ;;
		esac
	else
		is_local=false
		secrets=""
	fi
	printf '%s\t%s\t%s\t%s\n' "${name}" "${dir}" "${is_local}" "${secrets}" >>"${work}/rows.tsv"
done <"${work}/pkgdirs.txt"
dups=$(cut -f1 "${work}/rows.tsv" | sort | uniq -d | wc -l)
if [ "${dups}" -ne 0 ]; then
	fail "two changed packages have the same name: the base builds by name"
	exit 1
fi

# 6. Matrices: every package gets tests_path (a missing directory means only
# the generic test); the full pipeline (images, overlay) is for the local ones.
rows_json=$(jq -R -s -c '
	split("\n") | map(select(length > 0) | split("\t")
	| {package: .[0], dir: .[1], local: (.[2] == "true"),
	   tests_path: (if .[2] == "true" then "packages/" + .[0] + "/tests" else "" end),
	   test_secrets: .[3]})' "${work}/rows.tsv")
matrix_all=$(printf '%s' "${rows_json}" | jq -c '{include: .}')
matrix_full=$(printf '%s' "${rows_json}" | jq -c '{include: map(select(.local))}')
has_full=$(printf '%s' "${rows_json}" | jq -r 'any(.[]; .local)')
overlay_dirs=$(tr '\n' ' ' <"${work}/pkgdirs.txt" | sed 's/ $//')

# 7. Outputs, after every check.
{
	echo "pr_number=${PR_NUMBER}"
	echo "line=${line}"
	echo "other_line=${other}"
	echo "other_branch=${other_branch}"
	echo "head_sha=${head_sha}"
	echo "matrix_all=${matrix_all}"
	echo "matrix_full=${matrix_full}"
	echo "has_full=${has_full}"
	echo "overlay_dirs=${overlay_dirs}"
} >>"${GITHUB_OUTPUT}"

# 8. Summary, in the job log too.
{
	echo "### upstream pull request ${upstream}#${PR_NUMBER}"
	echo
	echo "- title: ${title}"
	echo "- state: ${state}, base branch: ${base_ref} -> line ${line}, other line: ${other} (branch ${other_branch})"
	echo "- head: ${head_sha} (refs/pull/${PR_NUMBER}/head), ${changed_files} changed files"
	echo "- changed packages: ${count} (directory, name, packages/<name>/ here, tests secrets)"
	while IFS="$(printf '\t')" read -r name dir is_local secrets; do
		if [ "${is_local}" = true ]; then
			pipeline="full pipeline on ${line} and, overlaid on ${other_branch}, on ${other}"
		else
			pipeline="build + generic test on ${line} only"
		fi
		echo "  - ${dir} (${name}): ${pipeline}${secrets:+; secrets ${secrets}}"
	done <"${work}/rows.tsv"
} | tee -a "${GITHUB_STEP_SUMMARY}"
