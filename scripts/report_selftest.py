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
        "overlay_repository": "wehagy/openwrt-ci-packages",
        "overlay_dirs": "net/netbird",
        "overlay_base_branch": "openwrt-25.12",
        "overlay_base_sha": "d" * 40,
        "run_url": "https://example.invalid/runs/1",
        "package_tests": "none",
        "upstream_base": "not a fork: upstream link not functional",
        "test_secrets": "NB_SETUP_KEY",
        "results": "",
    }
    values.update(extra)
    return argparse.Namespace(**values)


def junit(generic: tuple[int, int, int], package: tuple[int, int, int]) -> str:
    """A results.xml with (passed, skipped, failed) cases per suite."""
    cases = []
    for classname, (passed, skipped, failed) in (
        ("tests.ext.test_package", generic),
        ("tests.ext.test_package_netbird", package),
    ):
        for n in range(passed):
            cases.append(f'<testcase classname="{classname}" name="ok{n}"/>')
        for n in range(skipped):
            cases.append(
                f'<testcase classname="{classname}" name="skip{n}">'
                '<skipped type="pytest.skip" message="NB_SETUP_KEY is not set"/>'
                "</testcase>"
            )
        for n in range(failed):
            cases.append(
                f'<testcase classname="{classname}" name="bad{n}">'
                '<failure message="boom"/></testcase>'
            )
    return (
        '<?xml version="1.0"?><testsuites><testsuite name="pytest">'
        + "".join(cases)
        + "</testsuite></testsuites>"
    )


def write_results(
    root: str, per_target: dict[tuple[str, str], str], logs: bool = True
) -> None:
    """Lay the artifacts out as `gh run download` does: one directory each."""
    for (line, target), xml in per_target.items():
        directory = os.path.join(root, f"qemu-netbird-{line}-{target}")
        os.makedirs(directory)
        with open(os.path.join(directory, "results.xml"), "w", encoding="utf-8") as f:
            f.write(xml)
        if logs:
            os.makedirs(os.path.join(root, f"qemu-netbird-{line}-{target}-logs"))


def every_target(generic: tuple[int, int, int], package: tuple[int, int, int]) -> dict:
    """The same junit for every target of both lines."""
    return {
        (line, target): junit(generic, package)
        for line in report.LINES
        for target in TARGETS
    }


ARTIFACTS = {
    "images-netbird-main-x86-64-generic",
    "images-netbird-25.12-x86-64-generic",
}


