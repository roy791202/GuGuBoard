# Review-driven test changes (2026-11-07)

Only test infrastructure, drivers, control targets and evidence verification are changed. Product files, Skeleton.ps1, original BDD and board completion state are protected by review-fix-protected.json. Previous source snapshots are in revisions/pre-review-fixes; older evidence is historical and must not be validated against changed source hashes.

## Invalid RED corrections

SCH-01-1 and SCH-02-1 now assert the specified absence of events/processes without forcing Clock/Store calls or inventing a required outcome. A safe no-op can legitimately PASS these negative scenarios. Separate due-time positive checks and time-ignore-boundary mutants prevent this from being misreported as complete scheduling behavior.

## Strengthening

- Individual invalid time/interval inputs and valid boundaries; replayed reconciliation; transaction payload, immutable fault history and recovery effects.
- HTTP observes actual supplied destination, headers, bytes and declared timeout. A scaled physical timeout keeps fixture controls fast; this is not a real ten-second production timing proof. Redirects are disabled. Exact allowlist comes from trusted fixture state, not request data.
- Board fake models its API contract: missing/blocked/future tickets, owner/generation fencing and persisted renewals. Concurrency uses independent command processes and a barrier at the claim seam, with per-worker trusted principal context.
- Real parent/descendant processes have creation-time markers. Stop is run/ticket targeted, reconstruction can inspect persisted identities, and workspace quarantine creates a real isolated marker.
- Completion tests separately omit tests/evidence, use individually valid conflicting payloads, and exercise an HTTP response loss after a new durable commit. Intermediate journal, release, replay receipt and history assertions are explicit.
- Trusted run/principal/PR/evidence records are loaded from review-fixtures.json; governance does not pass client gate booleans. Missing review/merge/authority and tree mismatch are tested separately.
- UI captures complete response text and HTML, checks exact reasons/field associations, forges direct API requests despite disabled controls, and actually clicks Pause. Control screenshots are isolated from baseline screenshots.
- Integration follows real upstream outbox and captured wire bytes into the next stage. If no upstream output exists, the driver records a blocked stage instead of manufacturing input. Dependent FIX-3 start is asserted after independent gates.

## Controls and evidence interpretation

fixture_contract_tests.py is a separate fixture-quality suite, never product acceptance. mutation_controls.py contains narrowly scripted positive targets and deliberately wrong targets; none is wired as the default application or shipped product. Controls do not receive expected assertions or scenario IDs. A mutation only counts as killed if it causes a NEW failed assertion relative to its positive control or baseline, not merely because the empty subject already fails. Positive scripts are fixture-specific oracle controls, not a general reference implementation.

Sixteen mutation sites cover time guards, reject-all, invalid-input mutation, wrong lease owner, start without claim, accepting invalid signatures, misleading errors with mutation, forged identity, approval bypass, viewer control, hidden secret, Pause no-op and incorrect gate reason. This does not claim exhaustive mutation coverage of all application rules.

run_drivers.py uses review-case-inventory.json only for discovery and BDD lineage. Actual fixture data is review-fixtures.json plus explicit arrangement in the driver. Old planning cases.json request/expected and task fixtures remain historical planning artifacts, not alternate runtime input oracles.

qualify_evidence.py now delegates to qualify_review_fixes.py. It checks uniqueness, observation consistency, source/BDD hashes, immutable fault history, mutation kills and positive controls. It does not declare all failures VALID_RED, set Done, or approve implementation. Unreached fault paths remain unqualified for failure handling. Independent re-review is mandatory.

## Commands

    python -B docs/dispatch-plan/red/fixture_contract_tests.py
    pwsh -NoProfile -File docs/dispatch-plan/red/Run-Red.ps1
    python -B docs/dispatch-plan/red/qualify_review_fixes.py

Default execution includes all 48 cases and mutation controls. No tests are skipped to make the gate pass. Exit 1 means application assertions failed; exit 2 also covers a surviving mutant/control or fixture problem. Read the report rather than treating the exit code as acceptance.

Remaining product gates are unchanged: production envelope/file scope, frozen product interfaces, independently accepted behavior, real product UI/adapters/CLI/runtime, and authorized approval. Test-only models or successful controls do not satisfy those gates.
