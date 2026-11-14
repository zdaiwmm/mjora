# Background backup failure investigation

Goal: diagnose the physical continued-task failure and report measured work without coarse percentage stalls. Preserve all upload destination restrictions, account ownership and saved backup intent.

1. Add regression tests for small measured preparation/upload changes and large-library system progress precision. Run them against the current implementation and confirm failure.
2. Keep measured upload fractions separate from coarse gallery redraws. Rate-limit resource presentation by time rather than percentage; allocate measured checking progress between preparation and upload. Snapshot the workload when its system task begins.
3. Add a bounded, protected task lifecycle diagnostic file with typed fields only. Verify coalescing, terminal flush, attempt isolation and persistence bounds. Connect lifecycle and phase/error boundaries without logging filenames, identifiers, URLs or descriptions.
4. Run the relevant tests, full suite and independent review. Commit/push only the user's app repository. Update the pinned renewal source and install in place.
5. Reproduce on the physical phone. Compare lifecycle records, verified backup counts and LAN socket byte counters. Do not report physical background success until observed. Then finish the separately requested public server repository.

Known: the screenshot's indexing title spans scanning/hashing/checking; the existing resume marker implicates expiration only if it was cleared for this attempt. The earlier upload timeout predates the current installation. The exact system expiration reason is not exposed by Apple.

Current task branch: mjora-public, baseline bc5c61a; previous full suite 192 passed, one physical skip. Continue in this existing authorized workspace.
