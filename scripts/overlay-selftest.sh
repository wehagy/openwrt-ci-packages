#!/usr/bin/env sh
# Responsibility: offline tests of how update.yml builds the lines other than the
# reference: the tree that scripts/upstream-pr/compose.sh makes from the bump
# commit (the packages_branch of the line plus only the package directory),
# for one line and for several (compose-lines.sh), the cleanup of the overlay
# branches (scripts/upstream-pr/cleanup.sh), the per-line result files and the
# decision of publish (line-result.sh, decide.sh: one line failing while the
# others pass, three lines, a line removed) and the wiring of the jobs in update.yml
# (which commit each line builds, who may write, who sees which secret). Local
# bare repositories stand in for openwrt/packages, the review repository and
# this repository; a gh shim stands in for the delete. Nothing reaches GitHub.
# Run by update-selftest.sh.
#
# Usage:
#   scripts/overlay-selftest.sh   (needs git and yq)
#
# Environment variables: none (BASE_LINES_FILE is set here to the stub with a
# fake third line, scripts/stubs/lines.yml).

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
BASE_LINES_FILE="${script_dir}/stubs/lines.yml"
export BASE_LINES_FILE
workflow="${script_dir}/../.github/workflows/update.yml"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/selftest.sh
. "${script_dir}/lib/selftest.sh"

GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
GIT_AUTHOR_NAME=fixture
GIT_AUTHOR_EMAIL=fixture@example.invalid
GIT_COMMITTER_NAME=fixture
GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# --- fixtures ---------------------------------------------------------------
# openwrt-25.12: golang 1.25 and netbird 0.81.4. master: golang 1.26 and the
# same netbird. The bump commit (on master, as in the review repository) makes
# netbird 0.81.5. upstream.git has both branches and the bump as pull 5;
# review.git has master and the update branch.
update_branch=ci/netbird-update-0.81.5
git init -q "${work}/src"
git -C "${work}/src" checkout -q -b openwrt-25.12
mkdir -p "${work}/src/net/netbird/files" "${work}/src/lang/golang" "${work}/src/net/other" "${work}/src/.github/workflows"
echo 'PKG_VERSION:=0.81.4' >"${work}/src/net/netbird/Makefile"
echo 'init' >"${work}/src/net/netbird/files/netbird.init"
echo 'GO_DEFAULT_VERSION:=1.25' >"${work}/src/lang/golang/Makefile"
echo 'other' >"${work}/src/net/other/Makefile"
echo 'upstream workflow' >"${work}/src/.github/workflows/ci.yml"
git -C "${work}/src" add -A
git -C "${work}/src" commit -q -m "openwrt-25.12"
base_sha=$(git -C "${work}/src" rev-parse HEAD)
git -C "${work}/src" checkout -q -b master
echo 'GO_DEFAULT_VERSION:=1.26' >"${work}/src/lang/golang/Makefile"
echo 'master only' >"${work}/src/net/other/master-only"
git -C "${work}/src" add -A
git -C "${work}/src" commit -q -m "master"
echo 'PKG_VERSION:=0.81.5' >"${work}/src/net/netbird/Makefile"
echo 'init 2' >"${work}/src/net/netbird/files/netbird.init"
git -C "${work}/src" commit -q -a -m "netbird: update to 0.81.5"
bump_sha=$(git -C "${work}/src" rev-parse HEAD)
# A fake third line, openwrt-26.12: golang 1.27.
git -C "${work}/src" checkout -q -b openwrt-26.12 openwrt-25.12
echo 'GO_DEFAULT_VERSION:=1.27' >"${work}/src/lang/golang/Makefile"
git -C "${work}/src" commit -q -a -m "openwrt-26.12"
git -C "${work}/src" checkout -q master
git init -q --bare "${work}/upstream.git"
git -C "${work}/src" push -q "file://${work}/upstream.git" openwrt-25.12:refs/heads/openwrt-25.12 openwrt-26.12:refs/heads/openwrt-26.12 master~1:refs/heads/master "${bump_sha}:refs/pull/5/head"
git init -q --bare "${work}/review.git"
git -C "${work}/src" push -q "file://${work}/review.git" "master:refs/heads/master" "master:refs/heads/${update_branch}"
git init -q --bare "${work}/target.git"

# Send the GitHub addresses the scripts use to the local repositories.
GIT_CONFIG_COUNT=2
GIT_CONFIG_KEY_0="url.file://${work}/upstream.git.insteadOf"
GIT_CONFIG_VALUE_0=https://github.com/openwrt/packages.git
GIT_CONFIG_KEY_1="url.file://${work}/review.git.insteadOf"
GIT_CONFIG_VALUE_1=https://github.com/wehagy/w.git
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1

# Record a case that passes when two values are equal.
#
# Arguments:
#   $1  case name
#   $2  value found
#   $3  value wanted
eq() {
	check "$1" "found '$2', wanted '$3'" same "$2" "$3"
}

# --- compose.sh as update.yml calls it --------------------------------------
# Run compose.sh with the arguments of the update workflow; sets cmp_rc and the
# files cmp.out / cmp.err / gh_out. The arguments are NAME=value overrides.
#
# Arguments:
#   $@  overrides of the environment
run_compose() {
	cmp_rc=0
	: >"${work}/gh_out"
	: >"${work}/gh_sum"
	env GITHUB_REPOSITORY=wehagy/openwrt-ci-packages GITHUB_OUTPUT="${work}/gh_out" \
		GITHUB_STEP_SUMMARY="${work}/gh_sum" PUSH_URL="file://${work}/target.git" \
		OTHER_BRANCH=openwrt-25.12 HEAD_SHA="${bump_sha}" OVERLAY_DIRS=net/netbird \
		SOURCE_URL=https://github.com/wehagy/w.git SOURCE_REF="refs/heads/${update_branch}" \
		SOURCE_LABEL="wehagy/w:${update_branch}" TARGET_BRANCH=upstream-overlay/update-netbird-1-1 \
		"$@" "${script_dir}/upstream-pr/compose.sh" >"${work}/cmp.out" 2>"${work}/cmp.err" || cmp_rc=$?
}

# The value of an output the script wrote.
#
# Arguments:
#   $1  name
output() {
	sed -n "s/^$1=//p" "${work}/gh_out"
}

run_compose
check "compose: exits 0" "${work}/cmp.err" same "${cmp_rc}" 0
overlay_sha=$(output sha)
got=$(git --git-dir="${work}/target.git" rev-parse refs/heads/upstream-overlay/update-netbird-1-1)
eq "compose: sha output is the pushed branch" "${overlay_sha}" "${got}"
got=$(output base_sha)
eq "compose: base_sha output is openwrt-25.12" "${got}" "${base_sha}"
got=$(output branch)
eq "compose: branch output" "${got}" upstream-overlay/update-netbird-1-1
got=$(git --git-dir="${work}/target.git" rev-list --parents -n 1 "${overlay_sha}")
eq "compose: a root commit" "${got}" "${overlay_sha}"

