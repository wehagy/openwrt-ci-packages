#!/usr/bin/env sh
# Responsibility: offline tests of the wiring of the workflows that run a line
# (.github/workflows/line.yml) and of how their callers (ci.yml, update.yml,
# upstream-pr.yml) hand it secrets. A workflow cannot run here, so each case
# reads the YAML (yq) and compares the text of what a mutation would change:
# the job `result` that writes the outcome of a leg (it must run whatever
# happened before and read all three jobs), the two QEMU test jobs (secrets
# only when asked for), the guard against a feed without a ref, the callers'
# secrets (upstream-pr.yml runs code of a pull request: none) and the
# expressions that choose the commit of a leg.
#
# Usage:
#   scripts/workflow-selftest.sh   (needs yq)
#
# Environment variables: none.

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
workflows="${script_dir}/../.github/workflows"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/selftest.sh
. "${script_dir}/lib/selftest.sh"

# Compare a value with the expected one and record the case.
#
# Arguments:
#   $1  case name
#   $2  value read
#   $3  expected value
eq() {
	if [ "$2" = "$3" ]; then
		record "$1" 0 ""
	else
		record "$1" 1 "got [$2], expected [$3]"
	fi
}

# Compare the value of a yq expression on a workflow with the expected one.
#
# Arguments:
#   $1  case name
#   $2  workflow file name (without .yml)
#   $3  yq expression
#   $4  expected value
expect() {
	ex_got=$(wf "$2" "$3")
	eq "$1" "${ex_got}" "$4"
}

# The value of a yq expression on a workflow, as text.
#
# Arguments:
#   $1  workflow file name (without .yml)
#   $2  yq expression
wf() {
	yq -r "$2" "${workflows}/$1.yml"
}

# --- line.yml: the job `result` ---------------------------------------------
# It writes the artifact the publish job, the reports and the decision read.
# Without `always()` it would vanish exactly when a stage failed.
expect "line.yml: result runs whatever happened before" line '.jobs.result.if' "\${{ always() }}"
for need in build test test_secrets image; do
	got=$(wf line ".jobs.result.needs | map(select(. == \"${need}\")) | length")
	eq "line.yml: result waits for ${need}" "${got}" 1
done
expect "line.yml: result waits for nothing else" line '.jobs.result.needs | length' 4
env_of='.jobs.result.steps[] | select(.name == "Write the result of the line").env'
expect "line.yml: result takes the build outcome of the build job" line "${env_of}.BUILD" "\${{ needs.build.result }}"
expect "line.yml: result takes the test outcome of the test jobs" line "${env_of}.TEST" "\${{ needs.test.result != 'skipped' && needs.test.result || needs.test_secrets.result }}"
expect "line.yml: result takes the image outcome, or says images were not requested" line "${env_of}.IMAGE" "\${{ inputs.with_images && needs.image.result || 'not requested' }}"
expect "line.yml: result takes the commit the build reports" line "${env_of}.FEED_SHA" "\${{ needs.build.outputs.feed_sha }}"
expect "line.yml: result names its line" line "${env_of}.LINE" "\${{ inputs.line }}"
expect "line.yml: result names its package" line "${env_of}.PACKAGE" "\${{ inputs.package }}"
expect "line.yml: result runs line-result.sh" line '.jobs.result.steps[] | select(.name == "Write the result of the line").run' "scripts/line-result.sh line-result/result.json"
expect "line.yml: result uploads one artifact per package and line" line '.jobs.result.steps[-1].with.name' "line-result-\${{ inputs.package }}-\${{ inputs.line }}"
expect "line.yml: result fails when there is no file to upload" line '.jobs.result.steps[-1].with."if-no-files-found"' error
expect "line.yml: result does not overwrite an artifact of that name" line '.jobs.result.steps[-1].with | has("overwrite")' false
expect "line.yml: result only reads the repository" line '.jobs.result.permissions // "workflow default"' "workflow default"
expect "line.yml: the workflow default is read only" line '.permissions.contents' read
expect "line.yml: nothing but build has more than read" line '[.jobs | to_entries[] | select(.value.permissions != null) | .key] | join(" ")' build

