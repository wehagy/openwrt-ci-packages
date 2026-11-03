#!/usr/bin/env sh
# Responsibility: prove, with fixed inputs and no network, the scripts that
# turn the configuration and the web form of custom-image.yml into inputs of
# the reusable base: scripts/images/config.sh (reads packages/<name>/config.yml
# and refuses a bad one), custom.sh (the form: profile choice, other_profile,
# source exclusivity, package list, device limit), pr-source.sh (head or
# overlay of a pull request), summary.sh (source, overlay, size against the
# limit, installed packages) and upstream-pr/cleanup.sh (refuses a branch that
# is not an overlay branch). It also checks that the workflows agree with the
# configuration: the profile choices of custom-image.yml are the profiles of
# packages/netbird/config.yml, and every call of the base uses the same ref in
# `uses:` and `ci_ref`. Runs every case and fails at the end if one failed.
# Needs yq and jq.
#
# Usage: scripts/images/selftest.sh   (run from the root of the repository)
# Environment variables: none.

set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "${here}/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
failed=0
total=0

# Reports one case. Arguments: $1 name, $2 "ok" or a reason.
report() {
	total=$((total + 1))
	if [ "$2" = ok ]; then
		echo "ok   $1"
	else
		echo "FAIL $1: $2"
		failed=$((failed + 1))
	fi
}

# Run a command with stdout in ${work}/out and stderr in ${work}/err; sets rc.
#
# Arguments: the command.
run() {
	rc=0
	"$@" >"${work}/out" 2>"${work}/err" || rc=$?
	out_text=$(cat "${work}/out")
	err_text=$(cat "${work}/err")
	stub_text=
	if [ -f "${work}/stub.log" ]; then
		stub_text=$(cat "${work}/stub.log")
	fi
}

# The command must succeed and its stdout must contain the line.
# Arguments: $1 case name, $2 line, rest the command.
expect_line() {
	name=$1
	want=$2
	shift 2
	run "$@"
	if [ "${rc}" -ne 0 ]; then
		report "${name}" "exit ${rc}: ${err_text}"
	elif grep -qxF -- "${want}" "${work}/out"; then
		report "${name}" ok
	else
		report "${name}" "no line '${want}' in: ${out_text}"
	fi
}

# The command must fail, print nothing on stdout and mention the text on stderr.
# Arguments: $1 case name, $2 text, rest the command.
expect_refused() {
	name=$1
	want=$2
	shift 2
	run "$@"
	if [ "${rc}" -eq 0 ]; then
		report "${name}" "succeeded: ${out_text}"
	elif [ -s "${work}/out" ]; then
		report "${name}" "printed on stdout: ${out_text}"
	elif grep -qF -- "${want}" "${work}/err"; then
		report "${name}" ok
	else
		report "${name}" "stderr lacks '${want}': ${err_text}"
	fi
}

# ---------------------------------------------------------------------------
# config.sh
# ---------------------------------------------------------------------------
cfg=${here}/config.sh
# The lines of the base: a stub with a FAKE third line, so that the tests do not
# depend on the real base (scripts/stubs/lines.yml: main, 25.12, 26.12).
export BASE_LINES_FILE="${root}/scripts/stubs/lines.yml"
# The real configuration only has to be readable; the values are checked on a
# fixture, so that a throwaway config (a proof branch) does not break this test.
export PACKAGES_DIR="${root}/packages"
expect_line "config: the real netbird config is readable" "package=netbird" "${cfg}" netbird
fx=${work}/fx
mkdir -p "${fx}/netbird"
cat >"${fx}/netbird/config.yml" <<'EOF'
package: netbird
lines: [main, "25.12"]
memory: 256M
apk_timeout: 120
services_disabled: [socat, ssh-agent]
images:
  packages: luci-app-attendedsysupgrade luci-app-uhttpd luci-ssl owut
  profiles:
    - x86/64/generic
    - ath79/generic/tplink_archer-c7-v4:too-big
    - ramips/mt7621/glinet_gl-mt1300
  limits:
    ramips/mt7621/glinet_gl-mt1300: 33226752
EOF
export PACKAGES_DIR="${fx}"
expect_line "config: package" "package=netbird" "${cfg}" netbird
expect_line "config: extra packages" "packages=luci-app-attendedsysupgrade luci-app-uhttpd luci-ssl owut" "${cfg}" netbird
expect_line "config: memory override" "memory=256M" "${cfg}" netbird
expect_line "config: apk timeout" "apk_timeout=120" "${cfg}" netbird
expect_line "config: services disabled by default" "services_disabled=socat ssh-agent" "${cfg}" netbird
expect_line "config: no targets means the base default" "targets=" "${cfg}" netbird
expect_line "config: limits" "limits=ramips/mt7621/glinet_gl-mt1300 33226752" "${cfg}" netbird
expect_line "config: profiles keep :too-big" "profiles=x86/64/generic ath79/generic/tplink_archer-c7-v4:too-big ramips/mt7621/glinet_gl-mt1300" "${cfg}" netbird
expect_refused "config: unknown package" "is not a package of this repository" "${cfg}" nope
expect_refused "config: invalid package name" "invalid package name" "${cfg}" 'Net;bird'
expect_refused "config: no argument" "usage" "${cfg}"

