"""Responsibility: turn the jobs and artifacts of an update.yml run into the body
of the draft pull request: the results of every line of the package (build, QEMU
tests, images), the test suites that ran (counted from the junit files of the QEMU jobs, with
what was skipped and what is missing) and the ready link that opens the
upstream pull request by hand. Nothing here talks to GitHub or writes to any
repository; the workflow feeds it JSON lines and junit files and publishes the
text.

Usage:
    scripts/report.py --package netbird --old 0.81.4 --new 0.82.0 ... \\
        --jobs jobs.jsonl --artifacts artifacts.jsonl --results results --out body.md
    prints "reference_passed=true|false" (a line for $GITHUB_OUTPUT)

The lines come from --lines (the lines of the package, in the order of its
config.yml); no line is named here. The result of a line is read from its own
artifact (line-result-<package>-<line>/result.json, scripts/line-result.sh),
the job list of the run gives the detail, and a line passes only when both
agree. The reference line (--reference) is the one that decides the pull
request; the others are reported.

Environment variables: none.
"""

import argparse
import glob
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from urllib.parse import quote

STAGES = ("build", "test", "image")
STAGE_TITLES = {"build": "Build (SDK)", "test": "QEMU test", "image": "Image"}
UPSTREAM_REPOSITORY = "openwrt/packages"
UPSTREAM_BRANCH = "master"
# Module of the generic package test of the base; every other test class is a
# test of the package itself (packages/<name>/tests).
GENERIC_CLASS = "tests.ext.test_package"
RESULTS_MAX_BYTES = 1_000_000
SKIP_REASON_MAX = 100
# Skip reasons listed in the description, per line and suite; the rest is counted.
SKIP_REASONS_SHOWN = 5
# Characters the text of a test file may not carry into the description: the
# markers of markdown (links, mentions through @, tables, code, HTML) and
# backslash. Whitespace of every kind, newlines included, becomes one space.
UNSAFE_TEXT = re.compile(r"[@\[\]()<>|`\\]")
# The target of a QEMU job comes from the name of an artifact.
TARGET_NAME = r"[A-Za-z0-9._-]+"
# "<matrix job (line)> / <stage> / <job of the base>", e.g.
# "lines (main) / image / main x86-64-generic": the base names its jobs
# "<line> <item>", so the line is read from there, whatever the caller calls
# its matrix job. Only the lines of the package match, so that a setup job of
# the base ("feed <line>", "targets <line>") is not taken for a worker job.
# `test_secrets` is the QEMU test of line.yml that runs with secrets (`test` is
# the one without): both are the stage "test".
JOB_NAME = r"^\S+(?: \([^)]*\))? / (build|test|test_secrets|image) / ({lines}) (\S+)$"
# The job `result` of line.yml, which writes the result file of a leg:
# "<matrix job> (<line>[, <feed values>]) / result".
RESULT_JOB_NAME = r"^\S+ \({line}(?:, [^)]*)?\) / result$"
# What a job of a leg may have ended with (scripts/line-result.sh writes these).
JOB_RESULTS = ("success", "failure", "cancelled", "skipped", "not requested")
# A commit the base reports having built: a full SHA, or nothing.
FEED_SHA = re.compile(r"(?:[0-9a-f]{40})?")


@dataclass
class Job:
    """One worker job of the base (an architecture, a QEMU target or a profile)."""

    stage: str
    line: str
    item: str
    conclusion: str
    url: str
    failed_steps: list[str] = field(default_factory=list)


def read_jsonl(path: str) -> list[dict]:
    """Read one JSON object per non-empty line."""
    with open(path, encoding="utf-8") as handle:
        return [json.loads(row) for row in handle if row.strip()]


