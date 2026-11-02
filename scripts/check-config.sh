#!/usr/bin/env sh
# Responsibility: read packages/<name>/config.yml, validate every key the
# update workflow uses and print them as KEY=value lines. Nothing is printed
# unless all keys are valid, so the output is safe for $GITHUB_OUTPUT. The key
# review_repository is the single setting that names where branches are pushed
# and the draft pull request is opened; the owner openwrt is refused.
#
# Usage:
#   scripts/check-config.sh packages/netbird/config.yml >> "$GITHUB_OUTPUT"
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

[ "$#" -eq 1 ] || die "usage: check-config.sh <config.yml>"
config=$1

package=$(config_get "${config}" package)
package_path=$(config_get "${config}" package_path)
upstream_repository=$(config_get "${config}" upstream_repository)
review_repository=$(config_get "${config}" review_repository)
review_branch=$(config_get "${config}" review_branch)

check_package "${package}"
check_package_path "${package_path}"
[ "${package_path##*/}" = "${package}" ] || die "package_path must end with the package name"
check_upstream_repository "${upstream_repository}"
check_review_repository "${review_repository}"
check_branch "${review_branch}"

printf 'package=%s\n' "${package}"
printf 'package_path=%s\n' "${package_path}"
printf 'upstream_repository=%s\n' "${upstream_repository}"
printf 'review_repository=%s\n' "${review_repository}"
printf 'review_branch=%s\n' "${review_branch}"
