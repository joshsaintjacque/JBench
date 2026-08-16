# PRD: JBench V1

## 1. Overview

JBench is a personal macOS application for running one prompt through two to six local agent configurations and comparing their results.

Each configuration selects a harness, model, and native reasoning level. V1 supports Codex and OpenCode. JBench uses the harnesses' existing local authentication and configuration. It does not call model-provider APIs directly.

The Parallel Lanes mockup is the visual direction. The core flow is one prompt, several agent lanes, and a side-by-side or blind comparison. Unproven decorative features, such as an automatic “Most Complete” winner, are not requirements.

## 2. Problem Statement

Comparing agent configurations now requires separate commands, repeated prompts, manual result collection, and unreliable comparison of settings and telemetry. This makes it hard to answer practical questions such as:

- Which agent produced the most useful answer?
- Which model and reasoning level were requested?
- Which settings did the harness report using?
- How long did each run take?
- Which output should be kept?

JBench must make this comparison repeatable without hiding harness differences or inventing unavailable metrics.

## 3. Goals

- Run the exact same prompt through two to six selected agent configurations.
- Support local Codex and OpenCode installations.
- Discover available models and native reasoning options when the harness supports discovery.
- Stream answers, activity, approvals, and status for each agent independently.
- Preserve requested settings separately from observed settings.
- Show operational timing, token counts, and cost only when the harness reports them authoritatively.
- Support safe read-only runs and isolated editable runs.
- Support side-by-side and identity-blind review.
- Save searchable local history, raw evidence, verdicts, and exported patches.
- Clean up only processes and worktrees that JBench owns.

## 4. Non-Goals

- Direct model-provider API integration.
- Credential or API-key storage.
- Harnesses other than Codex and OpenCode.
- Automatic answer scoring, ranking, or winner selection.
- Scientific benchmarking, repeated trials, warmups, or statistical analysis.
- Prompt attachments.
- Hidden prompt wrappers or per-agent private instructions.
- Automatic merge or application of agent changes to the original repository.
- Line-by-line diffing of independent prose answers.
- Product analytics, remote crash reporting, or cloud synchronization.
- App Store distribution, notarization, auto-update, or a public release.
- Support for macOS versions before macOS 26.

## 5. Users and Roles

### Owner

V1 has one local owner: Josh.

The owner may:

- configure harness executable paths;
- inspect harness readiness and versions;
- create and manage presets;
- select a working directory;
- start, approve, cancel, retry, and review runs;
- inspect and export raw evidence and patches;
- keep or discard JBench-owned worktrees;
- delete local history.

V1 has no accounts, teams, sharing permissions, or remote roles.

## 6. Core Workflows

### 6.1 Verify harness readiness

1. The owner opens Settings.
2. JBench detects common Codex and OpenCode executable paths.
3. JBench shows the exact executable path, version, authentication readiness, and discovery status.
4. The owner may override an executable path.
5. If authentication is missing, JBench shows the exact login command. JBench does not collect credentials.

### 6.2 Create and start a run

1. The owner opens New Run.
2. The owner enters one prompt.
3. The owner selects one working directory.
4. JBench reports whether the directory is a clean Git repository, a dirty Git repository, or a non-Git directory.
5. The owner selects read-only or editable mode when editable mode is available.
6. The owner adds two to six configurations or loads a named preset.
7. Each configuration selects a harness, model, native reasoning value, timeout, and approval policy.
8. JBench validates harness readiness and the requested values.
9. JBench submits the exact visible prompt to every agent. It adds no hidden prompt text.
10. All selected agents begin in parallel.

### 6.3 Handle working directories

