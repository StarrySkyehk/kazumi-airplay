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
//  v2 (protocol-v2.md §三):
//  - `ARDanmakuConfig` mirrors the Dart `danmakuConfig` payload (tolerant initializer,
//    every value clamped) and `apply(config:)` re-lays the overlay out live.
//  - Scrolling lanes only cover `bounds.height * area`; top / bottom lanes stay pinned
//    to their screen edges. Lane pitch is `fontSize * max(1.0, lineHeight)` and the
//    right-to-left travel time comes from `durationSeconds` (2...20 s).
//  - Stroke is rendered inside explicitly inset labels (`drawText(in:)`) whose intrinsic
//    size also contains the inset, at the screen's native scale and on pixel-aligned
//    origins. That fixes the clipped / blurry glyph edges of the v1 renderer.
//  - `fontWeight` uses the same mapping as the Flutter `canvas_danmaku` package
//    (`FontWeight.values[fontWeight]`, 0-based): wire 1 -> .thin (w200), 2 -> .light,
//    3 -> .regular, 4 -> .medium (w500, the default), 5 -> .semibold, 6 -> .bold,
//    7 -> .heavy, 8/9 -> .black (w900). The v1 renderer hard-coded .bold (wire 6).
//
//  Everything here runs on the main thread: the view is a UIView (main-actor isolated)
//  and every entry point is reached from UIKit or from the display link.
//

import AVFoundation
import QuartzCore
import UIKit

// MARK: - Model

/// One danmaku line as sent by Dart.
///
/// Payload (see `airplay-notes/protocol-v2.md`):
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

// MARK: - Appearance config

/// Danmaku appearance / behaviour configuration.
///
/// This is the native counterpart of the Dart `danmakuConfig` map. Every field is
/// optional on the wire: a missing or mistyped value falls back to the documented
/// default, and out-of-range values are clamped. Ranges:
/// `opacity` 0.1...1, `fontScale` 0.4...3, `area` 0...1, `durationSeconds` 2...20,
/// `lineHeight` 0...3 (`0` means "use the default 1.6"), `strokeWidth` 0...8
/// (`0` means no outline), `fontWeight` 1...9.
struct ARDanmakuConfig: Equatable {

    var opacity: CGFloat
    var fontScale: CGFloat
    var area: CGFloat
    var durationSeconds: Double
    /// Lane pitch multiplier (0 means the default 1.6).
    var lineHeight: CGFloat
    /// Outline width in points (0 disables the outline).
    var strokeWidth: CGFloat
    var fontWeight: Int
    var massiveMode: Bool
    var hideTop: Bool
    var hideScroll: Bool
    var hideBottom: Bool

    /// Defaults used when a field is absent (protocol-v2.md §一).
    static let `default` = ARDanmakuConfig(payload: nil)

    /// Tolerant parser: accepts missing fields, numbers sent as strings, etc.
    init(payload: [String: Any]?) {
        let payload = payload ?? [:]
        let opacityRaw = ARDanmakuConfig.value(payload["opacity"]) ?? 1.0
        let fontScaleRaw = ARDanmakuConfig.value(payload["fontScale"]) ?? 1.0
        let areaRaw = ARDanmakuConfig.value(payload["area"]) ?? 1.0
        let durationRaw = ARDanmakuConfig.value(payload["durationSeconds"])
            ?? ARDanmakuConfig.value(payload["duration"])
            ?? 8.0
        let lineHeightRaw = ARDanmakuConfig.value(payload["lineHeight"]) ?? 1.6
        let strokeWidthRaw = ARDanmakuConfig.value(payload["strokeWidth"]) ?? 1.5
        let fontWeightRaw = ARDanmakuConfig.value(payload["fontWeight"]) ?? 4.0

        self.opacity = CGFloat(ARDanmakuConfig.clamp(
            opacityRaw, lower: 0.1, upper: 1.0, fallback: 1.0
        ))
        self.fontScale = CGFloat(ARDanmakuConfig.clamp(
            fontScaleRaw, lower: 0.4, upper: 3.0, fallback: 1.0
        ))
        self.area = CGFloat(ARDanmakuConfig.clamp(
            areaRaw, lower: 0.0, upper: 1.0, fallback: 1.0
        ))
        self.durationSeconds = ARDanmakuConfig.clamp(
            durationRaw, lower: 2.0, upper: 20.0, fallback: 8.0
        )
        self.lineHeight = CGFloat(ARDanmakuConfig.clamp(
            lineHeightRaw, lower: 0.0, upper: 3.0, fallback: 1.6
        ))
        self.strokeWidth = CGFloat(ARDanmakuConfig.clamp(
            strokeWidthRaw, lower: 0.0, upper: 8.0, fallback: 1.5
        ))
        self.fontWeight = Int(ARDanmakuConfig.clamp(
            fontWeightRaw, lower: 1.0, upper: 9.0, fallback: 4.0
        ).rounded())
        self.massiveMode = ARDanmakuConfig.boolValue(payload["massiveMode"]) ?? false
        self.hideTop = ARDanmakuConfig.boolValue(payload["hideTop"]) ?? false
        self.hideScroll = ARDanmakuConfig.boolValue(payload["hideScroll"]) ?? false
        self.hideBottom = ARDanmakuConfig.boolValue(payload["hideBottom"]) ?? false
    }