# --- line.yml: the jobs of a leg --------------------------------------------
expect "line.yml: the image job runs only when images are asked for" line '.jobs.image.if' "\${{ inputs.with_images }}"
for job in build test test_secrets image; do
	got=$(wf line ".jobs.${job}.uses")
	file=${got##*/}
	eq "line.yml: ${job} calls its own workflow of the base" "${got%@*}" "wehagy/openwrt-ci/.github/workflows/${file%@*}"
	case "${job}" in
	build) want_file=build.yml ;;
	image) want_file=images.yml ;;
	*) want_file=test.yml ;;
	esac
	eq "line.yml: ${job} calls ${want_file}" "${file%@*}" "${want_file}"
	eq "line.yml: ${job} takes the workflow of the base from main" "${got##*@}" main
	expect "line.yml: ${job} takes the scripts of the base from main" line ".jobs.${job}.with.ci_ref" main
	expect "line.yml: ${job} runs the line of the leg" line ".jobs.${job}.with.line" "\${{ inputs.line }}"
	expect "line.yml: ${job} runs the package of the leg" line ".jobs.${job}.with.package" "\${{ inputs.package }}"
done
expect "line.yml: build waits for the feed check" line '.jobs.build.needs' check
expect "line.yml: test waits for build" line '.jobs.test.needs' build
expect "line.yml: test_secrets waits for build" line '.jobs.test_secrets.needs' build
expect "line.yml: image waits for build" line '.jobs.image.needs' build

# --- line.yml: secrets only when the caller asks for them -------------------
expect "line.yml: test runs only without test_secrets" line '.jobs.test.if' "\${{ inputs.test_secrets == '' }}"
expect "line.yml: test_secrets runs only with test_secrets" line '.jobs.test_secrets.if' "\${{ inputs.test_secrets != '' }}"
expect "line.yml: test gets no secrets" line '.jobs.test | has("secrets")' false
expect "line.yml: test is given no test_secrets" line '.jobs.test.with | has("test_secrets")' false
expect "line.yml: test_secrets inherits the secrets of the caller" line '.jobs.test_secrets.secrets' inherit
expect "line.yml: test_secrets passes the names the caller gave" line '.jobs.test_secrets.with.test_secrets' "\${{ inputs.test_secrets }}"
expect "line.yml: it is the only job with secrets" line '[.jobs | to_entries[] | select(.value | has("secrets")) | .key] | join(" ")' test_secrets
same_with=$(wf line '.jobs.test_secrets.with | del(.test_secrets)')
expect "line.yml: the two test jobs take the same inputs" line '.jobs.test.with' "${same_with}"
expect "line.yml: the workflow declares no secrets of its own" line '.on.workflow_call | has("secrets")' false
expect "line.yml: test_secrets defaults to none" line '.on.workflow_call.inputs.test_secrets.default' ""

# --- line.yml: a feed repository without a ref stops the leg ---------------
check_run=$(wf line '.jobs.check.steps[0].run')
expect "line.yml: the check reads the feed repository" line '.jobs.check.steps[0].env.FEED_REPOSITORY' "\${{ inputs.feed_repository }}"
expect "line.yml: the check reads the feed ref" line '.jobs.check.steps[0].env.FEED_REF' "\${{ inputs.feed_ref }}"
# Run the step as the runner does, with the cases of the callers.
#
# Arguments:
#   $1  feed repository  $2  feed ref
run_check() {
	rc_status=0
	env FEED_REPOSITORY="$1" FEED_REF="$2" sh -c "${check_run}" >"${work}/out" 2>&1 || rc_status=$?
}
run_check wehagy/w 0123456789abcdef0123456789abcdef01234567
eq "line.yml check: repository and ref pass" "${rc_status}" 0
run_check "" ""
eq "line.yml check: no feed (the branch of the line) passes" "${rc_status}" 0
run_check "" main
eq "line.yml check: a ref alone passes" "${rc_status}" 0
run_check wehagy/w ""
eq "line.yml check: a repository without a ref fails" "${rc_status}" 1
check "line.yml check: ... and says why" "${work}/out" has "${work}/out" "feed_ref is empty"