- A clean Git repository supports read-only and editable runs.
- An editable run creates one isolated Git worktree per agent from the same committed `HEAD`.
- A dirty Git repository supports read-only runs only.
- A non-Git directory supports read-only runs only.
- Read-only execution requires a verified harness restriction that prevents filesystem mutation.
- Codex must use its enforced read-only sandbox.
- OpenCode must deny every mutation-capable permission, including shell execution, unless its active version provides an equivalent verified read-only sandbox.
- If an adapter cannot prove read-only enforcement with its supported contract, JBench must block that read-only run rather than rely on the prompt or UI label.
- JBench never changes or deletes the original working directory.

### 6.4 Monitor and control a run

1. Each lane streams rendered Markdown.
2. Each lane exposes a collapsible activity log and raw harness events.
3. A waiting approval appears only in the lane that requested it.
4. The owner may approve once, approve for that agent run, or decline when supported.
5. JBench explains any harness-specific limitation before sending the decision.
6. The owner may cancel one agent or the complete run.
7. A failed or timed-out agent does not remove completed outputs.
8. The owner may retry only the failed agent from the original run snapshot.
9. Every editable retry receives a fresh worktree from the recorded source commit.

### 6.5 Compare results

1. Side by Side shows the selected configurations in fixed-width, horizontally scrollable lanes.
2. Blind Review randomizes lane order and replaces identity with Response A, Response B, and so on.
3. Blind Review hides harness, model, reasoning, telemetry, and original order.
4. The owner may record an optional winner and note.
5. The owner reveals identities after recording or skipping a verdict.
6. JBench does not choose a winner automatically.

### 6.6 Review changes from editable agents

1. Every terminal editable attempt, including failed, cancelled, timed-out, and interrupted attempts, shows any changed-file count.
2. The owner may expand a diff, open the worktree, or export a patch.
3. The owner chooses whether to keep or discard the worktree.
4. Discard removes only the recorded JBench-owned worktree after owned processes exit.
5. Keep transfers the worktree to a user-selected path through a Git-aware move and ends JBench cleanup ownership.
6. JBench records the transfer result but never removes a transferred worktree during history deletion.
7. JBench does not apply or merge changes into the original repository.

### 6.7 Revisit and rerun

1. History supports text search and filters for date, directory, harness, model, and verdict.
2. A history entry restores outputs, evidence, telemetry, verdict, and worktree disposition.
3. Run Again opens a new draft with the prompt and requested configurations prefilled.
4. Before execution, JBench revalidates the current directory, Git state, and current `HEAD`.
5. If `HEAD` differs from the prior run, JBench shows the prior and current source commits; the new run uses the current commit only after the owner starts the revalidated draft.
6. A missing, dirty, or non-Git directory cannot start an editable rerun and must offer an eligible read-only path when supported.
7. Run Again creates a new run, fresh worktrees, and new observed-version records.
8. It does not resume old harness sessions or reuse old outputs.

## 7. Functional Requirements

### 7.1 Harness integrations

- Codex integration must use the local Codex app-server protocol.
- OpenCode integration must use the local OpenCode server/API contract.
- Adapters must retain native events before normalization.
- Each adapter must map only fields supported by evidence from that harness.
- JBench must retain the harness version and integration protocol version for each run.
- Adapter failures must remain isolated to their lanes.
- Each agent attempt must own a separate harness server process. No live attempts may share a cancellable server process.

### 7.2 Discovery

- JBench must discover Codex models and supported reasoning levels from Codex app-server.
- JBench must discover configured OpenCode models and native variants from OpenCode when available.
- Discovery runs at launch, on manual refresh, and after a discovery error.
- The last successful catalog remains available during refresh or temporary failure.
- A custom model field remains available when discovery fails.
- Custom values must be labeled `Custom — not verified` before execution.
- JBench must never silently substitute a default model or reasoning level.

### 7.3 Presets

- A named preset contains an ordered list of two to six agent configurations.
- Each configuration contains harness, model, reasoning value, timeout, and approval policy.
- A preset does not contain a prompt or working directory.

### 7.4 Run state

An agent run has one of these states:

