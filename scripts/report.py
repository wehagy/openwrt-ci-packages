"""Responsibility: turn the jobs and artifacts of an update.yml run into the body
of the draft pull request: the results of both lines (build, QEMU tests, images)
the test suites that ran (counted from the junit files of the QEMU jobs, with
what was skipped and what is missing) and the ready link that opens the
upstream pull request by hand. Nothing here talks to GitHub or writes to any
repository; the workflow feeds it JSON lines and junit files and publishes the
text.

Usage:
    scripts/report.py --package netbird --old 0.81.4 --new 0.82.0 ... \\
        --jobs jobs.jsonl --artifacts artifacts.jsonl --results results --out body.md
    prints "main_passed=true|false" (a line for $GITHUB_OUTPUT)

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

LINES = ("main", "25.12")
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
# "<caller job> / <job of the base>", e.g. "image-main / main x86-64-generic".
JOB_NAME = re.compile(r"^(build|test|image)-(?:main|25-12) / (main|25\.12) (\S+)$")


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


def parse_jobs(records: list[dict]) -> list[Job]:
    """Keep the worker jobs; the setup jobs (feed, targets, ...) do not match."""
    jobs = []
    for record in records:
        found = JOB_NAME.match(record.get("name") or "")
        if found is None:
            continue
        jobs.append(
            Job(
                stage=found.group(1),
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


def parse_results(directory: str, package: str) -> list[TargetResult]:
    """Read <directory>/qemu-<package>-<line>-<target>/results.xml (the artifacts
    of the QEMU jobs, as `gh run download` lays them out)."""
    found = []
    name = re.compile(rf"^qemu-{re.escape(package)}-(main|25\.12)-({TARGET_NAME})$")
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


def line_passed(jobs: list[Job], line: str) -> bool:
    """A line passes when every stage has jobs and all of them succeeded."""
    for stage in STAGES:
        group = [j for j in jobs if j.line == line and j.stage == stage]
        if not group or any(j.conclusion != "success" for j in group):
            return False
    return True


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
        if result.line == "main":
            package_run.add(result.package)
    runtime = (
        f"; package runtime tests: {package_run.passed} passed, "
        f"{package_run.skipped} skipped, {package_run.failed} failed"
        if args.package_tests == "present" and results
        else ""
    )
    body = (
        f"Maintainer: @{owner}\n"
        f"Compile tested: {', '.join(built) or 'none'} (OpenWrt main SDK)\n"
        f"Run tested: QEMU {', '.join(tested) or 'none'} (OpenWrt main, "
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


def overlay_text(args: argparse.Namespace) -> str:
    """What line 25.12 built: the bumped package laid over openwrt-25.12.

    The line does not build the bump commit (a tree of master) but the branch of
    the line with only the package directory of the bump on it, pushed as a
    commit of this repository, so the check is the one a backport needs.
    """
    what = (
        f"overlay of {args.overlay_dirs} onto {args.overlay_base_branch} "
        f"@ {args.overlay_base_sha}"
    )
    if not args.feed_sha_25_12:
        return f"{what}: **not built**"
    return f"{what}: {args.overlay_repository} @ `{args.feed_sha_25_12}`"


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
    for line in LINES:
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
        f"| Bump commit | `{args.update_branch}` @ `{args.head_sha}` |\n"
        f"| Built (line `main`) | {args.review_repository} @ `{args.feed_sha_main}` |\n"
        f"| Built (line `25.12`) | {overlay_text(args)} |\n"
    )
    out.extend(tests_section(args, jobs, results))
    out.append("## Results\n")
    out.append("| Line | Build (SDK) | QEMU test | Images |\n|---|---|---|---|")
    for line in LINES:
        verdict = "passed" if line_passed(jobs, line) else "**FAILED**"
        cells = " | ".join(
            stage_summary(jobs, line, s, artifacts, args.package) for s in STAGES
        )
        out.append(f"| `{line}` {verdict} | {cells} |")
    out.append("")
    for line in LINES:
        verdict = "passed" if line_passed(jobs, line) else "FAILED"
        out.append(f"### Line `{line}`: {verdict}\n")
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
    if not line_passed(jobs, "25.12"):
        out.append(
            "Line `25.12` did not pass; the failed jobs are linked above. It builds "
            f"only `{args.overlay_dirs}` of the bump on `{args.overlay_base_branch}`, "
            "so a failure there is the bump as a backport failing (for example a "
            "Go version the branch does not have), not a failure of master's "
            "feed. The pull request is open because line `main` passed.\n"
        )
    out.append("## Upstream pull request\n")
    link = upstream_link(args, [j for j in jobs if j.line == "main"], results)
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
        "feed-sha-main",
        "feed-sha-25-12",
        "overlay-repository",
        "overlay-dirs",
        "overlay-base-branch",
        "overlay-base-sha",
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
    jobs = parse_jobs(read_jsonl(args.jobs))
    artifacts = {a["name"] for a in read_jsonl(args.artifacts)}
    results = parse_results(args.results, args.package)
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(build_body(args, jobs, artifacts, results))
    print(f"main_passed={'true' if line_passed(jobs, 'main') else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
