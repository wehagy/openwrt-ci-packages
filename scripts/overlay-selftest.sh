#!/usr/bin/env sh
# Responsibility: offline tests of how update.yml builds line 25.12: the tree
# that scripts/upstream-pr/compose.sh makes from the bump commit (openwrt-25.12
# plus only the package directory), the cleanup of the overlay branch
# (scripts/upstream-pr/cleanup.sh) and the wiring of the jobs in update.yml
# (which commit each line builds, who may write, who sees which secret). Local
# bare repositories stand in for openwrt/packages, the review repository and
# this repository; a gh shim stands in for the delete. Nothing reaches GitHub.
# Run by update-selftest.sh.
#
# Usage:
#   scripts/overlay-selftest.sh   (needs git and yq)
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
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
git init -q --bare "${work}/upstream.git"
git -C "${work}/src" push -q "file://${work}/upstream.git" openwrt-25.12:refs/heads/openwrt-25.12 master~1:refs/heads/master "${bump_sha}:refs/pull/5/head"
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
# GH_SHIM_LIST_ALL makes the listing return every branch. Every call is logged.
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
	git --git-dir="${SHIM_TARGET}" for-each-ref --format='%(refname)%09%(objectname)' "refs/heads/${prefix}*"
	;;
*/commits/*)
	git --git-dir="${SHIM_TARGET}" log -1 --format=%ct "${path##*/}"
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

got=$(wf '.jobs."build-25-12".with.feed_repository')
eq "wiring: line 25.12 builds a commit of this repository" "${got}" "\${{ github.repository }}"
got=$(wf '.jobs."build-25-12".with.feed_ref')
eq "wiring: line 25.12 builds the overlay commit" "${got}" "\${{ needs.compose.outputs.sha }}"
check "wiring: line 25.12 waits for compose" "needs" needs build-25-12 compose
got=$(wf '.jobs."build-main".with.feed_repository')
eq "wiring: line main builds the review repository" "${got}" "\${{ needs.detect.outputs.review_repository }}"
got=$(wf '.jobs."build-main".with.feed_ref')
eq "wiring: line main builds the bump commit" "${got}" "\${{ needs.prepare.outputs.sha }}"
check "wiring: compose waits for prepare" "needs" needs compose prepare
check "wiring: test and image of 25.12 follow its build" "needs" needs test-25-12 build-25-12
check "wiring: image of 25.12 follows its build" "needs" needs image-25-12 build-25-12

compose_step='.jobs.compose.steps[] | select(.id == "compose").env'
got=$(wf "${compose_step}.OTHER_BRANCH")
eq "wiring: compose overlays onto openwrt-25.12" "${got}" openwrt-25.12
got=$(wf "${compose_step}.OVERLAY_DIRS")
eq "wiring: compose overlays the package directory" "${got}" "\${{ needs.detect.outputs.package_path }}"
got=$(wf "${compose_step}.HEAD_SHA")
eq "wiring: compose takes the bump commit" "${got}" "\${{ needs.prepare.outputs.sha }}"
got=$(wf "${compose_step}.SOURCE_REF")
eq "wiring: compose reads the update branch of the review repository" "${got}" "refs/heads/\${{ needs.detect.outputs.update_branch }}"
got=$(wf "${compose_step}.SOURCE_URL")
eq "wiring: compose reads the review repository" "${got}" "https://github.com/\${{ needs.detect.outputs.review_repository }}.git"
got=$(wf "${compose_step}.TARGET_BRANCH")
cleanup_branch=$(wf '.jobs.cleanup.steps[] | select(has("env")).env.BRANCH')
eq "wiring: compose and cleanup use the same branch" "${got}" "${cleanup_branch}"
got=$(wf '.env.OVERLAY_BRANCH' | cut -c1-17)
eq "wiring: the overlay branch is under upstream-overlay/" "${got}" upstream-overlay/
got=$(wf '.jobs.cleanup.if')
eq "wiring: cleanup runs on every path" "${got}" "\${{ always() && needs.compose.result != 'skipped' }}"
check "wiring: cleanup waits for compose" "needs" needs cleanup compose
check "wiring: cleanup waits for the 25.12 build" "needs" needs cleanup build-25-12
check "wiring: publish waits for compose" "needs" needs publish compose
check "wiring: publish waits for cleanup" "needs" needs publish cleanup
check "wiring: the description gets the base of the overlay" "report" has "${workflow}" "OVERLAY_BASE_SHA: \${{ needs.compose.outputs.base_sha }}"
check "wiring: publish checks the commit line 25.12 built" "decide" has "${workflow}" "\"\${FEED_SHA_25_12}\" != \"\${OVERLAY_SHA}\""

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
for job in build-25-12 build-main test-25-12 test-main image-25-12 image-main; do
	want=$(config_inputs "${ci_workflow}" "${job}" config | tr '\n' ' ')
	got=$(config_inputs "${workflow}" "${job}" detect | tr '\n' ' ')
	check "wiring: ${job} gets what ci.yml gives it from config.yml" "${want}" same "${got}" "${want}"
	check "wiring: ${job} gets at least one setting from config.yml" "none" test -n "${got}"
