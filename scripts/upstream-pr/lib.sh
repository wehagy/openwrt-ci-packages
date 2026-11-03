#!/usr/bin/env sh
# Responsibility: the pure decisions of the upstream pull request workflow
# (.github/workflows/upstream-pr.yml): input validation and the packages a list
# of changed files belongs to (the lines come from scripts/lib/lines.sh). Sourced by
# resolve.sh and selftest.sh; it does no I/O besides stdin, stdout and stderr.
#
# Usage: . scripts/upstream-pr/lib.sh
# Environment variables: none.

# Prints the workflow command that fails the step to stderr, returns 1.
# Arguments: the message (a value taken from the caller or the API goes
# through clean() before it is put in it).
fail() {
	printf '::error::%s\n' "$*" >&2
	return 1
}

# Keeps only the characters a ref or a name can have and at most 64 of them,
# so a value taken from the API or the input cannot forge a workflow command.
# Arguments: $1 the value. Sets ${cleaned} (no output: it is used inside messages).
clean() {
	cleaned=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._/+-' | cut -c1-64)
}

# The PR number is the only free input of the workflow: a positive integer,
# no sign, no leading zero, at most 7 digits (openwrt/packages is at 31000).
# Arguments: $1 the value.
check_pr_number() {
	if [ -z "$1" ]; then
		fail "pr_number is empty: give the number of a pull request of openwrt/packages"
		return 1
	fi
	if [ "${#1}" -gt 7 ]; then
		fail "pr_number is longer than 7 characters"
		return 1
	fi
	case "$1" in
	*[!0-9]*)
		clean "$1"
		fail "pr_number must be a positive integer (digits only), got '${cleaned}'"
		return 1
		;;
	0*)
		clean "$1"
		fail "pr_number must be a positive integer without a leading zero, got '${cleaned}'"
		return 1
		;;
	*) ;;
	esac
}

# A package is a directory of the feed with a Makefile; its name must be one
# the base accepts. Arguments: $1 the name.
check_package_name() {
	case "$1" in
	'' | [!a-z0-9]* | *[!a-z0-9._+-]*)
		clean "$1"
		fail "package '${cleaned}' has a name the base does not accept"
		return 1
		;;
	*) ;;
	esac
	if [ "${#1}" -gt 128 ]; then
		fail "package name longer than 128 characters"
		return 1
	fi
}

# The base builds one package by name and takes the .apk of that name, so the
# Makefile of <dir>/ must define a package called like the directory (the
# source package udns builds libudns, python-yaml builds python3-yaml: both
# fail in the base at "no <name> .apk"). Arguments: $1 the name. stdin: the
# Makefile. Prints yes when it has a line `define Package/<name>`, else no.
makefile_defines_package() {
	if grep -Fxq "define Package/${1}"; then
		echo yes
	else
		echo no
	fi
}

# The packages a Makefile defines, one per line (for the message).
# stdin: the Makefile.
makefile_package_names() {
	sed -n 's|^define Package/\([A-Za-z0-9._+-]*\)[[:space:]]*$|\1|p' | sort -u
}

# Directories of the feed tree that have a Makefile, from `git ls-tree -r
# --name-only` on stdin. The top level has none, so it never matches.
makefile_dirs() {
	sed -n 's|/Makefile$||p'
}

# The package of each changed path: the shallowest ancestor directory that has
# a Makefile (deeper ones are build files of the package, e.g. src/Makefile).
# A path with no such ancestor (a file outside any package, or a package the
# pull request removed) belongs to no package.
# Arguments: $1 file with the directories from makefile_dirs. stdin: changed
# paths. Prints the package directories, sorted, once each.
detect_packages() {
	awk -v dirsfile="$1" '
		BEGIN { while ((getline d < dirsfile) > 0) dirs[d] = 1 }
		{
			n = split($0, p, "/")
			prefix = ""
			for (i = 1; i < n; i++) {
				prefix = (i == 1) ? p[1] : prefix "/" p[i]
				if (prefix in dirs) { out[prefix] = 1; break }
			}
		}
		END { for (d in out) print d }
	' | sort
}

# A package with packages/<name>/ must list the line of the base branch of the
# pull request (its config.yml `lines:`); otherwise nothing says it is meant to
# work there. Arguments: $1 package, $2 its lines (separated by spaces), $3 the
# line of the pull request.
check_lists_line() {
	case " $2 " in
	*" $3 "*) ;;
	*)
		fail "packages/$1/config.yml does not list the line $3, the line of the base branch of this pull request (its lines: $2): add the line to the config.yml, or the package is not tested on this branch"
		return 1
		;;
	esac
}

# The job matrix of upstream-pr.yml: one leg per (package, line). Every changed
# package has a leg on the line of the pull request (kind pr: the head of the
# pull request); a package with packages/<name>/ here also has one per other
# line of its config.yml (kind overlay: the changed directories laid over the
# branch of that line), and it builds the images on all of them.
# Arguments: $1 the package rows as JSON (name, local, lines, ...), $2 the line
# of the pull request. Prints {"include": [legs]}.
legs_matrix() {
	printf '%s' "$1" | jq -c --arg pr "$2" '
		[.[] | . as $r
		| ($r + {line: $pr, kind: "pr", with_images: $r.local}),
		  (if $r.local then ($r.lines | split(" ")[] | select(. != $pr)
		  | $r + {line: ., kind: "overlay", with_images: true}) else empty end)]
		| {include: .}'
}

# The lines other than the pull request line that the local packages list,
# once each, separated by spaces. Arguments: $1 the rows as JSON, $2 the line
# of the pull request.
overlay_lines() {
	printf '%s' "$1" | jq -r --arg pr "$2" '
		[.[] | select(.local) | .lines | split(" ")[] | select(. != $pr)]
		| unique | join(" ")'
}