def parse_jobs(records: list[dict], lines: list[str]) -> list[Job]:
    """Keep the worker jobs of the given lines; the setup jobs (feed, targets,
    ...) do not match."""
    jobs = []
    choice = "|".join(re.escape(line) for line in lines)
    pattern = re.compile(JOB_NAME.format(lines=choice))
    for record in records:
        found = pattern.match(record.get("name") or "")
        if found is None:
            continue
        jobs.append(
            Job(
                stage="test" if found.group(1) == "test_secrets" else found.group(1),
                line=found.group(2),
                item=found.group(3),
                conclusion=record.get("conclusion") or "unfinished",
                url=record.get("html_url") or "",
                failed_steps=list(record.get("failed_steps") or []),
            )
        )
    return jobs


@dataclass
class Counts:
    """Passed, skipped and failed test cases of one suite."""

    passed: int = 0
    skipped: int = 0
    failed: int = 0
    reasons: list[str] = field(default_factory=list)

    def add(self, other: "Counts") -> None:
        """Accumulate another count."""
        self.passed += other.passed
        self.skipped += other.skipped
        self.failed += other.failed
        for reason in other.reasons:
            if reason not in self.reasons:
                self.reasons.append(reason)


@dataclass
class TargetResult:
    """The junit result of one QEMU job: the generic suite and the package's."""

    line: str
    target: str
    generic: Counts = field(default_factory=Counts)
    package: Counts = field(default_factory=Counts)


def safe_text(text: str, limit: int = SKIP_REASON_MAX) -> str:
    """One line of plain text out of text a test produced.

    The tests run code of the package under test, so whatever they write into
    results.xml is not trusted: it must not open a heading, a mention, a link,
    an HTML tag or a table cell in the description. The markdown and HTML
    markers are dropped, whitespace collapses to single spaces (no newline
    survives) and the length is capped.
    """
    return " ".join(UNSAFE_TEXT.sub("", str(text)).split())[:limit].strip()


def parse_junit(path: str) -> tuple[Counts, Counts]:
    """Count the test cases of one results.xml: (generic suite, package suite)."""
    if os.path.getsize(path) > RESULTS_MAX_BYTES:
        raise ValueError(f"{path} is larger than {RESULTS_MAX_BYTES} bytes")
    generic, package = Counts(), Counts()
    for case in ET.parse(path).getroot().iter("testcase"):
        counts = generic if case.get("classname") == GENERIC_CLASS else package
        tags = {child.tag for child in case}
        if "skipped" in tags:
            counts.skipped += 1
            message = case.find("skipped").get("message") or ""
            reason = safe_text(f"{case.get('name')}: {message}")
            if reason not in counts.reasons:
                counts.reasons.append(reason)
        elif tags & {"failure", "error"}:
            counts.failed += 1
        else:
            counts.passed += 1
    return generic, package


def parse_results(directory: str, package: str, lines: list[str]) -> list[TargetResult]:
    """Read <directory>/qemu-<package>-<line>-<target>/results.xml (the artifacts
    of the QEMU jobs, as `gh run download` lays them out) of the given lines."""
    found = []
    choice = "|".join(re.escape(line) for line in lines)
    name = re.compile(rf"^qemu-{re.escape(package)}-({choice})-({TARGET_NAME})$")
    for path in sorted(glob.glob(os.path.join(directory, "qemu-*", "results.xml"))):
        match = name.match(os.path.basename(os.path.dirname(path)))
        if match is None or match.group(2).endswith("-logs"):
            continue
        generic, package_counts = parse_junit(path)
        found.append(
            TargetResult(match.group(1), match.group(2), generic, package_counts)
        )
    return found


def image_result(job: Job, artifacts: set[str], package: str) -> str:
    """fits / too big (expected) for a green image job, else the conclusion.

    An image job is green only when the outcome is the declared one, and a
    declared fit uploads the artifact images-<package>-<line>-<profile>; a green
    job without the artifact is a profile declared too big.
    """
    if job.conclusion != "success":
        return job.conclusion
    name = f"images-{package}-{job.line}-{job.item}"
    return "fits" if name in artifacts else "too big (expected)"