- queued;
- starting;
- running;
- waiting for approval;
- completed;
- failed;
- cancelled;
- timed out;
- interrupted.

The parent run derives its state from its agent runs and may be partially complete.

### 7.5 Approval behavior

- Approval actions are scoped to one agent lane.
- JBench must not expose a global Approve All action.
- The UI must show the command, target path, proposed file change, or permission category supplied by the harness.
- Approval mapping must be capability-aware. Unsupported semantics must not be simulated silently.

### 7.6 Cancellation and timeouts

- The default per-agent timeout is 30 minutes.
- The owner may change the timeout or select No Timeout before starting.
- Cancellation first uses the harness protocol.
- If the run does not stop within five seconds, JBench terminates only the process tree it started and recorded.
- JBench must never terminate unrelated Codex or OpenCode sessions.
- Retry creates a new agent attempt linked to the original agent run.
- Every editable attempt, including a retry, creates a separate worktree from the run's recorded source commit.
- Cancellation fallback must not terminate a process used by another attempt.

### 7.7 Output and evidence

- The primary response renders as Markdown with selectable text and copy controls.
- Raw events remain available without replacing the readable response.
- Requested and observed model and reasoning fields are stored independently.
- Unknown observed fields display `Unavailable`.
- Metrics must record provenance: harness-reported, locally measured, or unavailable.
- Locally measured elapsed time is allowed and must be labeled as such.
- Estimated cost must not be presented as observed cost.

### 7.8 Local history

- History remains until manually deleted.
- Individual deletion and Delete All History require confirmation.
- Deletion must identify affected raw evidence, patches, and JBench-owned worktrees.
- A retained worktree must receive an explicit keep-or-discard decision before destructive cleanup.
- A kept worktree is transferred out of JBench ownership and is never removed by later history deletion.
- JBench retains only the transfer audit record after ownership changes.

### 7.9 Export

- Markdown export contains the prompt, requested configurations, observed settings, final responses, metrics with provenance, verdict, and notes.
- JSON export creates a self-contained bundle with a manifest, normalized JSON, copied raw-event files, checksums, and applicable patches.
- Bundle paths must be relative so the export remains valid after it is moved or source history is deleted.
- Patch export includes only the selected JBench-owned worktree diff.
- Export must warn that prompts, tool output, and raw events may contain sensitive data.

### 7.10 Background behavior

- Closing the main window does not stop an active run.
- A menu-bar status item shows active, waiting-approval, and completed states.
- When enabled, notifications fire for waiting approvals and full-run completion.
- JBench requests notification permission only when the owner enables notifications.
- Full app quit cancels active runs, waits for protocol shutdown, terminates remaining owned processes, and marks unfinished runs interrupted.

## 8. UX Requirements

### 8.1 Navigation

V1 has four destinations:

- New Run;
- History;
- Presets;
- Settings.

### 8.2 New Run

- Prompt composer at the top.
- Working-directory selector with repository-state validation.
- Read-only or editable mode selector when allowed.
- Ordered configuration controls for two to six agents.
- Run button names the number of selected agents.
- Validation explains missing harnesses, missing authentication, invalid custom values, dirty repositories, and unsupported editable mode.

### 8.3 Results

- Fixed-width lanes preserve readability.
- Two or three lanes fit without shrinking body text.
- Four to six lanes use horizontal scrolling.
- Headers remain aligned and show status clearly.
- Requested and Observed are visually distinct.
- Failure, timeout, and approval states remain readable without relying on color alone.
- Side by Side and Blind Review are the only V1 comparison modes.

### 8.4 History and presets

- Run titles use deterministic local truncation of the prompt and remain editable.
- History shows date, directory, agent count, completion state, and verdict.
- Presets can be created, renamed, reordered, edited, and deleted.

### 8.5 Accessibility

