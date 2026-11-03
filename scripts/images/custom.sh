#!/usr/bin/env sh
# Responsibility: turn the web form of .github/workflows/custom-image.yml into
# what its jobs pass to the reusable base: the line, the profile, the package
# list and the source of the package tree. Every value is validated before
# anything is printed, so the output is safe for $GITHUB_OUTPUT; a bad
# combination fails with a message that says what to change.
#
# Rules:
#   profile      a configured profile (<target>/<subtarget>/<profile>) or
#                `other`, which takes other_profile; other_profile with a
#                configured profile is refused (it would be ignored).
#   packages     the images.packages of the package's config.yml (when a
#                package is given) followed by the form's packages (additions
#                and -removals, Image Builder syntax).
#   line         a line of the base (harness/lines.yml); with a package, one of
#                the lines of its config.yml. The form lists the lines it knows
#                (a GitHub form cannot read files); this check is what refuses
#                a line the package does not have.
#   package      empty: images without a package of ours. Otherwise a package
#                of this repository (packages/<name>/config.yml).
#   pr_number    a pull request of openwrt/packages, built or overlaid (see
#                scripts/images/pr-source.sh); needs a package.
#   feed_repository, feed_ref
#                a branch of a fork or another tree, passed to build.yml;
#                needs a package and excludes pr_number.
# Output: line, profile, package, packages, limit (bytes, empty if unknown),
# source_mode (default, fork or pr), pr_number, feed_repository, feed_ref.
#
# Usage:
#   scripts/images/custom.sh >> "$GITHUB_OUTPUT"
#
# Environment variables (the form fields):
#   LINE, PROFILE, OTHER_PROFILE, PACKAGES, PACKAGE, PR_NUMBER,
#   FEED_REPOSITORY, FEED_REF
#   PACKAGES_DIR  directory with <name>/config.yml (default: packages)
#   BASE_LINES_FILE  harness/lines.yml of the base (default:
#                 ci-base/harness/lines.yml)

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/lib/lines.sh
. "${script_dir}/../lib/lines.sh"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

line=${LINE:-}
profile_choice=${PROFILE:-}
other_profile=${OTHER_PROFILE:-}
user_packages=${PACKAGES:-}
package=${PACKAGE:-}
pr_number=${PR_NUMBER:-}
feed_repository=${FEED_REPOSITORY:-}
feed_ref=${FEED_REF:-}

# Strip the whitespace that a web form leaves around a value.
#
# Arguments:
#   $1  value
trim() {
	printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
other_profile=$(trim "${other_profile}")
package=$(trim "${package}")
pr_number=$(trim "${pr_number}")
feed_repository=$(trim "${feed_repository}")
feed_ref=$(trim "${feed_ref}")

# ---------------------------------------------------------------------------
# Line and profile.
# ---------------------------------------------------------------------------
# The line is checked against the package's lines further down (once the
# package is known); here only that it is a line name at all.
check_line_name "${line}"
case "${profile_choice}" in
other)
	[ -n "${other_profile}" ] || die "profile is other: fill other_profile with <target>/<subtarget>/<profile>, e.g. ipq40xx/generic/glinet_gl-b1300"
	case "${other_profile}" in
	*[!A-Za-z0-9_/-]* | '' | */*/*/* | /* | */ | *//*) die "other_profile must be <target>/<subtarget>/<profile> (letters, digits, _ and -)" ;;
	*/*/*) ;;
	*) die "other_profile must be <target>/<subtarget>/<profile> (letters, digits, _ and -)" ;;
	esac
	profile=${other_profile}
	;;
*)
	[ -z "${other_profile}" ] || die "other_profile is only used when profile is other; clear it or choose other"
	case "${profile_choice}" in
	*[!A-Za-z0-9_/-]* | '' | */*/*/* | /* | */ | *//*) die "profile must be one of the choices of the form" ;;
	*/*/*) ;;
	*) die "profile must be one of the choices of the form" ;;
	esac
	profile=${profile_choice}
	;;
esac

# ---------------------------------------------------------------------------
# Source of the package tree.
# ---------------------------------------------------------------------------
if [ -n "${pr_number}" ] && { [ -n "${feed_repository}" ] || [ -n "${feed_ref}" ]; }; then
	die "pr_number and feed_repository/feed_ref are mutually exclusive: give a pull request of openwrt/packages or a branch of another repository, not both"
fi
source_mode=default
if [ -n "${pr_number}" ]; then
	source_mode="pr"
	case "${pr_number}" in
	*[!0-9]* | 0*) die "pr_number must be a positive integer (digits only, no leading zero)" ;;
	*) ;;
	esac
	[ "${#pr_number}" -le 7 ] || die "pr_number has more than 7 digits"
elif [ -n "${feed_repository}${feed_ref}" ]; then
	source_mode=fork
fi
if [ "${source_mode}" != default ] && [ -z "${package}" ]; then
	die "a pull request or feed branch is the source of the package, so package must name it (e.g. netbird)"
fi

# ---------------------------------------------------------------------------
# Package and packages.
# ---------------------------------------------------------------------------
config_packages=
limit=
lines_check_file
if [ -z "${package}" ]; then
	# No package of ours: any line of the base will do.
	branch_for_line "${line}" >/dev/null
else
	cfg=$("${script_dir}/config.sh" "${package}")
	package_lines=$(printf '%s\n' "${cfg}" | sed -n -e 's/^lines=//p')
	case " ${package_lines} " in
	*" ${line} "*) ;;
	*) die "line ${line} is not a line of ${package} (its lines: ${package_lines}): choose one of them, or add the line to packages/${package}/config.yml" ;;
	esac
	config_packages=$(printf '%s\n' "${cfg}" | sed -n -e 's/^packages=//p')
	limits=$(printf '%s\n' "${cfg}" | sed -n -e 's/^limits=//p')
	# limits is "<profile> <bytes>" pairs; the profile has no :too-big suffix.
	limit=$(printf '%s' "${limits}" | awk -v p="${profile}" '{ for (i = 1; i < NF; i += 2) if ($i == p) print $(i + 1) }') ||
		die "cannot read the limits"
fi
# Whitespace of the form (newlines) becomes single spaces; the base checks
# the syntax of every token again.
user_packages=$(printf '%s' "${user_packages}" | tr '\n\t\r' '   ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')
packages=$(printf '%s %s' "${config_packages}" "${user_packages}" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')
case "${packages}" in
*[!a-z0-9._+\ -]*) die "packages: allowed are package names [a-z0-9][a-z0-9._+-]*, optionally with a leading - to remove one, separated by spaces" ;;
*) ;;
esac

printf 'line=%s\n' "${line}"
printf 'profile=%s\n' "${profile}"
printf 'package=%s\n' "${package}"
printf 'packages=%s\n' "${packages}"
printf 'limit=%s\n' "${limit}"
printf 'source_mode=%s\n' "${source_mode}"
printf 'pr_number=%s\n' "${pr_number}"
printf 'feed_repository=%s\n' "${feed_repository}"
printf 'feed_ref=%s\n' "${feed_ref}"