    /// Normalised copy used by `apply(config:)`, so a caller that mutates the struct
    /// afterwards can never put the renderer into an unsupported state.
    fileprivate func clamped() -> ARDanmakuConfig {
        var copy = self
        copy.opacity = ARDanmakuConfig.clamp(opacity, lower: 0.1, upper: 1.0, fallback: 1.0)
        copy.fontScale = ARDanmakuConfig.clamp(fontScale, lower: 0.4, upper: 3.0, fallback: 1.0)
        copy.area = ARDanmakuConfig.clamp(area, lower: 0.0, upper: 1.0, fallback: 1.0)
        copy.durationSeconds = ARDanmakuConfig.clamp(
            durationSeconds, lower: 2.0, upper: 20.0, fallback: 8.0
        )
        copy.lineHeight = ARDanmakuConfig.clamp(lineHeight, lower: 0.0, upper: 3.0, fallback: 1.6)
        copy.strokeWidth = ARDanmakuConfig.clamp(strokeWidth, lower: 0.0, upper: 8.0, fallback: 1.5)
        copy.fontWeight = min(max(fontWeight, 1), 9)
        return copy
    }

    private static func value(_ raw: Any?) -> Double? {
        let number: Double?
        if let raw = raw as? Double {
            number = raw
        } else if let raw = raw as? Int {
            number = Double(raw)
        } else if let raw = raw as? NSNumber {
            number = raw.doubleValue
        } else if let raw = raw as? String {
            number = Double(raw)
        } else {
            number = nil
        }
        guard let number = number, number.isFinite else { return nil }
        return number
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        if let raw = raw as? Bool { return raw }
        if let raw = raw as? NSNumber { return raw.boolValue }
        if let raw = raw as? String {
            switch raw.lowercased() {
            case "true", "1":
                return true
            case "false", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func clamp<T: BinaryFloatingPoint>(
        _ value: T,
        lower: T,
        upper: T,
        fallback: T
    ) -> T {
        guard value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, lower), upper)
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

// MARK: - Label

/// A danmaku label with text insets.
///
/// The outline of an attributed string is painted *around* the glyph outlines, i.e.
/// partly outside the text's layout rect. A plain `UILabel` sizes itself to the glyph
/// rect, so the outer half of the outline gets clipped by the label bounds (the v1
/// "cut / fuzzy glyph edge" artifact). This subclass insets the drawing rect and adds
/// the same inset to the sized rect, so the outline always fits inside the label.
private final class ARDanmakuLabel: UILabel {

    let textInsets: UIEdgeInsets

    init(insets: UIEdgeInsets) {
        self.textInsets = insets
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false
        numberOfLines = 1
        lineBreakMode = .byClipping
    }

    required init?(coder: NSCoder) {
        self.textInsets = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false
        numberOfLines = 1
        lineBreakMode = .byClipping
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        return padded(super.intrinsicContentSize)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        return padded(super.sizeThatFits(size))
    }

    /// Natural text size (single line) plus the outline insets.
    func sizeForText() -> CGSize {
        let fitting = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        var natural = super.sizeThatFits(fitting)
        if !ARDanmakuLabel.isUsable(natural) {
            natural = super.intrinsicContentSize
        }
        if !ARDanmakuLabel.isUsable(natural) {
            natural = attributedText?.size() ?? .zero
        }
        return padded(natural)
    }

    private func padded(_ size: CGSize) -> CGSize {
        guard ARDanmakuLabel.isUsable(size) else { return size }
        return CGSize(
            width: ceil(size.width) + textInsets.left + textInsets.right,
            height: ceil(size.height) + textInsets.top + textInsets.bottom
        )
    }

    private static func isUsable(_ size: CGSize) -> Bool {
        return size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0
    }
}

// MARK: - Overlay

/// Draws scrolling / top / bottom danmaku on top of the external display video.
///
/// Labels are created once per danmaku and only re-positioned every frame; the text is
/// never re-laid out per frame, which keeps the 60 fps budget for the video decoder.
final class ARDanmakuOverlayView: UIView {

    // MARK: Tuning

    fileprivate static let maximumTextLength = 240

    private enum Layout {
        static let referenceHeight: CGFloat = 1080.0
        static let referenceFontSize: CGFloat = 42.0
        static let minimumFontSize: CGFloat = 12.0
        static let maximumFontSize: CGFloat = 512.0
        static let defaultLineHeight: CGFloat = 1.6
        static let maximumScrollLanes = 64
        static let topLanes = 4
        static let bottomLanes = 4
        /// Minimum room around the glyphs so the outline is never clipped.
        static let minimumTextInset: CGFloat = 4.0
    }

    private enum Timing {
        /// Minimum spacing between two danmaku emitted on the same scroll lane.
        static let scrollGapMilliseconds: Double = 320.0
        /// Top / bottom danmaku lifetime.
        static let fixedLifetimeMilliseconds: Double = 4000.0
        /// Danmaku that are already older than this when they are emitted are dropped
        /// (keeps a seek from flushing thousands of labels at once).
        static let lateToleranceMilliseconds: Double = 400.0
        /// A clock delta larger than this means the player seeked; rebase instead of jumping.
        static let clockJumpThresholdMilliseconds: Double = 1200.0
    }

    private enum Limits {
        static let maximumActiveLabels = 250
        /// massiveMode shrinks new labels once more than this many are alive.
        static let massiveModeThreshold = 80
        static let massiveModeFontScale: CGFloat = 0.8
    }

    private struct ActiveDanmaku {
        let label: ARDanmakuLabel
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
    private var laneHeight: CGFloat = Layout.referenceFontSize * Layout.defaultLineHeight
    private var lastLayoutSize: CGSize = .zero
    /// `false` until the first successful geometry pass; keeps the display link from
    /// spinning on a zero-sized (or zero-lane) overlay.
    private var isGeometryReady = false

    // MARK: Clock / animation

    private var displayLink: CADisplayLink?
    private var displayLinkProxy: ARDanmakuDisplayLinkProxy?
    private var lastTickMilliseconds: Double?
    private var pausedAtMilliseconds: Double?
    private var isPaused = false

    // MARK: Configuration

    private(set) var isDanmakuEnabled = true
    private var configuration = ARDanmakuConfig.default
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
            // Labels already on screen were rasterised for the previous window's screen.
            let scale = ARDanmakuOverlayView.windowScale(for: newWindow)
            for active in activeDanmakus {
                active.label.contentScaleFactor = scale
                active.label.layer.contentsScale = scale
            }
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
        seek(toMilliseconds: currentPlaybackMilliseconds() ?? 0)
        updateDisplayLinkState()
    }

    func setDanmakuEnabled(_ enabled: Bool) {
        guard isDanmakuEnabled != enabled else { return }
        isDanmakuEnabled = enabled
        isHidden = !enabled
        if enabled {
            seek(toMilliseconds: currentPlaybackMilliseconds() ?? 0)
        } else {
            clearActiveDanmakus()
        }
        updateDisplayLinkState()
    }

    /// Applies a complete appearance configuration.
    ///
    /// Safe to call at any time and idempotent: an unchanged configuration is a no-op,
    /// a changed one drops the labels on screen, recomputes the geometry and re-seeks the
    /// emission index so every following danmaku uses the new settings immediately.
    func apply(config newConfig: ARDanmakuConfig) {
        let normalized = newConfig.clamped()
        // Opacity is applied to the container: one compositing property instead of
        // touching every label, and it also covers labels created later.
        alpha = normalized.opacity
        guard normalized != configuration else { return }
        configuration = normalized
        if refreshGeometryIfNeeded(force: true) {
            seek(toMilliseconds: currentPlaybackMilliseconds() ?? lastTickMilliseconds ?? 0)
        } else {
            // No bounds yet: the first layout pass will build the geometry from this config.
            let reference = currentPlaybackMilliseconds() ?? lastTickMilliseconds ?? 0
            resetLaneState(atMilliseconds: reference)
            lastTickMilliseconds = reference
        }
        updateDisplayLinkState()
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
        if refreshGeometryIfNeeded(force: false) {
            seek(toMilliseconds: currentPlaybackMilliseconds() ?? lastTickMilliseconds ?? 0)
        }
        updateDisplayLinkState()
    }

    // MARK: - Display link

    /// `false` when every kind is hidden: no label could be spawned, so no link is needed.
    private var hasVisibleKind: Bool {
        return !(configuration.hideTop && configuration.hideScroll && configuration.hideBottom)
    }

    private func updateDisplayLinkState() {
        let shouldRun = window != nil
            && player != nil
            && isDanmakuEnabled
            && hasVisibleKind
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
        guard isDanmakuEnabled, !isPaused, window != nil, hasVisibleKind else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }
        if !isGeometryReady || lastLayoutSize != bounds.size {
            // Rotation / first layout: rebuild lanes around the current playback position.
            refreshGeometryIfNeeded(force: true)
            seek(toMilliseconds: currentPlaybackMilliseconds() ?? lastTickMilliseconds ?? 0)
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
        let scale = screenScale
        spawnDueItems(atMilliseconds: nowMilliseconds, scale: scale)
        updateActiveDanmakus(atMilliseconds: nowMilliseconds, scale: scale)
    }

    // MARK: - Clock

    private func currentPlaybackMilliseconds() -> Double? {
        guard let player = player, player.currentItem != nil else { return nil }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return nil }
        return seconds * 1000.0
    }

    // MARK: - Screen scale / pixel alignment

    private var screenScale: CGFloat {
        return ARDanmakuOverlayView.windowScale(for: window)
    }

    private static func windowScale(for window: UIWindow?) -> CGFloat {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        return scale > 0 ? scale : 1.0
    }

    /// Snaps a point position to the screen's pixel grid. A fractional origin makes
    /// CoreAnimation resample the label's cached bitmap, which is exactly the blur /
    /// tearing the glasses showed in v1.
    private func pixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return floor(value * scale) / scale
    }

    private func alignedFrame(_ frame: CGRect, scale: CGFloat) -> CGRect {
        return CGRect(
            x: pixelAligned(frame.origin.x, scale: scale),
            y: pixelAligned(frame.origin.y, scale: scale),
            width: frame.width,
            height: frame.height
        )
    }

    // MARK: - Geometry

    /// Lane pitch multiplier: `lineHeight == 0` (or absent) means the 1.6 default.
    private var effectiveLineHeight: CGFloat {
        if configuration.lineHeight <= 0 {
            return Layout.defaultLineHeight
        }
        return max(1.0, configuration.lineHeight)
    }

    @discardableResult
    private func refreshGeometryIfNeeded(force: Bool) -> Bool {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return false }
        if !force, isGeometryReady, size == lastLayoutSize {
            return false
        }
        lastLayoutSize = size
        isGeometryReady = true
        recomputeGeometry(for: size)
        return true
    }