- Full keyboard access for run creation, lane navigation, approvals, verdicts, and cancellation.
- VoiceOver labels for all controls and status changes.
- Text remains selectable and supports system text scaling where practical.
- Color is never the only indicator of harness, status, approval, or failure.
- Reduced Motion disables nonessential transitions.

### 8.6 Empty, loading, and error states

- First launch directs the owner to harness diagnostics without requiring onboarding.
- Model refresh shows cached data and a visible refresh state.
- A missing harness provides its detected paths and the exact setting to fix.
- A protocol error provides a concise explanation and access to raw diagnostic evidence.
- Empty history and empty presets provide one clear next action.

## 9. Data and Domain Model

### 9.1 HarnessInstallation

- harness kind;
- executable path;
- detected version;
- authentication status;
- last diagnostic result;
- last successful discovery time.

### 9.2 ModelCatalogEntry

- harness kind;
- native model identifier;
- display name when supplied;
- native reasoning or variant values;
- discovery source;
- catalog timestamp;
- availability state.

### 9.3 Preset and PresetAgent

- preset name;
- ordered agent configurations;
- requested harness, model, reasoning, timeout, and approval policy.

### 9.4 Run

- stable UUID;
- editable title;
- exact prompt;
- selected-directory reference;
- repository state and source commit when applicable;
- execution mode;
- timestamps and aggregate state;
- verdict and note;
- raw-evidence directory;
- created and observed harness versions.

### 9.5 AgentRun and AgentAttempt

- stable UUID and parent run;
- display order and blind-review order;
- requested settings;
- observed settings with provenance;
- attempt number and state;
- local process identifiers owned by the attempt;
- dedicated harness-server ownership record;
- protocol session identifiers;
- timestamps, elapsed time, token fields, and cost fields;
- final response;
- error and cancellation details;
- raw-event file reference.

### 9.6 WorktreeRecord

- parent agent attempt;
- original repository path;
- source commit;
- exact JBench-owned worktree path;
- changed-file count;
- patch reference;
- keep, transfer, or discard state;
- transferred path when ownership changed;
- cleanup verification result.

### 9.7 Storage lifecycle

- Use a native local metadata store backed by SQLite.
- Store raw event streams and exported patches as files under JBench's Application Support directory.
- Do not place JBench history in an iCloud-synchronized container.
- Do not add custom application-level encryption in V1.
- Never store provider credentials in JBench data.

## 10. Permissions and Security

- JBench is an unsandboxed personal application in V1.
- Unsandboxed status is not permission to scan or modify arbitrary folders.
- The owner selects every working directory through the UI.
- Editable execution is restricted to clean Git repositories.
- Each editable agent receives a separate JBench-owned worktree.
- Read-only execution must use a verified harness restriction that blocks mutation.
- A harness without enforceable read-only capability cannot start a read-only run.
- JBench records every process it starts and every worktree it creates.
- Cleanup targets must be exact recorded paths and owned process identifiers.
- Broad recursive deletion, unresolved paths, and harness-wide process termination are prohibited.
- Credentials remain in Codex and OpenCode storage.
- JBench shows authentication status but never displays secret values.
- Raw evidence is local and may contain sensitive prompts, paths, commands, or tool output.
- Exports require an explicit owner action and a sensitive-data warning.
- JBench sends no product analytics or crash reports.

## 11. Technical Requirements

### 11.1 Platform

- Native SwiftUI macOS application.
- Deployment target: macOS 26.
- Current development baseline: Xcode 26.6 and Swift 6.3.3.
- No App Sandbox entitlement in V1.

### 11.2 Architecture

- Separate UI, domain, persistence, process-ownership, worktree, and harness-adapter boundaries.
- Codex adapter communicates with the owned local app-server process through its typed protocol.
- OpenCode adapter communicates with the owned local server through its typed HTTP/event protocol.
- Each attempt owns its own app-server or OpenCode server process and never shares that process with another live attempt.
- Adapter normalization is versioned and lossless with respect to retained raw events.
- UI state must not depend directly on vendor event shapes.
- Protocol fixtures and fake adapters must support provider-free automated tests.