done
config_run=$(wf '.jobs.detect.steps[] | select(.id == "images").run')
eq "wiring: detect reads config.yml with scripts/images/config.sh" "${config_run}" "scripts/images/config.sh netbird | tee -a \"\${GITHUB_OUTPUT}\""
for key in profiles packages targets memory apk_timeout services_disabled; do
	got=$(wf ".jobs.detect.outputs.${key}")
	eq "wiring: detect exports ${key} from the config step" "${got}" "\${{ steps.images.outputs.${key} }}"
done
check "wiring: detect self-tests the config reader" "selftest" has "${workflow}" "scripts/images/selftest.sh"
for job in test-25-12 test-main; do
	got=$(wf ".jobs.\"${job}\".with.test_secrets")
	eq "wiring: ${job}: the NetBird runtime tests get NB_SETUP_KEY" "${got}" NB_SETUP_KEY
	got=$(wf ".jobs.\"${job}\".secrets")
	eq "wiring: ${job}: the tests inherit the repository secrets" "${got}" inherit
	got=$(wf ".jobs.\"${job}\".with.tests_path")
	eq "wiring: ${job}: the package tests directory is given" "${got}" "packages/\${{ needs.detect.outputs.package }}/tests"
	got=$(wf ".jobs.\"${job}\" | has(\"environment\")")
	eq "wiring: ${job} has no environment" "${got}" false
done
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
for job in detect prepare compose build-25-12 cleanup build-main test-25-12 test-main image-25-12 image-main; do
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

# The Decide step as a script: it is run with the values of every case. The
# commit the base reports must be the one this run made, and only a green line
# main opens a pull request.
wf '.jobs.publish.steps[] | select(.id == "decide").run' >"${work}/decide.sh"
sha_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sha_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
sha_c=cccccccccccccccccccccccccccccccccccccccc
# Run the Decide step; sets dec_rc and the files dec.out ($GITHUB_OUTPUT) and
# dec.log. Everything passed, with the right commits, unless overridden.
#
# Arguments:
#   $@  overrides of the environment
run_decide() {
	dec_rc=0
	: >"${work}/dec.out"
	env BUILD=success TEST=success IMAGE=success REPORT_PASSED=true FEED_SHA_MAIN="${sha_a}" HEAD_SHA="${sha_a}" \
		BUILD_25_12=success FEED_SHA_25_12="${sha_b}" OVERLAY_SHA="${sha_b}" GITHUB_OUTPUT="${work}/dec.out" \
		"$@" sh "${work}/decide.sh" >"${work}/dec.log" 2>&1 || dec_rc=$?
}
run_decide
check "decide: all green: exits 0" "${work}/dec.log" same "${dec_rc}" 0
check "decide: all green: opens" "${work}/dec.out" has "${work}/dec.out" "open=true"
run_decide FEED_SHA_MAIN="${sha_c}"
check "decide: line main built another commit: fails" "${work}/dec.log" failed "${dec_rc}"
check "decide: line main built another commit: says so" "${work}/dec.log" has "${work}/dec.log" "line main built ${sha_c}, not the bump commit ${sha_a}"
check "decide: line main built another commit: no decision" "${work}/dec.out" lacks "${work}/dec.out" "open="
run_decide FEED_SHA_MAIN=
check "decide: line main reported no commit: fails" "${work}/dec.log" failed "${dec_rc}"
run_decide FEED_SHA_25_12="${sha_c}"
check "decide: line 25.12 built another commit: fails" "${work}/dec.log" failed "${dec_rc}"
check "decide: line 25.12 built another commit: says so" "${work}/dec.log" has "${work}/dec.log" "line 25.12 built ${sha_c}, not the overlay commit ${sha_b}"
check "decide: line 25.12 built another commit: no decision" "${work}/dec.out" lacks "${work}/dec.out" "open="
run_decide BUILD_25_12=failure FEED_SHA_25_12=
check "decide: line 25.12 failed to build: exits 0" "${work}/dec.log" same "${dec_rc}" 0
check "decide: line 25.12 failed to build: still opens" "${work}/dec.out" has "${work}/dec.out" "open=true"
run_decide BUILD=failure FEED_SHA_MAIN=
check "decide: line main failed to build: exits 0" "${work}/dec.log" same "${dec_rc}" 0
check "decide: line main failed to build: no pull request" "${work}/dec.out" has "${work}/dec.out" "open=false"
for stage in TEST IMAGE; do
	for result in failure cancelled skipped; do
		run_decide "${stage}=${result}"
		check "decide: ${stage} ${result}: no pull request" "${work}/dec.out" has "${work}/dec.out" "open=false"
	done
done
run_decide REPORT_PASSED=false
check "decide: the description disagrees: no pull request" "${work}/dec.out" has "${work}/dec.out" "open=false"
run_decide REPORT_PASSED=
check "decide: no verdict of the description: no pull request" "${work}/dec.out" has "${work}/dec.out" "open=false"

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
check "wiring: the results are downloaded before the description" "${got} ${report_at}" test "${got}" -lt "${report_at}"
got=$(wf '.jobs.publish.permissions.actions')
eq "wiring: publish may read the artifacts of the run" "${got}" read

finish