export PACKAGES_DIR="${work}/pk"
mkdir -p "${PACKAGES_DIR}/a" "${PACKAGES_DIR}/b" "${PACKAGES_DIR}/c" "${PACKAGES_DIR}/d" "${PACKAGES_DIR}/e" "${PACKAGES_DIR}/f"
printf 'package: a\nlines: [main]\n' >"${PACKAGES_DIR}/a/config.yml"
printf 'package: other\nlines: [main]\n' >"${PACKAGES_DIR}/b/config.yml"
printf 'package: c\nlines: [main]\nimages:\n  profiles:\n    - "x86/64/generic;id"\n' >"${PACKAGES_DIR}/c/config.yml"
printf 'package: d\nlines: [main]\nmemory: 2G\n' >"${PACKAGES_DIR}/d/config.yml"
printf 'package: f\nlines: [main]\napk_timeout: 2m\n' >"${PACKAGES_DIR}/f/config.yml"
mkdir -p "${PACKAGES_DIR}/g"
printf 'package: g\nlines: [main]\nservices_disabled: ["a/b"]\n' >"${PACKAGES_DIR}/g/config.yml"
printf 'package: e\nlines: [main]\ntargets: "x86-64\\n::error::x"\n' >"${PACKAGES_DIR}/e/config.yml"
expect_line "config: a package with no images or overrides: empty profiles" "profiles=" "${cfg}" a
expect_line "config: a package with no overrides: empty memory" "memory=" "${cfg}" a
expect_refused "config: package key differs from the directory" "package is not b" "${cfg}" b
expect_refused "config: character outside the allowed set in profiles" "profiles has a character" "${cfg}" c
expect_line "config: no apk_timeout means the labgrid default" "apk_timeout=" "${cfg}" a
expect_line "config: no services_disabled means none" "services_disabled=" "${cfg}" a
expect_refused "config: service name with a slash" "services_disabled has a character" "${cfg}" g
expect_refused "config: invalid apk_timeout" "apk_timeout must be whole seconds" "${cfg}" f
for pair in h:29 i:600 j:601 k:029; do
	n=${pair%%:*}
	v=${pair#*:}
	mkdir -p "${PACKAGES_DIR}/${n}"
	printf 'package: %s\nlines: [main]\napk_timeout: %s\n' "${n}" "${v}" >"${PACKAGES_DIR}/${n}/config.yml"
done
expect_refused "config: apk_timeout below 30 s" "apk_timeout must be whole seconds from 30 to 600" "${cfg}" h
expect_line "config: apk_timeout 600 is the ceiling" "apk_timeout=600" "${cfg}" i
expect_refused "config: apk_timeout above 600 s" "apk_timeout must be whole seconds from 30 to 600" "${cfg}" j
expect_refused "config: apk_timeout with a leading zero" "apk_timeout must be whole seconds from 30 to 600" "${cfg}" k
for pair in m:32M n:64M o:1024M p:1025M q:2048M r:0256M s:256 t:M u:99999M; do
	n=${pair%%:*}
	v=${pair#*:}
	mkdir -p "${PACKAGES_DIR}/${n}"
	printf 'package: %s\nlines: [main]\nmemory: %s\n' "${n}" "${v}" >"${PACKAGES_DIR}/${n}/config.yml"
done
expect_refused "config: memory below 64M" "memory must be NNNM from 64M to 1024M" "${cfg}" m
expect_line "config: memory 64M is the floor" "memory=64M" "${cfg}" n
expect_line "config: memory 1024M is the ceiling" "memory=1024M" "${cfg}" o
expect_refused "config: memory above 1024M" "memory must be NNNM from 64M to 1024M" "${cfg}" p
expect_refused "config: memory 2048M" "memory must be NNNM from 64M to 1024M" "${cfg}" q
expect_refused "config: memory with a leading zero" "memory must be NNNM from 64M to 1024M" "${cfg}" r
expect_refused "config: memory without the M" "memory must be NNNM from 64M to 1024M" "${cfg}" s
expect_refused "config: memory M alone" "memory must be NNNM from 64M to 1024M" "${cfg}" t
expect_refused "config: memory with five digits" "memory must be NNNM from 64M to 1024M" "${cfg}" u
expect_refused "config: invalid memory" "memory must be NNNM" "${cfg}" d
expect_refused "config: newline in a value cannot forge a command" "targets has a character" "${cfg}" e

# --- the lines of a package: all from its config.yml and the base's lines.yml ---
# Arguments: $1 package (a directory under ${PACKAGES_DIR}), $2 the text of its
# `lines:` key (a line of YAML), or nothing for a config without the key.
mkpkg() {
	mkdir -p "${PACKAGES_DIR}/$1"
	if [ "$#" -ge 2 ]; then
		printf 'package: %s\n%s\n' "$1" "$2" >"${PACKAGES_DIR}/$1/config.yml"
	else
		printf 'package: %s\n' "$1" >"${PACKAGES_DIR}/$1/config.yml"
	fi
}
mkpkg two 'lines: [main, "25.12"]'
expect_line "lines: two lines, in the order of the config" "lines=main 25.12" "${cfg}" two
expect_line "lines: the matrix of two lines" 'lines_json=["main","25.12"]' "${cfg}" two
expect_line "lines: the reference line is the one on master" "reference=main" "${cfg}" two
expect_line "lines: the others" "others=25.12" "${cfg}" two
expect_line "lines: the others as JSON" 'others_json=["25.12"]' "${cfg}" two
# A new line is added by editing this one list (and the base): three lines.
mkpkg three 'lines: [main, "25.12", "26.12"]'
expect_line "lines: three lines in the matrix" 'lines_json=["main","25.12","26.12"]' "${cfg}" three
expect_line "lines: three lines, two of them not the reference" 'others_json=["25.12","26.12"]' "${cfg}" three
# The old line goes by deleting it from the list.
mkpkg dropped 'lines: [main, "26.12"]'
expect_line "lines: dropping 25.12 leaves the others" "lines=main 26.12" "${cfg}" dropped
expect_line "lines: dropping 25.12, the others as JSON" 'others_json=["26.12"]' "${cfg}" dropped
mkpkg order 'lines: ["26.12", main, "25.12"]'
expect_line "lines: the reference need not be first" "reference=main" "${cfg}" order
expect_line "lines: the others keep the order of the config" "others=26.12 25.12" "${cfg}" order
mkpkg only 'lines: [main]'
expect_line "lines: a package with only the reference line" 'others_json=[]' "${cfg}" only
expect_line "lines: SELECT_LINES narrows the matrix" 'lines_json=["26.12"]' env SELECT_LINES=26.12 "${cfg}" three
expect_line "lines: SELECT_LINES keeps the order of the config" "lines=main 26.12" env "SELECT_LINES=26.12 main" "${cfg}" three
expect_refused "lines: SELECT_LINES with a line the package does not have" "is not a line of three" env SELECT_LINES=24.10 "${cfg}" three
mkpkg nolines
expect_refused "lines: missing key" "lines is required" "${cfg}" nolines
mkpkg scalar 'lines: main'
expect_refused "lines: not a list" "must be a list" "${cfg}" scalar
mkpkg empty 'lines: []'
expect_refused "lines: empty list" "lines is empty" "${cfg}" empty
mkpkg unknown 'lines: [main, "27.01"]'
expect_refused "lines: a line the base does not have" "names the line '27.01', which the base does not have" "${cfg}" unknown
mkpkg twice 'lines: [main, "25.12", "25.12"]'
expect_refused "lines: a line listed twice" "lists the line '25.12' twice" "${cfg}" twice
mkpkg noref 'lines: ["25.12", "26.12"]'
expect_refused "lines: the reference line is required" "does not list the reference line main" "${cfg}" noref
mkpkg number 'lines: [main, 26.10]'
expect_refused "lines: an unquoted number is refused" "must be a quoted string" "${cfg}" number
mkpkg spaced 'lines: [main, "26.10 26.1"]'
expect_refused "lines: one name with a space is not two lines" "invalid line name" "${cfg}" spaced
mkpkg glob 'lines: [main, "*"]'
expect_refused "lines: a glob character is not a line" "invalid line name" "${cfg}" glob
mkpkg multi 'lines: [main, "25.12\n26.12"]'
expect_refused "lines: a name with a newline is refused" "invalid line name" "${cfg}" multi
mkpkg blank 'lines: [main, ""]'
expect_refused "lines: an empty name is refused" "invalid line name" "${cfg}" blank
mkpkg lead 'lines: [main, " 25.12"]'
expect_refused "lines: a name with a leading space is refused" "invalid line name" "${cfg}" lead
# check_package_lines of lib/lines.sh on a list with a glob character, in a
# shell where globbing is on (config.sh turns it off): the word is no line, and
# it does not expand into the files of the directory.
expect_refused "lines.sh: a glob in a list is no line, with globbing on" "invalid line name" sh -ec ". \"${root}/scripts/lib/lines.sh\"; check_package_lines 'main *' list"
expect_refused "lines: SELECT_LINES with a glob is no line" "invalid line name" env 'SELECT_LINES=*' "${cfg}" two
expect_refused "lines: SELECT_LINES with a forged name" "invalid line name" env 'SELECT_LINES=main;id' "${cfg}" two
mkpkg forged 'lines: [main, "25.12;id"]'
expect_refused "lines: a forged name is refused" "invalid line name" "${cfg}" forged
expect_refused "lines: no base lines.yml" "lines.yml is not at" env BASE_LINES_FILE="${work}/missing.yml" "${cfg}" two
printf 'lines:\n  main:\n    packages_branch: other\n' >"${work}/noref-base.yml"
expect_refused "lines: a base with no line on master" "no line of the base has packages_branch master" env BASE_LINES_FILE="${work}/noref-base.yml" "${cfg}" two
printf 'lines:\n  main:\n    packages_branch: master\n  next:\n    packages_branch: master\n' >"${work}/dup-base.yml"
expect_refused "lines: a base with two lines on master" "reference line is ambiguous" env BASE_LINES_FILE="${work}/dup-base.yml" "${cfg}" two

# ---------------------------------------------------------------------------
# custom.sh (the form)
# ---------------------------------------------------------------------------
export PACKAGES_DIR="${fx}"
cu=${here}/custom.sh
# Run custom.sh with a form: the defaults are a valid form, "NAME=value"
# arguments override them.
#
# Arguments: overrides.
form() {
	env LINE=main PROFILE=x86/64/generic OTHER_PROFILE= PACKAGES= PACKAGE= PR_NUMBER= \
		FEED_REPOSITORY= FEED_REF= "$@" "${cu}"
}
expect_line "form: default line" "line=main" form
expect_line "form: default profile" "profile=x86/64/generic" form
expect_line "form: no package means no source" "source_mode=default" form
expect_line "form: no package, no config packages" "packages=" form
expect_line "form: user packages only" "packages=-dnsmasq dnsmasq-full" form "PACKAGES=-dnsmasq
dnsmasq-full"
expect_line "form: config packages and user packages" "packages=luci-app-attendedsysupgrade luci-app-uhttpd luci-ssl owut -dnsmasq dnsmasq-full" \
	form PACKAGE=netbird "PACKAGES=-dnsmasq dnsmasq-full"
expect_line "form: package" "package=netbird" form PACKAGE=netbird
expect_line "form: limit of a configured profile" "limit=33226752" form PACKAGE=netbird PROFILE=ramips/mt7621/glinet_gl-mt1300
expect_line "form: no limit when unknown" "limit=" form PACKAGE=netbird PROFILE=x86/64/generic
expect_line "form: other profile" "profile=ipq40xx/generic/glinet_gl-b1300" form PROFILE=other OTHER_PROFILE=ipq40xx/generic/glinet_gl-b1300
expect_line "form: whitespace around other_profile" "profile=ipq40xx/generic/glinet_gl-b1300" form PROFILE=other "OTHER_PROFILE= ipq40xx/generic/glinet_gl-b1300 "
expect_refused "form: other without other_profile" "fill other_profile" form PROFILE=other
expect_refused "form: other_profile with a configured profile" "only used when profile is other" form OTHER_PROFILE=ipq40xx/generic/glinet_gl-b1300
expect_refused "form: other_profile with two words" "other_profile must be" form PROFILE=other "OTHER_PROFILE=a/b/c d/e/f"
expect_refused "form: other_profile of two parts" "other_profile must be" form PROFILE=other OTHER_PROFILE=a/b
expect_refused "form: other_profile with a command" "other_profile must be" form PROFILE=other 'OTHER_PROFILE=a/b/c;id'
expect_refused "form: a line the base does not have" "the base has no line '24.10'" form LINE=24.10
expect_refused "form: a forged line" "invalid line name" form 'LINE=main;id'
expect_refused "form: a line the package does not have" "line 26.12 is not a line of netbird" form PACKAGE=netbird LINE=26.12
expect_line "form: a line of the package" "line=25.12" form PACKAGE=netbird LINE=25.12
# 26.12 is a line of the base and, with it in the list, of the package: nothing
# else changes (and 25.12 is refused when the package drops it).
mkdir -p "${work}/pk3/netbird" "${work}/pk4/netbird"
sed 's/^lines: .*/lines: [main, "25.12", "26.12"]/' "${fx}/netbird/config.yml" >"${work}/pk3/netbird/config.yml"
sed 's/^lines: .*/lines: [main, "26.12"]/' "${fx}/netbird/config.yml" >"${work}/pk4/netbird/config.yml"
expect_line "form: a third line in the config is accepted" "line=26.12" form "PACKAGES_DIR=${work}/pk3" PACKAGE=netbird LINE=26.12
expect_refused "form: a dropped line is refused" "line 25.12 is not a line of netbird (its lines: main 26.12)" form "PACKAGES_DIR=${work}/pk4" PACKAGE=netbird LINE=25.12
expect_refused "form: unknown package" "is not a package of this repository" form PACKAGE=nope
expect_refused "form: invalid packages text" "packages: allowed are" form 'PACKAGES=owut;id'
expect_line "form: pull request" "source_mode=pr" form PACKAGE=netbird PR_NUMBER=31059
expect_line "form: pull request number" "pr_number=31059" form PACKAGE=netbird PR_NUMBER=31059
expect_line "form: fork" "source_mode=fork" form PACKAGE=netbird FEED_REPOSITORY=wehagy/packages FEED_REF=my-branch
expect_line "form: fork ref alone" "feed_ref=my-branch" form PACKAGE=netbird FEED_REF=my-branch
expect_refused "form: pr_number with feed_ref" "mutually exclusive" form PACKAGE=netbird PR_NUMBER=31059 FEED_REF=my-branch
expect_refused "form: pr_number with feed_repository" "mutually exclusive" form PACKAGE=netbird PR_NUMBER=31059 FEED_REPOSITORY=wehagy/packages
expect_refused "form: pull request without a package" "package must name it" form PR_NUMBER=31059
expect_refused "form: fork without a package" "package must name it" form FEED_REF=my-branch
for n in abc 0 007 -1 1.5 12345678 '1 2'; do
	expect_refused "form: invalid pr_number '${n}'" "pr_number" form PACKAGE=netbird "PR_NUMBER=${n}"
done

# ---------------------------------------------------------------------------
# pr-source.sh
# ---------------------------------------------------------------------------
ps=${here}/pr-source.sh
sha=0123456789abcdef0123456789abcdef01234567
matrix='{"include":[{"package":"netbird","dir":"net/netbird","local":true},{"package":"curl","dir":"net/curl","local":false}]}'
# Arguments: overrides of the environment of pr-source.sh.
decide() {
	env LINE=25.12 PACKAGE=netbird PR_NUMBER=31059 PR_LINE=main HEAD_SHA="${sha}" \
		MATRIX_ALL="${matrix}" OVERLAY_DIRS="net/netbird net/curl" "$@" "${ps}"
}
expect_line "pr-source: PR to master on line 25.12 is an overlay" "overlay=true" decide
expect_line "pr-source: the overlay goes over the branch of the chosen line" "base_branch=openwrt-25.12" decide
expect_line "pr-source: an overlay has no feed of its own" "feed_ref=" decide
expect_line "pr-source: PR to master on line main builds the head" "overlay=false" decide LINE=main
expect_line "pr-source: the head is built from openwrt/packages" "feed_repository=openwrt/packages" decide LINE=main
expect_line "pr-source: the head is built as a commit" "feed_ref=${sha}" decide LINE=main
expect_line "pr-source: PR to openwrt-25.12 on line main is an overlay on master" "base_branch=master" decide PR_LINE=25.12 LINE=main
expect_line "pr-source: PR to openwrt-25.12 on line 25.12 builds the head" "overlay=false" decide PR_LINE=25.12
expect_line "pr-source: another changed package of the PR is accepted" "overlay=true" decide PACKAGE=curl
expect_refused "pr-source: the package is not changed by the PR" "does not change the package" decide PACKAGE=nginx
expect_refused "pr-source: the message lists what the PR changes" "netbird curl" decide PACKAGE=nginx
expect_refused "pr-source: invalid head sha" "invalid head sha" decide HEAD_SHA=zz
expect_refused "pr-source: invalid pr number" "pr_number" decide PR_NUMBER=abc
expect_refused "pr-source: unknown line" "the base has no line '24.10'" decide LINE=24.10
expect_line "pr-source: a third line overlays on its own branch" "base_branch=openwrt-26.12" decide LINE=26.12
expect_line "pr-source: PR to a third line's branch on that line builds the head" "overlay=false" decide LINE=26.12 PR_LINE=26.12

# ---------------------------------------------------------------------------
# summary.sh
# ---------------------------------------------------------------------------
sm=${here}/summary.sh
art=${work}/art
mkdir -p "${art}/images-netbird-25.12-glinet-gl-mt1300"
head -c 30000000 /dev/zero >"${art}/images-netbird-25.12-glinet-gl-mt1300/openwrt-sysupgrade.bin"
printf 'base-files - 1-r1\nnetbird - 0.78.1-r1\ndnsmasq-full - 2.91-r1\n' >"${art}/images-netbird-25.12-glinet-gl-mt1300/openwrt.manifest"
printf 'sum\n' >"${art}/images-netbird-25.12-glinet-gl-mt1300/sha256sums"
# Arguments: overrides of the environment of summary.sh.
summary() {
	env LINE=25.12 PROFILE=ramips/mt7621/glinet_gl-mt1300 PACKAGE=netbird PACKAGES="-dnsmasq dnsmasq-full" \
		LIMIT=33226752 SOURCE_MODE=default FEED_REPOSITORY=openwrt/packages FEED_REF=openwrt-25.12 \
		FEED_SHA="${sha}" IMAGE_RESULT=success "$@" "${sm}" "${art}"
}
expect_line "summary: size against the limit" "| openwrt-sysupgrade.bin | 30000000 | 90.29 % of 33226752 bytes, margin 3226752 bytes |" summary
expect_line "summary: over the limit" "| openwrt-sysupgrade.bin | 30000000 | 106.15 % of 28261000 bytes, OVER by 1739000 bytes |" summary LIMIT=28261000
expect_line "summary: limit unknown" "| openwrt-sysupgrade.bin | 30000000 | limit unknown (the Image Builder prints it only when the image does not fit) |" summary LIMIT=
expect_line "summary: installed packages are listed" "netbird - 0.78.1-r1" summary
expect_line "summary: manifest line count" "installed packages (openwrt.manifest, 3):" summary
expect_line "summary: the manifest is not listed as an image" "- result of the image job: success" summary
expect_line "summary: default source" "- source: the branch of openwrt/packages of line 25.12" summary
expect_line "summary: commit" "- commit: ${sha}" summary
expect_line "summary: no overlay" "- overlay: no" summary
expect_line "summary: pull request overlay" "- overlay: yes (the ref above is a temporary branch of this repository, deleted after the build)" \
	summary SOURCE_MODE=pr OVERLAY=true PR_NUMBER=31059 PR_LINE=main PR_HEAD_SHA=abc BASE_BRANCH=openwrt-25.12 OVERLAY_DIRS=net/netbird FEED_REPOSITORY=wehagy/openwrt-ci-packages FEED_REF=upstream-overlay/x
expect_line "summary: pull request overlay source" "- source: pull request openwrt/packages#31059 (base branch of line main, head abc) built on line 25.12 by overlay: its changed directories (net/netbird) copied over the branch openwrt-25.12" \
	summary SOURCE_MODE=pr OVERLAY=true PR_NUMBER=31059 PR_LINE=main PR_HEAD_SHA=abc BASE_BRANCH=openwrt-25.12 OVERLAY_DIRS=net/netbird
expect_line "summary: pull request head source" "- source: pull request openwrt/packages#31059, head abc, built as it is (its base branch is line main)" \
	summary SOURCE_MODE=pr OVERLAY=false PR_NUMBER=31059 PR_LINE=main PR_HEAD_SHA=abc
expect_line "summary: fork source" "- source: feed given by the form (feed_repository, feed_ref)" summary SOURCE_MODE=fork
expect_line "summary: no package" "- source: nothing was built (no package); the images use the official feed of line 25.12" summary PACKAGE=
# One artifact only: download-artifact puts its files directly in the path.
flat=${work}/flat
mkdir -p "${flat}"
cp "${art}"/images-netbird-25.12-glinet-gl-mt1300/* "${flat}/"
run env LINE=25.12 PROFILE=x LIMIT=33226752 IMAGE_RESULT=success "${sm}" "${flat}"
if [ "${rc}" -eq 0 ] && grep -qxF '| openwrt-sysupgrade.bin | 30000000 | 90.29 % of 33226752 bytes, margin 3226752 bytes |' "${work}/out" &&
	grep -qxF 'netbird - 0.78.1-r1' "${work}/out" && ! grep -q 'no image artifact' "${work}/out"; then
	report "summary: a single artifact downloaded without a subdirectory" ok
else
	report "summary: a single artifact downloaded without a subdirectory" "rc ${rc}: ${out_text}"
fi
run env LINE=25.12 PROFILE=x IMAGE_RESULT=failure "${sm}" "${work}/missing"
if [ "${rc}" -eq 0 ] && grep -q 'no image artifact' "${work}/out"; then
	report "summary: no artifact" ok
else
	report "summary: no artifact" "rc ${rc}: ${out_text}"
fi

# ---------------------------------------------------------------------------
# upstream-pr/cleanup.sh
# ---------------------------------------------------------------------------
cl=${root}/scripts/upstream-pr/cleanup.sh
mkdir -p "${work}/bin"
cat >"${work}/bin/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >>"${STUB_LOG}"
EOF
chmod +x "${work}/bin/gh"
: >"${work}/stub.log"
: >"${work}/summary.md"
cleanup() {
	env PATH="${work}/bin:${PATH}" STUB_LOG="${work}/stub.log" GITHUB_REPOSITORY=o/r GITHUB_STEP_SUMMARY="${work}/summary.md" "$@" "${cl}"
}
run cleanup BRANCH=main
if [ "${rc}" -ne 0 ] && grep -q "refusing to delete 'main'" "${work}/out" && [ ! -s "${work}/stub.log" ]; then
	report "cleanup: refuses a branch outside upstream-overlay/" ok
else
	report "cleanup: refuses a branch outside upstream-overlay/" "rc ${rc}, stub: ${stub_text}"
fi
run cleanup BRANCH=upstream-overlay/pr1-2-3
if [ "${rc}" -eq 0 ] && grep -qxF 'gh api -X DELETE repos/o/r/git/refs/heads/upstream-overlay/pr1-2-3' "${work}/stub.log"; then
	report "cleanup: deletes an overlay branch" ok
else
	report "cleanup: deletes an overlay branch" "rc ${rc}, stub: ${stub_text}"
fi

# ---------------------------------------------------------------------------
# The workflows agree with the configuration and with each other.
# ---------------------------------------------------------------------------
wf=${root}/.github/workflows/custom-image.yml
want=$(yq -r '.images.profiles[] | sub(":too-big$", "")' "${root}/packages/netbird/config.yml" | tr '\n' ' ')
have=$(yq -r '.on.workflow_dispatch.inputs.profile.options[]' "${wf}" | grep -vx other | tr '\n' ' ')
if [ -n "${want}" ] && [ "${want}" = "${have}" ]; then
	report "workflow: the profile choices are the configured profiles" ok
else
	report "workflow: the profile choices are the configured profiles" "config: ${want} / form: ${have}"
fi
last=$(yq -r '.on.workflow_dispatch.inputs.profile.options[-1]' "${wf}")
if [ "${last}" = other ]; then
	report "workflow: other is the last choice" ok
else
	report "workflow: other is the last choice" "last is ${last}"
fi
for f in line custom-image; do
	file=${root}/.github/workflows/${f}.yml
	uses=$(grep -o 'wehagy/openwrt-ci/\.github/workflows/[a-z]*\.yml@[^ ]*' "${file}" | sed 's/.*@//' | sort -u | tr '\n' ' ')
	cirefs=$(grep -o '^ *ci_ref: .*' "${file}" | sed 's/.*ci_ref: //' | sort -u | tr '\n' ' ')
	if [ -n "${uses}" ] && [ "${uses}" = "${cirefs}" ]; then
		report "workflow: ${f}.yml uses and ci_ref name the same ref (${uses% })" ok
	else
		report "workflow: ${f}.yml uses and ci_ref name the same ref" "uses: ${uses} / ci_ref: ${cirefs}"
	fi
done

# The `image` job of custom-image.yml must not run when the package was asked
# for but not built (source or compose failed, build skipped). The `if:` of the
# workflow is evaluated itself: its GitHub expression is turned into a jq
# expression (needs.X.result -> .needs.X.result, && -> and, ...).
#
# Arguments:
#   $1  case name
#   $2  expected: run or skip
#   $3  result of config
#   $4  package output of config
#   $5  result of build
image_case() {
	ic_expr=$(yq -r '.jobs.image.if' "${wf}" | tr '\n' ' ' |
		sed -e 's/\${{//' -e 's/}}//' -e 's/!cancelled()/true/g' \
			-e 's/&&/ and /g' -e 's/||/ or /g' -e "s/'/\"/g" -e 's/needs\./.needs./g')
	ic_ctx=$(jq -n -c --arg c "$3" --arg p "$4" --arg b "$5" \
		'{needs: {config: {result: $c, outputs: {package: $p}}, build: {result: $b}}}')
	ic_got=$(jq -n --argjson ctx "${ic_ctx}" "\$ctx | (${ic_expr}) | if . then \"run\" else \"skip\" end" -r 2>&1)
	if [ "${ic_got}" = "$2" ]; then
		report "workflow: image job $1" ok
	else
		report "workflow: image job $1" "got '${ic_got}', expected '$2' (expression: ${ic_expr})"
	fi
}
# image_case turns `!cancelled()` into true to evaluate the expression, so
# dropping it from the `if:` would pass every case. It is asserted on the text.
if yq -r '.jobs.image.if' "${wf}" | grep -qF '!cancelled()'; then
	report "workflow: image job if: keeps !cancelled()" ok
else
	report "workflow: image job if: keeps !cancelled()" "the if: of the image job does not contain !cancelled()"
fi
image_case "runs after a successful build" run success netbird success
image_case "does not run when source or compose failed (build skipped, package asked)" skip success netbird skipped
image_case "does not run after a failed build" skip success netbird failure
image_case "does not run after a cancelled build" skip success netbird cancelled
image_case "runs for images only (no package, build skipped)" run success "" skipped
image_case "does not run when config failed" skip failure "" skipped
image_case "does not run when config failed (build success)" skip failure netbird success

# ---------------------------------------------------------------------------
# No line is named outside the data: the lines of a package are its config.yml,
# the branch of a line and the reference line are the base's lines.yml. The one
# exception is the list of choices of the custom-image form (a GitHub form cannot
# read files).
# ---------------------------------------------------------------------------
# Print the lines of the files that name a line (25.12, 26.x, openwrt-2x, or a
# literal main / master line), except the form choices.
#
# Arguments: the files.
named_lines() {
	awk '
		BEGIN {
			pat = "25[.-]12|2[6-9][.-][0-9]+|openwrt-2[0-9]|(^|[^A-Za-z0-9_./-])line: *\"?(main|[0-9])|\"main\"|== *.main."
		}
		$0 ~ pat && index($0, "options: [main, \"25.12\"]") == 0 && index($0, "ubuntu-26.04") == 0 {
			print FILENAME ":" FNR ":" $0
		}' "$@"
}
got=$(find "${root}/.github/workflows" -name '*.yml' | sort | while IFS= read -r file; do named_lines "${file}"; done)
if [ -z "${got}" ]; then
	report "no line is named in the workflows (but the form choices)" ok
else
	report "no line is named in the workflows (but the form choices)" "${got}"
fi
got=$(find "${root}/scripts" -type f \( -name '*.sh' -o -name '*.py' \) ! -name '*selftest*' ! -path '*/stubs/*' | sort | while IFS= read -r file; do named_lines "${file}"; done)
if [ -z "${got}" ]; then
	report "no line is named in the scripts or in report.py" ok
else
	report "no line is named in the scripts or in report.py" "${got}"
fi
# The guard sees a line when one is named (a mutant that hides them all fails).
printf 'run: echo 25.12\nok: nothing\n' >"${work}/named.txt"
got=$(named_lines "${work}/named.txt")
if [ "${got}" = "${work}/named.txt:1:run: echo 25.12" ]; then
	report "the guard for named lines sees a named line" ok
else
	report "the guard for named lines sees a named line" "got: ${got}"
fi
# The form choices are lines of the base, and the only place that lists them.
choices=$(yq -r '.on.workflow_dispatch.inputs.line.options[]' "${root}/.github/workflows/custom-image.yml" | tr '\n' ' ')
for choice in ${choices}; do
	if yq -e ".lines.\"${choice}\"" "${BASE_LINES_FILE}" >/dev/null; then
		report "custom-image form choice ${choice} is a line of the base" ok
	else
		report "custom-image form choice ${choice} is a line of the base" "not in ${BASE_LINES_FILE}"
	fi
done
# The callers run the lines through line.yml with a matrix over the lines of
# the package; none builds, tests or images a line by itself.
for f in ci update upstream-pr; do
	file=${root}/.github/workflows/${f}.yml
	uses=$(yq -r '.jobs.lines.uses' "${file}")
	if [ "${uses}" = ./.github/workflows/line.yml ]; then
		report "workflow: ${f}.yml runs its lines through line.yml" ok
	else
		report "workflow: ${f}.yml runs its lines through line.yml" "uses: ${uses}"
	fi
	direct=$(awk '/wehagy\/openwrt-ci\/\.github\/workflows\//{n++} END{print n+0}' "${file}")
	if [ "${direct}" -eq 0 ]; then
		report "workflow: ${f}.yml calls the base only through line.yml" ok
	else
		report "workflow: ${f}.yml calls the base only through line.yml" "${direct} direct call(s)"
	fi
done
got=$(yq -r '.jobs.lines.strategy.matrix.line' "${root}/.github/workflows/ci.yml")
if [ "${got}" = "\${{ fromJSON(needs.config.outputs.lines_json) }}" ]; then
	report "workflow: ci.yml's matrix is the lines of the package" ok
else
	report "workflow: ci.yml's matrix is the lines of the package" "${got}"
fi
got=$(yq -r '.on.workflow_dispatch.inputs.lines.type' "${root}/.github/workflows/ci.yml")
if [ "${got}" = string ]; then
	report "workflow: ci.yml's lines input is free text, validated by config.sh" ok
else
	report "workflow: ci.yml's lines input is free text, validated by config.sh" "type ${got}"
fi

# --- refresh-config.sh: the lists of the daily image refresh ----------------
rcfg=${here}/refresh-config.sh
fx2=${work}/fx2
mkdir -p "${fx2}/aaa" "${fx2}/bbb"
cat >"${fx2}/aaa/config.yml" <<'EOF'
package: aaa
lines: [main, "25.12"]
targets: x86-64 malta-le
images:
  profiles:
    - x86/64/generic
    - ath79/generic/tplink_archer-c7-v4:too-big
EOF
cat >"${fx2}/bbb/config.yml" <<'EOF'
package: bbb
lines: [main]
targets: x86-64 armsr-armv8
images:
  profiles:
    - x86/64/generic
    - mediatek/filogic/bananapi_bpi-r3
    - ath79/generic/tplink_archer-c7-v4
EOF
expect_line "refresh-config: the union of the lines" "lines=main 25.12" env PACKAGES_DIR="${fx2}" "${rcfg}"
expect_line "refresh-config: profiles once each, without :too-big" "profiles=x86/64/generic ath79/generic/tplink_archer-c7-v4 mediatek/filogic/bananapi_bpi-r3" env PACKAGES_DIR="${fx2}" "${rcfg}"
expect_line "refresh-config: the union of the targets" "targets=x86-64 malta-le armsr-armv8" env PACKAGES_DIR="${fx2}" "${rcfg}"
fx3=${work}/fx3
mkdir -p "${fx3}/aaa" "${fx3}/ccc"
cp "${fx2}/aaa/config.yml" "${fx3}/aaa/config.yml"
printf 'package: ccc\nlines: [main]\nimages:\n  profiles:\n    - x86/64/generic\n' >"${fx3}/ccc/config.yml"
expect_line "refresh-config: a package with the default targets leaves them empty" "targets=" env PACKAGES_DIR="${fx3}" "${rcfg}"
run env PACKAGES_DIR="${fx3}" "${rcfg}"
case "${out_text}" in
*"targets=x86"*) report "refresh-config: no partial targets when one package has the default" "got: ${out_text}" ;;
*) report "refresh-config: no partial targets when one package has the default" ok ;;
esac
mkdir -p "${work}/empty"
expect_refused "refresh-config: no package" "no packages/<name>/config.yml" env PACKAGES_DIR="${work}/empty" "${rcfg}"
mkdir -p "${work}/bad/aaa"
printf 'package: zzz\nlines: [main]\n' >"${work}/bad/aaa/config.yml"
expect_refused "refresh-config: an invalid config stops everything" "package is not aaa" env PACKAGES_DIR="${work}/bad" "${rcfg}"
# An invalid config next to a valid one must still stop everything: the valid
# package would otherwise get its images and the broken one none, silently.
mkdir -p "${work}/bad2/aaa" "${work}/bad2/bbb"
printf 'package: zzz\nlines: [main]\n' >"${work}/bad2/aaa/config.yml"
cp "${fx2}/bbb/config.yml" "${work}/bad2/bbb/config.yml"
expect_refused "refresh-config: an invalid config next to a valid one stops everything" "package is not aaa" env PACKAGES_DIR="${work}/bad2" "${rcfg}"

if [ "${failed}" -ne 0 ]; then
	echo "images self-test: ${failed} of ${total} case(s) failed" >&2
	exit 1
fi
echo "images self-test: ${total} cases passed"