### 11.3 Executable discovery

- Search common user and Homebrew locations.
- Allow explicit executable overrides.
- Launch the exact resolved executable directly rather than through an interactive login shell.
- Record the resolved path and version for each run.
- Never print environment secrets in diagnostics.

### 11.4 Persistence

- Use a native SQLite-backed metadata store with schema migration support.
- Write raw events incrementally so a crash does not lose the entire stream.
- Use atomic file replacement for finalized reports and patches.
- Batch UI-facing persistence updates so six event streams do not block rendering.

### 11.5 Process ownership

- Use a unique ownership record for each server, session, and child process.
- Maintain one server-process ownership tree per agent attempt.
- Never reuse a recorded process identifier without validating the process identity.
- Graceful cancellation precedes process termination.
- On relaunch after abnormal termination, mark unfinished attempts interrupted and report possible leftovers. Do not terminate unverified processes.
- Retain exact cleanup results in diagnostic evidence.

### 11.6 Performance and reliability

- The UI remains interactive while six agents stream events.
- One adapter failure does not stop other adapters.
- History search does not parse raw-event files during ordinary queries.
- Model discovery failures do not erase the last successful catalog.
- Worktree creation must fail safely before any agent starts if isolation cannot be guaranteed.

### 11.7 Delivery

- Produce a locally runnable application, source code, and automated tests.
- No signing, notarization, package publication, or public release is required.
- Live or paid Codex and OpenCode smoke runs require separate explicit approval.

## 12. Acceptance Criteria

### Harness readiness

- Given an installed harness, when Settings opens, then JBench shows its exact resolved path and version.
- Given missing authentication, when diagnostics run, then JBench shows a login command without collecting credentials.
- Given a discovery failure after a prior success, when New Run opens, then cached models remain visible and are marked with their catalog timestamp.
- Given no usable catalog, when configuring an agent, then the owner may enter a clearly marked custom model value.

### Run setup

- Given fewer than two or more than six configurations, when the owner tries to run, then JBench blocks execution with a clear validation message.
- Given a dirty or non-Git directory, when editable mode is requested, then JBench blocks editable mode and offers read-only mode.
- Given a read-only run, when an agent attempts a filesystem write, then the harness restriction blocks it and the selected directory remains unchanged.
- Given a harness version without verified read-only enforcement, when read-only mode is requested, then JBench blocks the run and explains the unsupported capability.
- Given a clean Git repository and an editable run, when execution starts, then every agent receives a separate worktree from the same source commit.
- Given a visible prompt, when agents start, then each harness receives that exact prompt without a hidden wrapper.

### Execution

- Given several configured agents, when a run starts, then agents execute in parallel and one failed lane does not cancel the others.
- Given a streaming agent, when events arrive, then the lane updates its readable response and retains raw events.
- Given an approval request, when it appears, then it identifies one agent and cannot approve another lane.
- Given a cancelled agent, when protocol cancellation does not finish in five seconds, then JBench terminates only verified processes owned by that attempt.
- Given two active lanes using the same harness, when one lane times out and requires forced termination, then the other lane continues successfully.
- Given a timed-out or failed lane, when Retry is selected, then only that lane receives a new attempt tied to the original run snapshot.
- Given an editable retry, when the new attempt starts, then it receives a fresh worktree with no partial changes from the prior attempt.

### Evidence and comparison

- Given requested and observed settings, when results render, then both appear separately with provenance.
- Given an unavailable observed metric, when results render, then it says `Unavailable` rather than showing an estimate.
- Given Blind Review, when it starts, then all identity and telemetry are hidden and lane order is randomized.
- Given a verdict, when identities are revealed, then the selected response maps to the correct original agent.
- Given four to six lanes, when results render, then body text remains readable and horizontal scrolling is available.

