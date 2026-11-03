#!/usr/bin/env sh
# Responsibility: prove the decisions of the upstream pull request workflow
# (lib.sh) and that resolve.sh refuses a bad input before any request, with
# fixed inputs and no network. Runs every case and fails at the end if one
# failed, so one run lists all of them.
#
# Usage: scripts/upstream-pr/selftest.sh   (needs sh, awk, sed, tr, cut, sort)
# Environment variables: none.
set -u

here=$(dirname "$0")
# shellcheck source=scripts/upstream-pr/lib.sh
. "${here}/lib.sh"
# shellcheck source=scripts/lib/lines.sh
. "${here}/../lib/lines.sh"
# The lines of the base: a stub with a FAKE third line (main, 25.12, 26.12).
BASE_LINES_FILE=${here}/../stubs/lines.yml
export BASE_LINES_FILE

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
failed=0

# Reports one case. Arguments: $1 name, $2 "ok" or a reason.
report() {
	if [ "$2" = ok ]; then
		echo "ok   $1"
	else
		echo "FAIL $1: $2"
		failed=$((failed + 1))
	fi
}

# The command must exit non-zero and its stderr must contain the text.
# Arguments: $1 case name, $2 text, rest the command.
expect_refused() {
	name=$1
	text=$2
	shift 2
	if "$@" 2>"${work}/err" >"${work}/out"; then
		report "${name}" "accepted, must be refused"
	elif ! grep -qF -- "${text}" "${work}/err"; then
		err=$(cat "${work}/err")
		report "${name}" "refused without '${text}': ${err}"
	else
		report "${name}" ok
	fi
}

# The command must exit 0 and print exactly the text. Arguments: $1 name, $2 text, rest the command.
expect_prints() {
	name=$1
	text=$2
	shift 2
	if ! "$@" >"${work}/out" 2>"${work}/err"; then
		err=$(cat "${work}/err")
		report "${name}" "refused: ${err}"
	elif got=$(cat "${work}/out") && [ "${got}" != "${text}" ]; then
		report "${name}" "printed '${got}', want '${text}'"
	else
		report "${name}" ok
	fi
}

# --- PR number ---------------------------------------------------------------
for n in 1 31059 9999999; do
	expect_prints "pr number ${n} accepted" "" check_pr_number "${n}"
done
nl=$(printf '1\n2')
for n in "" abc 12a 1.5 -5 +5 0 007 12345678 "1 2" "${nl}" "1;id"; do
	label=$(printf '%s' "${n}" | tr '\n' '~')
	expect_refused "pr number '${label}' refused" "::error::pr_number" check_pr_number "${n}"
done

# --- base branch -> line -----------------------------------------------------
expect_prints "master is line main" main line_for_branch master
expect_prints "openwrt-25.12 is line 25.12" 25.12 line_for_branch openwrt-25.12
expect_prints "openwrt-26.12 is line 26.12 (the fake third line)" 26.12 line_for_branch openwrt-26.12
for b in openwrt-24.10 openwrt-23.05 main "" master2 "master
::error::forged"; do
	label=$(printf '%s' "${b}" | tr '\n' '~')
	expect_refused "base '${label}' refused" "unsupported base branch" line_for_branch "${b}"
done
expect_prints "branch of main" master branch_for_line main
expect_prints "branch of 25.12" openwrt-25.12 branch_for_line 25.12
expect_prints "branch of 26.12" openwrt-26.12 branch_for_line 26.12
expect_refused "branch of an unknown line" "the base has no line '24.10'" branch_for_line 24.10
expect_prints "the reference line is the one on master" main reference_line
# A forged workflow command in a branch name does not start a line of its own.
if line_for_branch "x
::error::forged" 2>&1 | grep -q '^::error::forged'; then
	report "forged line is not echoed" "a line starts with ::error::forged"
else
	report "forged line is not echoed" ok
fi

# --- the legs of the matrix: one per (package, line) -------------------------
# netbird is local with three lines; curl is a package of the PR with no
# packages/<name>/ here. rows: {package, local, lines}.
rows='[{"package":"netbird","local":true,"lines":"main 25.12 26.12"},{"package":"curl","local":false,"lines":""}]'

leg_list() {
	legs_matrix "${rows}" "$1" | jq -r '.include[] | "\(.package):\(.line):\(.kind):\(.with_images)"' | tr '\n' ' '
}
expect_prints "legs: PR on 26.12 overlays the other two lines of netbird" \
	"netbird:26.12:pr:true netbird:main:overlay:true netbird:25.12:overlay:true curl:26.12:pr:false " leg_list 26.12
expect_prints "legs: PR on main" "netbird:main:pr:true netbird:25.12:overlay:true netbird:26.12:overlay:true curl:main:pr:false " leg_list main
expect_prints "legs: a package outside the PR line is not a leg of that line" "netbird:25.12:pr:true netbird:main:overlay:true netbird:26.12:overlay:true curl:25.12:pr:false " leg_list 25.12
expect_prints "overlay lines of a PR on main" "25.12 26.12" overlay_lines "${rows}" main
expect_prints "overlay lines of a PR on 26.12" "25.12 main" overlay_lines "${rows}" 26.12
expect_prints "no overlay line without a local package" "" overlay_lines '[{"package":"curl","local":false,"lines":""}]' main
expect_prints "a package lists the line of the PR" "" check_lists_line netbird "main 26.12" 26.12
expect_refused "a package that dropped the line of the PR" "does not list the line 25.12" check_lists_line netbird "main 26.12" 25.12

