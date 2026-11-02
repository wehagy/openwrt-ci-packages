"""Responsibility: self-test of scripts/report.py with fixed jobs and artifacts:
the verdict of a line, the image outcomes (fits / too big as expected), the
failure detail and the upstream link, which must name only the review
repository's branch. No network.

Usage:
    python3 scripts/report_selftest.py

Environment variables: none.
"""

import argparse
import json
import os
import sys
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import report

ARCHS = ["x86_64", "aarch64_generic", "mips_24kc"]
TARGETS = ["x86-64", "malta-be"]
PROFILES = ["x86-64-generic", "tplink-archer-c7-v4"]


def job(stage: str, line: str, item: str, conclusion: str = "success") -> dict:
    """A record as the workflow extracts it from the jobs API."""
    outer = f"{stage}-{'25-12' if line == '25.12' else 'main'}"
    return {
        "name": f"{outer} / {line} {item}",
        "conclusion": conclusion,
        "html_url": f"https://example.invalid/jobs/{stage}-{line}-{item}",
        "failed_steps": ["Run tests"] if conclusion == "failure" else [],
    }


def all_jobs(failing: dict[tuple[str, str], str] | None = None) -> list[dict]:
    """Every worker job of both lines, plus setup jobs that must be ignored."""
    failing = failing or {}
    records = []
    for line in report.LINES:
        for stage, items in (
            ("build", ARCHS),
            ("test", TARGETS),
            ("image", PROFILES),
        ):
            for item in items:
                state = failing.get((line, f"{stage}/{item}"), "success")
                records.append(job(stage, line, item, state))
        records.append({"name": f"build-{line} / feed {line}", "conclusion": "failure"})
        records.append({"name": "detect", "conclusion": "success"})
    return records


def args_for(**extra: str) -> argparse.Namespace:
    """The CLI arguments of one run."""
    values = {
        "package": "netbird",
        "old": "0.81.4",
        "new": "0.82.0",
        "upstream_repository": "netbirdio/netbird",
        "review_repository": "wehagy/w",
        "review_is_fork": "false",
        "base_branch": "ci/netbird-base-0.82.0",
        "update_branch": "ci/netbird-update-0.82.0",
        "base_sha": "a" * 40,
        "head_sha": "b" * 40,
        "feed_sha_main": "b" * 40,
        "feed_sha_25_12": "c" * 40,
        "run_url": "https://example.invalid/runs/1",
        "package_tests": "none",
    }
    values.update(extra)
    return argparse.Namespace(**values)


ARTIFACTS = {
    "images-netbird-main-x86-64-generic",
    "images-netbird-25.12-x86-64-generic",
}


