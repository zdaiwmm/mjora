# Gallery responsiveness and viewer handoff

The library caches derived year/month groups and month-day compositions until timeline sections change. The capture-date source survives transitions back to All, and year covers select their image lazily. Month visibility bookkeeping no longer invalidates its SwiftUI section for every appearance change.

Video pages create a controlled byte-range resource instead of waiting for a full remote file download. Requests retain the client's authenticated transport and current account/private-media authorization. Transport controls appear during preparation, and the opening thumbnail remains until a video frame is ready. Returning from the viewer retains temporarily hidden source tiles and can use the current opening surface before full viewer media is bound.

In compact Library navigation, the first left-button tap expands Library/Collections in place. A second Library tap scrolls to the latest row with UIKit animation, respecting Reduce Motion. The last row clears the floating controls. Item counts use their full intrinsic width and an accessible value; Collections uses a 36pt avatar inside its existing 44pt button.

## Validation

- Final iOS simulator build succeeded.
- 59 focused regression tests passed, including calendar invalidation/reentry, month topology, anchor restoration, viewer lifecycle, hidden return-source pixels, controlled video ranges and network boundaries.
- The Chinese UI flow passed count presentation, first-tap position preservation, second-tap return, final-row clearance, Years/Months/All switching and Collections avatar capture. Measured clearance to the Library button's content frame was 11pt.
- With 12,000 synthetic photos over 40 repeated layout calculations, uncached grouping/month content took approximately 200ms and cached calculations approximately 5ms. This is a computation measurement, not a frame-rate claim.
- AVFoundation read the streamed duration and decoded a first frame. The video control strip appeared immediately in the UI flow.
- Actual playback-time advancement could not be accepted in this simulator: both the changed app and a retained pre-change test package stalled at zero during playback. The autoplay UI check failed for this reason; physical-device playback and perceived transition smoothness remain to be verified.

Evidence is retained locally in the gallery-responsive build logs, unit/UI result bundles and baseline playback probe. Private signed packages, device identifiers and enrollment resources are not part of this repository.