class ReportTest(unittest.TestCase):
    """Cases of scripts/report.py."""

    def body(
        self, failing=None, results=None, **extra: str
    ) -> tuple[str, list[report.Job]]:
        jobs = report.parse_jobs(all_jobs(failing))
        with tempfile.TemporaryDirectory() as tmp:
            write_results(tmp, results or {})
            found = report.parse_results(tmp, "netbird")
        return report.build_body(args_for(**extra), jobs, ARTIFACTS, found), jobs

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
        self.assertIn(
            "| Built (line `25.12`) | overlay of net/netbird onto openwrt-25.12 @ "
            + "d" * 40
            + ": wehagy/openwrt-ci-packages @ `"
            + "c" * 40
            + "` |",
            body,
        )
        self.assertNotIn("wehagy/w @ `" + "c" * 40, body)

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

    def test_25_12_failure_says_it_is_the_backport_check(self) -> None:
        body, _ = self.body({("25.12", "build/mips_24kc"): "failure"})
        self.assertIn("only `net/netbird` of the bump on `openwrt-25.12`", body)

    def test_25_12_not_built_says_so(self) -> None:
        body, _ = self.body(feed_sha_25_12="")
        self.assertIn("@ " + "d" * 40 + ": **not built** |", body)

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
        body, _ = self.body(
            review_is_fork="true",
            review_repository="wehagy/packages",
            upstream_base="identical to openwrt/packages master",
        )
        self.assertNotIn("not a fork", body)
        self.assertIn("[Open the upstream pull request](https://github.com/", body)
        self.assertIn("compare/master...wehagy:packages:", body)

    def test_missing_runtime_tests_are_said_not_run(self) -> None:
        body, _ = self.body(
            results=every_target((3, 0, 0), (0, 0, 0)), package_tests="none"
        )
        self.assertIn("## Test suites that ran", body)
        self.assertIn(
            "| `main` | package tests (`packages/netbird/tests`) | **NOT RUN**: the "
            "directory does not exist | | | |",
            body,
        )
        self.assertIn("A green QEMU test above is the generic test only", body)

    def test_runtime_tests_that_ran_are_counted_per_line(self) -> None:
        body, _ = self.body(
            results=every_target((3, 0, 0), (7, 0, 0)), package_tests="present"
        )
        self.assertIn(
            "| `main` | generic package test (install and files) | 6 | 0 | 0 | "
            "malta-be, x86-64 |",
            body,
        )
        self.assertIn(
            "| `25.12` | package tests (`packages/netbird/tests`) | 14 | 0 | 0 | "
            "malta-be, x86-64 |",
            body,
        )
        self.assertIn(
            "Secrets passed to the tests (`test_secrets`, names only): `NB_SETUP_KEY`.",
            body,
        )
        self.assertNotIn("NOT RUN", body)
        self.assertNotIn("test(s) of the", body)
        self.assertNotIn("generic test only", body)
        self.assertNotIn("No package test passed", body)

    def test_skipped_runtime_tests_are_named(self) -> None:
        results = every_target((3, 0, 0), (6, 1, 0))
        results[("25.12", "x86-64")] = junit((3, 0, 0), (7, 0, 0))
        body, _ = self.body(results=results, package_tests="present")
        self.assertIn(
            "| `main` | package tests (`packages/netbird/tests`) | 12 | 2 | 0 |", body
        )
        self.assertIn(
            "| `25.12` | package tests (`packages/netbird/tests`) | 13 | 1 | 0 |", body
        )
        self.assertIn(
            "2 test(s) of the package suite skipped (skip0: NB_SETUP_KEY is not set)",
            body,
        )
        self.assertIn("A skipped test is not a pass", body)

    def test_failed_tests_are_counted_and_missing_results_are_said(self) -> None:
        results = every_target((2, 0, 1), (7, 0, 0))
        del results[("main", "malta-be")]
        body, _ = self.body(results=results, package_tests="present")
        self.assertIn(
            "| `main` | generic package test (install and files) | 2 | 0 | 1 | x86-64; **no result file: malta-be** |",
            body,
        )
        self.assertIn("test(s) of the generic suite failed", body)

    def test_no_result_files_do_not_read_as_a_pass(self) -> None:
        body, _ = self.body(results={}, package_tests="present")
        self.assertIn(
            "| `main` | package tests (`packages/netbird/tests`) | 0 | 0 | 0 | none; **no result file: malta-be, x86-64** |",
            body,
        )
        self.assertIn("No package test passed on any target", body)

    def test_no_secret_is_said(self) -> None:
        body, _ = self.body(
            results=every_target((3, 0, 0), (7, 0, 0)),
            package_tests="present",
            test_secrets="",
        )
        self.assertIn("No secret was passed to the tests.", body)

    def test_logs_artifacts_and_other_packages_are_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            write_results(tmp, {("main", "x86-64"): junit((3, 0, 0), (7, 0, 0))})
            os.makedirs(
                os.path.join(tmp, "qemu-netbird-main-x86-64-logs"), exist_ok=True
            )
            with open(
                os.path.join(tmp, "qemu-netbird-main-x86-64-logs", "results.xml"),
                "w",
                encoding="utf-8",
            ) as f:
                f.write(junit((9, 9, 9), (9, 9, 9)))
            write_results(tmp, {("main", "malta-be"): junit((1, 0, 0), (1, 0, 0))})
            os.rename(
                os.path.join(tmp, "qemu-netbird-main-malta-be"),
                os.path.join(tmp, "qemu-other-main-malta-be"),
            )
            found = report.parse_results(tmp, "netbird")
        self.assertEqual([(r.line, r.target) for r in found], [("main", "x86-64")])
        self.assertEqual(found[0].package.passed, 7)

    def test_run_tested_line_counts_the_package_tests(self) -> None:
        body, _ = self.body(
            results=every_target((3, 0, 0), (7, 1, 0)), package_tests="present"
        )
        link = next(r for r in body.splitlines() if r.startswith("https://github.com/"))
        text = parse_qs(urlsplit(link).query)["body"][0]
        self.assertIn(
            "generic package test: install and files; package runtime tests: "
            "14 passed, 2 skipped, 0 failed)",
            text,
        )

    def test_upstream_base_row(self) -> None:
        body, _ = self.body()
        self.assertIn(
            "| Upstream base | not a fork: upstream link not functional |", body
        )
        body, _ = self.body(upstream_base="behind openwrt/packages master by 3 commits")
        self.assertIn(
            "| Upstream base | behind openwrt/packages master by 3 commits |", body
        )

    def test_suites_come_before_the_results(self) -> None:
        body, _ = self.body()
        self.assertLess(body.index("## Test suites that ran"), body.index("## Results"))

    def test_cli_requires_the_suites(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            argv = []
            for key, value in vars(args_for()).items():
                if key not in ("package_tests", "results"):
                    argv += [f"--{key.replace('_', '-')}", value]
            argv += ["--jobs", "j", "--artifacts", "a", "--results", tmp]
            argv += ["--out", os.path.join(tmp, "o")]
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
            results = os.path.join(tmp, "results")
            write_results(results, every_target((3, 0, 0), (7, 0, 0)))
            argv += ["--jobs", paths["jobs"], "--artifacts", paths["artifacts"]]
            argv += ["--results", results, "--out", paths["out"]]
            self.assertEqual(report.main(argv), 0)
            with open(paths["out"], encoding="utf-8") as handle:
                self.assertIn("## Results", handle.read())

    def test_cli_requires_the_new_inputs(self) -> None:
        for missing in ("upstream_base", "test_secrets", "results"):
            argv = []
            for key, value in vars(args_for()).items():
                if key != missing:
                    argv += [f"--{key.replace('_', '-')}", value]
            argv += ["--jobs", "j", "--artifacts", "a", "--out", "o"]
            with self.subTest(missing=missing), self.assertRaises(SystemExit):
                report.main(argv)


if __name__ == "__main__":
    unittest.main(verbosity=2)