# The content of a file of the overlay commit.
#
# Arguments:
#   $1  path
blob() {
	git --git-dir="${work}/target.git" show "${overlay_sha}:$1"
}

got=$(blob net/netbird/Makefile)
eq "compose: netbird is the bumped one" "${got}" "PKG_VERSION:=0.81.5"
got=$(blob net/netbird/files/netbird.init)
eq "compose: netbird files are the bumped ones" "${got}" "init 2"
got=$(blob lang/golang/Makefile)
eq "compose: golang is the one of openwrt-25.12, not master" "${got}" "GO_DEFAULT_VERSION:=1.25"
got=$(blob net/other/Makefile)
eq "compose: other packages are those of openwrt-25.12" "${got}" "other"
got=$(git --git-dir="${work}/target.git" ls-tree -r --name-only "${overlay_sha}" | grep -c master-only || :)
eq "compose: no file of master leaks in" "${got}" 0
got=$(git --git-dir="${work}/target.git" ls-tree -r --name-only "${overlay_sha}" | grep -c '^\.github' || :)
eq "compose: the upstream .github is dropped" "${got}" 0
got=$(git --git-dir="${work}/target.git" log -1 --format=%s "${overlay_sha}")
eq "compose: the message names the source and the base" "${got}" "overlay of net/netbird from wehagy/w:${update_branch} (${bump_sha}) on openwrt-25.12 (${base_sha})"
got=$(git --git-dir="${work}/review.git" for-each-ref --format='%(refname)' | grep -c overlay || :)
eq "compose: nothing is pushed to the review repository" "${got}" 0
got=$(git --git-dir="${work}/upstream.git" for-each-ref --format='%(refname)' | grep -c overlay || :)
eq "compose: nothing is pushed to the upstream" "${got}" 0

# --- compose-lines.sh: one job composes every other line ------------------
# Run compose-lines.sh as update.yml does; sets cl_rc and the files cl.out /
# cl.err / cl_out (GITHUB_OUTPUT).
#
# Arguments:
#   $@  overrides of the environment
run_lines() {
	cl_rc=0
	: >"${work}/cl_out"
	: >"${work}/gh_sum"
	env GITHUB_REPOSITORY=wehagy/openwrt-ci-packages GITHUB_OUTPUT="${work}/cl_out" \
		GITHUB_STEP_SUMMARY="${work}/gh_sum" PUSH_URL="file://${work}/target.git" \
		OTHER_LINES="25.12 26.12" REFERENCE_LINE=main REFERENCE_FEED_REPOSITORY=wehagy/w \
		REFERENCE_FEED_REF="${bump_sha}" HEAD_SHA="${bump_sha}" OVERLAY_DIRS=net/netbird \
		SOURCE_URL=https://github.com/wehagy/w.git SOURCE_REF="refs/heads/${update_branch}" \
		SOURCE_LABEL="wehagy/w:${update_branch}" TARGET_PREFIX=upstream-overlay/update-cl-1-1 \
		TOLERATE_FAILURE=true "$@" "${script_dir}/upstream-pr/compose-lines.sh" >"${work}/cl.out" 2>"${work}/cl.err" || cl_rc=$?
}
# The value of an output of compose-lines.sh as JSON text.
#
# Arguments:
#   $1  name
#   $2  jq filter
lines_output() {
	sed -n "s/^$1=//p" "${work}/cl_out" | jq -r "$2"
}
run_lines
check "compose-lines: three lines: exits 0" "${work}/cl.err" same "${cl_rc}" 0
got=$(lines_output matrix '[.include[].line] | join(" ")')
eq "compose-lines: the matrix names the reference line first, then the others" "${got}" "main 25.12 26.12"
got=$(lines_output matrix '.include[0] | .feed_repository + " " + .feed_ref')
eq "compose-lines: the reference line builds the bump commit of the review repository" "${got}" "wehagy/w ${bump_sha}"
got=$(lines_output matrix '[.include[1:][].feed_repository] | unique | join(" ")')
eq "compose-lines: the other lines build this repository" "${got}" wehagy/openwrt-ci-packages
sha_25=$(lines_output overlays '.["25.12"].sha')
sha_26=$(lines_output overlays '.["26.12"].sha')
got=$(lines_output matrix '[.include[1:][].feed_ref] | join(" ")')
eq "compose-lines: each line builds its own overlay commit" "${got}" "${sha_25} ${sha_26}"
check "compose-lines: the overlay commits differ" "${sha_25}" test "${sha_25}" != "${sha_26}"
got=$(lines_output overlays '.["25.12"].branch')
eq "compose-lines: the branch of 25.12" "${got}" upstream-overlay/update-cl-1-1-25.12
got=$(lines_output overlays '.["26.12"].branch')
eq "compose-lines: the branch of 26.12" "${got}" upstream-overlay/update-cl-1-1-26.12
got=$(lines_output overlays '.["25.12"].base_branch')
eq "compose-lines: 25.12 is overlaid on openwrt-25.12" "${got}" openwrt-25.12
got=$(lines_output overlays '.["26.12"].base_branch')
eq "compose-lines: 26.12 is overlaid on openwrt-26.12" "${got}" openwrt-26.12
got=$(git --git-dir="${work}/target.git" show "${sha_25}:lang/golang/Makefile")
eq "compose-lines: 25.12 has the golang of openwrt-25.12" "${got}" "GO_DEFAULT_VERSION:=1.25"
got=$(git --git-dir="${work}/target.git" show "${sha_26}:lang/golang/Makefile")
eq "compose-lines: 26.12 has the golang of openwrt-26.12" "${got}" "GO_DEFAULT_VERSION:=1.27"
got=$(git --git-dir="${work}/target.git" show "${sha_26}:net/netbird/Makefile")
eq "compose-lines: 26.12 has the bumped netbird" "${got}" "PKG_VERSION:=0.81.5"
got=$(sed -n 's/^failed=//p' "${work}/cl_out")
eq "compose-lines: nothing failed" "${got}" ""
# A line removed from the list is not composed: no branch, no entry.
run_lines OTHER_LINES=26.12 TARGET_PREFIX=upstream-overlay/update-cl-2-1
got=$(lines_output matrix '[.include[].line] | join(" ")')
eq "compose-lines: with 25.12 removed the matrix has no 25.12" "${got}" "main 26.12"
got=$(git --git-dir="${work}/target.git" for-each-ref --format='%(refname)' | grep -c 'update-cl-2-1-25.12' || :)
eq "compose-lines: with 25.12 removed its branch is not pushed" "${got}" 0
# A package with only the reference line: no overlay, the matrix is the reference.
run_lines OTHER_LINES= TARGET_PREFIX=upstream-overlay/update-cl-3-1
got=$(lines_output matrix '[.include[].line] | join(" ")')
eq "compose-lines: no other line: the matrix is the reference line" "${got}" main
got=$(lines_output overlays 'length')
eq "compose-lines: no other line: no overlay" "${got}" 0
# One overlay that cannot be composed does not stop the reference line (update
# tolerates it) and is reported; the others are still composed.
run_lines OTHER_LINES="25.12 26.12" HEAD_SHA=0000000000000000000000000000000000000000 TARGET_PREFIX=upstream-overlay/update-cl-4-1
check "compose-lines: tolerated failure: exits 0" "${work}/cl.err" same "${cl_rc}" 0
got=$(sed -n 's/^failed=//p' "${work}/cl_out")
eq "compose-lines: tolerated failure: the lines are reported" "${got}" "25.12 26.12"
got=$(lines_output matrix '[.include[].line] | join(" ")')
eq "compose-lines: tolerated failure: the reference line stays" "${got}" main
check "compose-lines: tolerated failure: says so" "${work}/cl.out" has "${work}/cl.out" "::error::the overlay of line 25.12 could not be composed"
run_lines TOLERATE_FAILURE=false HEAD_SHA=0000000000000000000000000000000000000000 TARGET_PREFIX=upstream-overlay/update-cl-5-1
check "compose-lines: a failure is fatal unless tolerated" "${work}/cl.err" failed "${cl_rc}"
run_lines OTHER_LINES="24.10" TARGET_PREFIX=upstream-overlay/update-cl-6-1
check "compose-lines: a line of the base that does not exist is refused" "${work}/cl.err" failed "${cl_rc}"
check "compose-lines: ... and says so" "${work}/cl.err" has "${work}/cl.err" "the base has no line"