# --- package names -----------------------------------------------------------
for p in netbird libsoc python-yaml libstdcpp6 a.b+c_d-e; do
	expect_prints "package ${p} accepted" "" check_package_name "${p}"
done
for p in "" Netbird -x .hidden "a b"; do
	expect_refused "package '${p}' refused" "::error::package" check_package_name "${p}"
done

# --- changed files -> packages -----------------------------------------------
cat >"${work}/tree.txt" <<'TREE'
Makefile.root-not-a-package
net/netbird/Makefile
net/netbird/files/netbird.init
net/other/Makefile
net/other/src/Makefile
lang/python/python-yaml/Makefile
utils/removed-by-pr/files/x
TREE
makefile_dirs <"${work}/tree.txt" >"${work}/dirs.txt"
expect_prints "makefile dirs" "net/netbird
net/other
net/other/src
lang/python/python-yaml" cat "${work}/dirs.txt"

# Paths: a file of a package, a nested build file (src/Makefile belongs to the
# outer package), a second package, a rename source, a file outside any package
# and a package the PR removed (not in the PR tree).
cat >"${work}/changed.txt" <<'CHANGED'
net/netbird/Makefile
net/netbird/files/netbird.init
net/other/src/Makefile
lang/python/python-yaml/Makefile
net/old-name/Makefile
utils/removed-by-pr/files/x
.github/workflows/ci.yml
README.md
CHANGED
expect_prints "changed files -> packages" "lang/python/python-yaml
net/netbird
net/other" sh -c ". '${here}/lib.sh'; detect_packages '${work}/dirs.txt' <'${work}/changed.txt'"
printf 'README.md\n.github/x.yml\n' >"${work}/none.txt"
expect_prints "no package changed" "" sh -c ". '${here}/lib.sh'; detect_packages '${work}/dirs.txt' <'${work}/none.txt'"

# --- the .apk must be named like the directory ----------------------------------
cat >"${work}/Makefile.ok" <<'MK'
define Package/netbird
  TITLE:=x
endef
define Package/netbird/description
endef
define Package/netbird-extra
endef
MK
cat >"${work}/Makefile.udns" <<'MK'
define Package/libudns
endef
define Package/libudns/description
endef
define Package/udns-utils
endef
MK
expect_prints "Makefile defines the directory's package" yes sh -c ". '${here}/lib.sh'; makefile_defines_package netbird <'${work}/Makefile.ok'"
expect_prints "Makefile of udns has no package udns" no sh -c ". '${here}/lib.sh'; makefile_defines_package udns <'${work}/Makefile.udns'"
expect_prints "a longer name is not a match" no sh -c ". '${here}/lib.sh'; makefile_defines_package net <'${work}/Makefile.ok'"
expect_prints "a dot is not a wildcard" no sh -c ". '${here}/lib.sh'; printf 'define Package/netbxrd\n' | makefile_defines_package netb.rd"
expect_prints "package names of a Makefile" "libudns
udns-utils" sh -c ". '${here}/lib.sh'; makefile_package_names <'${work}/Makefile.udns'"

# --- resolve.sh refuses before any request -----------------------------------
# curl is a stub that records a call; a bad number or an unsupported base must
# not reach it (number) or must stop right after the one GET (base branch).
mkdir "${work}/bin"
cat >"${work}/bin/curl" <<'STUB'
#!/usr/bin/env sh
echo "curl $*" >>"${STUB_LOG}"
out=""
while [ "$#" -gt 0 ]; do
	[ "$1" = -o ] && out=$2
	shift
done
cat "${STUB_RESPONSE}" >"${out}"
printf 200
STUB
chmod +x "${work}/bin/curl"
: >"${work}/stub.log"
printf '%s' '{"base":{"ref":"openwrt-24.10"},"head":{"sha":"abc123"},"state":"closed","merged":true,"changed_files":2,"title":"t"}' >"${work}/pr-24.json"
: >"${work}/summary.md"
: >"${work}/output.txt"
run_resolve() {
	GH_TOKEN=selftest-not-a-token PATH="${work}/bin:${PATH}" STUB_LOG="${work}/stub.log" STUB_RESPONSE="${work}/pr-24.json" \
		PR_NUMBER=$1 GITHUB_OUTPUT="${work}/output.txt" GITHUB_STEP_SUMMARY="${work}/summary.md" \
		"${here}/resolve.sh"
}
expect_refused "resolve: non-numeric number refused" "::error::pr_number must be a positive integer" run_resolve abc
if [ -s "${work}/stub.log" ]; then
	made=$(cat "${work}/stub.log")
	report "resolve: no request for a bad number" "made: ${made}"
else
	report "resolve: no request for a bad number" ok
fi
expect_refused "resolve: base openwrt-24.10 refused" "unsupported base branch 'openwrt-24.10'" run_resolve 30947
if [ -s "${work}/output.txt" ]; then
	wrote=$(cat "${work}/output.txt")
	report "resolve: no output written on refusal" "wrote: ${wrote}"
else
	report "resolve: no output written on refusal" ok
fi

if [ "${failed}" -ne 0 ]; then
	echo "upstream-pr self-test: ${failed} case(s) failed" >&2
	exit 1
fi
echo "upstream-pr self-test: all cases passed"
