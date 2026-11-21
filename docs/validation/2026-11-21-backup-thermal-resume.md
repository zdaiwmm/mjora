# Backup progress and thermal resume validation

Source baseline: `445b7f49c683f3d7379d338e3c530e45d7959536`.

The backup status now distinguishes current revisions with a known server copy
from revisions carrying fresh proof. Known server copies complete the backup
work itself, while cleanup still requires the exact-account, exact-revision
proof. Proofs update live status one item at a time instead of waiting for the
whole library check.

At serious thermal pressure, backup continues with one preparation or upload
worker so ordinary device warmth does not stop the queue. A critical thermal
event pauses new work and starts a three-minute cooldown. If iOS reports only
fair heat when that timeout ends, restart is delayed by another minute.
Metadata verification concurrency is four instead of eight. A critical thermal
hold keeps the index and unstarted queue for the next run and is not reported
as a backup failure.

## Verification

- Focused backup and policy selection: 18 tests, 0 failures.
- Backup-related selection: 80 tests, 1 Photos-permission test skipped,
  0 failures.
- `git diff --check`: clean.

The complete local simulator run was attempted but is not claimed as passing.
It reached unrelated existing `Phase4CacheRecoveryTests` failures and a photo
permission UI flow that stopped producing results. The backup-focused selection
above includes receipt replay, remote deletion protection, Live Photo pairing,
upload scheduling, thermal policy, recovery intent, and progress presentation.

Physical-device thermal cadence and completion of the installed app's large
backlog remain to be checked after installation.
