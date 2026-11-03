"""Responsibility: self-test of scripts/report.py with fixed jobs and artifacts:
the verdict of every line of a package (two lines, three lines with a fake
"26.12", one line removed; a failing line next to passing ones), the image
outcomes (fits / too big as expected), the failure detail and the upstream link,
which must name only the review repository's branch. No network.

Usage:
    python3 scripts/report_selftest.py

Environment variables: none.
"""

import argparse
import contextlib
import io
import json
import os
import re
import sys
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit
from xml.sax.saxutils import quoteattr

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import report

# The lines of the package in the tests: the data of a fixture, in the order of
# a config.yml; "main" is the reference line. THIRD is a fake line that does not
# exist in the base, to prove that nothing in report.py knows the lines.
LINES = ["main", "25.12"]
REFERENCE = "main"
THIRD = "26.12"
ARCHS = ["x86_64", "aarch64_generic", "mips_24kc"]
TARGETS = ["x86-64", "malta-be"]
PROFILES = ["x86-64-generic", "tplink-archer-c7-v4"]


def job(stage: str, line: str, item: str, conclusion: str = "success") -> dict:
    """A record as the workflow extracts it from the jobs API."""
    return {
        "name": f"lines ({line}) / {stage} / {line} {item}",
        "conclusion": conclusion,
        "html_url": f"https://example.invalid/jobs/{stage}-{line}-{item}",
        "failed_steps": ["Run tests"] if conclusion == "failure" else [],
    }


def all_jobs(
    failing: dict[tuple[str, str], str] | None = None, lines: list[str] | None = None
) -> list[dict]:
    """Every worker job of the lines, plus setup jobs that must be ignored."""
    failing = failing or {}
    records = []
    for line in lines or LINES:
        for stage, items in (
            ("build", ARCHS),
            ("test", TARGETS),
            ("image", PROFILES),
        ):
            for item in items:
                state = failing.get((line, f"{stage}/{item}"), "success")
                records.append(job(stage, line, item, state))
        records.append(
            {"name": f"lines ({line}) / build / feed {line}", "conclusion": "failure"}
        )
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
        "lines": " ".join(LINES),
        "reference": REFERENCE,
        "overlays": "{}",
        "line_results": "",
        "overlay_repository": "wehagy/openwrt-ci-packages",
        "overlay_dirs": "net/netbird",
        "run_url": "https://example.invalid/runs/1",
        "package_tests": "none",
        "upstream_base": "not a fork: upstream link not functional",
        "test_secrets": "NB_SETUP_KEY",
        "results": "",
    }
    values.update(extra)
    if "line_list" not in values:
        values["line_list"] = values["lines"].split()
    return argparse.Namespace(**values)


def overlays_for(lines: list[str]) -> dict:
    """What compose-lines.sh reports for the lines other than the reference."""
    return {
        line: {
            "branch": f"upstream-overlay/update-1-1-{line}",
            "sha": chr(ord("c") + n) * 40,
            "base_sha": chr(ord("d") + n) * 40,
            "base_branch": f"openwrt-{line}" if line != REFERENCE else "master",
        }
        for n, line in enumerate(x for x in lines if x != REFERENCE)
    }


def result_for(line: str, lines: list[str], **override: str) -> dict:
    """The result file of a passing line (scripts/line-result.sh)."""
    sha = "b" * 40 if line == REFERENCE else overlays_for(lines)[line]["sha"]
    data = {
        "line": line,
        "package": "netbird",
        "build": "success",
        "test": "success",
        "image": "success",
        "feed_sha": sha,
        "passed": True,
    }
    data.update(override)
    return data


def all_results(lines: list[str] | None = None) -> dict:
    """The result file of every line, all passing."""
    return {
        line: result_for(
            line,
            lines or LINES,
        )
        for line in lines or LINES
    }


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
        (line, target): junit(generic, package) for line in LINES for target in TARGETS
    }


# What hostile test code can write into results.xml: line breaks that open a
# heading, a mention, a link, a tag, a table cell and a code span.
HOSTILE_NAME = "a\n\n# Injected heading @octocat"
HOSTILE_MESSAGE = (
    "needs\n\n[x](http://e.example) @victim <img src=x onerror=y> "
    "| cell | `code` \\ ![i](http://e.example/i.png)"
)
# The only lines of the description that may start a heading.
HEADINGS = {
    "## Test suites that ran",
    "## Results",
    *(f"### Line `{line}`: passed" for line in LINES),
    "## Upstream pull request",
}


