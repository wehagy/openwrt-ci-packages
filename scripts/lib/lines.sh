#!/usr/bin/env sh
# Responsibility: the release lines, read from the harness of the base
# (wehagy/openwrt-ci, harness/lines.yml). No line name is written anywhere else
# in this repository: a package lists its lines in packages/<name>/config.yml,
# and everything that depends on a line (the branch of openwrt/packages it is
# built from, the line of a pull request's base branch, the reference line)
# is looked up here. Sourced, not run. A function prints `error: ...` to stderr
# and returns 1; scripts that source it run under `set -e` and call the
# functions as plain commands (or as `x=$(f)`), so a failure ends them.
#
# The reference line is the one whose packages_branch is master: the branch the
# upstream pull request targets. The bump commit of update.yml is made on it,
# and its result decides whether the pull request opens. Every other line
# builds an overlay of the bump over its own packages_branch.
#
# Usage:
#   . "${script_dir}/lib/lines.sh"
#
# Environment variables:
#   BASE_LINES_FILE  harness/lines.yml of the base (default:
#                    ci-base/harness/lines.yml, where the workflows check the
#                    base out)

# The packages_branch of the line that is the reference.
REFERENCE_BRANCH=master
# Where the workflows check the base out.
LINES_DEFAULT_FILE=ci-base/harness/lines.yml
# The file every function reads.
: "${BASE_LINES_FILE:=${LINES_DEFAULT_FILE}}"

# Print an error message to stderr and return 1. The value that was rejected is
# never echoed unless it passed the name checks (a newline or "::" could forge
# a workflow command).
#
# Arguments:
#   $*  message
lines_error() {
	printf 'error: %s\n' "$*" >&2
	return 1
}

# Fail unless the base's lines.yml is readable and has a `lines` table. Run
# once per script.
lines_check_file() {
	lc_file=${BASE_LINES_FILE}
	if [ ! -f "${lc_file}" ]; then
		lines_error "the base's lines.yml is not at ${lc_file}: check the base out (wehagy/openwrt-ci) or set BASE_LINES_FILE"
		return 1
	fi
	lc_tag=$(yq -r '.lines | tag' "${lc_file}")
	if [ "${lc_tag}" != '!!map' ]; then
		lines_error "${lc_file} has no 'lines' table"
		return 1
	fi
}

# Fail unless the argument is a well-formed line name: [A-Za-z0-9][A-Za-z0-9._-]*,
# at most 32 characters. Nothing else can reach a branch name, a JSON text or
# a job name.
#
# Arguments:
#   $1  line name
check_line_name() {
	case "$1" in
	'' | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*)
		lines_error "invalid line name (allowed: [A-Za-z0-9][A-Za-z0-9._-]*, up to 32 characters)"
		return 1
		;;
	*) ;;
	esac
	if [ "${#1}" -gt 32 ]; then
		lines_error "invalid line name (longer than 32 characters)"
		return 1
	fi
}

# Print the lines of the base whose packages_branch is the argument, one per
# line of output.
#
# Arguments:
#   $1  branch
lines_on_branch() {
	B=$1 yq -r '.lines | to_entries | map(select(.value.packages_branch == strenv(B))) | .[].key' "${BASE_LINES_FILE}"
}

# Print the packages_branch of a line, "" when the base has no such line. The
# name must already have passed check_line_name.
#
# Arguments:
#   $1  line name
line_branch() {
	BL_LINE=$1 yq -r '.lines[strenv(BL_LINE)].packages_branch // ""' "${BASE_LINES_FILE}"
}

# Print the packages_branch of a line; fail when the base has no such line.
#
# Arguments:
#   $1  line name
branch_for_line() {
	check_line_name "$1"
	bl_branch=$(line_branch "$1")
	if [ -z "${bl_branch}" ]; then
		bl_known=$(yq -r '.lines | keys | join(" ")' "${BASE_LINES_FILE}")
		lines_error "the base has no line '$1' (lines of the base: ${bl_known})"
		return 1
	fi
	printf '%s\n' "${bl_branch}"
}

# Print the reference line: the single line whose packages_branch is master.
reference_line() {
	rl_found=$(lines_on_branch "${REFERENCE_BRANCH}")
	case "${rl_found}" in
	'')
		lines_error "no line of the base has packages_branch ${REFERENCE_BRANCH}: there is no reference line"
		return 1
		;;
	*"
"*)
		lines_error "more than one line of the base has packages_branch ${REFERENCE_BRANCH}: the reference line is ambiguous"
		return 1
		;;
	*) printf '%s\n' "${rl_found}" ;;
	esac
}

# Print the line a branch of openwrt/packages belongs to (the base branch of a
# pull request). Exactly one line may have it as packages_branch.
#
# Arguments:
#   $1  branch
line_for_branch() {
	case "$1" in
	'' | *[!A-Za-z0-9._/+-]*)
		lines_error "unsupported base branch (not a branch name)"
		return 1
		;;
	*) ;;
	esac
	lf_found=$(lines_on_branch "$1")
	case "${lf_found}" in
	'')
		lf_known=$(yq -r '.lines | to_entries | map(.key + "=" + .value.packages_branch) | join(" ")' "${BASE_LINES_FILE}")
		lines_error "unsupported base branch '$1': no line of the base builds it (branch of each line: ${lf_known})"
		return 1
		;;
	*"
"*)
		lines_error "base branch '$1' belongs to more than one line of the base"
		return 1
		;;
	*) printf '%s\n' "${lf_found}" ;;
	esac
}

# Fail with a clear message unless every line of the list is in the base and
# the reference line is among them.
#
# Arguments:
#   $1  lines, separated by spaces
#   $2  what the list is (for the message), e.g. "packages/netbird/config.yml: lines"
check_package_lines() {
	cpl_ref=$(reference_line)
	cpl_have_ref=false
	cpl_seen=" "
	cpl_known=$(yq -r '.lines | keys | join(" ")' "${BASE_LINES_FILE}")
	if [ -z "$1" ]; then
		lines_error "$2 is empty: list at least the reference line ${cpl_ref}"
		return 1
	fi
	# Split by hand: `for x in $1` would expand a glob character of a name.
	cpl_rest=$1
	while [ -n "${cpl_rest}" ]; do
		cpl_line=${cpl_rest%% *}
		case "${cpl_rest}" in
		*" "*) cpl_rest=${cpl_rest#* } ;;
		*) cpl_rest= ;;
		esac
		check_line_name "${cpl_line}"
		case "${cpl_seen}" in
		*" ${cpl_line} "*)
			lines_error "$2 lists the line '${cpl_line}' twice"
			return 1
			;;
		*) ;;
		esac
		cpl_seen="${cpl_seen}${cpl_line} "
		cpl_branch=$(line_branch "${cpl_line}")
		if [ -z "${cpl_branch}" ]; then
			lines_error "$2 names the line '${cpl_line}', which the base does not have (lines of the base: ${cpl_known}): add it to the base's harness/lines.yml and harness/targets.yml first"
			return 1
		fi
		if [ "${cpl_line}" = "${cpl_ref}" ]; then cpl_have_ref=true; fi
	done
	if [ "${cpl_have_ref}" != true ]; then
		lines_error "$2 does not list the reference line ${cpl_ref} (packages_branch ${REFERENCE_BRANCH}): the bump commit is made on it and its result decides the pull request"
		return 1
	fi
}
