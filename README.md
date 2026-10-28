# Microsoft 365 Copilot insights

`aktsmm/m365-copilot-insights` combines generic collection and publication code
with a separately built public static demonstration. This is a new source-only
repository, not a fork or a copy of private Git history.

## Public data boundary

`tests/fixtures/public-measured-monthly.json` is an approved, sanitized measured
snapshot from a demonstration environment. Its account and department labels are
public-only aliases. Numeric values, nulls, coverage, metric and dates are retained.
`tests/fixtures/monthly-pages.cjs` and `exports/synthetic/summary.json` are independent
synthetic fixtures, not additional measurements. The UI keeps measured actions,
prompts, incomplete months and unknown values distinct. Unknown is never zero.

Pages builds only these static public inputs. There is **no live-to-public refresh**.
The planned Pages base is `https://aktsmm.github.io/m365-copilot-insights/`;
deployment and HTTP verification must complete before calling that URL available.

## Manual workflows and configuration

All workflows are manual-only. No schedules are installed.

- `live-validation.yml`: Graph collection, strict joins and existing private SPO
  department publication.
- `calendar-validation.yml`: daily actions collection, verified private history
  restoration, immutable publication, byte readback and ETag metadata CAS.
- `synthetic-pages.yml`: public fixture tests, reproducible static build and Pages.
  Its Pages OIDC token is for Pages deployment, not Graph; it has no tenant inputs.
- `oidc-probe.yml`: unchanged parent-approved GitHub claim probe. It does not
  exchange an Azure token or call Graph; only
  sub/aud/iss/repository/repository_id/repository_owner_id/ref appear.
- `synthetic-commentary.lock.yml`: installed gh-aw Copilot engine, synthetic
  aggregate only, noop output. Compilation does not prove inference eligibility.

Personal inference is `blocked-personal-inference-token-not-provisioned`.
GitHub Agentic Workflows personal billing requires a user-provided
`COPILOT_GITHUB_TOKEN`; the existing `copilot-requests: write` permission belongs
to centralized organization billing and is not proof of personal eligibility.
No PAT is provisioned, no engine is switched, and no known-blocked inference is
dispatched by this migration. This does not block the independent backend/Pages
gates. References: https://github.github.com/gh-aw/reference/billing/ and
https://github.github.com/gh-aw/reference/auth/

Private backend workflows require repository variables `TENANT_ID`,
`COLLECTOR_CLIENT_ID`, `PUBLISHER_CLIENT_ID`, `SPO_SITE_ID`, `SPO_LIBRARY_ID`,
`SPO_SITE_PATH` (the existing `/sites/` path), and `SPO_OWNERSHIP_MARKER` (the existing
site-description ownership marker). Set these from independently verified private
configuration, not from guessed defaults. Exact site ID, path, description marker,
library host and path checks remain mandatory. Collector roles are exactly
Reports.Read.All/User.Read.All; publisher role is exactly Sites.Selected. No
site-grant/bootstrap workflow, credential fallback or broad permission is included.

Backend output is isolated in a private child process. All child stdout/stderr,
exception bodies and summary/output files are suppressed from public Actions.
Only bounded operation/status JSON reaches public logs. Failure exits nonzero,
never blindly rewrites current and requires private reconciliation before replay.
Pre-commit failures leave current untouched; ambiguous CAS outcomes must be read
back privately rather than assumed unchanged. No backend artifacts, caches or reports are uploaded, on either
success or failure. Raw data is processed only in RUNNER_TEMP and the existing
private SPO; ephemeral runner data is removed when the entry point exits.

New immutable run keys use `repo-<repository_id>-<run_id>-<attempt>`. Readers accept
both the old numeric run keys and the new namespaced keys, verifying manifests,
provenance and hashes before aggregation. Duplicate dates remain revisions, not
double-counted activity; current metadata still uses the existing ETag CAS contract.
Do not delete or rewrite historical private runs during migration.

## Local validation

PowerShell 7.5+, Node.js and Git are required; gh-aw is needed to recompile the
Agentic Markdown, without switching engine or supplying a PAT.

```powershell
& .\tests\Test-CopilotPipeline.ps1
& .\tests\Test-CopilotPublicExposure.ps1
& .\tests\Test-CopilotCalendar.ps1
& .\tests\Test-CopilotHistory.ps1
& .\tests\Test-CopilotMonthlyPublish.ps1
& .\tests\Test-CopilotCurrentPointer.ps1
node --test .\tests\synthetic-pages.test.cjs .\tests\public-monthly.test.cjs
& .\tests\Test-CopilotSyntheticPages.ps1 -EvidenceDirectory .\.local\reproducibility
& .\scripts\Build-CopilotPublicPages.ps1 -OutputDirectory .\.local\public-site
```

Use fresh local output directories. A local pass does not verify Graph, SPO, OIDC,
Pages deployment, licensed Agentic inference, Viva fresh ingestion or SPFx access.
No live complete-month prompt coverage is claimed by this package.