# The sweep tests below count the branches of the target: drop the ones above.
for ref in $(git --git-dir="${work}/target.git" for-each-ref --format='%(refname)' 'refs/heads/upstream-overlay/update-cl-*'); do
	git --git-dir="${work}/target.git" update-ref -d "${ref}"
done

# --- line-result.sh and decide.sh: the outcome of each line ----------------
# One result file per line, as the artifacts of the legs of the matrix lay them
# out; decide.sh reads these, never the aggregate `needs.<job>.result`.
sha_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sha_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
sha_c=cccccccccccccccccccccccccccccccccccccccc
sha_d=dddddddddddddddddddddddddddddddddddddddd
# Write the result file of a line.
#
# Arguments:
#   $1  line
#   $2  build result  $3  test result  $4  image result  $5  commit built
put_result() {
	env LINE="$1" PACKAGE=netbird BUILD="$2" TEST="$3" IMAGE="$4" FEED_SHA="$5" \
		"${script_dir}/line-result.sh" "${work}/res/line-result-netbird-$1/result.json" >/dev/null
}
rm -rf "${work}/res"
put_result main success success success "${sha_a}"
got=$(jq -r .passed "${work}/res/line-result-netbird-main/result.json")
eq "line-result: all green is passed" "${got}" true
put_result 25.12 failure skipped skipped ""
got=$(jq -r .passed "${work}/res/line-result-netbird-25.12/result.json")
eq "line-result: a failed build is not passed" "${got}" false
got=$(jq -r .build "${work}/res/line-result-netbird-25.12/result.json")
eq "line-result: ... and keeps the build result" "${got}" failure
put_result 26.12 success success "not requested" "${sha_c}"
got=$(jq -r .passed "${work}/res/line-result-netbird-26.12/result.json")
eq "line-result: images not requested do not fail the line" "${got}" true
put_result 26.12 success failure success "${sha_c}"
got=$(jq -r .passed "${work}/res/line-result-netbird-26.12/result.json")
eq "line-result: a failed test is not passed" "${got}" false
put_result 26.12 success success skipped "${sha_c}"
got=$(jq -r .passed "${work}/res/line-result-netbird-26.12/result.json")
eq "line-result: skipped images are not passed" "${got}" false
# Run line-result.sh with the given environment on a throwaway file; sets lr_rc
# and the files lr.out / lr.err.
#
# Arguments:
#   $@  NAME=value pairs
result_rc() {
	lr_rc=0
	env "$@" "${script_dir}/line-result.sh" "${work}/x.json" >"${work}/lr.out" 2>"${work}/lr.err" || lr_rc=$?
}
result_rc LINE=main PACKAGE=netbird BUILD='success;id' TEST=success IMAGE=success
check "line-result: a forged result is refused" "${work}/lr.err" failed "${lr_rc}"
result_rc LINE='ma in' PACKAGE=netbird BUILD=success TEST=success IMAGE=success
check "line-result: a forged line is refused" "${work}/lr.err" failed "${lr_rc}"
result_rc LINE=main PACKAGE=netbird BUILD=success TEST=success IMAGE=success FEED_SHA=zz
check "line-result: a forged commit is refused" "${work}/lr.err" failed "${lr_rc}"
# The summary shows each leg on its own row.
put_result 26.12 success success success "${sha_c}"
"${script_dir}/line-summary.sh" "${work}/res" >"${work}/sum.md"
check "line-summary: the failed line is a row of its own" "${work}/sum.md" has "${work}/sum.md" "| netbird | 25.12 | failure | skipped | skipped | **FAILED** |"
check "line-summary: the passing lines are rows too" "${work}/sum.md" has "${work}/sum.md" "| netbird | 26.12 | success | success | success | passed |"

# Run decide.sh with the three lines (main is the reference); sets dec_rc and the
# files dec.out (stdout) and dec.log (stderr). Everything passed, with the right
# commits, unless overridden.
#
# Arguments:
#   $@  overrides of the environment
run_decide() {
	dec_rc=0
	env PACKAGE=netbird LINES="main 25.12 26.12" REFERENCE=main RESULTS_DIR="${work}/res" REPORT_PASSED=true \
		MATRIX="{\"include\":[{\"line\":\"main\",\"feed_ref\":\"${sha_a}\"},{\"line\":\"25.12\",\"feed_ref\":\"${sha_b}\"},{\"line\":\"26.12\",\"feed_ref\":\"${sha_c}\"}]}" \
		"$@" sh "${script_dir}/decide.sh" >"${work}/dec.out" 2>"${work}/dec.log" || dec_rc=$?
}
rm -rf "${work}/res"
put_result main success success success "${sha_a}"
put_result 25.12 success success success "${sha_b}"
put_result 26.12 success success success "${sha_c}"
run_decide
check "decide: three green lines: exits 0" "${work}/dec.log" same "${dec_rc}" 0
check "decide: three green lines: opens" "${work}/dec.out" has "${work}/dec.out" "open=true"
# ONE line fails, the others pass: the failing line is named, the pull request
# still opens when it is not the reference line.
put_result 25.12 failure skipped skipped ""
run_decide
check "decide: 25.12 failed, the others passed: exits 0" "${work}/dec.log" same "${dec_rc}" 0
check "decide: 25.12 failed, the others passed: opens" "${work}/dec.out" has "${work}/dec.out" "open=true"
check "decide: 25.12 failed: the log names it" "${work}/dec.log" has "${work}/dec.log" "line 25.12: build=failure test=skipped image=skipped passed=false"
check "decide: 25.12 failed: the others are reported as passed (main)" "${work}/dec.log" has "${work}/dec.log" "line main: build=success test=success image=success passed=true"
check "decide: 25.12 failed: the others are reported as passed (26.12)" "${work}/dec.log" has "${work}/dec.log" "line 26.12: build=success test=success image=success passed=true"
put_result 25.12 success success success "${sha_b}"
put_result 26.12 success failure success "${sha_c}"
run_decide
check "decide: the third line failed, the others passed: opens" "${work}/dec.out" has "${work}/dec.out" "open=true"
check "decide: the third line failed: the log names it" "${work}/dec.log" has "${work}/dec.log" "line 26.12: build=success test=failure image=success passed=false"
# The reference line failing stops the pull request whatever the others do.
put_result 26.12 success success success "${sha_c}"
put_result main failure skipped skipped ""
run_decide
check "decide: the reference failed, the others passed: exits 0" "${work}/dec.log" same "${dec_rc}" 0
check "decide: the reference failed, the others passed: no pull request" "${work}/dec.out" has "${work}/dec.out" "open=false"
for stage in test image; do
	for result in failure cancelled skipped; do
		case "${stage}" in
		test) put_result main success "${result}" success "${sha_a}" ;;
		*) put_result main success success "${result}" "${sha_a}" ;;
		esac
		run_decide
		check "decide: reference ${stage} ${result}: no pull request" "${work}/dec.out" has "${work}/dec.out" "open=false"
	done
