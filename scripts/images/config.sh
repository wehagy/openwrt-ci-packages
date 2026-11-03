#!/usr/bin/env sh
# Responsibility: read packages/<name>/config.yml of this repository and print
# what the workflows pass to the reusable base wehagy/openwrt-ci as KEY=value
# lines (package, profiles, packages, targets, memory, apk_timeout,
# services_disabled, limits). Nothing is
# printed unless the file and every value in it are well formed, so the output
# is safe for $GITHUB_OUTPUT. The base validates the same values again with
# its own rules; this check keeps a typo from reaching a run.
#
# profiles, packages and targets are single lines of space separated words;
# `memory`, `apk_timeout`, `targets` and `services_disabled` are empty when the
# config does not set them (the base defaults then apply; `services_disabled`
# lists the init scripts of the package that are disabled by default, which the
# service test of the base skips). `limits` is "<profile> <bytes>" pairs separated by
# spaces.
#
# `lines` (space separated) and `lines_json` (a JSON array, the matrix of the
# workflows) are the release lines of the package, as listed in its config.yml
# (`lines:`, in that order); `reference` is the reference line (the line of the
# base whose packages_branch is master) and `others` / `others_json` the lines
# without it. Every line must exist in the base's harness/lines.yml and the
# reference line must be listed (scripts/lib/lines.sh). SELECT_LINES narrows
# the output to some of the lines of the package (a manual run of ci.yml).
#
# Usage:
#   scripts/images/config.sh <package> >> "$GITHUB_OUTPUT"
#
# Environment variables:
#   PACKAGES_DIR   directory with <name>/config.yml (default: packages)
#   BASE_LINES_FILE  harness/lines.yml of the base (default:
#                  ci-base/harness/lines.yml)
#   SELECT_LINES   optional, lines of the package to keep, separated by spaces;
#                  a line the package does not list is an error

# -f: no word of a list (SELECT_LINES, the lines of the config) is a glob.
set -efu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/lib/lines.sh
. "${script_dir}/../lib/lines.sh"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

[ "$#" -eq 1 ] || die "usage: config.sh <package>"
package=$1
case "${package}" in
*[!a-z0-9._+-]* | [!a-z0-9]* | '') die "invalid package name (allowed: [a-z0-9][a-z0-9._+-]*)" ;;
*) ;;
esac
[ "${#package}" -le 128 ] || die "invalid package name (longer than 128 chars)"
dir=${PACKAGES_DIR:-packages}
config=${dir}/${package}/config.yml
[ -f "${config}" ] || die "${config} does not exist: ${package} is not a package of this repository"

# Print the value of a yq expression, "" for a missing key.
#
# Arguments:
#   $1  yq expression
value() {
	v_out=$(yq -r "$1 // \"\"" "${config}") || die "yq failed on ${config}: $1"
	printf '%s\n' "${v_out}"
}

name=$(value .package)
[ "${name}" = "${package}" ] || die "${config}: package is not ${package}"
lines_check_file
# The lines: a list of strings (an unquoted 25.10 is a number in YAML and would
# lose its zero), every one a line of the base, the reference line among them.
lines_tag=$(value '.lines | tag')
[ "${lines_tag}" = '!!seq' ] ||
	die "${config}: lines is required and must be a list, e.g. lines: [<reference line>, <other line>]"
lines_bad=$(value '[.lines[] | select(tag != "!!str")] | length')
[ "${lines_bad}" = 0 ] ||
	die "${config}: every line must be a quoted string, e.g. \"<line>\" (an unquoted number is read as a decimal and loses a trailing zero)"
# Every element is ONE line name: a string with a space in it is
# not two lines, and a glob character is not a name.
lines_count=$(value '.lines | length')
lines_at=0
while [ "${lines_at}" -lt "${lines_count}" ]; do
	lines_name=$(value ".lines[${lines_at}]")
	check_line_name "${lines_name}"
	lines_at=$((lines_at + 1))
