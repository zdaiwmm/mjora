# Private integrated motion release

The private release retains the locally integrated memory functionality at `9fca160`, which has separate publication authorization. The public motion branch contains only its scoped motion and acceptance changes.

- Integrated implementation tested: `1957508f4a44b32cada69b567dfa63e810d560e7`.
- Full integrated native suite: 657 tests, 3 expected environment/fixture skips, 0 failures. Evidence: `/Users/achilles/mjora/execution/private/photos-motion-20261117/unit-integrated.xcresult`.
- Public motion implementation: 644 tests, 2 expected environment skips, 0 failures; five UI acceptance flows passed in the documented batches.
- Shared timing parameters are captured from the installed iOS 27.2 Photos simulator. The connected deployment device reports iOS 26.6.1; physical-device frame timing is not measured by the simulator tests.
- After the integrated run, only validation documents changed. No app implementation changed.
- Private package preparation verifies each device's own identity, enrollment, signature and immutable source fingerprint through the existing family update functions. Version allocation and manifest publication share the existing signing lock to avoid racing another authorized release.
- Deployment receipts stay outside the repository in `/Users/achilles/mjora/execution/private/photos-motion-20261117`.