class ReportTest(unittest.TestCase):
    """Cases of scripts/report.py."""

    def body(self, failing=None, **extra: str) -> tuple[str, list[report.Job]]:
        jobs = report.parse_jobs(all_jobs(failing))
        return report.build_body(args_for(**extra), jobs, ARTIFACTS), jobs

    def test_setup_jobs_are_ignored(self) -> None:
        jobs = report.parse_jobs(all_jobs())
        self.assertEqual(len(jobs), 2 * (len(ARCHS) + len(TARGETS) + len(PROFILES)))

    def test_both_lines_pass(self) -> None:
        body, jobs = self.body()
        self.assertTrue(report.line_passed(jobs, "main"))
        self.assertTrue(report.line_passed(jobs, "25.12"))
        self.assertIn("| `main` passed | passed (3/3) | passed (2/2) |", body)
        self.assertIn("passed (2/2): 1 too big as expected |", body)
        self.assertIn("| Built (line `main`) | wehagy/w @ `" + "b" * 40 + "` |", body)
        self.assertIn("| Built (line `25.12`) | wehagy/w @ `" + "c" * 40 + "` |", body)

    def test_image_outcomes(self) -> None:
        body, _ = self.body()
        self.assertIn("| Image | `x86-64-generic` | fits |", body)
        self.assertIn("| Image | `tplink-archer-c7-v4` | too big (expected) |", body)

    def test_25_12_failure_keeps_main_passing(self) -> None:
        body, jobs = self.body({("25.12", "test/malta-be"): "failure"})
        self.assertTrue(report.line_passed(jobs, "main"))
        self.assertFalse(report.line_passed(jobs, "25.12"))
        self.assertIn("| `25.12` **FAILED** |", body)
        self.assertIn("**failure** (step: Run tests) [log](", body)
        self.assertIn("Line `25.12` did not pass", body)

    def test_main_failure_fails_the_line(self) -> None:
        _, jobs = self.body({("main", "build/mips_24kc"): "failure"})
        self.assertFalse(report.line_passed(jobs, "main"))

    def test_missing_stage_fails_the_line(self) -> None:
        records = [r for r in all_jobs() if not r["name"].startswith("image-main")]
        jobs = report.parse_jobs(records)
        self.assertFalse(report.line_passed(jobs, "main"))

    def test_upstream_link_names_the_review_branch(self) -> None:
        body, _ = self.body()
        link = next(
            row for row in body.splitlines() if row.startswith("https://github.com/")
        )
        parts = urlsplit(link)
        self.assertEqual(parts.netloc, "github.com")
        self.assertEqual(
            parts.path,
            "/openwrt/packages/compare/master...wehagy:w:ci/netbird-update-0.82.0",
        )
        query = parse_qs(parts.query)
        self.assertEqual(query["expand"], ["1"])
        self.assertEqual(query["title"], ["netbird: update to 0.82.0"])
        text = query["body"][0]
        self.assertIn("Compile tested: aarch64_generic, mips_24kc, x86_64", text)
        self.assertIn("Run tested: QEMU malta-be, x86-64", text)
        self.assertIn("releases/tag/v0.82.0", text)
        self.assertNotIn(" ", link)
        self.assertNotIn("\n", link)

    def test_test_copy_note_only_when_not_a_fork(self) -> None:
        body, _ = self.body()
        self.assertIn("not a fork: the link below is only generated", body)
        body, _ = self.body(review_is_fork="true", review_repository="wehagy/packages")
        self.assertNotIn("not a fork", body)
        self.assertIn("[Open the upstream pull request](https://github.com/", body)
        self.assertIn("compare/master...wehagy:packages:", body)

    def test_missing_runtime_tests_are_said_not_run(self) -> None:
        body, _ = self.body(package_tests="none")
        self.assertIn("## Test suites that ran", body)
        self.assertIn(
            "| Package runtime tests | **NOT RUN**: `packages/netbird/tests` does not "
            "exist |",
            body,
        )
        self.assertIn("A green QEMU test above is the generic test only", body)

    def test_runtime_tests_without_secrets_are_said_skipped(self) -> None:
        body, _ = self.body(package_tests="present")
        self.assertIn("run only when that secret is set and are skipped", body)
        self.assertNotIn("NOT RUN", body)
        self.assertIn("A test skipped for lack of a secret is not a pass", body)
        self.assertNotIn("generic test only", body)

    def test_suites_come_before_the_results(self) -> None:
        body, _ = self.body()
        self.assertLess(body.index("## Test suites that ran"), body.index("## Results"))

    def test_cli_requires_the_suites(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            argv = []
            for key, value in vars(args_for()).items():
                if key != "package_tests":
                    argv += [f"--{key.replace('_', '-')}", value]
            argv += ["--jobs", "j", "--artifacts", "a", "--out", os.path.join(tmp, "o")]
            with self.assertRaises(SystemExit):
                report.main(argv)

    def test_cli_writes_the_body_and_the_verdict(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            paths = {n: os.path.join(tmp, n) for n in ("jobs", "artifacts", "out")}
            with open(paths["jobs"], "w", encoding="utf-8") as handle:
                handle.write("\n".join(json.dumps(r) for r in all_jobs()) + "\n")
            with open(paths["artifacts"], "w", encoding="utf-8") as handle:
                handle.write(json.dumps({"name": "images-netbird-main-x86-64-generic"}))
            argv = []
            for key, value in vars(args_for()).items():
                argv += [f"--{key.replace('_', '-')}", value]
            argv += ["--jobs", paths["jobs"], "--artifacts", paths["artifacts"]]
            argv += ["--out", paths["out"]]
            self.assertEqual(report.main(argv), 0)
            with open(paths["out"], encoding="utf-8") as handle:
                self.assertIn("## Results", handle.read())


if __name__ == "__main__":
    unittest.main(verbosity=2)