done
put_result main success success success "${sha_a}"
# A line without a result file (killed, never ran).
rm -f "${work}/res/line-result-netbird-25.12/result.json"
run_decide
check "decide: no result for 25.12 does not stop the pull request" "${work}/dec.out" has "${work}/dec.out" "open=true"
check "decide: no result for 25.12 is reported" "${work}/dec.log" has "${work}/dec.log" "line 25.12: build=no result"
put_result 25.12 success success success "${sha_b}"
rm -f "${work}/res/line-result-netbird-main/result.json"
run_decide
check "decide: no result for the reference line: no pull request" "${work}/dec.out" has "${work}/dec.out" "open=false"
put_result main success success success "${sha_a}"
# The two views of the reference line must agree.
run_decide REPORT_PASSED=false
check "decide: the description disagrees: no pull request" "${work}/dec.out" has "${work}/dec.out" "open=false"
run_decide REPORT_PASSED=
check "decide: no verdict of the description: no pull request" "${work}/dec.out" has "${work}/dec.out" "open=false"
# The commit the base reports must be the one this run made, for every line.
put_result main success success success "${sha_d}"
run_decide
check "decide: the reference built another commit: fails" "${work}/dec.log" failed "${dec_rc}"
check "decide: the reference built another commit: says so" "${work}/dec.log" has "${work}/dec.log" "line main built ${sha_d}, not the commit this run made for it (${sha_a})"
check "decide: the reference built another commit: no decision" "${work}/dec.out" lacks "${work}/dec.out" "open="
put_result main success success success ""
run_decide
check "decide: the reference reported no commit: fails" "${work}/dec.log" failed "${dec_rc}"
put_result main success success success "${sha_a}"
put_result 25.12 success success success "${sha_d}"
run_decide
check "decide: 25.12 built another commit: fails" "${work}/dec.log" failed "${dec_rc}"
check "decide: 25.12 built another commit: says so" "${work}/dec.log" has "${work}/dec.log" "line 25.12 built ${sha_d}, not the commit this run made for it (${sha_b})"
put_result 25.12 success success success "${sha_b}"
# 25.12 removed from the package: the line is neither in LINES nor in the matrix
# and nothing else changes.
rm -rf "${work}/res/line-result-netbird-25.12"
run_decide LINES="main 26.12" MATRIX="{\"include\":[{\"line\":\"main\",\"feed_ref\":\"${sha_a}\"},{\"line\":\"26.12\",\"feed_ref\":\"${sha_c}\"}]}"
check "decide: with 25.12 removed: opens" "${work}/dec.out" has "${work}/dec.out" "open=true"
check "decide: with 25.12 removed: never mentions it" "${work}/dec.log" lacks "${work}/dec.log" "25.12"
# A package with only the reference line.
run_decide LINES=main MATRIX="{\"include\":[{\"line\":\"main\",\"feed_ref\":\"${sha_a}\"}]}"
check "decide: only the reference line: opens" "${work}/dec.out" has "${work}/dec.out" "open=true"

# The bump moved after prepare: refuse, push nothing.
git -C "${work}/src" commit -q --allow-empty -m "another commit"
git -C "${work}/src" push -q "file://${work}/review.git" "master:refs/heads/${update_branch}" --force
run_compose TARGET_BRANCH=upstream-overlay/update-netbird-2-1
check "compose: a moved update branch is refused" "${work}/cmp.err" failed "${cmp_rc}"
check "compose: a moved update branch says so" "${work}/cmp.err" has "${work}/cmp.err" "moved"
got=$(git --git-dir="${work}/target.git" for-each-ref --format='%(refname)' | grep -c 'update-netbird-2-1' || :)
eq "compose: a moved update branch pushes nothing" "${got}" 0

run_compose SOURCE_URL=https://example.invalid/wehagy/w.git
check "compose: a source outside github.com is refused" "${work}/cmp.err" failed "${cmp_rc}"
run_compose SOURCE_REF='refs/heads/x;id'
check "compose: a forged source ref is refused" "${work}/cmp.err" failed "${cmp_rc}"
run_compose OTHER_BRANCH=openwrt-24.10
check "compose: another base branch is refused" "${work}/cmp.err" failed "${cmp_rc}"
run_compose TARGET_BRANCH=feat/update-pr
check "compose: a target outside upstream-overlay/ is refused" "${work}/cmp.err" failed "${cmp_rc}"
run_compose SOURCE_LABEL=
check "compose: a source without a label is refused" "${work}/cmp.err" failed "${cmp_rc}"

# The default of upstream-pr.yml still works: the head of a pull request.
run_compose SOURCE_URL= SOURCE_REF= SOURCE_LABEL= PR_NUMBER=5 OTHER_BRANCH=master TARGET_BRANCH=upstream-overlay/pr5-1-1
check "compose: a pull request overlay: exits 0" "${work}/cmp.err" same "${cmp_rc}" 0
pr_sha=$(output sha)
got=$(git --git-dir="${work}/target.git" show "${pr_sha}:net/netbird/Makefile")
eq "compose: a pull request overlay: bumped netbird" "${got}" "PKG_VERSION:=0.81.5"
got=$(git --git-dir="${work}/target.git" log -1 --format=%s "${pr_sha}" | cut -d' ' -f1-5)
eq "compose: a pull request overlay: message" "${got}" "overlay of net/netbird from openwrt/packages#5"

