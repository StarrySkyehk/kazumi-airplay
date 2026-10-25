//
//  ARDanmakuOverlayView.swift
//  Runner
//
//  Native danmaku renderer for the AR-glasses (external display) player.
//
//  The overlay is driven by a CADisplayLink and reads the current playback clock
//  from the AVPlayer it is attached to, so pause / seek / buffer stalls naturally
//  freeze or rebase the danmaku without an extra timer on the Dart side.
//

import AVFoundation
import QuartzCore
import UIKit

// MARK: - Model

/// One danmaku line as sent by Dart.
///
/// Payload (see `airplay-notes/protocol.md`):
/// `{"t": double milliseconds, "m": String, "c": int 0xRRGGBB, "y": int}`,
/// where `y` is `1` scroll, `5` top, `4` bottom.
struct ARDanmakuItem {

    enum Kind {
        case scroll
        case top
        case bottom
    }

    /// Playback position (milliseconds) at which the danmaku becomes visible.
    let timeMs: Double
    let text: String
    let color: UIColor
    let kind: Kind

    init?(payload: [String: Any]) {
        guard let rawTime = ARDanmakuItem.numberValue(payload["t"]),
              rawTime.isFinite,
              rawTime >= 0
        else {
            return nil
        }
        guard let rawText = payload["m"] as? String else { return nil }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.timeMs = rawTime
        self.text = trimmed.count > ARDanmakuOverlayView.maximumTextLength
            ? String(trimmed.prefix(ARDanmakuOverlayView.maximumTextLength))
            : trimmed
        let colorValue = ARDanmakuItem.numberValue(payload["c"]).map { Int($0) } ?? 0xFFFFFF
        self.color = ARDanmakuItem.color(fromRGB: colorValue)
        let kindValue = Int(ARDanmakuItem.numberValue(payload["y"]) ?? 1)
        switch kindValue {
        case 5:
            self.kind = .top
        case 4:
            self.kind = .bottom
        default:
            self.kind = .scroll
        }
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? String { return Double(number) }
        return nil
    }

    private static func color(fromRGB value: Int) -> UIColor {
        let clamped = value & 0xFFFFFF
        let red = CGFloat((clamped >> 16) & 0xFF) / 255.0
        let green = CGFloat((clamped >> 8) & 0xFF) / 255.0
        let blue = CGFloat(clamped & 0xFF) / 255.0
        return UIColor(red: red, green: green, blue: blue, alpha: 1.0)
    }
}

// MARK: - Display link proxy

/// Weak display-link target: `CADisplayLink` retains its target, which would
/// otherwise create a `CADisplayLink -> overlay` retain cycle.
@MainActor
private final class ARDanmakuDisplayLinkProxy: NSObject {

    private weak var overlayView: ARDanmakuOverlayView?

    init(overlayView: ARDanmakuOverlayView) {
        self.overlayView = overlayView
        super.init()
    }

    @objc func handleDisplayLinkTick(_ displayLink: CADisplayLink) {
        overlayView?.advance(with: displayLink)
    }
}

// MARK: - Overlay

/// Draws scrolling / top / bottom danmaku on top of the external display video.
///
/// All state lives on the main thread: the view is a `UIView` (main actor isolated)
/// and every entry point is reached from UIKit or from the display link, which both
/// run on the main run loop.
final class ARDanmakuOverlayView: UIView {

    // MARK: Tuning

    fileprivate static let maximumTextLength = 240

    private enum Layout {
        static let referenceHeight: CGFloat = 1080.0
        static let referenceFontSize: CGFloat = 42.0
        static let minimumFontSize: CGFloat = 12.0
        static let maximumFontSize: CGFloat = 96.0
        static let laneSpacing: CGFloat = 1.32
        static let minimumScrollLanes = 4
        static let maximumScrollLanes = 12
        static let topLanes = 4
        static let bottomLanes = 4
    }

