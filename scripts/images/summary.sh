#!/usr/bin/env sh
# Responsibility: print the Markdown summary of a custom-image.yml run: what
# was asked (line, profile, packages), which package tree was built (source,
# repository, ref, commit, overlay or not), and, for each image artifact, the
# image files with their size against the device limit when it is known, and
# the packages the image installs (from the Image Builder manifest). No secret
# is read or printed.
#
# Usage:
#   scripts/images/summary.sh <artifact-dir> | tee -a "$GITHUB_STEP_SUMMARY"
#   <artifact-dir> holds one directory per downloaded artifact
#   (images-<package>-<line>-<id>/ with the images and *.manifest); it may be
#   empty or missing (the image job failed or was too big).
#
# Environment variables:
#   LINE, PROFILE            the form (PROFILE is <target>/<subtarget>/<profile>)
#   PACKAGE                  package of this repository, empty for none
#   PACKAGES                 extra packages of the image (config + form)
#   LIMIT                    size limit of the firmware in bytes, empty if unknown
#   SOURCE_MODE              default, fork or pr
#   FEED_REPOSITORY, FEED_REF, FEED_SHA   what build.yml built (its outputs)
#   PR_NUMBER, PR_LINE, PR_HEAD_SHA, OVERLAY (true/false), BASE_BRANCH,
#   OVERLAY_DIRS             the pull request, when there is one
#   IMAGE_RESULT             result of the image job (success, failure, ...)

set -eu

[ "$#" -eq 1 ] || {
	echo "usage: summary.sh <artifact-dir>" >&2
	exit 1
}
dir=$1

line=${LINE:-unknown}
profile=${PROFILE:-unknown}
package=${PACKAGE:-}
limit=${LIMIT:-}
mode=${SOURCE_MODE:-default}

printf '### custom image: %s on line %s\n\n' "${profile}" "${line}"
printf -- '- result of the image job: %s\n' "${IMAGE_RESULT:-unknown}"
printf -- '- profile: %s\n' "${profile}"
if [ -n "${package}" ]; then
	printf -- '- package of this repository: %s\n' "${package}"
else
	printf -- '- package of this repository: none\n'
fi
printf -- '- extra packages: %s\n' "${PACKAGES:-(none)}"

# ---------------------------------------------------------------------------
# Source of the package tree.
# ---------------------------------------------------------------------------
if [ -z "${package}" ]; then
	printf -- '- source: nothing was built (no package); the images use the official feed of line %s\n' "${line}"
else
	case "${mode}" in
	pr)
		if [ "${OVERLAY:-false}" = true ]; then
			printf -- '- source: pull request openwrt/packages#%s (base branch of line %s, head %s) built on line %s by overlay: its changed directories (%s) copied over the branch %s\n' \
				"${PR_NUMBER:-?}" "${PR_LINE:-?}" "${PR_HEAD_SHA:-?}" "${line}" "${OVERLAY_DIRS:-?}" "${BASE_BRANCH:-?}"
		else
			printf -- '- source: pull request openwrt/packages#%s, head %s, built as it is (its base branch is line %s)\n' \
				"${PR_NUMBER:-?}" "${PR_HEAD_SHA:-?}" "${PR_LINE:-?}"
		fi
		;;
	fork) printf -- '- source: feed given by the form (feed_repository, feed_ref)\n' ;;
	*) printf -- '- source: the branch of openwrt/packages of line %s\n' "${line}" ;;
	esac
	printf -- '- repository: %s\n- ref: %s\n- commit: %s\n' \
		"${FEED_REPOSITORY:-unknown}" "${FEED_REF:-unknown}" "${FEED_SHA:-unknown}"
	if [ "${OVERLAY:-false}" = true ]; then
		printf -- '- overlay: yes (the ref above is a temporary branch of this repository, deleted after the build)\n'
	else
		printf -- '- overlay: no\n'
	fi
fi

# ---------------------------------------------------------------------------
# Images.
# ---------------------------------------------------------------------------
# Print the image files of one artifact directory with their size against the
# limit, and the manifest.
#
# Arguments:
#   $1  directory
#   $2  title
report_dir() {
	printf '\n#### %s\n\n' "$2"
	printf '| image file | bytes | vs device limit |\n|---|---|---|\n'
	for file in "$1"/*; do
		[ -f "${file}" ] || continue
		case "${file}" in
		*.manifest | */sha256sums) continue ;;
		*) ;;
		esac
		bytes=$(wc -c <"${file}") || exit 1
		if [ -n "${limit}" ]; then
			cmp=$(awk -v b="${bytes}" -v l="${limit}" 'BEGIN { printf "%.2f %% of %d bytes, %s %d bytes", 100 * b / l, l, (b <= l ? "margin" : "OVER by"), (b <= l ? l - b : b - l) }') || exit 1
		else
			cmp="limit unknown (the Image Builder prints it only when the image does not fit)"
		fi
		printf '| %s | %s | %s |\n' "$(basename "${file}")" "${bytes}" "${cmp}"
	done
	for manifest in "$1"/*.manifest; do
		[ -f "${manifest}" ] || continue
		count=$(wc -l <"${manifest}") || exit 1
		printf '\ninstalled packages (%s, %s):\n\n' "$(basename "${manifest}")" "${count}"
		printf '```\n'
		cat "${manifest}"
		printf '```\n'
	done
}

# actions/download-artifact with a pattern puts each artifact in a directory
# named after it when several match, and the files directly in the path when
# only one does; both layouts are read.
found=0
if [ -d "${dir}" ]; then
	for art in "${dir}"/images-*; do
		[ -d "${art}" ] || continue
		found=1
		report_dir "${art}" "$(basename "${art}")"
	done
	if [ "${found}" -eq 0 ]; then
		for manifest in "${dir}"/*.manifest; do
			[ -f "${manifest}" ] || continue
			found=1
			report_dir "${dir}" "image files (one artifact)"
			break
		done
	fi
fi
if [ "${found}" -eq 0 ]; then
	printf '\nno image artifact: the image job did not produce one (see its summary; an image that does not fit the flash has none)\n'
fi
