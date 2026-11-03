#!/usr/bin/env sh
# Responsibility: derive, from every packages/<name>/config.yml of this
# repository, the lists that the daily refresh of the SDK and Image Builder
# images (refresh-images.yml) passes to the reusable base, printed as
# KEY=value lines: the union of the lines, of the image profiles and of the
# QEMU test targets of all the packages. Each config is read and validated by
# scripts/images/config.sh. Nothing is printed unless every config is valid, so
# the output is safe for $GITHUB_OUTPUT. A profile appears once, without its
# :too-big suffix (the Image Builder is the same). `targets` is empty when any
# package leaves its targets to the base default (all of them), because the
# base then needs the architectures of all the targets.
#
# Usage:
#   scripts/images/refresh-config.sh >> "$GITHUB_OUTPUT"
#
# Environment variables:
#   PACKAGES_DIR     directory with <name>/config.yml (default: packages)
#   BASE_LINES_FILE  harness/lines.yml of the base (see config.sh)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

dir=${PACKAGES_DIR:-packages}
all_lines=
all_profiles=
all_targets=
any_default_targets=false
count=0
for config in "${dir}"/*/config.yml; do
	[ -f "${config}" ] || die "no packages/<name>/config.yml in ${dir}"
	name=$(basename "$(dirname "${config}")")
	out=$("${script_dir}/config.sh" "${name}") || die "cannot read ${config}"
	got_lines=$(printf '%s\n' "${out}" | sed -n -e 's/^lines=//p')
	got_profiles=$(printf '%s\n' "${out}" | sed -n -e 's/^profiles=//p')
	got_targets=$(printf '%s\n' "${out}" | sed -n -e 's/^targets=//p')
	all_lines="${all_lines} ${got_lines}"
	all_profiles="${all_profiles} ${got_profiles}"
	if [ -n "${got_targets}" ]; then
		all_targets="${all_targets} ${got_targets}"
	else
		any_default_targets=true
	fi
	count=$((count + 1))
done
[ "${count}" -ge 1 ] || die "no package in ${dir}"
[ -n "${all_lines# }" ] || die "no line in any package"

# Print the words of the argument once each, in the order of first appearance.
#
# Arguments:
#   $1  words, separated by spaces
unique_words() {
	printf '%s\n' "$1" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed -e 's/ $//'
}

targets=
if [ "${any_default_targets}" = false ]; then
	targets=$(unique_words "${all_targets}")
fi
profiles=$(unique_words "$(printf '%s\n' "${all_profiles}" | sed -e 's/:too-big//g')")
printf 'lines=%s\n' "$(unique_words "${all_lines}")"
printf 'profiles=%s\n' "${profiles}"
printf 'targets=%s\n' "${targets}"