    private enum Timing {
        /// A scrolling danmaku needs 8 s to travel from the right edge to the left edge.
        static let scrollTravelMilliseconds: Double = 8000.0
        /// Top / bottom danmaku stay for 4 s.
        static let fixedLifetimeMilliseconds: Double = 4000.0
        /// Minimum spacing between two danmaku emitted on the same scroll lane.
        static let scrollGapMilliseconds: Double = 320.0
        /// Danmaku that are already older than this when they are emitted are dropped
        /// (keeps a seek from flushing thousands of labels at once).
        static let lateToleranceMilliseconds: Double = 400.0
        /// A clock delta larger than this means the player seeked; rebase instead of jumping.
        static let clockJumpThresholdMilliseconds: Double = 1200.0
    }

    private enum Limits {
        static let maximumActiveLabels = 250
    }

    private struct ActiveDanmaku {
        let label: UILabel
        let kind: ARDanmakuItem.Kind
        let laneIndex: Int
        let width: CGFloat
        var spawnMilliseconds: Double
    }

    // MARK: Data

    private var items: [ARDanmakuItem] = []
    private var nextItemIndex = 0
    private var activeDanmakus: [ActiveDanmaku] = []

    // MARK: Lane bookkeeping (all values are playback milliseconds)

    private var scrollLaneFreeAtMilliseconds: [Double] = []
    private var topLaneFreeAtMilliseconds: [Double] = []
    private var bottomLaneFreeAtMilliseconds: [Double] = []

    // MARK: Geometry

    private var fontSize: CGFloat = Layout.referenceFontSize
    private var laneHeight: CGFloat = Layout.referenceFontSize * Layout.laneSpacing
    private var lastLayoutSize: CGSize = .zero

    // MARK: Clock / animation

    private var displayLink: CADisplayLink?
    private var displayLinkProxy: ARDanmakuDisplayLinkProxy?
    private var lastTickMilliseconds: Double?
    private var pausedAtMilliseconds: Double?
    private var isPaused = false

    // MARK: Configuration

    private var isDanmakuEnabled = true
    private var labelOpacity: CGFloat = 1.0
    private var fontScale: CGFloat = 1.0
    private weak var player: AVPlayer?