# --- the callers -------------------------------------------------------------
for f in ci update upstream-pr; do
	expect "${f}.yml: the lines run through line.yml" "${f}" '.jobs.lines.uses' ./.github/workflows/line.yml
	expect "${f}.yml: a failing line does not cancel the others" "${f}" '.jobs.lines.strategy."fail-fast"' false
	expect "${f}.yml: the lines job has no environment" "${f}" '.jobs.lines | has("environment")' false
done
expect "ci.yml: the NetBird runtime tests get NB_SETUP_KEY" ci '.jobs.lines.with.test_secrets' NB_SETUP_KEY
expect "ci.yml: the lines inherit the repository secrets" ci '.jobs.lines.secrets' inherit
expect "update.yml: the NetBird runtime tests get NB_SETUP_KEY" update '.jobs.lines.with.test_secrets' NB_SETUP_KEY
expect "update.yml: the lines inherit the repository secrets" update '.jobs.lines.secrets' inherit
# upstream-pr.yml runs code of a pull request of openwrt/packages: it passes no
# secret anywhere, and names none for the tests.
expect "upstream-pr.yml: no job passes secrets" upstream-pr '[.jobs | to_entries[] | select(.value | has("secrets"))] | length' 0
expect "upstream-pr.yml: no job names test_secrets" upstream-pr '[.jobs | to_entries[] | select(.value.with // {} | has("test_secrets"))] | length' 0
expect "upstream-pr.yml: no expression reads a secret" upstream-pr '[.. | select(tag == "!!str") | select(test("secrets[.]|secrets[\\[]"))] | length' 0
expect "upstream-pr.yml: no secret of the repository in the environment" upstream-pr '[.. | select(tag == "!!str") | select(test("NB_SETUP_KEY|TEST_UPSTREAM_TOKEN"))] | length' 0
expect "upstream-pr.yml: no job has an environment" upstream-pr '[.jobs | to_entries[] | select(.value | has("environment"))] | length' 0
expect "upstream-pr.yml: the lines run when resolve passed and compose passed or was skipped" upstream-pr '.jobs.lines.if' "\${{ !cancelled() && needs.resolve.result == 'success' && (needs.compose.result == 'success' || needs.compose.result == 'skipped') }}"
expect "ci.yml: the summary runs after any result once config passed" ci '.jobs.summary.if' "\${{ always() && needs.config.result == 'success' }}"

# --- upstream-pr.yml: the commit each leg builds ----------------------------
# kind pr: the head the PR was resolved at; kind overlay: the commit composed
# for THE LINE OF THE LEG (a JSON map keyed by line). A line missing from the
# map yields an empty ref, which line.yml's check refuses.
expect "upstream-pr.yml: the commit of a leg" upstream-pr '.jobs.lines.with.feed_ref' "\${{ matrix.kind == 'pr' && needs.resolve.outputs.head_sha || fromJSON(needs.compose.outputs.overlays || '{}')[matrix.line].sha }}"
expect "upstream-pr.yml: the repository of a leg" upstream-pr '.jobs.lines.with.feed_repository' "\${{ matrix.kind == 'pr' && 'openwrt/packages' || github.repository }}"
expect "upstream-pr.yml: the legs are the ones resolve made" upstream-pr '.jobs.lines.strategy.matrix' "\${{ fromJSON(needs.resolve.outputs.matrix_legs) }}"
expect "upstream-pr.yml: a leg is one line" upstream-pr '.jobs.lines.with.line' "\${{ matrix.line }}"
expect "upstream-pr.yml: a leg is one package" upstream-pr '.jobs.lines.with.package' "\${{ matrix.package }}"
expect "upstream-pr.yml: the lines wait for compose" upstream-pr '.jobs.lines.needs | map(select(. == "compose")) | length' 1
# --- the images are read only everywhere but refresh-images.yml --------------
# No run but the daily refresh may write the packages of GHCR: a `packages:
# write` in any workflow, at any level, would let the code of a pull request or
# of a feed push an image that every later build trusts.
all_perms='[.permissions, (.jobs[] | .permissions)]'
for f in line ci upstream-pr update custom-image refresh-images; do
	expect "${f}.yml: every permissions block is a map (no write-all)" "${f}" \
		"${all_perms} | map(select(. != null) | select(tag != \"!!map\")) | length" 0
	expect "${f}.yml: no refresh_sdk input or text" "${f}" \
		'[.. | select(tag == "!!map") | keys | .[] | select(. == "refresh_sdk")] | length' 0
	expect "${f}.yml: no refresh_sdk value" "${f}" '[.. | select(tag == "!!str") | select(test("refresh_sdk"))] | length' 0
