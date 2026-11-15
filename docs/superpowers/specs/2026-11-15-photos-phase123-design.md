# Photos native experience phases 1–3, approved design

Approved by the user on 2026-11-15 after the in-chat proposal. Implement every item in phases 1–3. Phase 4 is planning only, in a separate chat.

## Intent and approach
Imora remains a self-hosted native photo library, using SwiftUI, UIKit, PhotoKit and the existing Immich-derived backend. Bring daily UI, interactions, motion and editing closer to the same-device Apple Photos app. Preserve separate device/cloud sources while sharing reliable identity and state for verified pairs. Build on existing grid/viewer and preserve offline browsing, backup and cleanup evidence.

## Binding scope
1. One photographer-local wall-clock formatter for visible dates, AX labels and metadata. UTC+8, UTC, negative offsets and midnight agree.
2. Search inherits device/cloud source, shows an explicit localized scope; device search matches filename and date on accessible PhotoKit media including unbacked items. Backend-only semantic/OCR/people options are not shown as local capabilities.
3. Device favorites write PhotoKit. Verified paired cloud favorites use account-scoped durable last-intent retry; don't lose accepted device results on cloud errors. Remote-only favorites work as before. No inference of pair identity from filename/date alone.
4. Atomic full edit intent for enhanced backend. One transaction replaces full edits; unknown transport outcome is read back before treating as failure. Retain user's draft after failures. Legacy dual-request failures must not silently masquerade as full rollback.
5. Adding an unbacked device item to an App album explicitly says Back Up and Add to Album, shows progress, and retains selection/retry information on failure. No silent upload. Album means App cloud album.
6. Navigation names Library / Collections, correct selected filled SF Symbols. Native scrolling edge blur/gradient, matching grid gaps/micro-corners. Backup status summary plus default quiet normal tiles; show failures. User can opt into all backup badges.
7. Collections preview size Large / Small / None, account-scoped persistent choices. Prefer actual covers for pins where available. Existing pin/order/collapse and creation remain.
8. Filters Edited / Not in Album / Screenshots in addition to existing categories. Results, counts and reset are coherent. Shared-related categories only if actual permission/semantics allow them.
9. Period drill-down uses one identified photo anchor through year/month/all geometry. Reversible/interruptible image opening, dismissal and information transitions. Existing continuous pinch stays. Reduced Motion simplifies effects.
10. PhotoKit non-destructive image editing works for unbacked device images. Unified parameter semantics for preview, local saved edits and enhanced cloud derivatives. Exposure/contrast/saturation/invert plus highlights/shadows/brightness/blackPoint/warmth/tint; normalized ranges and original comparison. Crop ratio, flip, quarter rotation plus straighten and horizontal/vertical perspective. Undo/redo/revert/discard cover all parameters.
11. Originals and verified backup receipts are independent of rendered edits; a derivative must never authorize device-original deletion.

## Explicit exclusions
No phase-4 Live Photo key-frame/effect editor, video color editor, new trip/memory movie engine, general offline-edit sync/conflict system. Favorite retry is phase 1 and is included. Do not push/merge/deploy production or install on the physical phone; final delivery is local changes plus tested simulator install.

## Shared editor wire contract
Use the existing PUT /assets/{id}/edits full-list transaction. Add an optional action `photo`, with version 1 parameters below. The `photo` action is last; existing crop (if any) is first, followed by mirrors and quarter rotation. Existing APIs/actions keep working. GET returns exactly the complete stored intent, including extensions. Empty intent uses DELETE as today. Advertise explicit `photoEditsV1: true` from GET /server/features, never infer this extension from version alone. Client ServerFeaturesFingerprint and ServerCapabilities add a matching field/supportsPhotoEditsV1.

photo.parameters = {version:1, exposure:0, contrast:0, saturation:0, invert:false, highlights:0, shadows:0, brightness:0, blackPoint:0, warmth:0, tint:0, straighten:0, horizontalPerspective:0, verticalPerspective:0}
Amounts exposure/contrast/saturation/highlights/shadows/brightness/blackPoint/warmth/tint are finite -100...100. Straighten is finite -45...45 degrees. Horizontal/vertical perspective finite -1...1. Missing color/geometry members decode as neutral; unsupported version rejected. Parameters must round-trip without loss. Original pixel dimensions remain the geometry input; preserve valid metadata.

Color math in nonlinear sRGB, channel values 0...1, with clamp after each stage, in this exact order:
- saturation matrix W3C coefficients R=.213 G=.715 B=.072, multiplier 1+saturation/100;
- invert (1-channel) if enabled;
- exposure multiplier 1+exposure/100;
- highlights: add .5*(highlights/100)*luma*luma to every channel, luma=.213R+.715G+.072B;
- shadows: add .5*(shadows/100)*(1-luma)^2 to every channel, recompute luma;
- brightness: add .5*brightness/100;
- blackPoint: (channel - .5*blackPoint/100)/(1 - .5*blackPoint/100);
- warmth: R += .15*warmth/100, B -= .15*warmth/100;
- tint: R/B += .075*tint/100, G -= .15*tint/100;
- contrast: (channel-.5)*(1+contrast/100)+.5.

Geometry: existing crop/mirror/quarter rotation then enhanced warp, with same output dimensions as that cropped/oriented input. Use normalized centered top-left-oriented coordinates u,v in [-1,1]. For output (u,v), inverse sample = rotate by -straighten divided by d=1+.25*(horizontalPerspective*u+verticalPerspective*v). Compute maximal absolute inverse sample coordinate at all 4 corners, `m=max(1,all abs x/y)`, divide inverse samples by m so the image fills without transparent corners. Bilinear sample, clamp source edge; no black padding. Client GPU kernel and backend raw pipeline share these formulas. If an aspect-aware correction is needed, coordinate it in the ledger before changing either side.

Implementation clarifications coordinated during validation: endpoints use `u=2*x/(width-1)-1` and the equivalent y formula; a singleton axis is zero. Core Image uses pixel centers (destination minus .5, sample plus .5). Interpolate **premultiplied RGBA** in the warp, then unpremultiply RGB for the nonlinear color stages and premultiply for Core Image output (Sharp raw output is straight RGBA). A fully transparent pixel's hidden color must not contaminate visible edges. Full-resolution backend CPU work must yield the event loop through worker isolation so job locks continue renewing.

## Validation
Meaningful red-to-green tests for date/time semantic agreement, source-bound search, durable account-isolated favorite retries, complete editor roundtrip and partial/unknown outcomes, non-destructive local save, color/geometry fixtures, filters and collection preference migration. Native full unit suite + current 9 UI regressions + new phase123 flows. Backend focused tests + type check + appropriate regression suite. Final fresh screenshots and simulator video for Library, Collections, menus, local/cloud viewers, scoped search, editor controls, selection, period transitions and Reduced Motion/dark appearance where supported. Do not claim physical frame rate/haptics/HDR from simulator evidence.
