## Summary

<!--
What does this PR do and why? One to three sentences.
-->

Closes #

<!--
GitHub auto-closes an issue only on a `Closes #N` reference in the body — the
`ISSUE-N` prefix in the title does nothing on its own. Delete this line if the
PR closes no issue.
-->

## Changes

<!--
Bullet list of what changed. Focus on the "what" — the summary covers the "why".
-->

-

## Test plan

- [ ] `swift test` passes locally
- [ ] `swiftformat --lint .` and `swiftlint` pass without violations
- [ ] Affected commands verified with a real pack (e.g. `mcs sync`, `mcs doctor`)

<details>
<summary>Checklist for engine changes</summary>

Only check items that apply to this PR. Delete irrelevant ones.

- [ ] `.shellCommand` components have `supplementaryDoctorChecks` defined (`deriveDoctorCheck()` returns `nil` for shell actions)
- [ ] Any `fix()` implementation does cleanup/migration only — never installs or registers resources
- [ ] State migrations are guarded by `isNeeded()` to stay idempotent with `mcs sync`
- [ ] Integration tests updated for new features (`LifecycleIntegrationTests` or `DoctorRunnerIntegrationTests`)
- [ ] New file write/copy/delete paths use `PathContainment.safePath()` and handle the `nil` (escape) case
- [ ] Docs updated if behavior changed (`CLAUDE.md`, `docs/`, `techpack.yaml` schema in `ExternalPackManifest.swift`)

</details>