# --- cleanup.sh -------------------------------------------------------------
# gh shim over target.git. DELETE of a ref removes it and fails, as the API
# does, when the ref does not exist. The listing of refs by prefix and the
# date of a commit answer what `--jq` would print (the shim ignores --jq).
# GH_SHIM_FAIL makes every call fail, GH_SHIM_FAIL_DELETE=<text> the deletes
# of the refs whose path contains the text,
# GH_SHIM_LIST_ALL makes the listing return every branch, GH_SHIM_PAGE=<n>
# makes a listing without --paginate return its first n branches only (as the
# API does with its first page), GH_SHIM_BAD_DATE makes the date of a commit
# unreadable. Every call is logged.
mkdir "${work}/bin"
cat >"${work}/bin/gh" <<'SHIM'
#!/usr/bin/env sh
echo "gh $*" >>"${SHIM_LOG}"
[ -z "${GH_SHIM_FAIL:-}" ] || exit 1
path=
for arg in "$@"; do
	case "${arg}" in
	repos/*) path=${arg} ;;
	*) ;;
	esac
done
case "$*" in
*matching-refs/heads/*)
	prefix=${path##*/matching-refs/heads/}
	[ -z "${GH_SHIM_LIST_ALL:-}" ] || prefix=
	limit=1000000
	case " $* " in
	*" --paginate "*) ;;
	*) limit=${GH_SHIM_PAGE:-1000000} ;;
	esac
	git --git-dir="${SHIM_TARGET}" for-each-ref --count="${limit}" --format='%(refname)%09%(objectname)' "refs/heads/${prefix}*"
	;;
*/commits/*)
	if [ -n "${GH_SHIM_BAD_DATE:-}" ]; then
		echo "not-a-date"
	else
		git --git-dir="${SHIM_TARGET}" log -1 --format=%ct "${path##*/}"
	fi
	;;
*DELETE*)
	case "${path}" in
	*"${GH_SHIM_FAIL_DELETE:-@none@}"*) exit 1 ;;
	*) ;;
	esac
	ref=refs/${path#repos/*/*/git/refs/}
	git --git-dir="${SHIM_TARGET}" rev-parse -q --verify "${ref}" >/dev/null || exit 1
	git --git-dir="${SHIM_TARGET}" update-ref -d "${ref}"
	;;
*) exit 99 ;;
esac
SHIM
chmod +x "${work}/bin/gh"
SHIM_LOG="${work}/gh.log"
SHIM_TARGET="${work}/target.git"
export SHIM_LOG SHIM_TARGET

# Run cleanup.sh against target.git; sets cln_rc and cln.out / cln.err.
#
# Arguments:
#   $@  overrides of the environment
run_cleanup() {
	cln_rc=0
	: >"${work}/gh.log"
	(
		# Outside any repository, as in the container of this test: the script
		# asks the remote only.
		cd "${work}"
		env PATH="${work}/bin:${PATH}" GITHUB_REPOSITORY=wehagy/openwrt-ci-packages REMOTE_URL="file://${work}/target.git" \
			BRANCH=upstream-overlay/update-netbird-1-1 "$@" "${script_dir}/upstream-pr/cleanup.sh"
	) >"${work}/cln.out" 2>"${work}/cln.err" || cln_rc=$?
}

# Print there or gone: whether target.git has the branch. Arguments: $1 branch.
target_state() {
	if git --git-dir="${work}/target.git" rev-parse -q --verify "refs/heads/$1" >/dev/null; then
		echo there
	else
		echo gone
	fi
}

git --git-dir="${work}/target.git" update-ref refs/heads/main "${overlay_sha}"
run_cleanup
check "cleanup: exits 0" "${work}/cln.err" same "${cln_rc}" 0
got=$(target_state upstream-overlay/update-netbird-1-1)
eq "cleanup: the overlay branch is gone" "${got}" gone
check "cleanup: says it deleted it" "${work}/cln.out" has "${work}/cln.out" "deleted wehagy/openwrt-ci-packages upstream-overlay/update-netbird-1-1"
got=$(target_state main)
eq "cleanup: the other branches stay" "${got}" there
got=$(target_state upstream-overlay/pr5-1-1)
eq "cleanup: the overlay of another run stays" "${got}" there

run_cleanup
check "cleanup: a branch that does not exist: exits 0" "${work}/cln.err" same "${cln_rc}" 0
check "cleanup: a branch that does not exist: says so" "${work}/cln.out" has "${work}/cln.out" "does not exist"
got=$(target_state main)
eq "cleanup: a branch that does not exist: the others stay" "${got}" there

for refused in main feat/update-pr upstream-overlay/ upstream-overlay/../main "upstream-overlay/x;id"; do
	run_cleanup BRANCH="${refused}"
	check "cleanup: refuses '${refused}'" "${work}/cln.err" failed "${cln_rc}"
	check "cleanup: '${refused}': no delete is made" "${work}/gh.log" empty "${work}/gh.log"
done
run_cleanup BRANCH=
check "cleanup: refuses an empty branch" "${work}/cln.err" failed "${cln_rc}"
got=$(target_state main)
eq "cleanup: refused branches are still there" "${got}" there

run_cleanup BRANCH=upstream-overlay/pr5-1-1 GH_SHIM_FAIL=1
check "cleanup: a failing delete of an existing branch fails" "${work}/cln.err" failed "${cln_rc}"
got=$(target_state upstream-overlay/pr5-1-1)
eq "cleanup: a failing delete leaves the branch" "${got}" there
run_cleanup BRANCH=upstream-overlay/pr5-1-1
check "cleanup: deletes another overlay branch by its name" "${work}/cln.out" same "${cln_rc}" 0

# --- sweep.sh ---------------------------------------------------------------
# Make a branch of target.git whose head was committed some seconds before
# sweep_now.
#
# Arguments:
#   $1  branch
#   $2  age in seconds
sweep_now=1700000000
aged_branch() {
	ab_tree=$(git --git-dir="${work}/target.git" mktree </dev/null)
	ab_date="@$((sweep_now - $2)) +0000"
	ab_sha=$(GIT_AUTHOR_DATE="${ab_date}" GIT_COMMITTER_DATE="${ab_date}" git --git-dir="${work}/target.git" commit-tree "${ab_tree}" -m "$1")
	git --git-dir="${work}/target.git" update-ref "refs/heads/$1" "${ab_sha}"
}

# Record a case that passes when target.git has (there) or has not (gone) a
# branch.
#
# Arguments:
#   $1  case name
#   $2  branch
#   $3  there or gone
state_case() {
	sc_got=$(target_state "$2")
	eq "$1" "${sc_got}" "$3"
}

# Run sweep.sh against target.git; sets swp_rc and swp.out / swp.err.
#
# Arguments:
#   $@  overrides of the environment
run_sweep() {
	swp_rc=0
	: >"${work}/gh.log"
	(
		cd "${work}"
		env PATH="${work}/bin:${PATH}" GITHUB_REPOSITORY=wehagy/openwrt-ci-packages REMOTE_URL="file://${work}/target.git" \
			NOW="${sweep_now}" "$@" "${script_dir}/upstream-pr/sweep.sh"
	) >"${work}/swp.out" 2>"${work}/swp.err" || swp_rc=$?
}