    // MARK: - Lifecycle

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        clipsToBounds = true
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            teardownDisplayLink()
        } else {
            updateDisplayLinkState()
        }
    }

    // MARK: - Public API

    /// Attaches the player used as the danmaku clock (weak: the manager owns the player).
    func attach(player: AVPlayer?) {
        self.player = player
        if player == nil {
            teardownDisplayLink()
            clearActiveDanmakus()
            nextItemIndex = 0
            lastTickMilliseconds = nil
            pausedAtMilliseconds = nil
        } else if let current = currentPlaybackMilliseconds() {
            seek(toMilliseconds: current)
        }
        updateDisplayLinkState()
    }

    func setItems(_ newItems: [ARDanmakuItem]) {
        items = newItems.sorted { $0.timeMs < $1.timeMs }
        nextItemIndex = 0
        clearActiveDanmakus()
        refreshGeometryIfNeeded(force: true)
        let reference = currentPlaybackMilliseconds() ?? 0
        seek(toMilliseconds: reference)
        updateDisplayLinkState()
    }

    func setDanmakuEnabled(_ enabled: Bool) {
        guard isDanmakuEnabled != enabled else { return }
        isDanmakuEnabled = enabled
        isHidden = !enabled
        if enabled {
            let reference = currentPlaybackMilliseconds() ?? 0
            seek(toMilliseconds: reference)
        } else {
            clearActiveDanmakus()
        }
        updateDisplayLinkState()
    }

    func setOpacity(_ opacity: CGFloat) {
        let clamped = min(max(opacity, 0.0), 1.0)
        labelOpacity = clamped
        for active in activeDanmakus {
            active.label.alpha = clamped
        }
    }

    func setFontScale(_ scale: CGFloat) {
        let clamped = min(max(scale, 0.5), 2.0)
        guard fontScale != clamped else { return }
        fontScale = clamped
        refreshGeometryIfNeeded(force: true)
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            pausedAtMilliseconds = currentPlaybackMilliseconds()
            displayLink?.isPaused = true
        } else {
            if let pausedAt = pausedAtMilliseconds,
               let now = currentPlaybackMilliseconds(),
               now > pausedAt {
                // Keep the on-screen labels where they are: everything that was
                // spawned before the pause moves its spawn time forward.
                shiftActiveDanmakus(byMilliseconds: now - pausedAt)
            }
            pausedAtMilliseconds = nil
            lastTickMilliseconds = currentPlaybackMilliseconds()
            displayLink?.isPaused = false
            updateDisplayLinkState()
        }
    }

    /// Rebuilds the emission index around `positionMs` and drops whatever is on screen.
    func seek(toMilliseconds positionMs: Double) {
        guard positionMs.isFinite else { return }
        clearActiveDanmakus()
        let searchTime = positionMs - Timing.lateToleranceMilliseconds
        nextItemIndex = firstItemIndex(atOrAfterMilliseconds: searchTime)
        resetLaneState(atMilliseconds: positionMs)
        lastTickMilliseconds = positionMs
        if isPaused {
            pausedAtMilliseconds = positionMs
        }
        updateDisplayLinkState()
    }

    /// Called when the video ends: parks the emission index at the end and stops the link.
    ///
    /// The item list is kept so that a later seek back (or a replay of the same session)
    /// can resume the danmaku; a full teardown passes an empty list to `setItems(_:)`.
    func stopAndClear() {
        clearActiveDanmakus()
        nextItemIndex = items.count
        lastTickMilliseconds = nil
        pausedAtMilliseconds = nil
        teardownDisplayLink()
    }

    /// Recomputes font / lane geometry after a bounds change (external screen rotation).
    func updateMetricsIfNeeded() {
        refreshGeometryIfNeeded(force: false)
        updateDisplayLinkState()
    }

    // MARK: - Display link

    private func updateDisplayLinkState() {
        let shouldRun = window != nil
            && player != nil
            && isDanmakuEnabled
            && !items.isEmpty
        if shouldRun {
            if displayLink == nil {
                let proxy = ARDanmakuDisplayLinkProxy(overlayView: self)
                let link = CADisplayLink(
                    target: proxy,
                    selector: #selector(ARDanmakuDisplayLinkProxy.handleDisplayLinkTick(_:))
                )
                link.add(to: .main, forMode: .common)
                displayLinkProxy = proxy
                displayLink = link
            }
            displayLink?.isPaused = isPaused
        } else {
            teardownDisplayLink()
        }
    }

    private func teardownDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        lastTickMilliseconds = nil
    }

    fileprivate func advance(with displayLink: CADisplayLink) {
        guard isDanmakuEnabled, !isPaused, window != nil else { return }
        if scrollLaneFreeAtMilliseconds.isEmpty || lastLayoutSize != bounds.size {
            refreshGeometryIfNeeded(force: true)
            return
        }
        guard let nowMilliseconds = currentPlaybackMilliseconds() else { return }
        if let lastTick = lastTickMilliseconds {
            let delta = nowMilliseconds - lastTick
            if delta < -100 || delta > Timing.clockJumpThresholdMilliseconds {
                // The player clock jumped (seek / resume): rebase the whole overlay.
                seek(toMilliseconds: nowMilliseconds)
                return
            }
        }
        lastTickMilliseconds = nowMilliseconds
        spawnDueItems(atMilliseconds: nowMilliseconds)
        updateActiveDanmakus(atMilliseconds: nowMilliseconds)
    }

    // MARK: - Clock

    private func currentPlaybackMilliseconds() -> Double? {
        guard let player = player, player.currentItem != nil else { return nil }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return nil }
        return seconds * 1000.0
    }

    // MARK: - Geometry

    @discardableResult
    private func refreshGeometryIfNeeded(force: Bool) -> Bool {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return false }
        if !force, size == lastLayoutSize, !scrollLaneFreeAtMilliseconds.isEmpty {
            return false
        }
        lastLayoutSize = size
        let scaled = Layout.referenceFontSize * (size.height / Layout.referenceHeight) * fontScale
        fontSize = min(max(scaled, Layout.minimumFontSize), Layout.maximumFontSize)
        laneHeight = fontSize * Layout.laneSpacing
        let scrollLaneCount = min(
            Layout.maximumScrollLanes,
            max(Layout.minimumScrollLanes, Int(size.height / laneHeight))
        )
        scrollLaneFreeAtMilliseconds = Array(repeating: 0, count: scrollLaneCount)
        topLaneFreeAtMilliseconds = Array(repeating: 0, count: Layout.topLanes)
        bottomLaneFreeAtMilliseconds = Array(repeating: 0, count: Layout.bottomLanes)
        clearActiveDanmakus()
        let reference = currentPlaybackMilliseconds() ?? 0
        seek(toMilliseconds: reference)
        return true
    }

    private func scrollLaneY(index: Int) -> CGFloat {
        return CGFloat(index) * laneHeight
    }

    private func topLaneY(index: Int) -> CGFloat {
        return CGFloat(index) * laneHeight
    }

    private func bottomLaneY(index: Int) -> CGFloat {
        return max(0, bounds.height - CGFloat(index + 1) * laneHeight)
    }

    // MARK: - Emission

    private func spawnDueItems(atMilliseconds nowMilliseconds: Double) {
        while nextItemIndex < items.count {
            let item = items[nextItemIndex]
            if item.timeMs > nowMilliseconds { break }
            nextItemIndex += 1
            if nowMilliseconds - item.timeMs > Timing.lateToleranceMilliseconds { continue }
            spawn(item, atMilliseconds: nowMilliseconds)
        }
    }

    private func spawn(_ item: ARDanmakuItem, atMilliseconds nowMilliseconds: Double) {
        guard activeDanmakus.count < Limits.maximumActiveLabels else { return }
        switch item.kind {
        case .scroll:
            guard let lane = firstFreeLane(in: scrollLaneFreeAtMilliseconds, nowMilliseconds: nowMilliseconds) else {
                return
            }
            let label = makeLabel(for: item)
            let labelSize = label.bounds.size
            let travel = bounds.width + labelSize.width
            guard travel > 0 else { return }
            let speedPerMillisecond = travel / CGFloat(Timing.scrollTravelMilliseconds)
            guard speedPerMillisecond > 0 else { return }
            // The lane is free again once the tail of this label has entered the screen.
            let tailEntersAt = Double(labelSize.width / speedPerMillisecond)
            scrollLaneFreeAtMilliseconds[lane] = nowMilliseconds + tailEntersAt + Timing.scrollGapMilliseconds
            label.frame = CGRect(
                x: bounds.width,
                y: scrollLaneY(index: lane),
                width: labelSize.width,
                height: labelSize.height
            )
            addSubview(label)
            activeDanmakus.append(
                ActiveDanmaku(
                    label: label,
                    kind: .scroll,
                    laneIndex: lane,
                    width: labelSize.width,
                    spawnMilliseconds: nowMilliseconds
                )
            )
        case .top:
            guard let lane = firstFreeLane(in: topLaneFreeAtMilliseconds, nowMilliseconds: nowMilliseconds) else {
                return
            }
            let label = makeLabel(for: item)
            let labelSize = label.bounds.size
            topLaneFreeAtMilliseconds[lane] = nowMilliseconds + Timing.fixedLifetimeMilliseconds + 100
            label.frame = CGRect(
                x: (bounds.width - labelSize.width) / 2,
                y: topLaneY(index: lane),
                width: labelSize.width,
                height: labelSize.height
            )
            addSubview(label)
            activeDanmakus.append(
                ActiveDanmaku(
                    label: label,
                    kind: .top,
                    laneIndex: lane,
                    width: labelSize.width,
                    spawnMilliseconds: nowMilliseconds
                )
            )
        case .bottom:
            guard let lane = firstFreeLane(in: bottomLaneFreeAtMilliseconds, nowMilliseconds: nowMilliseconds) else {
                return
            }
            let label = makeLabel(for: item)
            let labelSize = label.bounds.size
            bottomLaneFreeAtMilliseconds[lane] = nowMilliseconds + Timing.fixedLifetimeMilliseconds + 100
            label.frame = CGRect(
                x: (bounds.width - labelSize.width) / 2,
                y: bottomLaneY(index: lane),
                width: labelSize.width,
                height: labelSize.height
            )
            addSubview(label)
            activeDanmakus.append(
                ActiveDanmaku(
                    label: label,
                    kind: .bottom,
                    laneIndex: lane,
                    width: labelSize.width,
                    spawnMilliseconds: nowMilliseconds
                )
            )
        }
    }

    private func firstFreeLane(in lanes: [Double], nowMilliseconds: Double) -> Int? {
        return lanes.firstIndex(where: { $0 <= nowMilliseconds })
    }

    private func updateActiveDanmakus(atMilliseconds nowMilliseconds: Double) {
        guard !activeDanmakus.isEmpty else { return }
        let width = bounds.width
        var index = 0
        while index < activeDanmakus.count {
            var active = activeDanmakus[index]
            let elapsed = nowMilliseconds - active.spawnMilliseconds
            switch active.kind {
            case .scroll:
                let travel = width + active.width
                let progress = CGFloat(elapsed) / CGFloat(Timing.scrollTravelMilliseconds)
                let x = width - travel * progress
                active.label.frame.origin.x = x
                if x <= -active.width {
                    removeActiveDanmaku(at: index)
                    continue
                }
            case .top, .bottom:
                if elapsed >= Timing.fixedLifetimeMilliseconds + 100 {
                    removeActiveDanmaku(at: index)
                    continue
                }
            }
            activeDanmakus[index] = active
            index += 1
        }
    }

    // MARK: - Label construction

    private func makeLabel(for item: ARDanmakuItem) -> UILabel {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        label.attributedText = makeAttributedText(for: item)
        label.numberOfLines = 1
        label.backgroundColor = .clear
        label.alpha = labelOpacity
        label.sizeToFit()
        return label
    }

    private func makeAttributedText(for item: ARDanmakuItem) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: item.color,
            .strokeColor: UIColor.black,
            .strokeWidth: -3.0,
        ]
        return NSAttributedString(string: item.text, attributes: attributes)
    }

    // MARK: - Lane state

    private func resetLaneState(atMilliseconds positionMs: Double) {
        let clamped = positionMs.isFinite ? positionMs : 0
        for index in scrollLaneFreeAtMilliseconds.indices {
            scrollLaneFreeAtMilliseconds[index] = clamped
        }
        for index in topLaneFreeAtMilliseconds.indices {
            topLaneFreeAtMilliseconds[index] = clamped
        }
        for index in bottomLaneFreeAtMilliseconds.indices {
            bottomLaneFreeAtMilliseconds[index] = clamped
        }
    }

    private func shiftActiveDanmakus(byMilliseconds delta: Double) {
        guard delta > 0 else { return }
        for index in activeDanmakus.indices {
            activeDanmakus[index].spawnMilliseconds += delta
        }
        for index in scrollLaneFreeAtMilliseconds.indices {
            scrollLaneFreeAtMilliseconds[index] += delta
        }
        for index in topLaneFreeAtMilliseconds.indices {
            topLaneFreeAtMilliseconds[index] += delta
        }
        for index in bottomLaneFreeAtMilliseconds.indices {
            bottomLaneFreeAtMilliseconds[index] += delta
        }
    }

    private func clearActiveDanmakus() {
        for active in activeDanmakus {
            active.label.removeFromSuperview()
        }
        activeDanmakus.removeAll()
    }

    private func removeActiveDanmaku(at index: Int) {
        guard activeDanmakus.indices.contains(index) else { return }
        activeDanmakus[index].label.removeFromSuperview()
        activeDanmakus.remove(at: index)
    }

    private func firstItemIndex(atOrAfterMilliseconds timeMs: Double) -> Int {
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].timeMs < timeMs {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