def result_text(job: Job, artifacts: set[str], package: str) -> str:
    """The cell of one job: its result, with a link when it did not pass."""
    result = (
        image_result(job, artifacts, package)
        if job.stage == "image"
        else job.conclusion
    )
    if job.conclusion == "success":
        return result
    steps = ", ".join(job.failed_steps)
    detail = f" (step: {steps})" if steps else ""
    return f"**{result}**{detail} [log]({job.url})"


def read_line_results(directory: str, package: str, lines: list[str]) -> dict:
    """The result file of each line: {line: {build, test, image, feed_sha, passed}}.

    <directory>/line-result-<package>-<line>/result.json, one artifact per leg
    of the matrix. The files are written by a job of the run but travel as
    artifacts, so none of their text is trusted: a file that is not a JSON
    object, names another line or package, has a job result outside
    JOB_RESULTS or a feed_sha that is not a full SHA (or empty) is dropped as if
    it was missing, and `passed` is recomputed from the three results. What
    comes back is only the fields read here, so nothing else reaches the
    description. A line without a readable file is absent from the result.
    """
    found = {}
    for line in lines:
        path = os.path.join(directory, f"line-result-{package}-{line}", "result.json")
        if not os.path.isfile(path) or os.path.getsize(path) > RESULTS_MAX_BYTES:
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict):
            continue
        if data.get("line") != line or data.get("package") != package:
            continue
        stages = {key: data.get(key) for key in ("build", "test", "image")}
        feed_sha = data.get("feed_sha", "")
        if any(value not in JOB_RESULTS for value in stages.values()):
            continue
        if not isinstance(feed_sha, str) or FEED_SHA.fullmatch(feed_sha) is None:
            continue
        found[line] = {
            "line": line,
            "package": package,
            **stages,
            "feed_sha": feed_sha,
            "passed": result_passed(stages),
        }
    return found


def result_passed(stages: dict) -> bool:
    """Build and test succeeded; the images succeeded or were not requested."""
    return (
        stages.get("build") == "success"
        and stages.get("test") == "success"
        and stages.get("image") in ("success", "not requested")
    )


def result_job_passed(records: list[dict], line: str) -> bool:
    """The job `result` of the leg of the line, in the job list of the run,
    succeeded. Its file is only believed then: an artifact that was there
    before the job, or that another job uploaded, comes with no such job."""
    pattern = re.compile(RESULT_JOB_NAME.format(line=re.escape(line)))
    found = [r for r in records if pattern.match(r.get("name") or "")]
    return bool(found) and all(r.get("conclusion") == "success" for r in found)


def jobs_passed(jobs: list[Job], line: str) -> bool:
    """The job list says the line passed: every stage has jobs, all succeeded."""
    for stage in STAGES:
        group = [j for j in jobs if j.line == line and j.stage == stage]
        if not group or any(j.conclusion != "success" for j in group):
            return False
    return True


def line_passed(jobs: list[Job], line: str, line_results: dict) -> bool:
    """A line passes when its own result file and the job list both say so."""
    return line_results.get(line, {}).get("passed") is True and jobs_passed(jobs, line)


def stage_summary(
    jobs: list[Job], line: str, stage: str, artifacts: set[str], package: str
) -> str:
    """The cell of the overview table for one stage of one line."""
    group = [j for j in jobs if j.line == line and j.stage == stage]
    if not group:
        return "**not run**"
    ok = [j for j in group if j.conclusion == "success"]
    state = "passed" if len(ok) == len(group) else "**failed**"
    text = f"{state} ({len(ok)}/{len(group)})"
    if stage == "image" and ok:
        fits = sum(1 for j in ok if image_result(j, artifacts, package) == "fits")
        text += f": {len(ok) - fits} too big as expected"
    return text


