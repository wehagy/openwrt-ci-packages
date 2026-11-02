"""Responsibility: turn the jobs and artifacts of an update.yml run into the body
of the draft pull request: the results of both lines (build, QEMU tests, images)
and the ready link that opens the upstream pull request by hand. Nothing here
talks to GitHub or writes to any repository; the workflow feeds it JSON lines
and publishes the text.

Usage:
    scripts/report.py --package netbird --old 0.81.4 --new 0.82.0 ... \\
        --jobs jobs.jsonl --artifacts artifacts.jsonl --out body.md
    prints "main_passed=true|false" (a line for $GITHUB_OUTPUT)

Environment variables: none.
"""

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from urllib.parse import quote

LINES = ("main", "25.12")
STAGES = ("build", "test", "image")
STAGE_TITLES = {"build": "Build (SDK)", "test": "QEMU test", "image": "Image"}
UPSTREAM_REPOSITORY = "openwrt/packages"
UPSTREAM_BRANCH = "master"
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


def upstream_link(args: argparse.Namespace, main_jobs: list[Job]) -> str:
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
    body = (
        f"Maintainer: @{owner}\n"
        f"Compile tested: {', '.join(built) or 'none'} (OpenWrt main SDK)\n"
        f"Run tested: QEMU {', '.join(tested) or 'none'} (OpenWrt main, "
        "generic package test: install and files)\n\n"
        f"Update NetBird from {args.old} to {args.new}.\n\n"
        "Release notes:\n"
        f"https://github.com/{args.upstream_repository}/releases/tag/v{args.new}\n"
    )
    return (
        f"https://github.com/{UPSTREAM_REPOSITORY}/compare/"
        f"{UPSTREAM_BRANCH}...{owner}:{name}:{args.update_branch}"
        f"?expand=1&title={quote(title, safe='')}&body={quote(body, safe='')}"
    )


def build_body(args: argparse.Namespace, jobs: list[Job], artifacts: set[str]) -> str:
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
        f"| Bump commit | `{args.update_branch}` @ `{args.head_sha}` |\n"
        f"| Built (line `main`) | {args.review_repository} @ `{args.feed_sha_main}` |\n"
        f"| Built (line `25.12`) | {args.review_repository} @ `{args.feed_sha_25_12}` |\n"
    )
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
            "Line `25.12` did not pass; the failed jobs are linked above. The pull "
            "request is open because line `main` passed.\n"
        )
    out.append("## Upstream pull request\n")
    link = upstream_link(args, [j for j in jobs if j.line == "main"])
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
        "run-url",
        "jobs",
        "artifacts",
        "out",
    ):
        parser.add_argument(f"--{option}", required=True)
    parser.add_argument("--review-is-fork", choices=("true", "false"), required=True)
    args = parser.parse_args(argv)
    jobs = parse_jobs(read_jsonl(args.jobs))
    artifacts = {a["name"] for a in read_jsonl(args.artifacts)}
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(build_body(args, jobs, artifacts))
    print(f"main_passed={'true' if line_passed(jobs, 'main') else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
