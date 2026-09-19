#!/usr/bin/env python3
"""Regression tests for the lint/format gates (#60, #30, #31).

The Makefile ``lint``/``format`` targets and the Forgejo CI shellcheck step
used to discard failures (``|| true``, output sent to /dev/null), so the
gates always passed. These tests pin the strict behavior.
"""

import unittest
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
MAKEFILE_PATH = REPO_ROOT / "Makefile"
CI_WORKFLOW_PATH = REPO_ROOT / ".forgejo" / "workflows" / "ci.yml"


def make_target_recipe(makefile_text, target):
    """Return the recipe of a Makefile target as a single string."""
    lines = makefile_text.splitlines()
    for idx, line in enumerate(lines):
        if line.startswith(f"{target}:"):
            recipe_lines = []
            for recipe_line in lines[idx + 1 :]:
                if recipe_line.startswith("\t"):
                    recipe_lines.append(recipe_line.lstrip("\t"))
                elif recipe_line.strip():
                    break
            return "\n".join(recipe_lines)
    raise AssertionError(f"Makefile target {target!r} not found")


def ci_step_run(workflow_text, job, step_name):
    """Return the ``run`` script of a named CI step."""
    workflow = yaml.safe_load(workflow_text)
    for step in workflow["jobs"][job]["steps"]:
        if step.get("name") == step_name:
            return step["run"]
    raise AssertionError(f"CI step {step_name!r} not found in job {job!r}")


class TestMakefileLintGate(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.recipe = make_target_recipe(MAKEFILE_PATH.read_text(), "lint")

    def test_shellcheck_failures_are_not_swallowed(self):
        self.assertNotIn("|| true", self.recipe)
        shellcheck_lines = [ln for ln in self.recipe.splitlines() if ln.startswith("@shellcheck")]
        self.assertEqual(len(shellcheck_lines), 2)
        for line in shellcheck_lines:
            self.assertIn("-S error", line)
            self.assertNotIn("2>/dev/null", line)

    def test_yamllint_runs_when_installed_and_fails_on_errors(self):
        self.assertIn("command -v yamllint", self.recipe)
        self.assertIn("yamllint $$files", self.recipe)
        for line in self.recipe.splitlines():
            if "yamllint" in line:
                self.assertNotIn("||", line)

    def test_yamllint_covers_repo_yaml_files(self):
        for pattern in ("*.yaml", "*.yml", "config.yaml.template", "dev/tests/*.yaml"):
            self.assertIn(pattern, self.recipe)


class TestMakefileFormatGate(unittest.TestCase):
    def test_format_runs_black_on_all_python_sources(self):
        recipe = make_target_recipe(MAKEFILE_PATH.read_text(), "format")
        self.assertRegex(recipe, r"black bootstrap\.py webui/ tests/unit/")
        self.assertNotIn("black not installed", recipe)


class TestCIShellcheckGate(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = ci_step_run(CI_WORKFLOW_PATH.read_text(), "lint", "Run shellcheck")

    def test_shellcheck_failures_are_not_swallowed(self):
        self.assertNotIn("|| true", self.script)
        self.assertNotIn("2>/dev/null", self.script)

    def test_shellcheck_keeps_error_severity(self):
        self.assertEqual(self.script.count("shellcheck -S error"), 2)


if __name__ == "__main__":
    unittest.main()
