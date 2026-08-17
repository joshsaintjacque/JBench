# JBench v1 visual QA

- Reference: `mockups/jbench-01-parallel-lanes.png`
- Implementation: `artifacts/jbench-v1.png`
- Combined comparison: `artifacts/jbench-v1-comparison.png`
- Capture: app-owned SwiftUI snapshot at 1420 x 920 points
- State: two completed provider-free demo lanes; no Codex or OpenCode prompt ran

## Visible comparison

- Structure: passed. The compact prompt header, review switcher, parallel result cards, export controls, and summary strip match the selected Parallel Lanes direction.
- Density: passed after fix. Completed outputs now appear above the fold instead of below the full setup form.
- Truthfulness: passed after fix. Demo lanes identify the harness as `Demo`, and unavailable observed telemetry stays unavailable.
- Expected differences: the implementation follows the Mac's dark appearance and uses two provider-free fixtures. The mockup uses a light appearance and three illustrative live-harness lanes.
- Screenshot limitation: the app-owned snapshot captures the core run surface because macOS Screen Recording access was unavailable to the capture process. The normal app keeps its native sidebar and window chrome.

Final result: passed.
