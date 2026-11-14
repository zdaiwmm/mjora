# Continued backup runtime validation

The physical device reported a failed continued task while its system activity still showed the indexing title. The app displayed a generic cancellation. This title also covers hashing and server verification; it does not identify a PhotoKit indexing error. The earlier recorded network timeout predates that installation and is not evidence for this attempt.

The change fixes independently reproduced progress defects:

- Measured preparation/upload changes below one percent were discarded. Resource presentation now samples actual changes at most twice per second, with immediate stage/final updates.
- Gallery redraw quantization no longer quantizes the system's upload progress. High-resolution units preserve small measured changes in large libraries.
- Server verification now advances through its own portion of progress. Completed measurements are removed as workers finish so per-callback work stays bounded to active uploads.
- Promoting an active run immediately reports its current progress. Retrying a terminal run starts a fresh progress range instead of inheriting 100%.

A protected task diagnostic file distinguishes submission, launch, expiration, owner invalidation and completion. It contains typed phase/progress, elapsed times, numeric error categories/codes and power/thermal/protected-data conditions. It contains no account/photo identifiers, filenames, addresses, tokens, error descriptions or userInfo. It is limited to 64 events and 32 KB, with progress persistence at most every five seconds and immediate terminal persistence. A late response from an expired request cannot end a newer attempt's diagnostic record.

Regression evidence includes observed failures before the percentage-filter, precision, terminal-retry and stale-submission fixes. Lifecycle tests exercise the coordinator through the same task operations used by the system adapter, including expiration before pausing and rejection of late worker completion.

The final simulator run on 2026-11-14 completed with 209 tests: 208 passed, one physical PhotoKit gate skipped, zero failures. This includes both English and Chinese UI flows and the dedicated local Immich integration fixture. The optional simulator diagnostic collector emitted its existing `simctl` lookup warning; the test command returned exit status zero. Independent review found and resolved stale diagnostic response mixing and completed-upload measurement retention. These results establish source-level regressions and simulator behavior, not physical background acceptance.

The physical retest of installed app revision `356add0d0291922501d3528af971cc34f9528205` recorded a background transition followed by continuing server verification and upload progress for more than three minutes, with no intervening foreground or expiration event in that observation window. Matching server TCP counters showed substantial incoming bytes on the verified LAN HTTPS connection; newly received components also had persisted verification proofs. The user separately confirmed that the background progress continued changing. These checks read task/index metadata and connection counters, without inspecting photo content or sending test photos to the production server.

This demonstrates background indexing and real LAN uploads during the observed run. It does not establish the original system expiration reason, completion of the entire library, or unlimited future background time. No timer fabricates progress and no upload redirect restriction is relaxed.
