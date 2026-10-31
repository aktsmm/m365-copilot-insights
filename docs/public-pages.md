# Public measured snapshot

The measured entry uses only `tests/fixtures/public-measured-monthly.json`,
whose reviewed public-payload SHA256 is checked by `Build-CopilotPublicPages.ps1`.
Numbers, nulls, coverage, metric and dates retain their original meaning. Names and department names are real demo-tenant data (fictional people); only the UPN domain is hidden. No GUID, tenant domain, URL or private source hash ships.
The sanitizer rebuilds allowlisted fields rather than copying unknown properties.

`synthetic-pages.yml` is manual-only in `aktsmm/m365-copilot-insights`. Its Pages
environment is separate from the backend branch OIDC identity. It builds no live
Graph/SPO input and has no tenant configuration. There is no automatic snapshot
refresh. Each deployment must verify the generated manifest against anonymous
HTTP bytes and the actual rendered language/filter/CSV behavior.

See the repository README for fresh-directory local test/build commands and known
limitations. Measured incomplete actions are not complete-month prompts.
