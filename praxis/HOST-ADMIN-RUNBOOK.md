# Host-admin runbook — promote praxis-gate to the full aah CI gate, fleet-wide

**Audience:** whoever has write access to the host at `/srv/swarm/praxis/`.
**Why a runbook and not a PR:** the canonical `praxis-gate.sh` is a **read-only, root-owned
mount** inside every container (`/workspace/.swarm/praxis/…`), so no container session can edit
it. These changes must be made on the host.

**Goal:** close every gap between what `praxis-gate` enforces today (build-time, fleet-wide) and
what the exported **aah** repo enforces in CI — so code stays deploy-ready throughout the build,
not refactored at deploy.

**Baseline versions (2026-07-26):** praxis-gate **v2.0.2** (300 lines); canonical file
`/srv/swarm/praxis/toolkit/bin/praxis-gate.sh`.

---

## 1. The gap table (aah CI enforces → praxis-gate lacks)

| # | Control | aah CI | praxis-gate today | Layer |
|---|---|---|---|---|
| G1 | **SAST — bandit** | ✅ hard | ✗ none | local ✅ closeable |
| G2 | **SAST — semgrep** | ✅ hard | ✗ none | local ✅ |
| G3 | **2nd type checker — pyright** | ✅ hard | one `typecheck` slot only | local ✅ |
| G4 | **Lint score gate — pylint ≥ 9.0** | ✅ hard | generic `lint` only | local ✅ |
| G5 | **Docstring coverage — interrogate ≥ 80%** | ✅ hard | ✗ none | local ✅ |
| G6 | **Coverage bar** | **90%** | **70%** (default) | local ✅ (config) |
| G7 | **CVE — hard fail** | osv-scanner hard | `cve` **warn** (`STRICT_CVE=0`) | local ✅ (config) |
| G8 | **Dedicated secret scanner — gitleaks** | ✅ hard | `scan_secrets` (built-in regex) | local ✅ (upgrade) |
| G9 | **Packaging integrity — validate-pyproject/build/twine** | ✅ hard | ✗ none | local ✅ |
| G10 | **CodeQL** (semantic SAST) | ✅ (own workflow) | ✗ | **CI-only** ⚠ |
| G11 | **Dependabot** (auto dep-update PRs) | ✅ | ✗ | **CI-only** ⚠ |
| G12 | **Branch protection / required checks** | ✅ | ✗ | **CI-only** ⚠ |
| G13 | **SHA-pinned actions + least-priv tokens** | ✅ | ✗ | **CI-only** ⚠ |

- **G1–G9 close in praxis-gate** (this runbook, §3–§4).
- **G10–G13 CANNOT** live in a local build-time gate — they are GitHub-CI / repo-settings
  controls. They are already packaged in **`forwardai-dev/ci-workflows@v1`**; the standard is
  *"any deliverable exported to its own repo calls `ci-workflows@v1` + enables branch protection
  + Dependabot."* praxis-gate covers the build; ci-workflows covers continuous. See §6.

---

## 2. Prerequisites — tools on the gate host

