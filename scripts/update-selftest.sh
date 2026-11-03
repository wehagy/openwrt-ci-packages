#!/usr/bin/env sh
# Responsibility: self-test of the shell side of the update workflow with fixed
# inputs: the validators of lib/common.sh (above all, that the review
# repository can never be a repository of the organization openwrt), the
# version comparison, the expansion of the source URL, the Makefile bump and
# check-config.sh, then flow-selftest.sh and overlay-selftest.sh. Every case runs; the script fails at the end if one failed.
# Needs yq (check-config.sh). A rejected value is never printed.
#
# Usage:
#   scripts/update-selftest.sh
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/selftest.sh
. "${script_dir}/lib/selftest.sh"

# Run a validator of lib/common.sh in a subshell (die exits it) and check that
# it accepts or rejects the value. The value is not printed.
#
# Arguments:
#   $1  validator function
#   $2  accept or reject
#   $3  value
#   $4  case label
validator_case() {
	vc_rc=0
	vc_out=$("$1" "$3" 2>&1) || vc_rc=$?
	case "$2:${vc_rc}" in
	accept:0 | reject:1) record "$1 $2 $4" 0 "" ;;
	*) record "$1 $2 $4" 1 "exit ${vc_rc}: ${vc_out}" ;;
	esac
}

# Check that version_cmp finds the first version newer (yes) or not (no).
#
# Arguments:
#   $1  yes or no
#   $2  version
#   $3  version
gt_case() {
	gc_out=$(version_cmp "$2" "$3")
	case "$1:${gc_out}" in
	yes:gt | no:eq | no:lt) record "version_cmp $2 $3 is $1 newer" 0 "" ;;
	*) record "version_cmp $2 $3 is $1 newer" 1 "${gc_out}" ;;
	esac
}

nl='
'

# --- the review repository: never openwrt ----------------------------------
validator_case check_review_repository accept 'wehagy/w' "wehagy/w"
validator_case check_review_repository accept 'wehagy/packages' "wehagy/packages"
validator_case check_review_repository accept 'A-b/c.d_e-f' "mixed characters"
validator_case check_review_repository reject 'openwrt/packages' "openwrt/packages"
validator_case check_review_repository reject 'OpenWrt/Packages' "OpenWrt/Packages"
validator_case check_review_repository reject 'OPENWRT/packages' "OPENWRT/packages"
validator_case check_review_repository reject 'openwrt/openwrt' "another repository of openwrt"
validator_case check_review_repository reject 'openwrt/w' "any repository of openwrt"
validator_case check_review_repository reject '' "empty"
validator_case check_review_repository reject 'wehagy' "no slash"
validator_case check_review_repository reject 'a/b/c' "three components"
validator_case check_review_repository reject '/w' "empty owner"
validator_case check_review_repository reject 'wehagy/' "empty name"
validator_case check_review_repository reject '-a/b' "leading dash in the owner"
validator_case check_review_repository reject 'a/-b' "leading dash in the name"
validator_case check_review_repository reject 'a/..' "dot dot name"
validator_case check_review_repository reject 'a/.' "dot name"
validator_case check_review_repository reject 'a/b.git' "name ending in .git"
validator_case check_review_repository reject 'a b/c' "space"
validator_case check_review_repository reject "wehagy/w${nl}::error::x" "newline and a workflow command"
validator_case check_review_repository reject "openwrt${nl}x/w" "newline in the owner"
validator_case check_review_repository reject 'wehagy/w?x' "query character"

# --- other validators -------------------------------------------------------
validator_case check_version accept '0.82.0' "0.82.0"
validator_case check_version accept '1.2.3' "1.2.3"
validator_case check_version reject 'v0.82.0' "v prefix"
validator_case check_version reject '0.82' "two parts"
validator_case check_version reject '0.82.0-rc.1' "pre-release"
validator_case check_version reject '1.2.3.4' "four parts"
validator_case check_version reject '' "empty"
validator_case check_version reject '.1.2' "leading dot"
validator_case check_version reject '1..2' "empty part"
validator_case check_version reject '1234567.0.0' "seven digits"
validator_case check_version reject "1.2.3${nl}4" "newline"
validator_case check_package accept 'netbird' "netbird"
validator_case check_package reject 'Net' "upper case"
validator_case check_package reject '../x' "path"
validator_case check_package_path accept 'net/netbird' "net/netbird"
validator_case check_package_path reject '../netbird' "dot dot"
validator_case check_package_path reject '/net/netbird' "absolute"
validator_case check_package_path reject 'netbird' "no section"
validator_case check_package_path reject 'net//netbird' "doubled slash"
validator_case check_package_path reject 'net/./netbird' "dot component"
validator_case check_branch accept 'master' "master"
validator_case check_branch accept 'ci/netbird-update-0.82.0' "update branch"
validator_case check_branch reject '-x' "leading dash"
validator_case check_branch reject 'a..b' "dot dot"
validator_case check_branch reject 'a b' "space"
validator_case check_branch reject 'a/' "trailing slash"
validator_case check_upstream_repository accept 'netbirdio/netbird' "netbirdio/netbird"
validator_case check_upstream_repository reject 'netbirdio' "no slash"
validator_case check_upstream_repository reject '-a/b' "leading dash"

