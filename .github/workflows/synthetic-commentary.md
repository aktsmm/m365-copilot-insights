---
name: Synthetic aggregate commentary
on:
  workflow_dispatch:
permissions:
  contents: read
  copilot-requests: write
engine: copilot
tools:
  bash: ["cat"]
safe-outputs:
  noop:
---

Read only `exports/synthetic/summary.json`. This file describes an independently
authored synthetic demonstration, not tenant activity. Write a short Japanese
interpretation of its already-calculated totals. Do not recalculate totals, infer
individual activity, treat an unknown prompt count as zero, or claim customer
adoption. Clearly state the synthetic provenance and unknown values.

Do not inspect any other files, query Microsoft 365, change files, create issues,
or publish comments. If the file is absent or invalid, report missing data rather
than fabricate a conclusion. End with a noop safe output after the read-only
analysis.
