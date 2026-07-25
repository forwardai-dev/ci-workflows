# Bringing the full gate to praxis (local, build-time)

`praxis-gate` is host-canonical and interactive-only (NOT CI). To make it enforce the same
full scanner set as `ci-workflows` at build time, two options:

**Per-project (no host change, works today):** drop `gate.conf.strict` into your project as
`.praxis/gate.conf` (replace `PKG` with your import name). praxis-gate picks up the stronger
LINT/TYPECHECK/TEST/coverage automatically.

**Fleet-wide (needs a host admin):** the canonical gate at `/srv/swarm/praxis/toolkit/bin/
praxis-gate.sh` is a read-only mount inside containers. To raise the fleet default
(COVERAGE_MIN 70→90, STRICT_CVE 0→1, add pyright/pylint/semgrep/bandit/gitleaks as hard
checks), edit it on the host and let it propagate. Do this behind a strict flag or stage it —
other clients' in-flight builds (medstar, mica, meeta…) will start failing until their code
and tooling meet the higher bar.

**Or just run `../preflight.sh`** from any project — it runs the identical full gate locally
without touching praxis at all.
