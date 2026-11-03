#!/usr/bin/env sh
# Responsibility: stand-in for gh in the offline tests of the update scripts
# (copied as `gh` into a directory at the front of PATH). It answers the few
# calls the scripts make from files in STUB_GH_DIR and never reaches GitHub; an
# unexpected call fails with status 99, so a script cannot write somewhere the
# test did not foresee. --jq is ignored: the stub prints the value the script
# asks for.
#
# Usage:
#   gh-stub.sh api [--method M] [-H h] [--jq expr] <path>
#   gh-stub.sh pr list --repo R --head B --state S --json number|url [--jq e]
#   gh-stub.sh pr create --repo R ...
#
# Environment variables:
#   STUB_GH_DIR  directory of the fixtures:
#     makefile      Makefile served as the contents of the package
#     head_sha      sha of the head of the review branch
#     tag           tag_name of the latest upstream release
#     branches      existing branches of the review repository, one per line
#     prs           pull requests, one "<head branch> <open|closed>" per line
#     pr_url        URL printed by `pr create`
#     delete_fail   exists: DELETE of a ref fails with HTTP 500
#     delete_noop   exists: DELETE of a ref succeeds but removes nothing
#     probe_status  HTTP status of POST pulls (422: allowed, 403: forbidden)
#     permissions   value of .permissions.push of the repository
#     compare       the tab-separated answer of repos/<upstream>/compare/...
#                   (status, ahead_by, behind_by, base sha, merge base sha)
#   STUB_LOG     file that receives one line "gh <arguments>" per call

set -eu

dir=${STUB_GH_DIR:?}
printf 'gh %s\n' "$*" >>"${STUB_LOG:?}"

# Count the pull requests of a head branch in a state ("all" matches any).
#
# Arguments:
#   $1  head branch
#   $2  open, closed or all
count_prs() {
	n=0
	while read -r head state; do
		[ "${head}" = "$1" ] || continue
		if [ "$2" = all ] || [ "$2" = "${state}" ]; then
			n=$((n + 1))
		fi
	done <"${dir}/prs"
	printf '%s\n' "${n}"
}

cmd=${1:-}
[ "$#" -eq 0 ] || shift
case "${cmd}" in
api)
	method=GET
	path=
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--method)
			method=$2
			shift
			;;
		-H | --jq | -f | -F)
			shift
			;;
		-*) ;;
		*) path=$1 ;;
		esac
		shift
	done
	case "${method} ${path}" in
	'GET repos/'*/contents/*/Makefile'?ref='*) cat "${dir}/makefile" ;;
	'GET repos/'*/compare/*) cat "${dir}/compare" ;;
	'GET repos/'*/commits/*) cat "${dir}/head_sha" ;;
	'GET repos/'*/releases/latest) cat "${dir}/tag" ;;
	'GET repos/'*/branches/*)
		name=${path##*/branches/}
		if grep -Fxq -- "${name}" "${dir}/branches"; then
			printf '%s\n' "${name}"
		else
			printf 'gh: Not Found (HTTP 404)\n' >&2
			exit 1
		fi
		;;
	'GET repos/'*)
		cat "${dir}/permissions"
		;;
	'DELETE repos/'*/git/refs/heads/*)
		name=${path##*/git/refs/heads/}
		if [ -e "${dir}/delete_fail" ]; then
			printf 'gh: Internal Server Error (HTTP 500)\n' >&2
			exit 1
		fi
		if ! grep -Fxq -- "${name}" "${dir}/branches"; then
			printf 'gh: Reference does not exist (HTTP 422)\n' >&2
			exit 1
		fi
		if [ ! -e "${dir}/delete_noop" ]; then
			grep -Fxv -- "${name}" "${dir}/branches" >"${dir}/branches.new" || :
			mv "${dir}/branches.new" "${dir}/branches"
		fi
		;;
	'POST repos/'*/pulls)
		status=$(cat "${dir}/probe_status")
		printf 'gh: probe answered (HTTP %s)\n' "${status}" >&2
		exit 1
		;;
	*)
		printf 'gh-stub: unexpected call: %s %s\n' "${method}" "${path}" >&2
		exit 99
		;;
	esac
	;;
pr)
	sub=${1:-}
	[ "$#" -eq 0 ] || shift
	head=
	state=open
	json=
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--head)
			head=$2
			shift
			;;
		--state)
			state=$2
			shift
			;;
		--json)
			json=$2
			shift
			;;
		--repo | --jq | --base | --title | --body-file)
			shift
			;;
		*) ;;
		esac
		shift
	done
	case "${sub}:${json}" in
	list:number) count_prs "${head}" "${state}" ;;
	list:url)
		found=$(count_prs "${head}" "${state}")
		if [ "${found}" -gt 0 ]; then
			printf 'https://example.invalid/pull/1\n'
		fi
		;;
	create:*)
		printf '%s open\n' "${head}" >>"${dir}/prs"
		cat "${dir}/pr_url"
		;;
	*)
		printf 'gh-stub: unexpected call: pr %s\n' "${sub}" >&2
		exit 99
		;;
	esac
	;;
*)
	printf 'gh-stub: unexpected call: %s\n' "${cmd}" >&2
	exit 99
	;;
esac