# --- version order ----------------------------------------------------------
gt_case yes 0.82.0 0.81.4
gt_case yes 0.81.5 0.81.4
gt_case no 0.81.4 0.81.4
gt_case no 0.81.3 0.81.4
gt_case yes 0.10.0 0.9.0
gt_case no 0.9.0 0.10.0
gt_case yes 1.0.0 0.99.99
gt_case yes 0.08.1 0.7.9

# --- Makefile fixtures ------------------------------------------------------
cat >"${work}/Makefile" <<'MK'
include $(TOPDIR)/rules.mk

PKG_NAME:=netbird
PKG_VERSION:=0.81.4
PKG_RELEASE:=3

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/netbirdio/netbird/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=c735ffec7dece473e61c8764fec7a5cb971bacc766620e9639c97c9a249bbcbb

PKG_LICENSE:=BSD-3-Clause
MK
want_url='https://codeload.github.com/netbirdio/netbird/tar.gz/v0.82.0?netbird-0.82.0.tar.gz'
got_url=$("${script_dir}/source-sha256.sh" --url "${work}/Makefile" 0.82.0 2>&1) || got_url="exit $?: ${got_url}"
if [ "${got_url}" = "${want_url}" ]; then
	record "source-sha256 expands the URL" 0 ""
else
	record "source-sha256 expands the URL" 1 "${got_url}"
fi
sed "s|^PKG_SOURCE_URL:=.*|PKG_SOURCE_URL:=https://x.example/\$(UNKNOWN)/\$(PKG_VERSION)|" "${work}/Makefile" >"${work}/Makefile.unknown"
status_case "source-sha256 refuses an unknown variable" 1 \
	"${script_dir}/source-sha256.sh" --url "${work}/Makefile.unknown" 0.82.0
sed 's|^PKG_SOURCE_URL:=https|PKG_SOURCE_URL:=http|' "${work}/Makefile" >"${work}/Makefile.http"
status_case "source-sha256 refuses a plain http URL" 1 \
	"${script_dir}/source-sha256.sh" --url "${work}/Makefile.http" 0.82.0

new_hash=$(printf 'x' | sha256sum)
new_hash=${new_hash%% *}
cp "${work}/Makefile" "${work}/bumped"
status_case "bump-package runs" 0 "${script_dir}/bump-package.sh" "${work}/bumped" 0.82.0 "${new_hash}"
changed=$(diff -U0 "${work}/Makefile" "${work}/bumped" | grep -c '^+[^+]') || changed=0
if [ "${changed}" -eq 3 ]; then
	record "bump-package changes exactly PKG_VERSION, PKG_RELEASE and PKG_HASH" 0 ""
else
	record "bump-package changes exactly PKG_VERSION, PKG_RELEASE and PKG_HASH" 1 "${changed} lines changed"
fi
if grep -q '^PKG_RELEASE:=1$' "${work}/bumped" && grep -q "^PKG_HASH:=${new_hash}\$" "${work}/bumped"; then
	record "bump-package resets PKG_RELEASE and sets PKG_HASH" 0 ""
else
	record "bump-package resets PKG_RELEASE and sets PKG_HASH" 1 "unexpected content"
fi
status_case "bump-package refuses a short hash" 1 "${script_dir}/bump-package.sh" "${work}/Makefile" 0.82.0 abc
status_case "bump-package refuses a v prefix" 1 "${script_dir}/bump-package.sh" "${work}/Makefile" v0.82.0 "${new_hash}"
{
	cat "${work}/Makefile"
	echo 'PKG_HASH:=abc'
} >"${work}/Makefile.twice"
status_case "bump-package refuses a Makefile with PKG_HASH twice" 1 \
	"${script_dir}/bump-package.sh" "${work}/Makefile.twice" 0.82.0 "${new_hash}"

# --- check-config.sh --------------------------------------------------------
write_config() {
	cat >"${work}/config.yml" <<CFG
package: netbird
package_path: net/netbird
upstream_repository: netbirdio/netbird
review_repository: $1
review_branch: master
CFG
}
write_config wehagy/w
status_case "check-config accepts wehagy/w" 0 "${script_dir}/check-config.sh" "${work}/config.yml"
write_config openwrt/packages
status_case "check-config refuses openwrt/packages" 1 "${script_dir}/check-config.sh" "${work}/config.yml"
# Nothing may be printed for a refused configuration.
out=$("${script_dir}/check-config.sh" "${work}/config.yml" 2>/dev/null) || out=${out:-}
if [ -z "${out}" ]; then
	record "check-config prints nothing for a refused configuration" 0 ""
else
	record "check-config prints nothing for a refused configuration" 1 "printed output"
fi
write_config wehagy/w
sed -i 's|^package_path:.*|package_path: net/other|' "${work}/config.yml"
status_case "check-config refuses a package_path of another package" 1 "${script_dir}/check-config.sh" "${work}/config.yml"
write_config wehagy/w
sed -i '/^review_repository:/d' "${work}/config.yml"
status_case "check-config refuses a missing review_repository" 1 "${script_dir}/check-config.sh" "${work}/config.yml"

# --- the flows with stubs of curl, gh and git -------------------------------
# A child process with its own counters: its failure fails this script too.
flow_rc=0
"${script_dir}/flow-selftest.sh" || flow_rc=$?
record "flow-selftest.sh" "${flow_rc}" "see the FAIL lines above"
overlay_rc=0
"${script_dir}/overlay-selftest.sh" || overlay_rc=$?
record "overlay-selftest.sh" "${overlay_rc}" "see the FAIL lines above"

finish