def upstream_link(
    args: argparse.Namespace, main_jobs: list[Job], results: list[TargetResult]
) -> str:
    """The URL that opens the upstream pull request from the review branch.

    It only names the branch of the fork (owner:repository:branch); nothing is
    created by it and nothing here writes to the upstream.
    """
    owner, name = args.review_repository.split("/", 1)
    built = sorted(
        j.item for j in main_jobs if j.stage == "build" and j.conclusion == "success"
    )
    tested = sorted(
        j.item for j in main_jobs if j.stage == "test" and j.conclusion == "success"
    )
    title = f"{args.package}: update to {args.new}"
    package_run = Counts()
    for result in results:
        if result.line == args.reference:
            package_run.add(result.package)
    runtime = (
        f"; package runtime tests: {package_run.passed} passed, "
        f"{package_run.skipped} skipped, {package_run.failed} failed"
        if args.package_tests == "present" and results
        else ""
    )
    body = (
        f"Maintainer: @{owner}\n"
        f"Compile tested: {', '.join(built) or 'none'} (OpenWrt {args.reference} SDK)\n"
        f"Run tested: QEMU {', '.join(tested) or 'none'} (OpenWrt {args.reference}, "
        f"generic package test: install and files{runtime})\n\n"
        f"Update NetBird from {args.old} to {args.new}.\n\n"
        "Release notes:\n"
        f"https://github.com/{args.upstream_repository}/releases/tag/v{args.new}\n"
    )
    return (
        f"https://github.com/{UPSTREAM_REPOSITORY}/compare/"
        f"{UPSTREAM_BRANCH}...{owner}:{name}:{args.update_branch}"
        f"?expand=1&title={quote(title, safe='')}&body={quote(body, safe='')}"
    )


def overlay_text(
    args: argparse.Namespace, line: str, overlays: dict, line_results: dict
) -> str:
    """What a line other than the reference built: the bumped package laid over
    the packages_branch of the line.

    The line does not build the bump commit (a tree of master) but the branch of
    the line with only the package directory of the bump on it, pushed as a
    commit of this repository, so the check is the one a backport needs.
    """
    overlay = overlays.get(line)
    if overlay is None:
        return "overlay could not be composed: **not built**"
    what = (
        f"overlay of {args.overlay_dirs} onto {overlay['base_branch']} "
        f"@ {overlay['base_sha']}"
    )
    built = line_results.get(line, {}).get("feed_sha", "")
    if not built:
        return f"{what}: **not built**"
    return f"{what}: {args.overlay_repository} @ `{built}`"


def result_file_text(line: str, line_results: dict) -> str:
    """What the leg of the line wrote about itself (scripts/line-result.sh).

    It says where a line stopped even when no worker job ran (a build that failed
    in its setup job has no job below it).
    """
    found = line_results.get(line)
    if found is None:
        return "Result file of the leg: **missing**."
    return (
        f"Result file of the leg: build `{safe_text(found.get('build', ''))}`, "
        f"test `{safe_text(found.get('test', ''))}`, "
        f"images `{safe_text(found.get('image', ''))}`."
    )


def counts_row(counts: Counts) -> str:
    """The Passed / Skipped / Failed cells of one suite (integers only)."""
    return f"{int(counts.passed)} | {int(counts.skipped)} | {int(counts.failed)}"


def reasons_text(reasons: list[str]) -> str:
    """The skip reasons as code spans (inert), the first few, then how many more."""
    shown = "; ".join(f"`{r}`" for r in reasons[:SKIP_REASONS_SHOWN])
    rest = len(reasons) - SKIP_REASONS_SHOWN
    return f"{shown}; and {rest} more" if rest > 0 else shown


