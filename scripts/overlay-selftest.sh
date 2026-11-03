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

# Succeed when an exit status is not 0: a refusal. A failed `:?` exits with 1 or
# 2, depending on the shell.
#
# Arguments:
#   $1  exit status
failed() {
	[ "$1" -ne 0 ]
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
# gh shim: the DELETE of a ref removes it from target.git; GH_SHIM_FAIL makes it
# fail. Every call is logged.
mkdir "${work}/bin"
cat >"${work}/bin/gh" <<SHIM
#!/usr/bin/env sh
echo "gh \$*" >>"${work}/gh.log"
[ -z "\${GH_SHIM_FAIL:-}" ] || exit 1
ref=\${4#repos/*/*/git/refs/}
git --git-dir="${work}/target.git" update-ref -d "refs/\${ref#refs/}"
SHIM
chmod +x "${work}/bin/gh"

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
check "cleanup: a branch that does not exist: no delete is made" "${work}/gh.log" empty "${work}/gh.log"

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
check "cleanup: a failing delete fails" "${work}/cln.err" failed "${cln_rc}"
run_cleanup BRANCH=upstream-overlay/pr5-1-1
check "cleanup: deletes another overlay branch by its name" "${work}/cln.out" same "${cln_rc}" 0

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

# Write access only where the overlay branch is pushed and deleted.
writers=$(wf '.jobs | to_entries[] | select(.value.permissions.contents == "write") | .key' | sort | tr '\n' ' ')
check "wiring: only compose and cleanup have contents: write" "${writers}" same "${writers}" "cleanup compose "
got=$(wf '.permissions.contents')
eq "wiring: the workflow default is read only" "${got}" read
# The token of the review repository: only the two jobs of the environment.
got=$(wf '.jobs | to_entries[] | select(.value | has("environment")) | .key' | sort | tr '\n' ' ')
eq "wiring: only prepare and publish have an environment" "${got}" "prepare publish "
for job in compose cleanup; do
	got=$(wf ".jobs.${job} | has(\"environment\")")
	eq "wiring: ${job} has no environment" "${got}" false
	job_yaml=$(wf ".jobs.${job}")
	got=$(printf '%s\n' "${job_yaml}" | grep -o 'secrets\.[A-Za-z_]*' | grep -vc 'secrets.GITHUB_TOKEN' || :)
	eq "wiring: ${job} sees no secret but the github token" "${got}" 0
	got=$(wf ".jobs.${job} | has(\"secrets\")")
	eq "wiring: ${job} passes no secrets" "${got}" false
done

finish
