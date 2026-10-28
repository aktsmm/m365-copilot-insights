# Independent synthetic demonstration

`tests/fixtures/monthly-pages.cjs` constructs fixed, independently authored synthetic
data. It never imports live reports, history, mappings or environment configuration.
All fixture identities use the reserved `example.invalid` domain.

The common monthly UI preserves Japanese/English, strict less-than thresholds
5/10/15/30 and arbitrary nonnegative integers, department/search, unknown values,
partial-month disclosures and CSV export. The complete synthetic month is not
evidence of measured complete-month coverage. Unknown is never replaced with zero.

`Test-CopilotSyntheticPages.ps1` verifies independent build reproducibility and all
manifest file hashes. `Build-CopilotPublicPages.ps1` keeps the measured and synthetic
entries separate. See the repository README for execution instructions.
