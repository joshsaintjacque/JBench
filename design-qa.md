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

## AI judges visual QA

- Source: `/Users/joshs/workspace/JBench/mockups/judges-01-integrated-drawer.png`
- Implementation: `/private/tmp/jbench-ai-judges-implementation.png`
- Combined comparison: `/private/tmp/jbench-ai-judges-comparison.png`
- Capture: app-owned SwiftUI snapshot at 1420 x 920 points (2840 x 1840 pixels); normalized to a 1536 x 1024 comparison canvas
- State: two completed provider-free candidates and one named correctness judge with a deterministic vote and reason

### Findings

- Full view: passed. The selected direction's stacked right inspector, candidate cards, add/run controls, and inline vote summaries fit the existing JBench run surface.
- Judge editor: passed. Name, harness, model, reasoning effort, and steering guidance remain visible and editable in one inspector.
- Vote attribution: passed. The winning card and inspector show the judge name, blind label, revealed harness/model, and reason.
- Existing design system: passed. The implementation uses JBench's native panel, control, spacing, and status styles instead of copying illustrative mockup chrome.
- Expected differences: the provider-free proof uses two candidates and one judge; the concept uses three candidates and three judges. The feature supports arbitrary judge counts.

### Iteration history

1. The first capture proved the configuration layout but occurred before judging finished.
2. Added a named provider-free demo judge and made snapshot mode wait for judge completion.
3. The snapshot initialization path could still finish candidates before automatic judging started, so snapshot mode now triggers one explicit judge pass when needed.
4. The final capture shows the vote and reasoning on both the winner card and the judge inspector.

Final result: passed.

## Focus reader visual QA

- Source: selected focus-reader ImageGen target from the implementation handoff; the user-local source path is intentionally omitted from this tracked record.
- Normal implementation: `artifacts/jbench-focus-reader-final.png`
- Capture: inspected app-window screenshot at the 1536 x 1024 point target viewport; the file remains an ignored local proof artifact.
- Fixture: provider-free lanes with deterministic local Markdown used only for local visual captures; no provider or account was used.

### Findings

- Structure: passed. The blind-review header, anonymous candidate rail, position controls, outline, readable response measure, and verdict inspector follow the selected focus-reader direction.
- Reading: passed. The active response is the hero surface with native `AttributedString(markdown:)` inline rendering, explicit list/code-block presentation, text selection, and anchored outline navigation.
- Identity safety: passed. Hidden mode uses Candidate labels and neutral approval copy; harness/model names and approval summaries appear only after reveal.
- Comparison: passed by code review. Pinning one candidate and switching to another produces side-by-side panes at wide widths and scrollable stacked panes at narrow widths. The rail marks the pinned candidate and the comparison header provides an accessible unpin action. No comparison media is retained.
- Verdict flow: passed. Existing winner, review-note, save/update, skip/reveal, history, and new-run actions remain in the inspector. Pin is view-local.
- Responsive behavior: passed by code review and the minimum-width branches. The outline is omitted below 980 points, the inspector moves below the reader below 760 points, and comparison panes stack below the wide breakpoint.

### Iteration history

1. The first capture showed the candidate rail but a blank reader because the existing vertical `ScrollView` gave the new workspace no height. Added a 620-point minimum height to the blind-review workspace.
2. The second capture showed the reader and inspector. Native Markdown parsing preserved inline attributes but did not visibly retain list/code-block presentation in SwiftUI `Text`, so added a small block presenter that keeps native inline parsing and gives lists/code blocks honest visual structure.
3. Added neutral pre-reveal approval copy, real pinned comparison panes, CommonMark-safe heading indentation, and a disabled focus effect while retaining arrow-key navigation.
4. Added the neutral hidden-identity header and notification copy, then recaptured and inspected the normal focus-reader state. Temporary capture instrumentation was removed from the implementation.

Final result: passed.
