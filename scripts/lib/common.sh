#!/usr/bin/env sh
# Responsibility: helpers shared by the scripts of the update workflow
# (.github/workflows/update.yml): input validators and the readers of a
# package Makefile. Sourced, not run. A validator never echoes the value it
# rejects: a newline or a "::" prefix could forge workflow commands in the log.
#
# Usage:
#   . "${script_dir}/lib/common.sh"
#
# Environment variables: none.

# Print an error and abort the calling script.
#
# Arguments:
#   $*  message
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# Abort unless the argument is a review repository: <owner>/<name> of GitHub
# and NOT in the organization openwrt. CI pushes branches and opens a pull
# request in this repository only, so refusing the owner openwrt (any letter
# case, any repository) is what keeps openwrt/packages out of reach.
#
# Arguments:
#   $1  repository
check_review_repository() {
	cr_owner=${1%%/*}
	cr_name=${1#*/}
	case "$1" in
	*/*/* | */ | /* | '') die "invalid review repository (expected <owner>/<name>)" ;;
	*/*) ;;
	*) die "invalid review repository (expected <owner>/<name>)" ;;
	esac
	case "${cr_owner}" in
	*[!A-Za-z0-9-]* | -* | '') die "invalid review repository owner" ;;
	*) ;;
	esac
	[ "${#cr_owner}" -le 39 ] || die "invalid review repository owner (longer than 39 chars)"
	case "${cr_name}" in
	*[!A-Za-z0-9._-]* | -* | . | .. | *.git | '') die "invalid review repository name" ;;
	*) ;;
	esac
	[ "${#cr_name}" -le 100 ] || die "invalid review repository name (longer than 100 chars)"
	cr_lower=$(printf '%s' "${cr_owner}" | tr '[:upper:]' '[:lower:]')
	[ "${cr_lower}" != openwrt ] || die "the review repository must not belong to openwrt: CI never writes to the upstream"
}

# Abort unless the argument is a GitHub repository, <owner>/<name> (the
# upstream project whose releases are watched; read only).
#
# Arguments:
#   $1  repository
check_upstream_repository() {
	case "$1" in
	*/*/* | */ | /* | '' | -* | */-* | *[!A-Za-z0-9._/-]*) die "invalid upstream repository" ;;
	*/*) ;;
	*) die "invalid upstream repository" ;;
	esac
	[ "${#1}" -le 140 ] || die "invalid upstream repository (longer than 140 chars)"
}

# Abort unless the argument is a package name: [a-z0-9][a-z0-9._+-]*.
#
# Arguments:
#   $1  package name
check_package() {
	case "$1" in
	*[!a-z0-9._+-]* | [!a-z0-9]* | '') die "invalid package name" ;;
	*) ;;
	esac
	[ "${#1}" -le 128 ] || die "invalid package name (longer than 128 chars)"
}

# Abort unless the argument is a relative package directory of the feed, for
# example net/netbird: two or more components of [a-z0-9._+-], no "." or "..".
#
# Arguments:
#   $1  path
check_package_path() {
	case "$1" in
	*[!a-z0-9._+/-]* | /* | */ | *//* | . | .. | ./* | ../* | */./* | */../* | */. | */.. | '') die "invalid package path" ;;
	*/*) ;;
	*) die "invalid package path (expected <section>/<package>)" ;;
	esac
	[ "${#1}" -le 128 ] || die "invalid package path (longer than 128 chars)"
}

# Abort unless the argument is a branch name that is safe in a ref and in a
# URL: [A-Za-z0-9._/-], no "..", no leading "-" or "/", no trailing "/" or ".".
#
# Arguments:
#   $1  branch name
check_branch() {
	case "$1" in
	*[!A-Za-z0-9._/-]* | -* | /* | */ | *//* | *..* | *. | *.lock | '') die "invalid branch name" ;;
	*) ;;
	esac
	[ "${#1}" -le 200 ] || die "invalid branch name (longer than 200 chars)"
}

# Abort unless the argument is a release version: three numbers, X.Y.Z, each
# of 1 to 6 digits (no "v" prefix, no pre-release suffix).
#
# Arguments:
#   $1  version
check_version() {
	case "$1" in
	*[!0-9.]* | .* | *. | *..* | '') die "invalid version (expected X.Y.Z)" ;;
	*.*.*.*) die "invalid version (expected X.Y.Z)" ;;
	*.*.*) ;;
	*) die "invalid version (expected X.Y.Z)" ;;
	esac
	cv_rest=$1
	while [ -n "${cv_rest}" ]; do
		cv_part=${cv_rest%%.*}
		[ "${#cv_part}" -le 6 ] || die "invalid version (a part has more than 6 digits)"
		case "${cv_rest}" in
		*.*) cv_rest=${cv_rest#*.} ;;
		*) cv_rest= ;;
		esac
	done
}

# Print a validated decimal number without leading zeros (POSIX arithmetic
# would read 08 as octal).
#
# Arguments:
#   $1  digits
strip_zeros() {
	sz_value=$1
	while [ "${#sz_value}" -gt 1 ]; do
		case "${sz_value}" in
		0*) sz_value=${sz_value#0} ;;
		*) break ;;
		esac
	done
	printf '%s\n' "${sz_value}"
}

# Print gt, eq or lt: how version $1 compares with version $2. Both must be
# valid. It always exits 0 for valid versions, so callers can test the output.
#
# Arguments:
#   $1  version
#   $2  version
version_cmp() {
	check_version "$1"
	check_version "$2"
	vg_a=$1
	vg_b=$2
	while [ -n "${vg_a}" ] || [ -n "${vg_b}" ]; do
		vg_x=$(strip_zeros "${vg_a%%.*}")
		vg_y=$(strip_zeros "${vg_b%%.*}")
		if [ "${vg_x}" -gt "${vg_y}" ]; then
			printf 'gt\n'
			return 0
		fi
		if [ "${vg_x}" -lt "${vg_y}" ]; then
			printf 'lt\n'
			return 0
		fi
		case "${vg_a}" in
		*.*) vg_a=${vg_a#*.} ;;
		*) vg_a= ;;
		esac
		case "${vg_b}" in
		*.*) vg_b=${vg_b#*.} ;;
		*) vg_b= ;;
		esac
	done
	printf 'eq\n'
}

# Print the value of a variable assigned with := at the start of a line of a
# package Makefile; a missing or empty variable is an error.
#
# Arguments:
#   $1  Makefile
#   $2  variable name, e.g. PKG_VERSION
makefile_var() {
	mv_line=$(grep -m 1 "^$2:=" "$1") || die "$2 is not set in $1"
	mv_value=${mv_line#"$2":=}
	[ -n "${mv_value}" ] || die "$2 is empty in $1"
	printf '%s\n' "${mv_value}"
}

# Print the value of a top-level key of a YAML file (needs yq); a missing key
# is an error. The value is checked by the caller.
#
# Arguments:
#   $1  YAML file
#   $2  key
config_get() {
	cg_value=$(yq -r ".$2" "$1") || die "yq failed on $1"
	case "${cg_value}" in
	null | '') die "missing key $2 in $1" ;;
	*) ;;
	esac
	printf '%s\n' "${cg_value}"
}
