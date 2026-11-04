# 運用メモ（詳細・英語）

> 確認日: 2026-11-04。初期移行時の未認証状態ではなく、現在の実装を記載しています。取得元・未達項目は [data-sources](data-sources.md)、初回設定は [setup-guide](setup-guide.md) を参照してください。

`aktsmm/m365-copilot-insights` combines generic collection and publication code
with a separately built public static demonstration. This is a new source-only
repository, not a fork or a copy of private Git history.

## Public data boundary

`tests/fixtures/public-measured-monthly.json` is an approved, sanitized measured
snapshot from a demonstration environment. Its names and department names are real (fictional demo people); only the UPN domain is hidden. Numeric values, nulls, coverage, metric and dates are retained.
`tests/fixtures/monthly-pages.cjs` and `exports/synthetic/summary.json` are independent
synthetic fixtures, not additional measurements. The UI keeps measured actions,
prompts, incomplete months and unknown values distinct. Unknown is never zero.

Pages builds only these static public inputs. There is **no live-to-public refresh**.
The deployed Pages base is `https://aktsmm.github.io/m365-copilot-insights/`.

## Manual workflows and configuration

Workflows are manual except two schedules: the daily calendar collection (`calendar-validation.yml`, 06:00 and 18:00 JST) and the daily audit aggregate (`audit-aggregate.yml`, 03:30 JST).
There are also event-triggered failure recording and Pages publication after measured commentary succeeds.

- `live-validation.yml`: Graph collection, strict joins and existing private SPO
  department publication.
- `calendar-validation.yml`: daily actions / prompts collection, verified private history
  restoration, immutable publication, byte readback and ETag metadata CAS.
- `synthetic-pages.yml`: public fixture tests, reproducible static build and Pages.
  Its Pages OIDC token is for Pages deployment, not Graph; it has no tenant inputs.
- `oidc-probe.yml`: unchanged parent-approved GitHub claim probe. It does not
  exchange an Azure token or call Graph; only
  sub/aud/iss/repository/repository_id/repository_owner_id/ref appear.
- `synthetic-commentary.lock.yml`: installed gh-aw Copilot engine, synthetic
  aggregate only, noop output. Compilation does not prove inference eligibility.
- `measured-commentary.lock.yml`: manual inference on the approved public measured
  aggregate only; a bounded JSON artifact, not a private API capability.
- `record-collection-failure.yml`: failure / timeout event recording in Issues,
  using job and step names only, never raw logs.

The audit workflow applies a fixed public-name allowlist before grouping:
`Researcher`, `Analyst`, and `Planner Agent`; other names are grouped as
`その他`, and a missing name remains separate. It rejects unexpected output
labels before writing the public log or summary and runs synthetic privacy
regressions before each live query. Audit interactions and distinct users are
not Viva session counts. The failure recorder's actual event trigger has not
been verified, and it cannot detect a scheduled workflow that never starts.

The inference credential `COPILOT_GITHUB_TOKEN` has been provisioned and the
synthetic workflow ran successfully on 2026-10-28. This is separate from the
Azure OIDC credentials. Do not copy token values into issues, prompts or artifacts.
Compilation alone does not prove a new measured inference run succeeded.
References: https://github.github.com/gh-aw/reference/billing/ and
https://github.github.com/gh-aw/reference/auth/

## Measured aggregate commentary

From GitHub Actions, run **Measured aggregate commentary** on `main`.
No local browser or Microsoft 365 login is needed. The pre-step computes
department / month / metric totals from the reviewed public fixture. It strips
user IDs, names and UPNs before the model reads `exports/measured-aggregate.json`.
The original private source and live APIs are never model inputs.

The model requests `output/commentary.json` through `upload_artifact`. The installed
gh-aw compiler first stages a root-relative `commentary.json` inside the one-day
`safe-outputs-upload-artifacts` intermediate artifact; the handler then uploads the
final artifact named `commentary.json`, with a seven-day retention setting. Pages
never treats the intermediate artifact as a successful safe output.