aged_branch upstream-overlay/update-old-1-1 172800
aged_branch upstream-overlay/update-fresh-1-1 3600
aged_branch upstream-overlay/pr7-1-1 259200
aged_branch upstream-overlay/custom-pr9-1-1 259200
run_sweep
check "sweep: exits 0" "${work}/swp.err" same "${swp_rc}" 0
state_case "sweep: a branch older than a day is deleted" upstream-overlay/update-old-1-1 gone
state_case "sweep: a branch younger than a day stays" upstream-overlay/update-fresh-1-1 there
state_case "sweep: an old branch of upstream-pr.yml stays" upstream-overlay/pr7-1-1 there
state_case "sweep: an old branch of custom-image.yml stays" upstream-overlay/custom-pr9-1-1 there
state_case "sweep: main stays" main there
check "sweep: counts" "${work}/swp.out" has "${work}/swp.out" "sweep: deleted 1, kept 1, failed 0"
check "sweep: deletes through cleanup.sh" "${work}/swp.out" has "${work}/swp.out" "deleted wehagy/openwrt-ci-packages upstream-overlay/update-old-1-1"

run_sweep MAX_AGE_HOURS=0
state_case "sweep: with no minimum age a young update branch goes too" upstream-overlay/update-fresh-1-1 gone
state_case "sweep: with no minimum age other workflows' branches stay" upstream-overlay/pr7-1-1 there

# Even when the listing hands over every branch, only update-* is touched.
run_sweep MAX_AGE_HOURS=0 GH_SHIM_LIST_ALL=1
check "sweep: a listing of every branch: exits 0" "${work}/swp.err" same "${swp_rc}" 0
state_case "sweep: a listing of every branch: main stays" main there
state_case "sweep: a listing of every branch: pr7 stays" upstream-overlay/pr7-1-1 there
check "sweep: a listing of every branch: no delete is made" "${work}/gh.log" lacks "${work}/gh.log" "DELETE"
check "sweep: nothing to do: says so" "${work}/swp.out" has "${work}/swp.out" "sweep: deleted 0, kept 0, failed 0"

aged_branch upstream-overlay/update-old-2-1 172800
aged_branch upstream-overlay/update-old-3-1 172800
run_sweep GH_SHIM_FAIL_DELETE=update-old-2
check "sweep: a failing delete fails the sweep" "${work}/swp.err" failed "${swp_rc}"
state_case "sweep: a failing delete leaves the branch" upstream-overlay/update-old-2-1 there
state_case "sweep: a failing delete does not stop the next branch" upstream-overlay/update-old-3-1 gone
check "sweep: a failing delete is counted" "${work}/swp.out" has "${work}/swp.out" "deleted 1, kept 0, failed 1"
run_sweep GH_SHIM_FAIL=1
check "sweep: a failing listing fails the sweep" "${work}/swp.err" failed "${swp_rc}"
check "sweep: a failing listing deletes nothing" "${work}/gh.log" lacks "${work}/gh.log" "DELETE"
run_sweep MAX_AGE_HOURS=abc
check "sweep: a bad age fails" "${work}/swp.err" failed "${swp_rc}"
check "sweep: a bad age asks nothing" "${work}/gh.log" empty "${work}/gh.log"
run_sweep
state_case "sweep: the next sweep deletes what the failing one left" upstream-overlay/update-old-2-1 gone

# A date that cannot be read fails the job (visibly, in the counts) and deletes
# nothing: the age of the branch is unknown.
aged_branch upstream-overlay/update-baddate-1-1 172800
run_sweep GH_SHIM_BAD_DATE=1
check "sweep: an unreadable date fails the sweep" "${work}/swp.err" failed "${swp_rc}"
check "sweep: an unreadable date is reported" "${work}/swp.out" has "${work}/swp.out" "::error::could not read the date"
check "sweep: an unreadable date is counted" "${work}/swp.out" has "${work}/swp.out" "sweep: deleted 0, kept 0, failed 1"
check "sweep: an unreadable date deletes nothing" "${work}/gh.log" lacks "${work}/gh.log" "DELETE"
state_case "sweep: an unreadable date leaves the branch" upstream-overlay/update-baddate-1-1 there
run_sweep
state_case "sweep: a readable date deletes it after all" upstream-overlay/update-baddate-1-1 gone

# More branches than one page of the API: every page is read, none is left
# behind unnoticed.
aged_branch upstream-overlay/update-page-1-1 172800
aged_branch upstream-overlay/update-page-2-1 172800
aged_branch upstream-overlay/update-page-3-1 172800
run_sweep GH_SHIM_PAGE=2
check "sweep: several pages: exits 0" "${work}/swp.err" same "${swp_rc}" 0
check "sweep: several pages: lists with --paginate" "${work}/gh.log" has "${work}/gh.log" "--paginate"
state_case "sweep: several pages: a branch of the first page goes" upstream-overlay/update-page-1-1 gone
state_case "sweep: several pages: a branch past the first page goes" upstream-overlay/update-page-3-1 gone
check "sweep: several pages: counts" "${work}/swp.out" has "${work}/swp.out" "sweep: deleted 3, kept 0, failed 0"

# --- update.yml: the wiring of the jobs --------------------------------------
# The value of an expression on update.yml, as text.
#
# Arguments:
#   $1  yq expression
wf() {
	yq -r "$1" "${workflow}"
}

# Succeed when a job lists another in needs. Arguments: $1 job, $2 needed job.
needs() {
	n_found=$(wf ".jobs.\"$1\".needs | (select(tag == \"!!seq\") | .[]) // . | select(. == \"$2\")")
	[ "${n_found}" = "$2" ]
}

# One matrix job runs every line (line.yml); the lines come from compose, which
# knows the commit each line builds. No line is named in the workflow.
got=$(wf '.jobs.lines.uses')
eq "wiring: the lines run through line.yml" "${got}" ./.github/workflows/line.yml
got=$(wf '.jobs.lines.strategy.matrix')
eq "wiring: the matrix is the one compose made" "${got}" "\${{ fromJSON(needs.compose.outputs.matrix) }}"
got=$(wf '.jobs.lines.strategy."fail-fast"')
eq "wiring: a failing line does not cancel the others" "${got}" false
check "wiring: the lines wait for compose" "needs" needs lines compose
check "wiring: the lines wait for detect" "needs" needs lines detect
got=$(wf '.jobs.lines.with.feed_repository')
eq "wiring: each line builds the repository its matrix entry names" "${got}" "\${{ matrix.feed_repository }}"
got=$(wf '.jobs.lines.with.feed_ref')
eq "wiring: each line builds the commit its matrix entry names" "${got}" "\${{ matrix.feed_ref }}"
got=$(wf '.jobs.lines.with.line')
eq "wiring: each leg is one line" "${got}" "\${{ matrix.line }}"
check "wiring: compose waits for prepare" "needs" needs compose prepare
check "wiring: compose waits for detect" "needs" needs compose detect

