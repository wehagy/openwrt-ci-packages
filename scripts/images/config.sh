#!/usr/bin/env sh
# Responsibility: read packages/<name>/config.yml of this repository and print
# what the workflows pass to the reusable base wehagy/openwrt-ci as KEY=value
# lines (package, profiles, packages, targets, memory, limits). Nothing is
# printed unless the file and every value in it are well formed, so the output
# is safe for $GITHUB_OUTPUT. The base validates the same values again with
# its own rules; this check keeps a typo from reaching a run.
#
# profiles, packages and targets are single lines of space separated words;
# `memory` and `targets` are empty when the config does not set them (the base
# defaults then apply). `limits` is "<profile> <bytes>" pairs separated by
# spaces.
#
# Usage:
#   scripts/images/config.sh <package> >> "$GITHUB_OUTPUT"
#
# Environment variables:
#   PACKAGES_DIR  directory with <name>/config.yml (default: packages)

set -eu

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
profiles=$(value '.images.profiles // [] | join(" ")')
packages=$(value '.images.packages')
targets=$(value .targets)
memory=$(value .memory)
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
case "${memory}" in
*[!0-9M]*) die "${config}: memory must be NNNM, e.g. 256M" ;;
*) ;;
esac

printf 'package=%s\n' "${name}"
printf 'profiles=%s\n' "${profiles}"
printf 'packages=%s\n' "${packages}"
printf 'targets=%s\n' "${targets}"
printf 'memory=%s\n' "${memory}"
printf 'limits=%s\n' "${limits}"