### Worktrees

- Given file changes in any terminal editable attempt, when the attempt stops, then JBench shows changed-file count and an expandable diff.
- Given Export Patch, when export completes, then the patch contains changes from only the selected worktree.
- Given Discard, when cleanup completes, then only the recorded JBench-owned worktree is removed and cleanup is verified.
- Given a retained worktree, when history deletion is requested, then JBench requires an explicit cleanup decision.
- Given Keep, when transfer completes, then the worktree moves to the selected path, JBench ends cleanup ownership, and later history deletion does not remove it.

### History and lifecycle

- Given a completed run, when the app relaunches, then prompt, outputs, evidence, metrics, verdict, and worktree state remain available.
- Given a history query, when filters are applied, then matching runs can be found without reading raw event files.
- Given Run Again, when selected, then JBench opens a prefilled draft and revalidates the current directory, repository state, and source commit before execution.
- Given an editable prior run whose directory is now missing, dirty, or non-Git, when Run Again is selected, then JBench blocks editable execution and explains the current state.
- Given an editable prior run whose `HEAD` changed, when Run Again is selected, then JBench shows both commits and the new run records the current commit after confirmation.
- Given a valid revalidated draft, when execution starts, then a new run and new observed-version records are created.
- Given a closed main window, when agents are active, then they continue and menu-bar status remains available.
- Given full app quit, when shutdown completes, then active runs are interrupted and only JBench-owned processes are stopped.
- Given disabled notifications, when a run changes state, then JBench does not request notification permission or send a notification.

### Export and deletion

- Given Markdown export, when complete, then the report contains prompt, configurations, outputs, provenance-labeled metrics, verdict, and notes.
- Given JSON export, when complete, then the bundle contains normalized records, copied raw events, checksums, and applicable patches using relative paths.
- Given a moved evidence bundle whose source history was deleted, when its manifest is verified, then every included checksum and relative reference still resolves.
- Given Delete All History, when confirmed, then JBench reports which records, files, patches, and owned worktrees will be affected before deletion.

## 13. Analytics and Success Metrics

JBench sends no product analytics. V1 success is established through local acceptance evidence:

- one prompt completes across at least one Codex and one OpenCode configuration;
- requested and observed settings remain distinct;
- approvals, cancellation, timeout, partial failure, and retry work independently per lane;
- blind verdict reveal maps identities correctly;
- saved history survives relaunch;
- exports are complete and readable;
- worktree and process cleanup leave no unreported owned leftovers;
- all provider-free automated tests pass.

Operational timing, token, and cost fields describe individual runs. They are not product analytics or scientific benchmark results.

## 14. Risks and Open Questions

### Confirmed risks

- Codex and OpenCode expose different event, approval, discovery, and telemetry contracts.
- OpenCode may not provide one authoritative observed reasoning field.
- Harness upgrades may change protocol fields or capability behavior.
- Editable parallel runs can consume significant disk space.
- Git worktrees do not include dirty or untracked changes, so editable V1 requires a clean repository.
- GUI-launched applications have a different environment from an interactive shell.
- Raw evidence may contain sensitive project data.
- Parallel timing is affected by shared CPU, memory, disk, network, and provider load.
- A read-only label does not protect files unless the harness enforces mutation restrictions.

### Required mitigations

- Preserve raw events and version the normalization layer.
- Label unsupported observed fields `Unavailable`.
- Cache discovery results without silently substituting values.
- Record executable paths, harness versions, source commits, and metric provenance.
- Require explicit worktree disposition and report disk use.
- Allow executable overrides and show diagnostics.
- Warn before evidence export.
- Describe timings as operational telemetry only.
- Test a real write attempt against every supported read-only adapter contract before enabling that mode.
- Use a separate owned harness server and process tree for every attempt.

### Open questions