compose_step='.jobs.compose.steps[] | select(.id == "compose").env'
got=$(wf "${compose_step}.OTHER_LINES")
eq "wiring: compose overlays the lines other than the reference" "${got}" "\${{ needs.detect.outputs.others }}"
got=$(wf "${compose_step}.REFERENCE_LINE")
eq "wiring: compose names the reference line" "${got}" "\${{ needs.detect.outputs.reference }}"
got=$(wf "${compose_step}.REFERENCE_FEED_REF")
eq "wiring: the reference line builds the bump commit" "${got}" "\${{ needs.prepare.outputs.sha }}"
got=$(wf "${compose_step}.REFERENCE_FEED_REPOSITORY")
eq "wiring: the reference line builds the review repository" "${got}" "\${{ needs.detect.outputs.review_repository }}"
got=$(wf "${compose_step}.OVERLAY_DIRS")
eq "wiring: compose overlays the package directory" "${got}" "\${{ needs.detect.outputs.package_path }}"
got=$(wf "${compose_step}.HEAD_SHA")
eq "wiring: compose takes the bump commit" "${got}" "\${{ needs.prepare.outputs.sha }}"
got=$(wf "${compose_step}.SOURCE_REF")
eq "wiring: compose reads the update branch of the review repository" "${got}" "refs/heads/\${{ needs.detect.outputs.update_branch }}"
got=$(wf "${compose_step}.SOURCE_URL")
eq "wiring: compose reads the review repository" "${got}" "https://github.com/\${{ needs.detect.outputs.review_repository }}.git"
got=$(wf "${compose_step}.TOLERATE_FAILURE")
eq "wiring: another line never stops the reference line" "${got}" true
got=$(wf "${compose_step}.TARGET_PREFIX")
eq "wiring: compose and cleanup use the same branch prefix" "${got}" "\${{ env.OVERLAY_PREFIX }}"
cleanup_run=$(wf '.jobs.cleanup.steps[] | select(has("run")).run')
got=$(printf '%s\n' "${cleanup_run}" | grep -cF "BRANCH=\"\${OVERLAY_PREFIX}-\${line}\"" || :)
eq "wiring: cleanup deletes the branch of each line under that prefix" "${got}" 1
got=$(wf '.env.OVERLAY_PREFIX' | cut -c1-17)
eq "wiring: the overlay branches are under upstream-overlay/" "${got}" upstream-overlay/
got=$(wf '.jobs.cleanup.if')
eq "wiring: cleanup runs on every path" "${got}" "\${{ always() && needs.compose.result != 'skipped' }}"
check "wiring: cleanup waits for compose" "needs" needs cleanup compose
check "wiring: cleanup waits for the lines" "needs" needs cleanup lines
check "wiring: publish waits for compose" "needs" needs publish compose
check "wiring: publish waits for cleanup" "needs" needs publish cleanup
check "wiring: the description gets the overlays" "report" has "${workflow}" "OVERLAYS: \${{ needs.compose.outputs.overlays }}"
check "wiring: the description gets the lines of the package" "report" has "${workflow}" "LINES: \${{ needs.detect.outputs.lines }}"
check "wiring: the description gets the reference line" "report" has "${workflow}" "REFERENCE: \${{ needs.detect.outputs.reference }}"
check "wiring: the decision runs decide.sh" "decide" has "${workflow}" "run: scripts/decide.sh | tee -a"
decide_env='.jobs.publish.steps[] | select(.id == "decide").env'
got=$(wf "${decide_env}.MATRIX")
eq "wiring: the decision checks the commits compose asked each line to build" "${got}" "\${{ needs.compose.outputs.matrix }}"
got=$(wf "${decide_env}.REPORT_PASSED")
eq "wiring: the decision also takes the verdict of the description" "${got}" "\${{ steps.report.outputs.reference_passed }}"
# The per-line outcome comes from the artifacts of the legs. The aggregate
# result of a matrix job (and its overwritten outputs) is never a source.
got=$(grep -c 'needs\.lines\.\(result\|outputs\)' "${workflow}" || :)
eq "wiring: nothing reads the aggregate result or outputs of the matrix job" "${got}" 0

# The same configuration as ci.yml: every input that ci.yml takes from its
# config job update.yml takes, under the same name, from the detect job (which
# reads the same file with the same script), and detect has a step that runs
# scripts/images/config.sh.
ci_workflow="${script_dir}/../.github/workflows/ci.yml"
# Print "<input>=<output name>" for the inputs of a job whose value reads an
# output of the given job, except package, the feed and the tests path
# (not settings of config.yml).
#
# Arguments:
#   $1  workflow file
#   $2  job whose inputs are read
#   $3  job whose outputs they read (config or detect)
config_inputs() {
	yq -r ".jobs.\"$2\".with | to_entries[] | select(.value | tag == \"!!str\") | select(.value | contains(\"needs.$3.outputs.\")) | .key + \"=\" + (.value | split(\"outputs.\")[1] | split(\" \")[0])" "$1" | grep -v '^package=\|^feed_\|^tests_path='
}
job=lines
want=$(config_inputs "${ci_workflow}" "${job}" config | tr '\n' ' ')
got=$(config_inputs "${workflow}" "${job}" detect | tr '\n' ' ')
check "wiring: ${job} gets what ci.yml gives it from config.yml" "${want}" same "${got}" "${want}"
check "wiring: ${job} gets at least one setting from config.yml" "none" test -n "${got}"
config_run=$(wf '.jobs.detect.steps[] | select(.id == "images").run')
eq "wiring: detect reads config.yml with scripts/images/config.sh" "${config_run}" "scripts/images/config.sh netbird | tee -a \"\${GITHUB_OUTPUT}\""
for key in profiles packages targets memory apk_timeout services_disabled; do
	got=$(wf ".jobs.detect.outputs.${key}")
	eq "wiring: detect exports ${key} from the config step" "${got}" "\${{ steps.images.outputs.${key} }}"
done
check "wiring: detect self-tests the config reader" "selftest" has "${workflow}" "scripts/images/selftest.sh"
job=lines
got=$(wf ".jobs.\"${job}\".with.test_secrets")
eq "wiring: ${job}: the NetBird runtime tests get NB_SETUP_KEY" "${got}" NB_SETUP_KEY
got=$(wf ".jobs.\"${job}\".secrets")
eq "wiring: ${job}: the tests inherit the repository secrets" "${got}" inherit
got=$(wf ".jobs.\"${job}\".with.tests_path")
eq "wiring: ${job}: the package tests directory is given" "${got}" "packages/\${{ needs.detect.outputs.package }}/tests"
got=$(wf ".jobs.\"${job}\" | has(\"environment\")")
eq "wiring: ${job} has no environment" "${got}" false
report_env='.jobs.publish.steps[] | select(.id == "report").env'
got=$(wf "${report_env}.TEST_SECRETS")
eq "wiring: the description names the secrets the test jobs pass" "${got}" NB_SETUP_KEY