done
package_lines=$(value '.lines | join(" ")')
check_package_lines "${package_lines}" "${config}: lines"
reference=$(reference_line)
selected=
if [ -n "${SELECT_LINES:-}" ]; then
	for want in ${SELECT_LINES}; do
		check_line_name "${want}"
		case " ${package_lines} " in
		*" ${want} "*) ;;
		*) die "line ${want} is not a line of ${package} (its lines: ${package_lines})" ;;
		esac
		case " ${selected} " in
		*" ${want} "*) ;;
		*) selected="${selected} ${want}" ;;
		esac
	done
	# Keep the order of the config.
	kept=
	for line in ${package_lines}; do
		case " ${selected} " in
		*" ${line} "*) kept="${kept} ${line}" ;;
		*) ;;
		esac
	done
	package_lines=${kept# }
	[ -n "${package_lines}" ] || die "SELECT_LINES selects no line of ${package}"
fi
others=
for line in ${package_lines}; do
	[ "${line}" = "${reference}" ] || others="${others} ${line}"
done
others=${others# }

# A JSON array of strings out of words that line_name_ok accepted.
#
# Arguments:
#   $1  words, separated by spaces
json_array() {
	ja_out=
	for ja_word in $1; do
		ja_out="${ja_out:+${ja_out},}\"${ja_word}\""
	done
	printf '[%s]' "${ja_out}"
}
profiles=$(value '.images.profiles // [] | join(" ")')
packages=$(value '.images.packages')
targets=$(value .targets)
memory=$(value .memory)
apk_timeout=$(value .apk_timeout)
services_disabled=$(value '.services_disabled // [] | join(" ")')
limits=$(value '.images.limits // {} | to_entries | map(.key + " " + (.value | tostring)) | join(" ")')

# One line of the allowed characters each: nothing can start a new output
# line or a workflow command.
for pair in "profiles:${profiles}" "packages:${packages}" "targets:${targets}" "limits:${limits}"; do
	key=${pair%%:*}
	text=${pair#*:}
	case "${text}" in
	*[!A-Za-z0-9_/:.+\ -]*) die "${config}: ${key} has a character outside [A-Za-z0-9_/:.+ -]" ;;
	*) ;;
	esac
done
# memory and apk_timeout have the ranges of the base (64M to 1024M, 30 to
# 600 s), so that a wrong value fails here, in the first job, and not after the
# builds.
if [ -n "${memory}" ]; then
	mem_mb=${memory%M}
	case "${memory}" in
	*M) ;;
	*) die "${config}: memory must be NNNM from 64M to 1024M, e.g. 256M" ;;
	esac
	case "${mem_mb}" in
	*[!0-9]* | 0* | '') die "${config}: memory must be NNNM from 64M to 1024M, e.g. 256M" ;;
	*) ;;
	esac
	{ [ "${#mem_mb}" -le 4 ] && [ "${mem_mb}" -ge 64 ] && [ "${mem_mb}" -le 1024 ]; } ||
		die "${config}: memory must be NNNM from 64M to 1024M, e.g. 256M"
fi
case "${services_disabled}" in
*[!A-Za-z0-9._\ -]*) die "${config}: services_disabled has a character outside [A-Za-z0-9._ -]" ;;
*) ;;
esac
if [ -n "${apk_timeout}" ]; then
	case "${apk_timeout}" in
	*[!0-9]* | 0*) die "${config}: apk_timeout must be whole seconds from 30 to 600, e.g. 120" ;;
	*) ;;
	esac
	{ [ "${#apk_timeout}" -le 3 ] && [ "${apk_timeout}" -ge 30 ] && [ "${apk_timeout}" -le 600 ]; } ||
		die "${config}: apk_timeout must be whole seconds from 30 to 600, e.g. 120"
fi

lines_json=$(json_array "${package_lines}")
others_json=$(json_array "${others}")

printf 'package=%s\n' "${name}"
printf 'lines=%s\n' "${package_lines}"
printf 'lines_json=%s\n' "${lines_json}"
printf 'reference=%s\n' "${reference}"
printf 'others=%s\n' "${others}"
printf 'others_json=%s\n' "${others_json}"
printf 'profiles=%s\n' "${profiles}"
printf 'packages=%s\n' "${packages}"
printf 'targets=%s\n' "${targets}"
printf 'memory=%s\n' "${memory}"
printf 'apk_timeout=%s\n' "${apk_timeout}"
printf 'services_disabled=%s\n' "${services_disabled}"
printf 'limits=%s\n' "${limits}"
