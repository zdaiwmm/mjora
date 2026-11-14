# Publication snapshot

This repository publishes the current source snapshot of the locally validated Imora-based implementation as **mjora**. Original Imora author and GPL v3 licensing are retained in README.md and LICENSE.md.

Private planning/security-audit documents and their historical Git commits are intentionally excluded because they contain deployment-specific addresses. The original local branch is preserved; only this publication snapshot and later public commits are pushed.

No runtime application source, shared runtime source, resource catalog, dependency lock or project configuration changed during publication. Publication edits are limited to README/ignore rules, replacing deployment-specific addresses in two synthetic unit tests with example LAN addresses, and making test tool/Docker socket paths portable. Runtime app names and original notices remain unchanged.

The existing validation report and build manifest record the earlier local build (source revision a06083e93700699c76177ce2e29a3753c7dc454d), not a newly signed release or an independently tested device build. The public snapshot preserves the exact runtime source of that build. Raw local audit history is not publicly available. Future builds should generate their own manifests.

Background uploads currently run only while iOS grants execution time. The app retains protected recovery state; true system-daemon background continuation is not enabled in this snapshot. Physical-device and signed extension gates remain documented in docs/validation/2026-11-14-implementation-validation.md.