    private func recomputeGeometry(for size: CGSize) {
        let heightScale = size.height / Layout.referenceHeight
        let scaledFontSize = Layout.referenceFontSize * heightScale * configuration.fontScale
        fontSize = min(
            max(scaledFontSize, Layout.minimumFontSize),
            Layout.maximumFontSize
        )
        laneHeight = fontSize * effectiveLineHeight

        // Scrolling lanes only use the top `area` fraction of the screen; at least one
        // lane is kept so a small area can not make scrolling danmaku disappear entirely.
        let scrollAreaHeight = size.height * min(max(configuration.area, 0.0), 1.0)
        let fittedLaneCount = Int(floor(scrollAreaHeight / max(laneHeight, 1.0)))
        let scrollLaneCount = min(
            Layout.maximumScrollLanes,
            max(1, fittedLaneCount)
        )
        scrollLaneFreeAtMilliseconds = Array(repeating: 0, count: scrollLaneCount)
        topLaneFreeAtMilliseconds = Array(repeating: 0, count: Layout.topLanes)
        bottomLaneFreeAtMilliseconds = Array(repeating: 0, count: Layout.bottomLanes)
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

    /// Right-to-left travel time of a scrolling danmaku (config value, clamped again
    /// here so a mutated struct can never slow the overlay to a crawl).
    private var scrollDurationMilliseconds: Double {
        let seconds = configuration.durationSeconds.isFinite ? configuration.durationSeconds : 8.0
        return min(max(seconds, 2.0), 20.0) * 1000.0
    }

    /// Font size used for labels spawned right now. massiveMode approximates the Flutter
    /// "dense danmaku" behaviour by shrinking the *new* labels only.
    private func spawnFontSize() -> CGFloat {
        if configuration.massiveMode, activeDanmakus.count > Limits.massiveModeThreshold {
            return fontSize * Limits.massiveModeFontScale
        }
        return fontSize
    }

    // MARK: - Emission

    private func spawnDueItems(atMilliseconds nowMilliseconds: Double, scale: CGFloat) {
        while nextItemIndex < items.count {
            let item = items[nextItemIndex]
            if item.timeMs > nowMilliseconds { break }
            nextItemIndex += 1
            if nowMilliseconds - item.timeMs > Timing.lateToleranceMilliseconds { continue }
            spawn(item, atMilliseconds: nowMilliseconds, scale: scale)
        }
    }

    private func isKindVisible(_ kind: ARDanmakuItem.Kind) -> Bool {
        switch kind {
        case .scroll:
            return !configuration.hideScroll
        case .top:
            return !configuration.hideTop
        case .bottom:
            return !configuration.hideBottom
        }
    }

    private func spawn(_ item: ARDanmakuItem, atMilliseconds nowMilliseconds: Double, scale: CGFloat) {
        guard activeDanmakus.count < Limits.maximumActiveLabels else { return }
        guard isKindVisible(item.kind) else { return }
        let pointSize = spawnFontSize()
        switch item.kind {
        case .scroll:
            guard let lane = firstFreeLane(
                in: scrollLaneFreeAtMilliseconds,
                nowMilliseconds: nowMilliseconds
            ) else {
                return
            }
            let label = makeLabel(for: item, pointSize: pointSize, scale: scale)
            let labelSize = label.frame.size
            let travel = bounds.width + labelSize.width
            guard travel > 0 else { return }
            let speedPerMillisecond = travel / CGFloat(scrollDurationMilliseconds)
            guard speedPerMillisecond > 0 else { return }
            // The lane is free again once the tail of this label has entered the screen.
            let tailEntersAt = Double(labelSize.width / speedPerMillisecond)
            scrollLaneFreeAtMilliseconds[lane] = nowMilliseconds
                + tailEntersAt
                + Timing.scrollGapMilliseconds
            label.frame = alignedFrame(
                CGRect(
                    x: bounds.width,
                    y: scrollLaneY(index: lane),
                    width: labelSize.width,
                    height: labelSize.height
                ),
                scale: scale
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
            guard let lane = firstFreeLane(
                in: topLaneFreeAtMilliseconds,
                nowMilliseconds: nowMilliseconds
            ) else {
                return
            }
            let label = makeLabel(for: item, pointSize: pointSize, scale: scale)
            let labelSize = label.frame.size
            topLaneFreeAtMilliseconds[lane] = nowMilliseconds
                + Timing.fixedLifetimeMilliseconds
                + 100
            label.frame = alignedFrame(
                CGRect(
                    x: (bounds.width - labelSize.width) / 2,
                    y: topLaneY(index: lane),
                    width: labelSize.width,
                    height: labelSize.height
                ),
                scale: scale
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
            guard let lane = firstFreeLane(
                in: bottomLaneFreeAtMilliseconds,
                nowMilliseconds: nowMilliseconds
            ) else {
                return
            }
            let label = makeLabel(for: item, pointSize: pointSize, scale: scale)
            let labelSize = label.frame.size
            bottomLaneFreeAtMilliseconds[lane] = nowMilliseconds
                + Timing.fixedLifetimeMilliseconds
                + 100
            label.frame = alignedFrame(
                CGRect(
                    x: (bounds.width - labelSize.width) / 2,
                    y: bottomLaneY(index: lane),
                    width: labelSize.width,
                    height: labelSize.height
                ),
                scale: scale
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

    private func updateActiveDanmakus(atMilliseconds nowMilliseconds: Double, scale: CGFloat) {
        guard !activeDanmakus.isEmpty else { return }
        let width = bounds.width
        let durationMs = scrollDurationMilliseconds
        var index = 0
        while index < activeDanmakus.count {
            var active = activeDanmakus[index]
            let elapsed = nowMilliseconds - active.spawnMilliseconds
            switch active.kind {
            case .scroll:
                let travel = width + active.width
                let progress = CGFloat(elapsed / durationMs)
                let x = width - travel * progress
                let alignedX = pixelAligned(x, scale: scale)
                if active.label.frame.origin.x != alignedX {
                    var frame = active.label.frame
                    frame.origin.x = alignedX
                    active.label.frame = frame
                }
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

    private func makeLabel(
        for item: ARDanmakuItem,
        pointSize: CGFloat,
        scale: CGFloat
    ) -> ARDanmakuLabel {
        // Room for the outline: half the stroke plus a hair of anti-aliasing margin.
        let inset = max(Layout.minimumTextInset, configuration.strokeWidth * 0.5 + 1.0)
        let insets = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        let label = ARDanmakuLabel(insets: insets)
        let font = ARDanmakuOverlayView.font(forWeight: configuration.fontWeight, size: pointSize)
        label.font = font
        label.attributedText = makeAttributedText(for: item, font: font, fontSize: pointSize)
        let labelSize = label.sizeForText()
        label.frame = CGRect(origin: .zero, size: labelSize)
        label.alpha = 1.0
        // Rasterise the glyphs at the external screen's native scale; a stale 1x/2x
        // contentsScale is the other half of the v1 blur.
        label.contentScaleFactor = scale
        label.layer.contentsScale = scale
        label.layer.allowsEdgeAntialiasing = true
        return label
    }

    private func makeAttributedText(
        for item: ARDanmakuItem,
        font: UIFont,
        fontSize: CGFloat
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: item.color,
        ]
        let strokeWidth = configuration.strokeWidth
        if strokeWidth > 0, fontSize > 0 {
            attributes[.strokeColor] = UIColor.black
            // NSAttributedString stroke width is a percentage of the font size and a
            // negative value means "fill + stroke" (outline around the glyphs).
            attributes[.strokeWidth] = NSNumber(
                value: Double(-(strokeWidth / fontSize) * 100.0)
            )
        }
        return NSAttributedString(string: item.text, attributes: attributes)
    }

    private static func font(forWeight value: Int, size: CGFloat) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: uiFontWeight(for: value))
    }

    /// Mirrors Flutter's `FontWeight.values[value]` (0-based) as used by canvas_danmaku:
    /// wire 4 is w500 / `.medium`, which is what the phone renders for the default.
    private static func uiFontWeight(for value: Int) -> UIFont.Weight {
        switch value {
        case 1:
            return .thin
        case 2:
            return .light
        case 3:
            return .regular
        case 4:
            return .medium
        case 5:
            return .semibold
        case 6:
            return .bold
        case 7:
            return .heavy
        default:
            return .black
        }
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
