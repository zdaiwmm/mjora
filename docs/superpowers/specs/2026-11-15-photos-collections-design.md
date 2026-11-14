# Native Photos and Collections

Approved by the user on 2026-11-15 through the interactive prototype at `/Users/achilles/.codex/visualizations/2026/11/14/01a1dabc-5102-7590-ac12-5e34a18f3c37/ios-photos-interaction.html`.

## Intent

Make browsing and organizing photos follow the system Photos app, while retaining all existing client capabilities. The user explicitly prefers native iOS components and authorizes implementation, simulator verification, remote integration and deployment.

## Approved behavior

- The compact bottom navigation contains Photos, Albums, and the separate system search tab. The old Library destinations move into Albums. Preserve the iPad sidebar destinations.
- Photos is an edge-to-edge timeline, without a cloud/device segmented row, backup banner or memory carousel. The leading title menu switches between cloud and device and provides account, backup and notifications access.
- Use native navigation toolbar items for sort/filter and Select. During selection, group filter and More, followed by a separate close control. Preserve the existing independent share / selected-items / trash controls and every permission/deletion policy.
- Sorting, filtering and grid density belong in native menus. Use the existing paged search for cloud media filters rather than filtering only loaded timeline pages. Local filters operate over the accessible local library.
- Add genuine Years / Months aggregation based on the full bucket index, including unloaded months, and return to the chosen month in the timeline. Date browsing must not discard unloaded photos or show sample periods.
- Albums becomes the Collections home: memories, pinned collections, albums, people/pets, places, media types, cleanup, archive/locked/trash and shared spaces. Remove the duplicate All Cloud Photos entry.
- Preserve album name search, all/mine/shared filtering, creation, editing, covers, members, sharing links, comments/likes, notification deep links and optimistic rollback behavior.
- New approved capabilities: pin collections/albums; collapse/reorder collections; Years/Months browsing; media shortcuts. Preferences must be isolated by account.
- Use SF Symbols, system type, semantic colors, standard navigation stacks, menus, sheets and List edit/reordering controls. Use native glass only for actual controls, without background bands behind toolbar rows.
- Retain viewer, editing, OCR, Live Photos, video, spatial scene, stacks, people sharing, backup verification and safe local removal unchanged except where navigation integration requires a change.

## Approach

Keep the existing timeline, viewer, album mutation and destination implementations; introduce presentation state and compose the Collections home around them. Rebuilding these features would risk regressions in established permission and recovery behavior. Native SwiftUI toolbars supply platform materials and hit targets; the UIKit grid remains responsible for virtualization and viewer transitions.

## Verification and release

Exercise real behavior in focused unit tests and the local synthetic server fixture; run the full unit suite, existing localization/viewer flows and new Photos/Albums UI flows on the iOS simulator. Capture and inspect both appearances, menu/selection states, deep navigation and long/empty content. Compare unchanged system concepts to screenshots of system Photos collected on the same simulator. Review the complete change before merging to remote main. Prepare, sign, publish and install the next app build through the existing enrolled Mac updater, then verify the installed version and source revision. Keep signing/enrollment/credentials private.
