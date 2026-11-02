#!/usr/bin/env sh
# Responsibility: the counters and the case runners shared by the self-tests of
# the update workflow (update-selftest.sh, flow-selftest.sh). Sourced, not run.
# It creates the scratch directory `work` (removed on exit); the caller ends
# with `finish`.
#
# Usage:
#   . "${script_dir}/lib/selftest.sh"
#
# Environment variables: none.

failures=0
checks=0
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

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

# Run a check and record it: it passes when the command exits 0.
#
# Arguments:
#   $1  case name
#   $2  detail printed on failure: the path of a file to print, or the text
#   $3...  command
check() {
	ck_name=$1
	ck_detail=$2
	shift 2
	if "$@"; then
		record "${ck_name}" 0 ""
		return 0
	fi
	if [ -f "${ck_detail}" ]; then
		ck_text=$(cat "${ck_detail}")
	else
		ck_text=${ck_detail}
	fi
	record "${ck_name}" 1 "${ck_text}"
}

# Succeed when a file contains a fixed string.
#
# Arguments:
#   $1  file
#   $2  text
has() {
	grep -Fq -- "$2" "$1"
}

# Succeed when a file does not contain a fixed string.
#
# Arguments:
#   $1  file
#   $2  text
lacks() {
	! grep -Fq -- "$2" "$1"
}

# Succeed when a file is empty.
#
# Arguments:
#   $1  file
empty() {
	[ ! -s "$1" ]
}

# Succeed when two values are equal.
#
# Arguments:
#   $1  value
#   $2  value
same() {
	[ "$1" = "$2" ]
}

# Print the totals and fail if a case failed.
finish() {
	printf '%s checks, %s failed\n' "${checks}" "${failures}"
	[ "${failures}" -eq 0 ]
}
