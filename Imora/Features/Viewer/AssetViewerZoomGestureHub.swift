import ObjectiveC
import Observation
import UIKit

@MainActor
protocol AssetViewerZoomGestureTarget: AnyObject {
    var allowsDoubleTapZoom: Bool { get }
    var supportsLiveHold: Bool { get }
    func routeMediaTap()
    func routeDoubleTap(at point: CGPoint, from view: UIView)
    func routeLiveHold(_ event: LiveHoldEvent)
}

extension AssetViewerZoomGestureTarget {
    var supportsLiveHold: Bool { false }
    func routeLiveHold(_ event: LiveHoldEvent) {}
}

/// Report release and a second finger even while UIKit is still waiting for
/// the long-press threshold. Navigation recognizers remain free to proceed.
@MainActor
final class LiveHoldGestureRecognizer: UILongPressGestureRecognizer {
    var onTouchEvent: ((LiveHoldEvent) -> Void)?
    private weak var firstTouch: UITouch?
    private var origin: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard firstTouch == nil, touches.count == 1, let touch = touches.first else {
            onTouchEvent?(.secondFinger)
            state = state == .possible ? .failed : .cancelled
            return
        }
        firstTouch = touch; origin = touch.location(in: view)
        onTouchEvent?(.began)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let firstTouch, let origin {
            let point = firstTouch.location(in: view)
            let distance = hypot(point.x - origin.x, point.y - origin.y)
            onTouchEvent?(.moved(distancePt: Double(distance)))
            if distance > LiveHoldController.maximumMovement {
                state = state == .possible ? .failed : .cancelled
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchEvent?(.ended)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchEvent?(.cancelled)
        super.touchesCancelled(touches, with: event)
    }

    override func reset() {
        super.reset()
        firstTouch = nil; origin = nil
    }
}

@MainActor
protocol AssetViewerZoomCommandTarget: AnyObject {
    var zoomCommandAssetID: String { get }

    @discardableResult
    func routeZoomToFit(completion: @escaping (Bool) -> Void) -> Bool
    func cancelRoutedZoomToFit()
}

@MainActor
@Observable
final class AssetViewerZoomCommandBridge {
    private struct PendingFit {
        let generation: Int
        let targetID: ObjectIdentifier
        let completion: (Bool) -> Void
    }

    @ObservationIgnored private weak var activeTarget: (any AssetViewerZoomCommandTarget)?
    @ObservationIgnored private var commandGeneration = 0
    @ObservationIgnored private var pendingFit: PendingFit?

    func setActive(_ target: any AssetViewerZoomCommandTarget, isActive: Bool) {
        if isActive {
            guard activeTarget !== target else { return }
            let previousTarget = activeTarget
            let cancelledFit = takePendingFit()
            commandGeneration &+= 1
            activeTarget = target
            cancel(cancelledFit, on: previousTarget)
        } else if activeTarget === target {
            let previousTarget = activeTarget
            let cancelledFit = takePendingFit()
            commandGeneration &+= 1
            activeTarget = nil
            cancel(cancelledFit, on: previousTarget)
        }
    }

    @discardableResult
    func fitActivePage(
        assetID: String,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard let activeTarget,
              activeTarget.zoomCommandAssetID == assetID
        else { return false }
        let cancelledFit = takePendingFit()
        if cancelledFit != nil {
            activeTarget.cancelRoutedZoomToFit()
        }
        commandGeneration &+= 1
        let generation = commandGeneration
        let targetID = ObjectIdentifier(activeTarget)
        pendingFit = PendingFit(
            generation: generation,
            targetID: targetID,
            completion: completion
        )
        let started = activeTarget.routeZoomToFit { [weak self] completed in
            self?.resolveFit(
                generation: generation,
                targetID: targetID,
                completed: completed
            )
        }
        if !started {
            discardFit(generation: generation, targetID: targetID)
        }
        cancelledFit?.completion(false)
        return started
    }

    func cancelPendingFit() {
        let target = activeTarget
        let cancelledFit = takePendingFit()
        cancel(cancelledFit, on: target)
    }

    private func takePendingFit() -> PendingFit? {
        guard let pendingFit else { return nil }
        self.pendingFit = nil
        commandGeneration &+= 1
        return pendingFit
    }

    private func cancel(
        _ pendingFit: PendingFit?,
        on target: (any AssetViewerZoomCommandTarget)?
    ) {
        guard let pendingFit else { return }
        target?.cancelRoutedZoomToFit()
        // cancellation can fire inside a representable update or hierarchy
        // teardown, where the completion writing swiftui state synchronously
        // is unsafe. delivery is deferred one tick, the completion is
        // request-scoped so a late cancel cannot clobber a newer fit.
        DispatchQueue.main.async { pendingFit.completion(false) }
    }

