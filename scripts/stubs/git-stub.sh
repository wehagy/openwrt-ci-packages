#!/usr/bin/env sh
# Responsibility: stand-in for git in the offline tests of prepare-branches.sh
# (copied as `git` into a directory at the front of PATH). It only changes one
# answer: `git remote get-url origin` prints the URL as it is configured. Real
# git expands url.<base>.insteadOf there, and the tests use insteadOf to send
# the https://github.com/<owner>/<repo> remote to a local bare repository, so
# the check of the origin URL still sees the GitHub address. Every other call is
# real git.
#
# Usage:
#   git-stub.sh <git arguments>
#
# Environment variables:
#   STUB_REAL_GIT  path of the real git

set -eu

if [ "$*" = "remote get-url origin" ]; then
	exec "${STUB_REAL_GIT:?}" config --get remote.origin.url
fi
exec "${STUB_REAL_GIT:?}" "$@"