done
for f in line ci upstream-pr update custom-image; do
	expect "${f}.yml: no job has a packages permission" "${f}" \
		"${all_perms} | map(select(tag == \"!!map\") | .packages // \"none\") | map(select(. != \"none\")) | length" 0
	expect "${f}.yml: nothing reaches the refresh" "${f}" '[.. | select(tag == "!!str") | select(test("refresh-images"))] | length' 0
done
for f in line ci upstream-pr update; do
	expect "${f}.yml: only custom-image.yml asks for the Image Builder fallback" "${f}" \
		'[.. | select(tag == "!!map") | keys | .[] | select(. == "ib_fallback")] | length' 0
done
expect "custom-image.yml: the image job allows the fallback" custom-image '.jobs.image.with.ib_fallback' true
expect "custom-image.yml: the package build has no fallback" custom-image '.jobs.build.with | has("ib_fallback")' false

# --- refresh-images.yml: the one workflow that writes the images -------------
expect "refresh-images.yml: only a schedule and a manual run start it" refresh-images '.on | keys | join(" ")' "schedule workflow_dispatch"
expect "refresh-images.yml: the workflow default is contents: read" refresh-images '.permissions | to_entries | map(.key + "=" + .value) | join(" ")' "contents=read"
expect "refresh-images.yml: one schedule" refresh-images '.on.schedule | length' 1
expect "refresh-images.yml: daily, before update.yml" refresh-images '.on.schedule[0].cron' "43 3 * * *"
expect "refresh-images.yml: the only input of a manual run is force" refresh-images '.on.workflow_dispatch.inputs | keys | join(" ")' force
expect "refresh-images.yml: one refresh at a time" refresh-images '.concurrency.group' refresh-images
expect "refresh-images.yml: a running refresh is not cancelled" refresh-images '.concurrency."cancel-in-progress"' false
expect "refresh-images.yml: the jobs are config and refresh" refresh-images '.jobs | keys | join(" ")' "config refresh"
expect "refresh-images.yml: only refresh has packages: write" refresh-images \
	'[.jobs | to_entries[] | select(.value.permissions.packages == "write") | .key] | join(" ")' refresh
expect "refresh-images.yml: refresh also reads the repository" refresh-images '.jobs.refresh.permissions.contents' read
expect "refresh-images.yml: config, which reads the code of the branch, only reads" refresh-images '.jobs.config.permissions // "workflow default"' "workflow default"
expect "refresh-images.yml: refresh waits for config" refresh-images '.jobs.refresh.needs' config
expect "refresh-images.yml: refresh calls the refresh of the base from main" refresh-images '.jobs.refresh.uses' "wehagy/openwrt-ci/.github/workflows/refresh-images.yml@main"
expect "refresh-images.yml: refresh takes the scripts of the base from main" refresh-images '.jobs.refresh.with.ci_ref' main
expect "refresh-images.yml: refresh gets no secret" refresh-images '.jobs.refresh | has("secrets")' false
expect "refresh-images.yml: no job has an environment" refresh-images '[.jobs | to_entries[] | select(.value | has("environment"))] | length' 0
expect "refresh-images.yml: refresh takes the lines from config" refresh-images '.jobs.refresh.with.lines' "\${{ needs.config.outputs.lines }}"
expect "refresh-images.yml: refresh takes the profiles from config" refresh-images '.jobs.refresh.with.profiles' "\${{ needs.config.outputs.profiles }}"
expect "refresh-images.yml: refresh takes the targets from config" refresh-images '.jobs.refresh.with.targets' "\${{ needs.config.outputs.targets }}"
expect "refresh-images.yml: force is a boolean of the manual run" refresh-images '.jobs.refresh.with.force' "\${{ inputs.force == true }}"
expect "refresh-images.yml: config fails when refresh-config.sh fails (pipefail)" refresh-images '.jobs.config.defaults.run.shell' bash
finish
