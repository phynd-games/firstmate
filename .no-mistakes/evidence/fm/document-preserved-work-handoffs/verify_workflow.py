import json
import subprocess
from pathlib import Path
import yaml

BASE = "fe601e80363dca6469775ca98ad0643071fb48f3"
HEAD = "47fe028abef61f3aed108f8f86849ec92cdee47a"
workflow = ".github/workflows/ci.yml"
def git(*args):
    return subprocess.check_output(["git", *args], text=True)
assert git("rev-parse", "HEAD").strip() == HEAD
# BaseLoader preserves GitHub's `on` key instead of YAML 1.1 boolean coercion.
base = yaml.load(git("show", BASE + ":" + workflow), Loader=yaml.BaseLoader)
head = yaml.load(Path(workflow).read_text(), Loader=yaml.BaseLoader)
assert isinstance(base, dict) and isinstance(head, dict)
removed = {"tests-portable-parallel-1", "tests-portable-parallel-2",
           "tests-portable-serial", "tests-timing-aggregate"}
retained = {"lint", "test-coverage", "invariants"}
assert set(base["jobs"]) - set(head["jobs"]) == removed
assert set(head["jobs"]) == retained
assert {k: v for k, v in base.items() if k != "jobs"} == {k: v for k, v in head.items() if k != "jobs"}
for job in retained:
    assert head["jobs"][job] == base["jobs"][job], job
assert base["jobs"]["tests-portable-serial"]["strategy"]["matrix"]["shard"] == ["1", "2", "3", "4"]
assert set(base["jobs"]["tests-timing-aggregate"]["needs"]) == removed - {"tests-timing-aggregate"}
expected = {"AGENTS.md", ".agents/skills/communication-discipline/SKILL.md",
            ".agents/skills/stuck-crewmate-recovery/SKILL.md", workflow}
assert set(git("diff", "--name-only", BASE, HEAD).splitlines()) == expected
result = {"base": BASE, "head": HEAD,
          "workflow_triggers": head["on"], "permissions": head["permissions"],
          "active_jobs": head["jobs"],
          "excluded_job_definitions": sorted(removed),
          "excluded_serial_matrix": base["jobs"]["tests-portable-serial"]["strategy"]["matrix"],
          "retained_jobs_identical_to_base": True,
          "non_job_workflow_settings_identical_to_base": True,
          "changed_files": sorted(expected),
          "limitation": "Local normalized workflow comparison; hosted GitHub Actions were not executed."}
output = Path(__file__).with_name("workflow-semantics.json")
output.write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps({k:v for k,v in result.items() if k != "active_jobs"}, indent=2))