The separate Pages workflow runs after a successful inference run. It requires the
final artifact from that run and attempt, checks its creation against the matching
`safe_outputs` job, repository / workflow / branch, bounded size, strict keys and
source digest, then HTML-escapes the short Japanese text. A successful workflow or
handler step alone does not establish that the final artifact was created. All numeric evidence is computed by
scripts; prose cannot contain numeric digits. Interpretation is labelled AI-generated,
not an official report, individual assessment, or proof of adoption.
The aggregate separates dates after the report refresh from expired unsaved gaps
and still-retrievable gaps. Missing days include future-report dates; do not
describe all of them as outages or promise that an expired month can be recovered.

Manual Pages dispatch uses the latest successful inference run. Before the first
inference it explicitly shows no AI prose. If that run's final artifact has expired,
the workflow may reuse the previously deployed `commentary.json` only if its
`commentary-provenance.json`, Pages manifest hashes, run, attempt and safe-output
job match; the builder must also accept the current aggregate digest. A missing
artifact before expiry, missing provenance, altered files, a new run without a
final artifact, invalid JSON or a changed aggregate stops deployment. After a
public fixture update, rerun measured commentary before publishing.

This reuse reads the fixed project Pages URL over HTTPS. The manifest and provenance
are integrity cross-checks, not independent signatures: trust depends on GitHub
Pages, TLS and the repository's authorized publishers. Previously deployed Pages
content remains until a successful replacement deployment.

The public page links to the aggregate input, AI JSON, provenance and inference run. Only the
public aggregate artifact is downloaded; never download backend artifacts or logs.
Source: https://github.github.com/gh-aw/reference/safe-outputs/#artifact-uploads-upload-artifact

The earlier integration run staged valid inference but its final handler rejected
the configured `output/commentary.json` allowlist: the handler checks paths
relative to the staging root. The allowlist now uses `commentary.json`; the Pages
downloader requires the final artifact and rejects staging-only output. Do not equate
an overall inference run success with downstream publication success.

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
Agentic Markdown, without switching engine or displaying a PAT.

```powershell
& .\tests\Test-CopilotPipeline.ps1
& .\tests\Test-CopilotPublicExposure.ps1
& .\tests\Test-CopilotCalendar.ps1
& .\tests\Test-CopilotHistory.ps1
& .\tests\Test-CopilotMonthlyPublish.ps1
& .\tests\Test-CopilotCurrentPointer.ps1
node --test .\tests\synthetic-pages.test.cjs .\tests\public-monthly.test.cjs .\tests\commentary.test.cjs
& .\tests\Test-CopilotSyntheticPages.ps1 -EvidenceDirectory .\.local\reproducibility
& .\scripts\Build-CopilotPublicPages.ps1 -OutputDirectory .\.local\public-site
```

Use fresh local output directories. A local pass does not verify Graph, SPO, OIDC,
Pages deployment, licensed Agentic inference, Viva fresh ingestion or SPFx access.
No live complete-month prompt coverage is claimed by this package.

## Troubleshooting a failed collection

`Record collection failure` automatically creates or comments on an Issue when
calendar collection or audit aggregation fails or times out. It records the run
URL, conclusion, and workflow-defined failed job / step names. This is deterministic
recording, not AI diagnosis or repair. It cannot see the hidden private exception
body, so it does not claim the root cause or copy report data into a public Issue.

The private processing deliberately hides its messages from public logs. The public run status carries only an allowlisted stage name:
`{"status":"failed","failedStage":"probe"}` (stages: `probe`, `restore`, `build`, `dashboard`, `publish`, and for the live mode `collect`, `observe`, `publish-observation`, `build-dashboard`, `publish-departments`).

1. Read `failedStage` in the run log.
2. `probe`: call the Graph report APIs once each (D7, D28, by-date) with a delegated admin token and check the HTTP status and the body format. Graph returns 504 intermittently; the by-date endpoint has answered JSON (actions) and CSV (prompts).
3. `restore` / `build` / `dashboard`: reproduce with the same stage scripts against fixtures; the calendar tests cover month rollover and two metrics.
4. `publish`: the verifier (`tests/Test-CopilotCalendarProbeResult.ps1`) independently recomputes the monthly values from the snapshots; a failed day must leave no data and record its error code.
5. Never publish or print private response bodies while debugging; use a temporary workflow that prints only the stage name and a redacted message, and delete it afterwards.

Known past causes (2026-11): Graph 504 on the usage reports, the by-date endpoint switching to CSV, a month rollover that left the new month without snapshots, and a strict gate that required all eight days to succeed.
