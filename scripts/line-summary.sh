#!/usr/bin/env sh
# Responsibility: print, as a markdown table, the result of every (package, line)
# leg of a run from the artifacts line-result-<package>-<line> that
# .github/workflows/line.yml uploads. One row per leg, so a failed leg is
# visible next to a passing one (the `needs` of a matrix job give a single
# aggregate).
#
# Usage: scripts/line-summary.sh <directory with line-result-*/result.json>
# Environment variables: none.
set -eu

[ "$#" -eq 1 ] || {
	echo "usage: line-summary.sh <directory>" >&2
	exit 1
}
echo "| package | line | build | QEMU test | images | result |"
echo "|---|---|---|---|---|---|"
found=0
for file in "$1"/line-result-*/result.json; do
	[ -f "${file}" ] || continue
	found=1
	# The files travel as artifacts: only plain words reach the summary.
	jq -r 'def plain: tostring | gsub("[^A-Za-z0-9._ -]"; "?") | .[:40];
		"| \(.package | plain) | \(.line | plain) | \(.build | plain) | \(.test | plain) | \(.image | plain) | \(if .passed == true then "passed" else "**FAILED**" end) |"' "${file}"
done
if [ "${found}" -eq 0 ]; then
	echo "| (no line result) | | | | | |"
fi
