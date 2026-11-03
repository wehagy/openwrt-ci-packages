#!/usr/bin/env sh
# Responsibility: delete the overlay branches that update.yml left in THIS
# repository because a run died before its cleanup job could run (forced
# cancellation, lost runner). Only branches named upstream-overlay/update-*
# that are older than MAX_AGE_HOURS are deleted, by cleanup.sh and therefore
# with its guards; the age is the committer date of the branch head (compose.sh
# makes the commit when it pushes). A younger branch may belong to a run in
# progress and stays. upstream-overlay/pr* and custom-pr* belong to other
# workflows and are never listed for deletion. Every old branch is tried even
# if one delete fails; the script then fails.
#
# Usage: scripts/upstream-pr/sweep.sh
# Environment variables:
#   GITHUB_REPOSITORY  this repository; GH_TOKEN authenticates list and delete
#   MAX_AGE_HOURS      minimum age of a branch to delete (default 24)
#   NOW                the current time in epoch seconds (default: date +%s)
#   REMOTE_URL         passed on to cleanup.sh
#   GITHUB_STEP_SUMMARY  optional: passed on to cleanup.sh
set -eu

here=$(dirname "$0")

: "${GITHUB_REPOSITORY:?}"
max_age=${MAX_AGE_HOURS:-24}
case "${max_age}" in
'' | *[!0-9]*)
	printf '::error::MAX_AGE_HOURS must be a number of hours\n'
	exit 1
	;;
*) ;;
esac
now=${NOW:-$(date +%s)}
prefix=upstream-overlay/update-
tab=$(printf '\t')

refs=$(gh api --paginate "repos/${GITHUB_REPOSITORY}/git/matching-refs/heads/${prefix}" \
	--jq '.[] | [.ref, .object.sha] | @tsv') || {
	printf '::error::could not list the %s branches of %s\n' "${prefix}" "${GITHUB_REPOSITORY}"
	exit 1
}

failed=0
deleted=0
kept=0
while IFS=${tab} read -r ref sha; do
	[ -n "${ref}" ] || continue
	branch=${ref#refs/heads/}
	# The API matches a prefix; keep only the names the guard of cleanup.sh
	# will accept anyway.
	case "${branch}" in
	"${prefix}"?*) ;;
	*) continue ;;
	esac
	committed=$(gh api "repos/${GITHUB_REPOSITORY}/commits/${sha}" \
		--jq '.commit.committer.date | fromdateiso8601') || committed=
	case "${committed}" in
	'' | *[!0-9]*)
		printf '::error::could not read the date of a branch under %s\n' "${prefix}"
		failed=$((failed + 1))
		continue
		;;
	*) ;;
	esac
	age=$((now - committed))
	if [ "${age}" -lt $((max_age * 3600)) ]; then
		printf 'kept %s (%s s old, younger than %s h)\n' "${branch}" "${age}" "${max_age}"
		kept=$((kept + 1))
	elif BRANCH=${branch} "${here}/cleanup.sh"; then
		deleted=$((deleted + 1))
	else
		failed=$((failed + 1))
	fi
done <<EOT
${refs}
EOT
printf 'sweep: deleted %s, kept %s, failed %s\n' "${deleted}" "${kept}" "${failed}"
[ "${failed}" -eq 0 ]
