#!/usr/bin/env sh
# Responsibility: turn the PR number of the dispatch into what the jobs of
# .github/workflows/upstream-pr.yml need: the line of the PR's base branch, the
# changed packages (from the files of the PR and the Makefiles of its tree),
# which of them have packages/<name>/ in this repository, which the base can
# build (the .apk must be named like the directory) and the job matrices.
# Nothing is written to GITHUB_OUTPUT before every check passed. Read-only
# towards openwrt/packages (GET requests and a git fetch).
#
# The line of the PR is the line of the base whose packages_branch is the PR's
# base branch (scripts/lib/lines.sh). A package with packages/<name>/ here runs
# on the PR line (the head of the PR) and, overlaid on its own branch, on every
# other line its config.yml lists; it must list the PR line. Outputs
# matrix_legs: one entry per (package, line).
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
#   BASE_LINES_FILE    harness/lines.yml of the base (default ci-base/harness/lines.yml)
set -eu

here=$(dirname "$0")
# shellcheck source=scripts/upstream-pr/lib.sh
. "${here}/lib.sh"
# shellcheck source=scripts/lib/lines.sh
. "${here}/../lib/lines.sh"

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
lines_check_file
line=$(line_for_branch "${base_ref}")
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
git -C "${work}/feed" remote add origin "https://github.com/${upstream}.git"
git -C "${work}/feed" fetch -q --depth=1 --filter=blob:none origin "refs/pull/${PR_NUMBER}/head"
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
# buildable (its Makefile defines a package called like the directory). The
# others are reported and left out: the base would fail at "no <name> .apk".
: >"${work}/rows.tsv"
: >"${work}/skipped.txt"
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
	git -C "${work}/feed" show "FETCH_HEAD:${dir}/Makefile" >"${work}/Makefile"
	defines=$(makefile_defines_package "${name}" <"${work}/Makefile")
	if [ "${defines}" = no ]; then
		defined=$(makefile_package_names <"${work}/Makefile" | tr '\n' ' ')
		echo "${dir}: its Makefile defines [${defined% }], none named ${name}: the base builds by package name and takes the .apk of that name" >>"${work}/skipped.txt"
		continue
	fi
	if [ -d "packages/${name}" ]; then
		is_local=true
	else
		is_local=false
	fi
	# The images and tests of a package with packages/<name>/ come from its
	# config.yml (scripts/images/config.sh); the others get the base defaults.
	profiles=
	targets=
	memory=
	apk_timeout=
	services_disabled=
	image_packages=
	pkg_lines=
	if [ "${is_local}" = true ]; then
		cfg=$("${here}/../images/config.sh" "${name}") || exit 1
		profiles=$(printf '%s\n' "${cfg}" | sed -n -e 's/^profiles=//p')
		targets=$(printf '%s\n' "${cfg}" | sed -n -e 's/^targets=//p')
		memory=$(printf '%s\n' "${cfg}" | sed -n -e 's/^memory=//p')
		apk_timeout=$(printf '%s\n' "${cfg}" | sed -n -e 's/^apk_timeout=//p')
		services_disabled=$(printf '%s\n' "${cfg}" | sed -n -e 's/^services_disabled=//p')
		image_packages=$(printf '%s\n' "${cfg}" | sed -n -e 's/^packages=//p')
		pkg_lines=$(printf '%s\n' "${cfg}" | sed -n -e 's/^lines=//p')
		check_lists_line "${name}" "${pkg_lines}" "${line}"
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${name}" "${dir}" "${is_local}" \
		"${profiles}" "${targets}" "${memory}" "${image_packages}" "${apk_timeout}" "${services_disabled}" "${pkg_lines}" >>"${work}/rows.tsv"
done <"${work}/pkgdirs.txt"
if [ ! -s "${work}/rows.tsv" ]; then
	while read -r line_skipped; do
		fail "not testable: ${line_skipped}"
	done <"${work}/skipped.txt"
	exit 1
fi
dups=$(cut -f1 "${work}/rows.tsv" | sort | uniq -d | wc -l)
if [ "${dups}" -ne 0 ]; then
	fail "two changed packages have the same name: the base builds by name"
	exit 1
fi

# 6. Matrices: every package gets tests_path (a missing directory means only
# the generic test); the full pipeline (images, overlay on the other lines) is
# for the local ones. matrix_legs has one leg per (package, line): the PR line
# for every package (kind pr: the head of the PR) and, for a local package,
# every other line of its config.yml (kind overlay).
rows_json=$(jq -R -s -c '
	split("\n") | map(select(length > 0) | split("\t")
	| {package: .[0], dir: .[1], local: (.[2] == "true"),
	   tests_path: (if .[2] == "true" then "packages/" + .[0] + "/tests" else "" end),
	   profiles: .[3], targets: .[4], memory: .[5], image_packages: .[6], apk_timeout: .[7], services_disabled: .[8], lines: .[9]})' "${work}/rows.tsv")
matrix_all=$(printf '%s' "${rows_json}" | jq -c '{include: .}')
matrix_legs=$(legs_matrix "${rows_json}" "${line}")
overlay_lines=$(overlay_lines "${rows_json}" "${line}")
if [ -n "${overlay_lines}" ]; then has_overlay=true; else has_overlay=false; fi
overlay_dirs=$(tr '\n' ' ' <"${work}/pkgdirs.txt" | sed 's/ $//')
skipped_count=$(wc -l <"${work}/skipped.txt")

# 7. Outputs, after every check.
{
	echo "pr_number=${PR_NUMBER}"
	echo "line=${line}"
	echo "overlay_lines=${overlay_lines}"
	echo "has_overlay=${has_overlay}"
	echo "head_sha=${head_sha}"
	echo "matrix_all=${matrix_all}"
	echo "matrix_legs=${matrix_legs}"
	echo "overlay_dirs=${overlay_dirs}"
	echo "skipped=${skipped_count}"
} >>"${GITHUB_OUTPUT}"

# 8. Summary, in the job log too.
{
	echo "### upstream pull request ${upstream}#${PR_NUMBER}"
	echo
	echo "- title: ${title}"
	echo "- state: ${state}, base branch: ${base_ref} -> line ${line}, overlay lines: ${overlay_lines:-none}"
	echo "- head: ${head_sha} (refs/pull/${PR_NUMBER}/head), ${changed_files} changed files"
	echo "- built as the head commit, without merging the base branch (refs/pull/${PR_NUMBER}/merge is not used)"
	echo "- no secret reaches the build or the tests of an upstream pull request: tests that need one skip"
	echo "- changed packages: ${count} (directory, name)"
	while IFS="$(printf '\t')" read -r name dir is_local _; do
		if [ "${is_local}" = true ]; then
			pipeline="full pipeline on ${line} and, overlaid on the branch of each line, on the other lines of its config.yml"
		else
			pipeline="build + generic test on ${line} only"
		fi
		echo "  - ${dir} (${name}): ${pipeline}"
	done <"${work}/rows.tsv"
	while read -r line_skipped; do
		echo "  - NOT TESTED ${line_skipped}"
		echo "::warning title=package not tested::${line_skipped}"
	done <"${work}/skipped.txt"
} | tee -a "${GITHUB_STEP_SUMMARY}"
