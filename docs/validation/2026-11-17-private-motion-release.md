# Private integrated motion release

The release retains memory functionality and the reliable-background-backup changes already published at `287ed7c`. Relative to that public baseline, the public motion branch contains only motion and acceptance changes.

- Final integrated implementation tested: `bd4853b` (App tree `e4903877670fd8d687ad4c221cc1c885df608a1c`). Subsequent changes only update validation documents. App, Shared, extensions and test source match the public motion branch.
- Final complete native suite: 667 tests, 3 expected environment/fixture skips, 0 failures. Evidence: `/Users/achilles/mjora/execution/private/photos-motion-20261117/unit-complete-release.xcresult`.
- Five UI acceptance flows passed in the documented batches. English/zh-Hans coverage, placeholders and newlines pass for all 1,919 entries.
- Shared timing parameters are captured from the installed iOS 27.2 Photos simulator. The connected deployment device reports iOS 26.6.1; physical-device frame timing is not measured by the simulator tests.
- Private package preparation verifies each device's own identity, enrollment, signature and immutable source fingerprint through the existing family update functions. Version allocation and manifest publication share the existing signing lock to avoid racing another authorized release.
- Before preparing a package, the publisher requires its source to descend from every currently published source revision, as well as local main. This release includes both the previous motion candidate `c497307` and the separately published background fix `287ed7c`.
- The first motion candidate, 1.0.14 (19), omitted the concurrently released background fix. It was withdrawn before this task attempted installation. Its signed bundles were withheld to stop update offers while preserving monotonic channel history. The next release supersedes it after the complete integrated regression.
- Deployment receipts stay outside the repository in `/Users/achilles/mjora/execution/private/photos-motion-20261117`.
