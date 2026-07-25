# ci-workflows — the ForwardAI reusable CI gate

One source of truth for the full **code-standards + security** gate, callable from any repo
with a single `uses:` line. It is the continuous-enforcement counterpart to the local
`praxis-gate` (build-time), and mirrors the PRAXIS §II-B controls (SAST, secrets, deps,
types, coverage, SBOM) so a deliverable exported to its own repo stays gated forever.

## What it enforces

`.github/workflows/full.yml` (reusable, `workflow_call`) runs two jobs:

| Job | Gates |
|---|---|
| **test** | `pytest` across a Python version matrix (default 3.11 / 3.12 / 3.13) |
| **quality** | ruff (lint+format) · **pylint ≥ 9.0** · mypy · **pyright** · **bandit** · **semgrep** · **gitleaks** · **coverage ≥ 90%** · interrogate ≥ 80% · **osv-scanner** · pip-audit (advisory) · **SBOM** (syft → CycloneDX artifact) · validate-pyproject · build + twine · optional docs-sync guard |

Scanner versions are **pinned** (semgrep 1.171.0, pyright 1.1.411, pylint 4.0.6) so a stricter
upstream release can't silently break callers. CodeQL and Dependabot are GitHub-native and ship
as **templates** (they can't be reusable-workflow jobs).

## Use it (recommended: reference `@v1`)

Add `.github/workflows/ci.yml` to your repo:

```yaml
name: ci
on: [push, pull_request]
permissions:
  contents: read
jobs:
  ci:
    uses: forwardai-dev/ci-workflows/.github/workflows/full.yml@v1
    with:
      package-name: "your_pkg"   # enables coverage gate; "" to disable
      src-paths: "src"
      lint-paths: "src tests"
      coverage-min: 90
      run-docs-sync: false
```

Then copy `templates/.github/codeql.yml` and `templates/.github/dependabot.yml` into your
repo (GitHub-native, not reusable), and enable branch protection + Dependabot alerts in
Settings.

## Or copy-in (no `@v1` reference)

```bash
./install.sh /path/to/target-repo your_pkg
```

Copies the caller workflows, dependabot, and a generic `.gitleaks.toml` into the target.

## Inputs

| Input | Default | Purpose |
|---|---|---|
| `python-versions` | `["3.11","3.12","3.13"]` | test matrix |
| `src-paths` | `src` | paths for mypy/pyright/pylint/bandit |
| `lint-paths` | `src tests` | paths for ruff/semgrep |
| `package-name` | `""` | coverage import name; empty disables the coverage gate |
| `coverage-min` | `90` | coverage % gate (0 disables) |
| `pylint-min` | `9.0` | pylint score gate (0 disables) |
| `docstring-min` | `80` | interrogate % gate (0 disables) |
| `run-docs-sync` | `false` | run `scripts/check_docs_sync.py` if present |

## Repo prerequisites (caller side)

The caller repo needs a `pyproject.toml` with a `dev` extra (pytest, ruff, mypy) and a
`tests/` dir. Non-Python stacks would need a sibling reusable workflow (not yet built).

## Relationship to praxis

- **praxis-gate** — local, build-time, run once by a human/agent before export. Interactive-only by design.
- **ci-workflows** — continuous, runs on every push/PR on GitHub infra, travels with the exported repo.

A repo that both passes praxis-gate at build AND calls this on every push is gated end-to-end.