    private func resolveFit(
        generation: Int,
        targetID: ObjectIdentifier,
        completed: Bool
    ) {
        guard pendingFit?.generation == generation,
              pendingFit?.targetID == targetID
        else { return }
        guard let activeTarget,
              ObjectIdentifier(activeTarget) == targetID
        else {
            resolveCurrentFit(completed: false)
            return
        }
        resolveCurrentFit(completed: completed)
    }

    private func resolveCurrentFit(completed: Bool) {
        guard let pendingFit else { return }
        self.pendingFit = nil
        commandGeneration &+= 1
        pendingFit.completion(completed)
    }

    private func discardFit(
        generation: Int,
        targetID: ObjectIdentifier
    ) {
        guard pendingFit?.generation == generation,
              pendingFit?.targetID == targetID
        else { return }
        pendingFit = nil
        commandGeneration &+= 1
    }
}

@MainActor
final class AssetViewerZoomGestureHub: NSObject, UIGestureRecognizerDelegate {
    private static var associationKey: UInt8 = 0

    static func attached(to view: UIView) -> AssetViewerZoomGestureHub {
        if let hub = objc_getAssociatedObject(view, &associationKey)
            as? AssetViewerZoomGestureHub {
            return hub
        }
        let hub = AssetViewerZoomGestureHub(view: view)
        objc_setAssociatedObject(
            view,
            &associationKey,
            hub,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return hub
    }

    private weak var gestureView: UIView?
    private weak var singleTapGesture: UITapGestureRecognizer?
    private weak var doubleTapGesture: UITapGestureRecognizer?
    private weak var activeTarget: (any AssetViewerZoomGestureTarget)?
    private weak var heldTarget: (any AssetViewerZoomGestureTarget)?
    private weak var holdGesture: LiveHoldGestureRecognizer?

    private init(view: UIView) {
        gestureView = view
        super.init()

        let singleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleSingleTap(_:))
        )
        configure(tap: singleTap)
        view.addGestureRecognizer(singleTap)
        singleTapGesture = singleTap

        let doubleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        configure(tap: doubleTap)
        view.addGestureRecognizer(doubleTap)
        doubleTapGesture = doubleTap

        singleTap.require(toFail: doubleTap)
        let hold = LiveHoldGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = LiveHoldController.minimumDuration
        hold.allowableMovement = LiveHoldController.maximumMovement
        hold.numberOfTouchesRequired = 1
        hold.cancelsTouchesInView = false
        hold.delaysTouchesBegan = false
        hold.delaysTouchesEnded = false
        hold.delegate = self
        hold.isEnabled = false
        hold.onTouchEvent = { [weak self] event in self?.routeHoldTouch(event) }
        view.addGestureRecognizer(hold)
        holdGesture = hold
        singleTap.require(toFail: hold)
        doubleTap.require(toFail: hold)
    }

    func setActive(_ target: any AssetViewerZoomGestureTarget, isActive: Bool) {
        if isActive {
            if activeTarget !== target { cancelHeldTarget() }
            activeTarget = target
            singleTapGesture?.isEnabled = true
            doubleTapGesture?.isEnabled = true
            holdGesture?.isEnabled = target.supportsLiveHold
        } else if activeTarget === target {
            cancelHeldTarget()
            activeTarget = nil
            singleTapGesture?.isEnabled = false
            doubleTapGesture?.isEnabled = false
            holdGesture?.isEnabled = false
        }
    }

    private func cancelHeldTarget() {
        guard let previous = heldTarget else { return }
        heldTarget = nil
        // Active targets can change during a representable update. Its scoped
        // cancellation must not synchronously reenter SwiftUI invalidation.
        DispatchQueue.main.async { [weak previous] in previous?.routeLiveHold(.pageChanged) }
    }

    private func routeHoldTouch(_ event: LiveHoldEvent) {
        if event == .began { heldTarget = activeTarget }
        heldTarget?.routeLiveHold(event)
        switch event {
        case .ended, .cancelled, .secondFinger: heldTarget = nil
        default: break
        }
    }

    @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { heldTarget?.routeLiveHold(.recognized) }
        else if gesture.state == .cancelled || gesture.state == .failed { routeHoldTouch(.cancelled) }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        activeTarget?.supportsLiveHold == true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard activeTarget?.supportsLiveHold == true else { return false }
        var view = touch.view
        while let current = view, current !== gestureView {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is UIPanGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        activeTarget?.routeMediaTap()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              let gestureView,
              let activeTarget
        else { return }
        activeTarget.routeDoubleTap(
            at: gesture.location(in: gestureView),
            from: gestureView
        )
    }

    private func configure(tap: UITapGestureRecognizer) {
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
    }
}
