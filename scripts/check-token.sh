#!/usr/bin/env sh
# Responsibility: prove, before any branch is pushed, that the token can push to
# the review repository AND open a pull request there. GitHub shows the
# permissions of a fine-grained token nowhere, so the pull request permission is
# probed with a request that cannot succeed: POST /pulls with a head branch that
# does not exist. Authorization is checked before validation, so a token with
# Pull requests: write gets 422 (invalid head) and one without gets 403; no pull
# request is created. The probe head must not exist (checked first), otherwise
# the request could open a real pull request.
#
# Usage:
#   scripts/check-token.sh
#
# Environment variables:
#   REVIEW_REPOSITORY  <owner>/<name> of the review repository (never openwrt)
#   REVIEW_BRANCH      base branch of the probe
#   PROBE_HEAD         branch name that does not exist (for example
#                      ci/token-probe-<run id>)
#   GH_TOKEN           the token to check

set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "${script_dir}/lib/common.sh"

: "${REVIEW_REPOSITORY:?}" "${REVIEW_BRANCH:?}" "${PROBE_HEAD:?}"
check_review_repository "${REVIEW_REPOSITORY}"
check_branch "${REVIEW_BRANCH}"
check_branch "${PROBE_HEAD}"

push=$(gh api "repos/${REVIEW_REPOSITORY}" --jq .permissions.push) ||
	die "cannot read ${REVIEW_REPOSITORY} with the token"
[ "${push}" = true ] || die "the token cannot push to ${REVIEW_REPOSITORY}"

rc=0
out=$(gh api "repos/${REVIEW_REPOSITORY}/branches/${PROBE_HEAD}" --jq .name 2>&1) || rc=$?
[ "${rc}" -ne 0 ] || die "the probe branch ${PROBE_HEAD} exists: not probing"
case "${out}" in
*'HTTP 404'*) ;;
*) die "cannot look for the probe branch: ${out}" ;;
esac

rc=0
out=$(gh api --method POST "repos/${REVIEW_REPOSITORY}/pulls" \
	-f title="token probe" -f head="${PROBE_HEAD}" -f base="${REVIEW_BRANCH}" 2>&1) || rc=$?
[ "${rc}" -ne 0 ] || die "the probe opened a pull request in ${REVIEW_REPOSITORY}"
case "${out}" in
*'HTTP 422'*)
	printf 'the token can push to and open pull requests in %s\n' "${REVIEW_REPOSITORY}"
	;;
*'HTTP 403'* | *'HTTP 401'*)
	die "the token cannot open pull requests in ${REVIEW_REPOSITORY}: give it Pull requests: read and write"
	;;
*) die "unexpected answer to the pull request probe: ${out}" ;;
esac