def hostile_junit(count: int = 1) -> str:
    """A results.xml whose skipped cases carry hostile names and messages."""
    cases = ['<testcase classname="tests.ext.test_package" name="t0"/>']
    for n in range(count):
        cases.append(
            f'<testcase classname="x" name={quoteattr(HOSTILE_NAME + str(n))}>'
            f"<skipped message={quoteattr(HOSTILE_MESSAGE)}/></testcase>"
        )
    return (
        '<testsuites><testsuite name="pytest">'
        + "".join(cases)
        + "</testsuite></testsuites>"
    )


ARTIFACTS = {
    "images-netbird-main-x86-64-generic",
    "images-netbird-25.12-x86-64-generic",
}


class ReportTest(unittest.TestCase):
    """Cases of scripts/report.py."""

    def body(
        self, failing=None, results=None, lines=None, line_results=None, **extra
    ) -> tuple[str, list[report.Job]]:
        """The description; line_results overrides the result file of a line
        (a dict of fields, or None to leave the file out)."""
        lines = lines or LINES
        jobs = report.parse_jobs(all_jobs(failing, lines), lines)
        with tempfile.TemporaryDirectory() as tmp:
            write_results(tmp, results or {})
            found = report.parse_results(tmp, "netbird", lines)
        files = all_results(lines)
        for line, override in (line_results or {}).items():
            if override is None:
                del files[line]
            else:
                files[line] = override
        overlays = extra.pop("overlays", overlays_for(lines))
        args = args_for(lines=" ".join(lines), **extra)
        self.files = files
        return report.build_body(args, jobs, ARTIFACTS, found, files, overlays), jobs

    def test_setup_jobs_are_ignored(self) -> None:
        jobs = report.parse_jobs(all_jobs(), LINES)
        self.assertEqual(
            len(jobs), len(LINES) * (len(ARCHS) + len(TARGETS) + len(PROFILES))
        )

    def test_both_lines_pass(self) -> None:
        body, jobs = self.body()
        self.assertTrue(report.line_passed(jobs, "main", self.files))
        self.assertTrue(report.line_passed(jobs, "25.12", self.files))
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

    def test_other_line_failure_keeps_the_reference_passing(self) -> None:
        failed = result_for("25.12", LINES, test="failure", passed=False)
        body, jobs = self.body(
            {("25.12", "test/malta-be"): "failure"}, line_results={"25.12": failed}
        )
        self.assertTrue(report.line_passed(jobs, "main", self.files))
        self.assertFalse(report.line_passed(jobs, "25.12", self.files))
        self.assertIn("| `25.12` **FAILED** |", body)
        self.assertIn("**failure** (step: Run tests) [log](", body)
        self.assertIn("Line `25.12` did not pass", body)
        self.assertIn("because the reference line `main` passed", body)

    def test_a_failed_line_says_it_is_the_backport_check(self) -> None:
        failed = result_for("25.12", LINES, build="failure", passed=False)
        body, _ = self.body(
            {("25.12", "build/mips_24kc"): "failure"}, line_results={"25.12": failed}
        )
        self.assertIn("only `net/netbird` of the bump on `openwrt-25.12`", body)

    def test_a_line_not_built_says_so(self) -> None:
        body, _ = self.body(
            line_results={"25.12": result_for("25.12", LINES, feed_sha="")}
        )
        self.assertIn("@ " + "d" * 40 + ": **not built** |", body)

    def test_the_reference_failure_fails_the_line(self) -> None:
        failed = result_for("main", LINES, build="failure", passed=False)
        _, jobs = self.body(
            {("main", "build/mips_24kc"): "failure"}, line_results={"main": failed}
        )
        self.assertFalse(report.line_passed(jobs, "main", self.files))

    def test_missing_stage_fails_the_line(self) -> None:
        records = [
            r for r in all_jobs() if not r["name"].startswith("lines (main) / image")
        ]
        jobs = report.parse_jobs(records, LINES)
        self.assertFalse(report.line_passed(jobs, "main", all_results()))

    def test_a_line_needs_its_result_file_and_the_job_list_to_agree(self) -> None:
        jobs = report.parse_jobs(all_jobs(), LINES)
        green = all_results()
        self.assertTrue(report.line_passed(jobs, "main", green))
        # The jobs are green but the leg's own file says the line failed.
        red = dict(green, main=result_for("main", LINES, test="failure", passed=False))
        self.assertFalse(report.line_passed(jobs, "main", red))
        # The file says passed but a job of the run failed.
        failing = report.parse_jobs(
            all_jobs({("main", "test/malta-be"): "failure"}), LINES
        )
        self.assertFalse(report.line_passed(failing, "main", green))
        # No file at all: the line cannot be told to have passed.
        self.assertFalse(report.line_passed(jobs, "main", {"25.12": green["25.12"]}))

    def test_a_missing_result_file_is_said(self) -> None:
        body, _ = self.body(line_results={"25.12": None})
        self.assertIn("| `25.12` **FAILED** |", body)
        self.assertIn("Its result file is missing", body)
        self.assertIn("| `main` passed |", body)

    def test_three_lines_one_failing_and_two_passing(self) -> None:
        lines = ["main", "25.12", THIRD]
        failed = result_for("25.12", lines, test="failure", passed=False)
        body, jobs = self.body(
            {("25.12", "test/x86-64"): "failure"},
            lines=lines,
            line_results={"25.12": failed},
        )
        self.assertTrue(report.line_passed(jobs, "main", self.files))
        self.assertFalse(report.line_passed(jobs, "25.12", self.files))
        self.assertTrue(report.line_passed(jobs, THIRD, self.files))
        self.assertIn("| `main` passed |", body)
        self.assertIn("| `25.12` **FAILED** |", body)
        self.assertIn(f"| `{THIRD}` passed |", body)
        self.assertIn(f"### Line `{THIRD}`: passed", body)
        self.assertIn("Line `25.12` did not pass", body)
        self.assertNotIn(f"Line `{THIRD}` did not pass", body)
        self.assertIn(
            f"| Built (line `{THIRD}`) | overlay of net/netbird onto openwrt-{THIRD} @ "
            + "e" * 40
            + ": wehagy/openwrt-ci-packages @ `"
            + "d" * 40
            + "` |",
            body,
        )

    def test_the_third_line_failing_leaves_the_other_two_passing(self) -> None:
        lines = ["main", "25.12", THIRD]
        failed = result_for(THIRD, lines, build="failure", passed=False)
        body, jobs = self.body(
            {(THIRD, "build/x86_64"): "failure"},
            lines=lines,
            line_results={THIRD: failed},
        )
        self.assertTrue(report.line_passed(jobs, "25.12", self.files))
        self.assertFalse(report.line_passed(jobs, THIRD, self.files))
        self.assertIn(f"Line `{THIRD}` did not pass", body)
        self.assertNotIn("Line `25.12` did not pass", body)
        self.assertIn(f"only `net/netbird` of the bump on `openwrt-{THIRD}`", body)

    def test_a_line_removed_from_the_package_is_not_mentioned(self) -> None:
        lines = ["main", THIRD]
        body, jobs = self.body(lines=lines)
        self.assertNotIn("25.12", body)
        self.assertTrue(report.line_passed(jobs, THIRD, self.files))
        self.assertEqual(
            {x for x in body.splitlines() if x.startswith("### Line")},
            {"### Line `main`: passed", f"### Line `{THIRD}`: passed"},
        )

    def test_a_package_with_only_the_reference_line(self) -> None:
        body, jobs = self.body(lines=["main"])
        self.assertTrue(report.line_passed(jobs, "main", self.files))
        self.assertNotIn("did not pass", body)

    def test_an_overlay_that_could_not_be_composed_says_so(self) -> None:
        overlays = overlays_for(LINES)
        del overlays["25.12"]
        body, _ = self.body(overlays=overlays, line_results={"25.12": None})
        self.assertIn(
            "| Built (line `25.12`) | overlay could not be composed: **not built** |",
            body,
        )

    def test_the_reference_line_is_the_one_named_not_the_first(self) -> None:
        lines = [THIRD, "main"]
        failed = result_for(THIRD, lines, build="failure", passed=False)
        body, jobs = self.body(
            {(THIRD, "build/x86_64"): "failure"},
            lines=lines,
            line_results={THIRD: failed},
        )
        self.assertTrue(report.line_passed(jobs, "main", self.files))
        self.assertIn(f"Line `{THIRD}` did not pass", body)

    def test_the_upstream_link_counts_the_tests_of_the_reference_line(self) -> None:
        lines = [THIRD, "25.12"]
        body, _ = self.body(
            lines=lines,
            reference=THIRD,
            results={
                (THIRD, "x86-64"): junit((3, 0, 0), (7, 0, 0)),
                ("25.12", "x86-64"): junit((3, 0, 0), (1, 0, 0)),
            },
            package_tests="present",
        )
        link = next(r for r in body.splitlines() if r.startswith("https://github.com/"))
        text = parse_qs(urlsplit(link).query)["body"][0]
        self.assertIn("package runtime tests: 7 passed, 0 skipped, 0 failed)", text)
        self.assertIn(f"(OpenWrt {THIRD} SDK)", text)

    def test_line_results_are_read_per_line_and_checked(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            for line, data in all_results(["main", "25.12", THIRD]).items():
                directory = os.path.join(tmp, f"line-result-netbird-{line}")
                os.makedirs(directory)
                with open(os.path.join(directory, "result.json"), "w") as handle:
                    json.dump(data, handle)
            # A file of another package, or one that names another line, is no
            # result of this line.
            other = os.path.join(tmp, "line-result-netbird-lonely")
            os.makedirs(other)
            with open(os.path.join(other, "result.json"), "w") as handle:
                json.dump(result_for("main", LINES), handle)
            found = report.read_line_results(
                tmp, "netbird", ["main", THIRD, "lonely", "gone"]
            )
            self.assertEqual(sorted(found), sorted(["main", THIRD]))
            self.assertEqual(report.read_line_results(tmp, "other", ["main"]), {})
            # A file in the directory of this package that says it is another
            # package's is not read either.
            stray = os.path.join(tmp, "line-result-netbird-25.12")
            os.makedirs(stray, exist_ok=True)
            with open(os.path.join(stray, "result.json"), "w") as handle:
                json.dump(dict(result_for("25.12", LINES), package="other"), handle)
            self.assertEqual(report.read_line_results(tmp, "netbird", ["25.12"]), {})

    def test_job_names_do_not_depend_on_the_name_of_the_matrix_job(self) -> None:
        for outer in ("lines (main)", "lines", "lines (netbird, main, pr)"):
            jobs = report.parse_jobs(
                [{"name": f"{outer} / test / main x86-64", "conclusion": "success"}],
                LINES,
            )
            self.assertEqual(
                [(j.stage, j.line, j.item) for j in jobs], [("test", "main", "x86-64")]
            )
        self.assertEqual(
            report.parse_jobs(
                [{"name": "detect"}, {"name": "lines (main) / build / feed main"}],
                LINES,
            ),
            [],
        )

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
            "2 test(s) of the package suite skipped (`skip0: NB_SETUP_KEY is not set`)",
            body,
        )
        self.assertIn("A skipped test is not a pass", body)

    def test_hostile_test_text_is_inert_in_the_body(self) -> None:
        body, _ = self.body(
            results=every_target((3, 0, 0), (7, 0, 0))
            | {("main", "x86-64"): hostile_junit()},
            package_tests="present",
        )
        for text in ("@octocat", "@victim", "[x]", "](", "<img", "onerror=y>", "\\"):
            self.assertNotIn(text, body)
        self.assertEqual(
            {line for line in body.splitlines() if line.startswith("#")}, HEADINGS
        )
        note = [line for line in body.splitlines() if "skipped (" in line]
        self.assertEqual(len(note), 1)
        self.assertTrue(note[0].endswith("A skipped test is not a pass.**"), note[0])
        self.assertRegex(note[0], r"skipped \(`a [^`]*`\)")

    def test_hostile_junit_text_is_one_plain_line(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "results.xml")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(hostile_junit())
            _, package = report.parse_junit(path)
        self.assertEqual(len(package.reasons), 1)
        reason = package.reasons[0]
        self.assertEqual(reason, " ".join(reason.split()))
        self.assertIn("Injected heading octocat", reason)
        self.assertRegex(reason, r"^[^@\[\]()<>|`\\\n]+$")

    def test_safe_text_drops_each_marker_and_collapses_whitespace(self) -> None:
        for char in "@[]()<>|`\\":
            with self.subTest(char=char):
                self.assertEqual(report.safe_text(f"a{char}b"), "ab")
        self.assertEqual(report.safe_text(" a\n\r\n# b\t\tc \u2028d "), "a # b c d")

    def test_safe_text_is_capped(self) -> None:
        self.assertEqual(len(report.safe_text("x" * 5000)), report.SKIP_REASON_MAX)
        self.assertEqual(report.safe_text("x" * 50, 10), "x" * 10)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "results.xml")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(hostile_junit().replace("needs", "n" * 5000))
            _, package = report.parse_junit(path)
        self.assertLessEqual(len(package.reasons[0]), report.SKIP_REASON_MAX)

    def test_only_the_first_skip_reasons_are_listed(self) -> None:
        body, _ = self.body(
            results={("main", "x86-64"): hostile_junit(12)}, package_tests="present"
        )
        self.assertIn("; and 7 more)", body)
        note = next(line for line in body.splitlines() if "skipped (" in line)
        self.assertEqual(len(re.findall(r"`a [^`]*`", note)), report.SKIP_REASONS_SHOWN)

    def test_counts_are_integers(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "results.xml")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(hostile_junit(3))
            generic, package = report.parse_junit(path)
        for counts in (generic, package):
            for value in (counts.passed, counts.skipped, counts.failed):
                self.assertIs(type(value), int)
        self.assertRegex(report.counts_row(package), r"^\d+ \| \d+ \| \d+$")
        body, _ = self.body(
            results=every_target((3, 0, 0), (7, 0, 1)), package_tests="present"
        )
        for line in body.splitlines():
            if line.startswith("| `main` | package tests"):
                self.assertRegex(line, r"\| \d+ \| \d+ \| \d+ \| ")

    def test_a_hostile_artifact_name_is_not_a_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            for target in ("x86-64", "x86@octocat", "x86[a](b)", "x86\n# h"):
                directory = os.path.join(tmp, f"qemu-netbird-main-{target}")
                os.makedirs(directory)
                with open(os.path.join(directory, "results.xml"), "w") as handle:
                    handle.write(junit((1, 0, 0), (1, 0, 0)))
            found = report.parse_results(tmp, "netbird", LINES)
        self.assertEqual([r.target for r in found], ["x86-64"])

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
            found = report.parse_results(tmp, "netbird", LINES)
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
                if key not in ("package_tests", "results", "line_list"):
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
                if key not in ("line_list", "line_results", "overlays"):
                    argv += [f"--{key.replace('_', '-')}", value]
            results = os.path.join(tmp, "results")
            write_results(results, every_target((3, 0, 0), (7, 0, 0)))
            line_results = os.path.join(tmp, "line-results")
            for line, data in all_results().items():
                directory = os.path.join(line_results, f"line-result-netbird-{line}")
                os.makedirs(directory)
                with open(os.path.join(directory, "result.json"), "w") as handle:
                    json.dump(data, handle)
            argv += ["--jobs", paths["jobs"], "--artifacts", paths["artifacts"]]
            argv += ["--results", results, "--out", paths["out"]]
            argv += ["--line-results", line_results]
            argv += ["--overlays", json.dumps(overlays_for(LINES))]
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                self.assertEqual(report.main(argv), 0)
            self.assertEqual(captured.getvalue().strip(), "reference_passed=true")
            with open(paths["out"], encoding="utf-8") as handle:
                self.assertIn("## Results", handle.read())
            # The reference line's own file says it failed: not passed.
            bad = os.path.join(line_results, "line-result-netbird-main", "result.json")
            with open(bad, "w") as handle:
                json.dump(
                    result_for("main", LINES, test="failure", passed=False), handle
                )
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                report.main(argv)
            self.assertEqual(captured.getvalue().strip(), "reference_passed=false")
            # A reference line that is not one of the lines is refused.
            with self.assertRaises(SystemExit):
                report.main(argv + ["--reference", "nope"])

    def test_cli_requires_the_new_inputs(self) -> None:
        for missing in (
            "upstream_base",
            "test_secrets",
            "results",
            "lines",
            "reference",
            "overlays",
            "line_results",
        ):
            argv = []
            for key, value in vars(args_for()).items():
                if key not in (missing, "line_list"):
                    argv += [f"--{key.replace('_', '-')}", value]
            argv += ["--jobs", "j", "--artifacts", "a", "--out", "o"]
            with self.subTest(missing=missing), self.assertRaises(SystemExit):
                report.main(argv)


if __name__ == "__main__":
    unittest.main(verbosity=2)