The new hard checks shell out to these. Install once in the environment praxis-gate runs in
(pin the versions aah validated so a stricter release can't silently break the fleet):

```bash
pip install "bandit==1.8.*" "semgrep==1.171.0" "pyright==1.1.411" "pylint==4.0.6" "interrogate==1.7.*" \
            "build" "twine" "validate-pyproject[all]"
# binaries:
curl -sSL https://github.com/gitleaks/gitleaks/releases/download/v8.21.2/gitleaks_8.21.2_linux_x64.tar.gz | tar -xz -C /usr/local/bin gitleaks
curl -sSL https://github.com/google/osv-scanner/releases/download/v1.9.1/osv-scanner_linux_amd64 -o /usr/local/bin/osv-scanner && chmod +x /usr/local/bin/osv-scanner
```

If any tool is absent, the checks below print `SKIP` (they do not fail-open silently — a SKIP on
a hard check is surfaced in results.tsv per the gate's existing `resolve_skip` logic).

---

## 3. Config-only gaps (G6, G7) — change two defaults

Edit `/srv/swarm/praxis/toolkit/bin/praxis-gate.sh`, **line 30**:

```diff
- COVERAGE_MIN=70; STRICT_CVE=0; LINT_CMD=""; TYPECHECK_CMD=""; TEST_CMD=""
+ COVERAGE_MIN="${COVERAGE_MIN:-90}"; STRICT_CVE="${STRICT_CVE:-1}"; LINT_CMD=""; TYPECHECK_CMD=""; TEST_CMD=""
```

This raises coverage 70→**90** and makes CVE a **hard** gate — while still letting a project
override downward via env/`.praxis/gate.conf` (the `:-` keeps it non-breaking for a project that
declares a lower bar with a reason).

---

## 4. New hard checks (G1–G5, G8, G9) — insert after the typecheck line

**Design:** gate the new checks behind a `PRAXIS_STRICT` flag so the rollout is **staged** (the
fleet does not break on day one — see §5). Each check auto-`SKIP`s if its config/tool is absent,
so a project that hasn't adopted the tool isn't failed for it.

Insert this block **immediately after line 136** (`… typecheck hard SKIP; fi`):

```bash
# ── strict profile: the full aah scanner set (staged via PRAXIS_STRICT) ──────────────
if [ "${PRAXIS_STRICT:-0}" = 1 ]; then
  # G3 second type checker
  if command -v pyright >/dev/null 2>&1 && [ -n "${SRC_PATHS:-src}" ]; then
    check "25010-Maintainability" pyright hard bash -lc "cd '$DIR' && pyright ${SRC_PATHS:-src}"
  else check "25010-Maintainability" pyright hard SKIP; fi
  # G4 lint score
  if command -v pylint >/dev/null 2>&1; then
    check "25010-Maintainability" pylint hard bash -lc "cd '$DIR' && pylint ${SRC_PATHS:-src} --fail-under=${PYLINT_MIN:-9.0}"
  else check "25010-Maintainability" pylint hard SKIP; fi
  # G1 SAST bandit
  if command -v bandit >/dev/null 2>&1; then
    check "§II-B P10" bandit hard bash -lc "cd '$DIR' && bandit -rq ${SRC_PATHS:-src} -c pyproject.toml"
  else check "§II-B P10" bandit hard SKIP; fi
  # G2 SAST semgrep
  if command -v semgrep >/dev/null 2>&1; then
    check "§II-B P10" semgrep hard bash -lc "cd '$DIR' && semgrep --config=auto --error --quiet ${LINT_PATHS:-src tests}"
  else check "§II-B P10" semgrep hard SKIP; fi
  # G8 dedicated secret scanner (upgrades the built-in regex)
  if command -v gitleaks >/dev/null 2>&1; then
    check "§II-B P10/P12" gitleaks hard bash -lc "cd '$DIR' && gitleaks detect --source . \$([ -f .gitleaks.toml ] && echo --config .gitleaks.toml) --redact"
  else check "§II-B P10/P12" gitleaks hard SKIP; fi
  # G5 docstring coverage
  if command -v interrogate >/dev/null 2>&1; then
    check "25010-Maintainability" docstrings hard bash -lc "cd '$DIR' && interrogate -c pyproject.toml ${SRC_PATHS:-src}"
  else check "25010-Maintainability" docstrings hard SKIP; fi
  # G9 packaging integrity (python projects)
  if [ -f "$DIR/pyproject.toml" ] && command -v twine >/dev/null 2>&1; then
    check "§II-B P15" packaging hard bash -lc "cd '$DIR' && validate-pyproject pyproject.toml && python -m build -q && twine check dist/*"
  else check "§II-B P15" packaging hard SKIP; fi
fi
# ─────────────────────────────────────────────────────────────────────────────────────
```

Notes:
- `SRC_PATHS` / `LINT_PATHS` / `PYLINT_MIN` are optional per-project overrides (settable in
  `.praxis/gate.conf`); they default to `src` / `src tests` / `9.0` to match aah.
- Bump the version banner: `PRAXIS_GATE_VERSION="2.1.0"` so `praxis-gate` prints which gate ran.

---

## 5. Rollout — you chose "force on all builds"; here is how to do it safely anyway

Forcing the higher bar on every build at once **will fail other clients' in-flight builds**
(medstar, mica, meeta, icf…) until their code + tooling meet it. The `PRAXIS_STRICT` flag lets
you get to the same end state without a fleet outage:

**Stage 1 — land the code, default OFF (zero blast radius).** Apply §3 + §4 with
`PRAXIS_STRICT` defaulting to `0`. Nothing changes for anyone; strict is available to opt into
per project via `.praxis/gate.conf` (`PRAXIS_STRICT=1`). aah-class deliverables opt in now.

**Stage 2 — announce + grace window.** Tell the fleet the bar rises on a date; point each
session at `preflight.sh` (from `ci-workflows`) so they can see failures early and fix ahead.

**Stage 3 — force it on (your chosen end state).** Flip the default in `praxis-gate.sh`:

```diff
- if [ "${PRAXIS_STRICT:-0}" = 1 ]; then
+ if [ "${PRAXIS_STRICT:-1}" = 1 ]; then    # strict is now the fleet default
```

and raise the two defaults' fallbacks in §3 to hard values if you want them non-overridable.
From here every build gets the full set; a project genuinely needing an exception uses the
gate's existing **dated-waiver** mechanism (visible + finite in results.tsv), not a silent pass.

> Doing Stage 3 on day one is the literal "force on all" option — it just means the fleet's
> current red builds surface immediately instead of at the grace deadline. Recommended only if
> you're prepared to help other clients green up at once.

---

## 6. What stays in CI, not the gate (G10–G13)

These are GitHub-native / repo-settings controls a local gate structurally cannot run. The
standard that closes them: **every exported deliverable repo**

1. adds `.github/workflows/ci.yml` calling `uses: forwardai-dev/ci-workflows/.github/workflows/full.yml@v1`,
2. copies `templates/.github/codeql.yml` + `dependabot.yml` from that repo,
3. enables **branch protection** (required checks + linear history) and **Dependabot alerts** in Settings.

praxis-gate proves it passed once at build; ci-workflows proves it stays passing forever.

---

## 7. Verify the promotion

```bash
# on the host, after editing:
bash -n /srv/swarm/praxis/toolkit/bin/praxis-gate.sh        # syntax ok
PRAXIS_STRICT=1 praxis-gate /path/to/a/known-green/project  # should PASS with the new checks listed
PRAXIS_STRICT=1 praxis-gate /path/to/a/repo/with/a/secret   # should FAIL on gitleaks
grep PRAXIS_GATE_VERSION /srv/swarm/praxis/toolkit/bin/praxis-gate.sh   # 2.1.0
```

Then confirm the mount propagates read-only into a container:
`grep PRAXIS_GATE_VERSION /workspace/.swarm/praxis/toolkit/bin/praxis-gate.sh` → `2.1.0`.

---

## Appendix — exact aah CI reference (the target state)

`ci.yml` quality job: ruff (lint+format) · pylint ≥9.0 · mypy · pyright · bandit · semgrep ·
gitleaks · coverage ≥90 · interrogate ≥80 · osv-scanner · pip-audit (advisory) · validate-pyproject ·
build+twine · docs-sync guard. Plus `codeql.yml`, Dependabot, branch protection, SHA-pinned
actions, least-priv tokens, and the `assurance-gate.yml` self-gate (aah-specific). Scanner
versions pinned: semgrep 1.171.0, pyright 1.1.411, pylint 4.0.6, gitleaks 8.21.2, osv-scanner 1.9.1.
```