No product-scope question remains open for V1. Low-level implementation choices may change if protocol fixtures prove that a confirmed requirement cannot be supported safely. Any such change requires a documented scope decision rather than a silent fallback.

## 15. Implementation Breakdown

### Slice 1: App shell and harness readiness

- Goal: The owner can open JBench and understand whether Codex and OpenCode are ready.
- User-visible or behaviorally complete outcome: New Run, History, Presets, and Settings exist; Settings shows detected paths, versions, authentication state, and refresh status using real diagnostics or fixtures.
- Backend/data work: Application shell, adapter contracts, executable resolution, diagnostic models, local settings persistence, fake adapters.
- Frontend/UI work: Navigation, diagnostics rows, path override, empty and error states.
- Tests: Path resolution, redacted diagnostics, state rendering, missing executable, missing authentication.
- Dependencies: None.
- Acceptance criteria: Installed harnesses show exact path and version; missing readiness produces one clear next action.

### Slice 2: Discover and save agent configurations

- Goal: The owner can create a valid two-to-six-agent configuration without running a model.
- User-visible or behaviorally complete outcome: Model and reasoning discovery, cached catalogs, custom fallback, ordered configuration rows, named presets.
- Backend/data work: Catalog store, refresh lifecycle, preset models, validation rules.
- Frontend/UI work: Agent picker, native values, custom warning, reorder controls, preset management.
- Tests: Catalog caching, discovery failure, custom values, count limits, preset persistence.
- Dependencies: Slice 1 adapter contracts and settings.
- Acceptance criteria: A valid preset survives relaunch; discovery failure keeps the last successful catalog.

### Slice 3: Provider-free read-only comparison

- Goal: Prove the complete run and comparison workflow with deterministic fake harnesses.
- User-visible or behaviorally complete outcome: Select a directory, enter a prompt, run two fake agents in parallel, stream Markdown, cancel, time out, retry, and compare results.
- Backend/data work: Run state machine, event normalization, raw-event writer, per-attempt server ownership, read-only capability enforcement, timeout and cancellation coordinator.
- Frontend/UI work: Prompt composer, directory selector, lane layout, activity disclosure, status, cancellation, retry.
- Tests: Parallel state transitions, partial failure, blocked write attempts, raw evidence, timeout, cancellation fallback with owned fake processes, and same-harness lane isolation.
- Dependencies: Slices 1 and 2.
- Acceptance criteria: Two fake agents complete independently; one failure does not remove the other result; a read-only write attempt cannot change the selected fixture directory.

### Slice 4: Real Codex read-only lane

- Goal: Replace one fake lane with a real Codex app-server session.
- User-visible or behaviorally complete outcome: Codex discovery, streaming, requested-versus-observed settings, approvals, cancellation, and raw evidence work through the real protocol contract.
- Backend/data work: Codex app-server client, typed messages, capability mapping, fixture capture, version guards.
- Frontend/UI work: Codex-specific readiness and unsupported-field explanations within shared UI.
- Tests: Recorded provider-free protocol fixtures, malformed messages, disconnects, approval decisions, graceful interruption.
- Dependencies: Slice 3 state machine.
- Acceptance criteria: Fixture-backed Codex sessions pass end to end. A live smoke remains approval-gated.

### Slice 5: Real OpenCode read-only lane

- Goal: Add OpenCode with behavior parallel to the Codex lane where the contract allows it.
- User-visible or behaviorally complete outcome: One run can contain Codex and OpenCode lanes with native model values, independent streaming, cancellation, approvals, and honest unavailable fields.
- Backend/data work: Owned OpenCode server lifecycle, HTTP/event client, capability mapping, fixture capture, version guards.
- Frontend/UI work: OpenCode-specific readiness and limitation explanations within shared UI.
- Tests: Recorded provider-free protocol fixtures, server startup failure, stream disconnect, permission response, abort.
- Dependencies: Slice 3; may proceed in parallel with Slice 4 after shared contracts stabilize.
- Acceptance criteria: Fixture-backed mixed-harness runs pass end to end. A live smoke remains approval-gated.

