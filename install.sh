#!/usr/bin/env bash
# Install the ForwardAI CI gate into a target repo. Copies the caller workflows +
# dependabot + gitleaks config into <target>/.github/. Idempotent.
#   ./install.sh /path/to/target-repo [package_name]
set -euo pipefail
TARGET="${1:?usage: install.sh <target-repo> [package_name]}"
PKG="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TARGET/.github/workflows"
cp "$HERE/templates/.github/workflows/ci.yml"     "$TARGET/.github/workflows/ci.yml"
cp "$HERE/templates/.github/workflows/codeql.yml" "$TARGET/.github/workflows/codeql.yml"
cp "$HERE/templates/.github/dependabot.yml"       "$TARGET/.github/dependabot.yml"
[ -f "$TARGET/.gitleaks.toml" ] || cp "$HERE/templates/.gitleaks.toml" "$TARGET/.gitleaks.toml"
[ -n "$PKG" ] && sed -i.bak "s/your_pkg/$PKG/" "$TARGET/.github/workflows/ci.yml" && rm -f "$TARGET/.github/workflows/ci.yml.bak"
echo "Installed CI gate into $TARGET/.github/ (package: ${PKG:-set your_pkg manually})"
echo "Next: enable branch protection + Dependabot alerts in repo Settings."