def tests_section(
    args: argparse.Namespace, jobs: list[Job], results: list[TargetResult]
) -> list[str]:
    """Which test suites ran, counted from the junit files of this run.

    A green QEMU job does not say what ran inside it: the generic package test
    proves install and files only, the package's own tests (packages/<name>/tests,
    which for NetBird need NB_SETUP_KEY and skip without it) prove that the
    program works. So the table lists, per line, what each suite passed, skipped
    and failed, and the targets whose test job left no result file.
    """
    directory = f"packages/{args.package}/tests"
    lines = [
        "## Test suites that ran\n",
        "Counted from the `results.xml` of the QEMU test jobs of this run.\n",
        "| Line | Suite | Passed | Skipped | Failed | Targets |\n|---|---|---|---|---|---|",
    ]
    notes = []
    for line in args.line_list:
        have = [r for r in results if r.line == line]
        expected = sorted(j.item for j in jobs if j.line == line and j.stage == "test")
        missing = [t for t in expected if t not in {r.target for r in have}]
        targets = ", ".join(sorted(r.target for r in have)) or "none"
        if missing:
            targets += f"; **no result file: {', '.join(missing)}**"
        for label, attr in (
            ("generic package test (install and files)", "generic"),
            (f"package tests (`{directory}`)", "package"),
        ):
            total = Counts()
            for r in have:
                total.add(getattr(r, attr))
            if attr == "package" and args.package_tests != "present":
                lines.append(
                    f"| `{line}` | {label} | **NOT RUN**: the directory does not exist"
                    " | | | |"
                )
                continue
            lines.append(f"| `{line}` | {label} | {counts_row(total)} | {targets} |")
            if total.skipped:
                notes.append(
                    f"**Line `{line}`: {total.skipped} test(s) of the {attr} suite "
                    f"skipped ({reasons_text(total.reasons)}). A skipped test is not a "
                    "pass.**"
                )
            if total.failed:
                notes.append(
                    f"**Line `{line}`: {total.failed} test(s) of the {attr} suite "
                    "failed; see the QEMU job logs.**"
                )
    secrets = args.test_secrets.replace(",", " ").split()
    lines.append("")
    if secrets:
        names = ", ".join(f"`{n}`" for n in secrets)
        lines.append(
            f"Secrets passed to the tests (`test_secrets`, names only): {names}.\n"
        )
    else:
        lines.append("No secret was passed to the tests.\n")
    if args.package_tests != "present":
        notes.append(
            "**A green QEMU test above is the generic test only. It does not show "
            "that the program works at runtime.**"
        )
    elif not any(r.package.passed for r in results):
        notes.append(
            "**No package test passed on any target: the QEMU result does not show "
            "that the program works at runtime.**"
        )
    for note in notes:
        lines.append(note + "\n")
    return lines