### Slice 6: Isolated editable comparisons

- Goal: Let full agents edit safely without sharing a working directory.
- User-visible or behaviorally complete outcome: Clean-repository validation, fresh per-attempt worktrees, changed-file count for every terminal state, expandable diff, Open, Export Patch, Keep transfer, and Discard.
- Backend/data work: Git state inspection, worktree manager, exact path ownership, diff and patch generation, cleanup verification.
- Frontend/UI work: Execution-mode selector, dirty/non-Git explanations, change summaries, worktree disposition controls.
- Tests: Clean and dirty repositories, non-Git folders, multiple worktrees from one commit, fresh retry worktrees, edits followed by every terminal state, ownership transfer, untracked changes, failed creation, and safe exact cleanup.
- Dependencies: Slice 3 run lifecycle; adapter slices can use fake editable agents initially.
- Acceptance criteria: Concurrent attempts never share a worktree; retry contains no prior partial edits; Keep transfers ownership; Discard removes only the selected owned worktree.

### Slice 7: Blind review, verdicts, history, and export

- Goal: Complete the decision and audit workflow.
- User-visible or behaviorally complete outcome: Blind Review, optional winner and note, reveal, searchable history, Run Again, Markdown report, JSON evidence bundle.
- Backend/data work: Blind order, verdict records, search indexes, self-contained evidence-bundle builder, deletion impact calculation.
- Frontend/UI work: Blind labels, reveal flow, verdict controls, history filters, export and deletion confirmation.
- Tests: Identity concealment, reveal mapping, filter combinations, relaunch persistence, rerun revalidation for missing/dirty/non-Git/changed-HEAD directories, portable bundle verification after move and source deletion, sensitive-data warning.
- Dependencies: Slice 3 persistence and evidence; can begin before real adapters finish.
- Acceptance criteria: A blind verdict maps to the correct agent after reveal and remains correct after relaunch.

### Slice 8: Background operation and release hardening

- Goal: Make long runs and shutdown behavior dependable on this Mac.
- User-visible or behaviorally complete outcome: Menu-bar status, opt-in notifications, window-close continuation, safe full-quit cancellation, interruption recovery.
- Backend/data work: Background lifecycle, notification coordination, process identity validation, startup reconciliation, schema migration checks.
- Frontend/UI work: Menu-bar states, permission setting, quit progress, leftover diagnostics.
- Tests: Window close, full quit, approval notification, disabled notifications, abnormal termination recovery, no unrelated process termination.
- Dependencies: Slices 3–7.
- Acceptance criteria: Quit stops and verifies only owned processes; any leftover is reported exactly.

## 16. Recommended Implementation Order

1. Slice 1 establishes the native shell, adapter boundary, and diagnostics.
2. Slice 2 makes configuration concrete without spending model usage.
3. Slice 3 proves the full workflow with provider-free fixtures.
4. Slices 4 and 5 add one real harness contract at a time.
5. Slice 6 adds editable isolation only after cancellation and ownership are proven.
6. Slice 7 completes evaluation, history, and export.
7. Slice 8 hardens lifecycle behavior and produces local acceptance evidence.

This order keeps paid or live verification outside the normal test loop and postpones destructive risk until process ownership is tested.

## 17. Parallelization Opportunities

- After Slice 1 defines adapter contracts, Codex fixture work and OpenCode fixture work can proceed in parallel with separate file ownership.
- After Slice 3 defines run persistence, worktree management and blind-review/history work can proceed in parallel because their file scopes and behaviors are distinct.
- Accessibility review and fixture expansion can proceed alongside later slices after each user-visible flow stabilizes.
- Release hardening must wait for both real adapters and worktree lifecycle behavior.
- Final integration, process-cleanup verification, and any live smoke run must remain coordinated and sequential.
