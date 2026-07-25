#!/usr/bin/env bash
# preflight — run the FULL ci-workflows gate LOCALLY before you commit/export, so code
# stays deploy-ready throughout the build (no refactor-at-deploy surprise). This is the
# local mirror of full.yml; run it from a project root. Skips any tool not installed
# (prints SKIP) so it degrades gracefully; install the pinned set for the real gate.
#
#   ./preflight.sh [src-paths] [lint-paths] [package-name] [coverage-min]
set -uo pipefail
SRC="${1:-src}"; LINT="${2:-src tests}"; PKG="${3:-}"; COVMIN="${4:-90}"
FAIL=0
run() { # name  hard|warn  cmd...
  local name="$1" mode="$2"; shift 2
  if ! command -v "${1%% *}" >/dev/null 2>&1 && ! python3 -c "import ${1}" 2>/dev/null; then
    printf '  [SKIP] %-12s (%s not installed)\n' "$name" "$1"; return; fi
  if "$@" >/tmp/pf.$$ 2>&1; then printf '  [PASS] %-12s\n' "$name"
  else
    if [ "$mode" = hard ]; then printf '  [FAIL] %-12s\n' "$name"; sed 's/^/         /' /tmp/pf.$$ | tail -4; FAIL=$((FAIL+1))
    else printf '  [WARN] %-12s\n' "$name"; fi
  fi; rm -f /tmp/pf.$$
}
echo "preflight — full local gate ($SRC)"
run ruff        hard ruff check $LINT
run ruff-fmt    hard ruff format --check $LINT
run pylint      hard pylint $SRC --fail-under=9.0
run mypy        hard mypy $SRC
run pyright     hard pyright $SRC
run bandit      hard bandit -r $SRC -c pyproject.toml -q
run semgrep     hard semgrep --config=auto --error --quiet $LINT
run gitleaks    hard gitleaks detect --source . $( [ -f .gitleaks.toml ] && echo "--config .gitleaks.toml" ) --redact
run osv         hard osv-scanner scan --recursive .
if [ -n "$PKG" ]; then run coverage hard bash -c "PYTHONPATH=src python3 -m pytest tests -q --cov=$PKG --cov-fail-under=$COVMIN"
else run pytest hard bash -c "PYTHONPATH=src python3 -m pytest tests -q"; fi
run interrogate warn interrogate -c pyproject.toml $SRC
run packaging   warn validate-pyproject pyproject.toml
echo "----------------------------------------"
if [ "$FAIL" -eq 0 ]; then echo "PREFLIGHT PASS — deploy-ready"; exit 0
else echo "PREFLIGHT FAIL — $FAIL hard gate(s); fix before commit/export"; exit 1; fi