def build_body(
    args: argparse.Namespace,
    jobs: list[Job],
    artifacts: set[str],
    results: list[TargetResult],
    line_results: dict,
    overlays: dict,
) -> str:
    """The full pull request description."""
    out = []
    out.append(
        f"Update NetBird from {args.old} to {args.new}. Draft for manual review: "
        "the starting point is the head of the review repository, the only "
        "change is `PKG_VERSION`, `PKG_RELEASE` and `PKG_HASH`.\n"
    )
    out.append("| | |\n|---|---|")
    out.append(
        f"| Release notes | https://github.com/{args.upstream_repository}"
        f"/releases/tag/v{args.new} |"
    )
    out.append(f"| CI run | {args.run_url} |")
    out.append(
        f"| Starting point | `{args.base_branch}` @ `{args.base_sha}` |\n"
        f"| Upstream base | {args.upstream_base} |\n"
        f"| Bump commit | `{args.update_branch}` @ `{args.head_sha}` |"
    )
    for line in args.line_list:
        if line == args.reference:
            built = line_results.get(line, {}).get("feed_sha", "")
            what = f"{args.review_repository} @ `{built}`" if built else "**not built**"
        else:
            what = overlay_text(args, line, overlays, line_results)
        out.append(f"| Built (line `{line}`) | {what} |")
    out.append("")
    out.extend(tests_section(args, jobs, results))
    out.append("## Results\n")
    out.append("| Line | Build (SDK) | QEMU test | Images |\n|---|---|---|---|")
    for line in args.line_list:
        verdict = "passed" if line_passed(jobs, line, line_results) else "**FAILED**"
        cells = " | ".join(
            stage_summary(jobs, line, s, artifacts, args.package) for s in STAGES
        )
        out.append(f"| `{line}` {verdict} | {cells} |")
    out.append("")
    for line in args.line_list:
        verdict = "passed" if line_passed(jobs, line, line_results) else "FAILED"
        out.append(f"### Line `{line}`: {verdict}\n")
        out.append(result_file_text(line, line_results) + "\n")
        out.append("| Stage | Item | Result |\n|---|---|---|")
        for stage in STAGES:
            group = sorted(
                (j for j in jobs if j.line == line and j.stage == stage),
                key=lambda j: j.item,
            )
            for job in group:
                out.append(
                    f"| {STAGE_TITLES[stage]} | `{job.item}` | "
                    f"{result_text(job, artifacts, args.package)} |"
                )
        out.append("")
    for line in args.line_list:
        if line == args.reference or line_passed(jobs, line, line_results):
            continue
        missing = (
            ""
            if line in line_results
            else " Its result file is missing: the line did not run to the end. "
        )
        branch = overlays.get(line, {}).get("base_branch", "its branch")
        out.append(
            f"Line `{line}` did not pass; the failed jobs are linked above.{missing}"
            f" It builds only `{args.overlay_dirs}` of the bump on `{branch}`, "
            "so a failure there is the bump as a backport failing (for example a "
            "Go version the branch does not have), not a failure of master's "
            "feed. The pull request is open because the reference line "
            f"`{args.reference}` passed.\n"
        )
    out.append("## Upstream pull request\n")
    link = upstream_link(args, [j for j in jobs if j.line == args.reference], results)
    if args.review_is_fork == "true":
        out.append(f"[Open the upstream pull request]({link})\n")
    else:
        out.append(
            f"`{args.review_repository}` is a test copy of `{UPSTREAM_REPOSITORY}`, "
            "not a fork: the link below is only generated and does not work. "
            "CI never writes to the upstream.\n"
        )
        out.append(f"{link}\n")
    out.append(
        "The upstream pull request is opened by hand from the link; it fills "
        "the title and the description.\n"
    )
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    """Write the description and print main_passed=<bool>."""
    parser = argparse.ArgumentParser(description="Build the pull request description.")
    for option in (
        "package",
        "old",
        "new",
        "upstream-repository",
        "review-repository",
        "base-branch",
        "update-branch",
        "base-sha",
        "head-sha",
        "lines",
        "reference",
        "overlays",
        "line-results",
        "overlay-repository",
        "overlay-dirs",
        "run-url",
        "jobs",
        "artifacts",
        "results",
        "out",
    ):
        parser.add_argument(f"--{option}", required=True)
    parser.add_argument("--upstream-base", required=True)
    parser.add_argument("--test-secrets", required=True)
    parser.add_argument("--review-is-fork", choices=("true", "false"), required=True)
    parser.add_argument("--package-tests", choices=("present", "none"), required=True)
    args = parser.parse_args(argv)
    args.line_list = args.lines.split()
    if args.reference not in args.line_list:
        parser.error("--reference is not one of --lines")
    overlays = json.loads(args.overlays)
    records = read_jsonl(args.jobs)
    jobs = parse_jobs(records, args.line_list)
    artifacts = {a["name"] for a in read_jsonl(args.artifacts)}
    results = parse_results(args.results, args.package, args.line_list)
    line_results = {
        line: found
        for line, found in read_line_results(
            args.line_results, args.package, args.line_list
        ).items()
        if result_job_passed(records, line)
    }
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(build_body(args, jobs, artifacts, results, line_results, overlays))
    passed = line_passed(jobs, args.reference, line_results)
    print(f"reference_passed={'true' if passed else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
