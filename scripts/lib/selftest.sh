#!/usr/bin/env sh
# Responsibility: the counters and the case runners shared by the self-tests of
# the update workflow (update-selftest.sh, flow-selftest.sh). Sourced, not run.
# The caller sets `work` (a scratch directory) before using status_case, and
# ends with `finish`.
#
# Usage:
#   . "${script_dir}/lib/selftest.sh"
#
# Environment variables: none.

failures=0
checks=0

# Record the result of one case.
#
# Arguments:
#   $1  case name
#   $2  0 if the case passed, otherwise it failed
#   $3  detail printed on failure
record() {
	checks=$((checks + 1))
	if [ "$2" -eq 0 ]; then
		printf 'ok   %s\n' "$1"
	else
		printf 'FAIL %s: %s\n' "$1" "$3"
		failures=$((failures + 1))
	fi
}

# Check that a command exits with the expected status. Its output goes to
# ${work}/out.
#
# Arguments:
#   $1  case name
#   $2  expected exit status
#   $3...  command
status_case() {
	sc_name=$1
	sc_want=$2
	shift 2
	sc_rc=0
	"$@" >"${work}/out" 2>&1 || sc_rc=$?
	if [ "${sc_rc}" -eq "${sc_want}" ]; then
		record "${sc_name}" 0 ""
	else
		sc_text=$(cat "${work}/out")
		record "${sc_name}" 1 "exit ${sc_rc}, expected ${sc_want}: ${sc_text}"
	fi
}

# Print the totals and fail if a case failed.
finish() {
	printf '%s checks, %s failed\n' "${checks}" "${failures}"
	[ "${failures}" -eq 0 ]
}