# Write access only where the overlay branch is pushed and deleted.
writers=$(wf '.jobs | to_entries[] | select(.value.permissions.contents == "write") | .key' | sort | tr '\n' ' ')
check "wiring: only compose, cleanup and sweep have contents: write" "${writers}" same "${writers}" "cleanup compose sweep "
got=$(wf '.permissions.contents')
eq "wiring: the workflow default is read only" "${got}" read
# The token of the review repository: only the two jobs of the environment.
got=$(wf '.jobs | to_entries[] | select(.value | has("environment")) | .key' | sort | tr '\n' ' ')
eq "wiring: only prepare and publish have an environment" "${got}" "prepare publish "
for job in compose cleanup sweep; do
	got=$(wf ".jobs.${job} | has(\"environment\")")
	eq "wiring: ${job} has no environment" "${got}" false
	job_yaml=$(wf ".jobs.${job}")
	got=$(printf '%s\n' "${job_yaml}" | grep -o 'secrets\.[A-Za-z_]*' | grep -vc 'secrets.GITHUB_TOKEN' || :)
	eq "wiring: ${job} sees no secret but the github token" "${got}" 0
	got=$(wf ".jobs.${job} | has(\"secrets\")")
	eq "wiring: ${job} passes no secrets" "${got}" false
done

# --- the guards that decide, and the order that keeps them (mutants: each line
# of this part fails when the thing it names is removed) ----------------------
got=$(wf '.concurrency.group')
eq "wiring: one update run at a time: the group" "${got}" update-netbird
got=$(wf '.concurrency."cancel-in-progress"')
eq "wiring: one update run at a time: a queued run is not cancelled" "${got}" false
got=$(wf '.jobs.publish.if')
eq "wiring: publish runs after any result once prepare pushed" "${got}" "\${{ always() && needs.prepare.result == 'success' }}"
got=$(wf '.jobs.publish.steps[] | select(.id == "open_pr").if')
eq "wiring: the pull request opens only on a decision to open" "${got}" "\${{ steps.decide.outputs.open == 'true' }}"
got=$(wf '.jobs.publish.steps[] | select(.name == "Delete the two branches unless a pull request was opened").if')
eq "wiring: the two branches are deleted on every way out but an opened pull request" "${got}" "\${{ always() && steps.open_pr.outcome != 'success' }}"
got=$(wf '.jobs.prepare.steps[-1].if')
eq "wiring: prepare deletes its branches on failure and cancellation" "${got}" "\${{ failure() || cancelled() }}"
for job in detect prepare compose lines cleanup; do
	check "wiring: publish waits for ${job}" "needs" needs publish "${job}"
done
needs_text=$(wf '.jobs | to_entries[] | select(.key != "publish") | .value.needs')
got=$(printf '%s\n' "${needs_text}" | grep -c sweep || :)
eq "wiring: no job waits for the sweep" "${got}" 0
got=$(wf '.jobs.sweep | has("needs")')
eq "wiring: the sweep waits for no job" "${got}" false
got=$(wf '.jobs.sweep.steps[-1].run')
eq "wiring: the sweep runs sweep.sh" "${got}" scripts/upstream-pr/sweep.sh
got=$(wf '.jobs.sweep.steps[-1].env.MAX_AGE_HOURS')
eq "wiring: the sweep deletes branches older than a day" "${got}" 24
got=$(wf '.jobs.sweep | has("secrets")')
eq "wiring: the sweep passes no secrets" "${got}" false
job_yaml=$(wf '.jobs.sweep | tostring')
got=$(printf '%s\n' "${job_yaml}" | grep -o 'secrets\.[A-Za-z_]*' | grep -vc 'secrets.GITHUB_TOKEN' || :)
eq "wiring: the sweep sees no secret" "${got}" 0

# The production guard and the test results reach the description, and the
# guard runs in detect, before anything is pushed.
got=$(wf '.jobs.detect.outputs.upstream_base')
eq "wiring: detect exports the upstream base" "${got}" "\${{ steps.upstream_base.outputs.upstream_base }}"
got=$(wf '.jobs.detect.steps[] | select(.id == "upstream_base").run')
eq "wiring: detect checks the base with check-fork-base.sh" "${got}" "scripts/check-fork-base.sh | tee -a \"\${GITHUB_OUTPUT}\""
got=$(wf '.jobs.detect.steps[] | select(.id == "upstream_base").env.REVIEW_IS_FORK')
eq "wiring: the base check knows whether the review repository is a fork" "${got}" "\${{ steps.fork.outputs.review_is_fork }}"
got=$(wf '.jobs.detect.steps[] | select(.id == "upstream_base").if')
eq "wiring: the base check runs when an update is needed" "${got}" "\${{ steps.plan.outputs.needed == 'true' }}"
got=$(wf '.jobs.detect.steps | to_entries[] | select(.value.id == "upstream_base") | .key')
fork_at=$(wf '.jobs.detect.steps | to_entries[] | select(.value.id == "fork") | .key')
check "wiring: the base check follows the fork check" "${got} ${fork_at}" test "${got}" -gt "${fork_at}"
check "wiring: prepare follows detect, so the base is checked before a push" "needs" needs prepare detect
got=$(wf "${report_env}.UPSTREAM_BASE")
eq "wiring: the description gets the upstream base" "${got}" "\${{ needs.detect.outputs.upstream_base }}"
check "wiring: report.py gets the upstream base" "report" has "${workflow}" "--upstream-base \"\${UPSTREAM_BASE}\""
check "wiring: report.py gets the results directory" "report" has "${workflow}" "--results results"
check "wiring: report.py gets the secret names" "report" has "${workflow}" "--test-secrets \"\${TEST_SECRETS}\""
download_run=$(wf '.jobs.publish.steps[] | select(.name == "Download the test results").run')
got=$(printf '%s\n' "${download_run}" | grep -cF "gh run download \"\${GITHUB_RUN_ID}\" --repo \"\${GITHUB_REPOSITORY}\" --pattern \"qemu-\${PACKAGE}-*\" --dir results" || :)
eq "wiring: publish downloads the QEMU results of this run" "${got}" 1
got=$(wf '.jobs.publish.steps | to_entries[] | select(.value.name == "Download the test results") | .key')
report_at=$(wf '.jobs.publish.steps | to_entries[] | select(.value.id == "report") | .key')
got=$(printf '%s\n' "${download_run}" | grep -cF "gh run download \"\${GITHUB_RUN_ID}\" --repo \"\${GITHUB_REPOSITORY}\" --pattern \"line-result-\${PACKAGE}-*\" --dir line-results" || :)
eq "wiring: publish downloads the result file of every line of this run" "${got}" 1
check "wiring: report.py gets the line results" "report" has "${workflow}" "--line-results line-results"
check "wiring: the results are downloaded before the description" "${got} ${report_at}" test "${got}" -lt "${report_at}"
got=$(wf '.jobs.publish.permissions.actions')
eq "wiring: publish may read the artifacts of the run" "${got}" read

finish
