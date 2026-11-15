# Imora native Photos design

## Platform and theme
SwiftUI/UIKit, iOS 26+. Follow system light/dark colors and SF typography. This is an existing native app, not a new visual direction; the user approved the phase123 brief after the screenshot audit.

## Navigation
Library and Collections, native selected filled SF Symbols, separate Search. Selection owns bottom controls. Keep iPad native sidebar adaptation.

## Library
Photo-first edge-to-edge grid, thin gaps and native micro-corners. Scrolling header uses system gradient/blur so grid lines do not compete with text. Normal backup status is summarized; explicit failures remain visible.

## Collections
Preserve account-scoped pins, order and collapse. Add large/small/no-preview modes. Actual photo covers when known.

## Motion
Preserve photo identity and geometry through opening, dismissal and period drill-down. Transitions are interruptible, with no independent decorative bounce. Reduced Motion uses simple stable transitions.

## Editor
Native control placement and yellow edit accent; undo, redo, original comparison, revert and discard are complete across every supported adjustment. Unsupported backend operations explain capability constraints.
