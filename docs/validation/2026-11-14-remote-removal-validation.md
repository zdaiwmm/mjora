# Remote removal and viewer regression validation

## Reproduced source defects

- A foreground/reconnect resync compared monthly counts and retained the old asset list when a deletion was balanced by an upload. A loopback regression retained `synthetic-deleted` instead of `synthetic-replacement` before the fix. Foreground and websocket reconnect now revalidate loaded bucket membership; routine event bursts retain their cheaper count-based refresh.
- A late persisted upload receipt could restore an association cleared by a newer server deletion. Missing known server components also entered the upload queue. The index now retains an account-bound removal hold independently of temporary verification state. Bulk missing responses, observed trash, permanent deletion, restart, local edits and late receipts cannot silently recreate removed content.
- Upload permission is checked against the current account generation, resources and removal hold before preparation and immediately before multipart transfer or each chunk handoff. Rejection removes only the exported request-body file. These paths never call PhotoKit deletion.
- Complete existing server candidates can still be verified after an external restore or explicit recreation. Only fresh full proof clears the hold; this verification disables Live Photo link repair. Newer removal evidence invalidates older proof revisions, including evidence observed during concurrent checks.

Regression assertions were observed failing before their fixes, including same-count membership, late receipt resurrection, preservation across local motion edits, external restoration, trash followed by network failure, and delayed proof after newer trash metadata. All fixtures are synthetic.

A real loopback URLSession test also observed the multipart POST reaching its listener before the final handoff gate was implemented. After the fix, a removal at that boundary produces zero photo POSTs, discards the prepared temporary body and retains the local index entry. Another regression preserves a newly verified externally recreated ID when an old receipt for the deleted ID arrives later.

## Viewer investigation

The reported physical-device interaction failure has not been reproduced. No speculative production viewer change is included. UIKit lifecycle tests open, close and open a different asset, including dismissal during the opening transition. Both language UI flows additionally exercise ordinary close, zoom followed by revealing the toolbar and close, downward dismissal, then further asset taps. They assert the old close button disappears and the next tile is hittable, rather than accepting the still-mounted background grid as evidence of dismissal.

An initial zoom test tried to press the close button while zoom had intentionally hidden the toolbar. Its failure was a test interaction error; revealing the toolbar exercises the supported return path. Context-menu-specific and physical-device behavior remain separate from these results.

## Physical limits and next observation

The paired physical phone was unavailable during this investigation, so neither this source change nor a new diagnostic build was installed. The prepared earlier diagnostic package and valid signing material were retained. Xcode destination discovery succeeded without a credential error, but it does not establish that provisioning/automatic renewal is repaired.

The background failure remains unresolved. Earlier real LAN transmission and verified receipts do not establish sustained execution; a later attempt stopped recording progress after approximately 345 seconds without a recorded terminal event. Existing resource reports do not establish a termination cause. A further detached physical observation must continuously retain app PID, UTC sample times, task history and resource snapshots for longer than that interval, and inspect the terminal outcome. No new production server deployment, trust-policy relaxation, device-photo deletion or automatic recreation of removed server content was performed.

## Final checks

The final complete simulator run on 2026-11-14 completed **223 tests: 222 passed, one skipped, zero failures**. The skip is `TransferIsolationTests.testDataProtectionMetadataOnPhysicalDevice`, which requires physical iOS Data Protection metadata. The real PhotoKit gate test ran with full access on the dedicated synthetic simulator. Both English and Chinese UI flows passed. The existing optional diagnostic export emitted a `simctl` lookup warning; the test command exited zero.

Localization validation passed for 1,659 catalog entries. Diff formatting and changed-file private-value scans passed. Independent source review found no remaining blocker. These results validate the source changes and exercised simulator paths; they do not establish the still-unavailable physical phone's behavior.
