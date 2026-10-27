//
//  ARDisplayManager.swift
//  Runner
//
//  "AR glasses" playback (external display) for iOS 27.
//
//  Mirrors `airplay-notes/protocol.md`:
//
//   Flutter --MethodChannel "com.predidit.kazumi/ar_display"--> ARDisplayManager
//   Flutter <--EventChannel  "com.predidit.kazumi/ar_display_events"-- ARDisplayManager
//
//   ARDisplayManager (singleton, main actor)
//    |- UISceneAccessoryRegistration (iOS 27): keeps the external display scene alive
//    |- AVPlayer / AVPlayerItem          (custom HTTP headers, 250 ms position feed)
//    `- ARDisplaySceneDelegate -> UIWindow(windowScene:) -> ARDisplayPlayerViewController
//    `- ARDanmakuOverlayView (native danmaku)
//
//  Everything is driven from the main thread. AVFoundation delivers KVO
//  notifications and item notifications on internal queues, so those callbacks are
//  funnelled back onto the main actor before touching any state.
//

import AVFoundation
import Flutter
import UIKit

// MARK: - Helpers

/// Funnels a callback onto the main actor.
///
/// Used for AVFoundation KVO / notification callbacks, which are not guaranteed to be
/// delivered on the main thread. `Task` is used instead of `DispatchQueue.main.async`
/// so the closure can legally touch main-actor isolated state.
private func arRunOnMainActor(_ body: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        body()
    }
}

private func arLog(_ message: @autoclosure () -> String) {
    NSLog("[Kazumi][ARDisplay] %@", message())
}

// MARK: - Event plumbing

/// Thread-safe holder for the Flutter event sink.
///
/// The sink is installed by a `FlutterStreamHandler` (called by the engine) and consumed
/// by the manager on the main thread, so a small lock is enough.
final class ARDisplayEventSinkBox: NSObject {

    private let lock = NSLock()
    private var sink: FlutterEventSink?

    var eventSink: FlutterEventSink? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return sink
        }
        set {
            lock.lock()
            sink = newValue
            lock.unlock()
        }
    }
}

/// `FlutterStreamHandler` for the event channel; keeps the sink in a shared box and
/// tells the manager when Dart starts listening so it can replay the current state.
final class ARDisplayEventRelay: NSObject, FlutterStreamHandler {

    private let sinkBox: ARDisplayEventSinkBox
    private weak var manager: ARDisplayManager?

    init(sinkBox: ARDisplayEventSinkBox, manager: ARDisplayManager) {
        self.sinkBox = sinkBox
        self.manager = manager
        super.init()
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sinkBox.eventSink = events
        // The manager is main-actor isolated; the engine calls this on the platform thread,
        // so hop onto the main actor before touching any state.
        arRunOnMainActor { [weak self] in
            self?.manager?.handleEventChannelDidStartListening()
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sinkBox.eventSink = nil
        return nil
    }
}

// MARK: - Manager

/// Handles the `ar_display` channel, the scene accessory and the AVPlayer lifecycle.
///
/// Main-actor isolated: every public entry point is called from the Flutter platform
/// thread (main) or from the scene delegate / player callbacks, and all UIKit and
/// AVPlayer mutation happens here.
@MainActor
final class ARDisplayManager: NSObject {

    static let shared = ARDisplayManager()

    // MARK: Channel names

    private static let methodChannelName = "com.predidit.kazumi/ar_display"
    private static let eventChannelName = "com.predidit.kazumi/ar_display_events"
    private static let startTimeoutSeconds: TimeInterval = 8.0
    /// One-shot presentation kick when the accessory scene is still missing after `start`.
    private static let startKickSeconds: TimeInterval = 2.5
    /// A kick toggles `isEnabled=false` for this long before enabling it again.
    private static let accessoryKickGapSeconds: TimeInterval = 0.25
    /// After the pre-registration the accessory normally connects immediately; if the glasses
    /// were already plugged in (app launched into mirroring) one kick is needed.
    private static let preRegistrationKickSeconds: TimeInterval = 2.0
    private static let stateEventIntervalSeconds: Double = 0.25

    /// Container extensions AVPlayer cannot decode on iOS. Rejecting them up front produces the
    /// documented `该本地视频格式不支持投放` error instead of a generic AVFoundation failure.
    private static let unsupportedLocalFileExtensions: Set<String> = [
        "flv", "mkv", "avi", "wmv", "rmvb", "rm", "webm", "ogv", "vob",
    ]

    // MARK: Flutter

    private let eventSinkBox = ARDisplayEventSinkBox()
    private var methodChannel: FlutterMethodChannel?
    private var eventRelay: ARDisplayEventRelay?

    // MARK: Scene accessory (iOS 27+)

    /// `UISceneAccessoryRegistration` only exists on iOS 27+, and a stored property of that
    /// type would force this whole class to be iOS 27-only. The type-safe accessor below
    /// narrows it back inside `#available` blocks.
    private var accessoryRegistrationStorage: Any?
    private weak var accessoryHostViewController: UIViewController?
    private var sceneDelegate: ARDisplaySceneDelegate?
    private weak var externalWindowScene: UIWindowScene?
    private var displayViewController: ARDisplayPlayerViewController?
    private var isDisplayConnected = false
    private var screenWidth = 0
    private var screenHeight = 0
    /// Fallback path for iOS builds where the scene accessory never connects but the wired
    /// display is still exposed as a `UIScreen` (classic multiple-display API).
    private var legacyExternalWindow: UIWindow?
    private var screenConnectObserver: NSObjectProtocol?
    private var screenDisconnectObserver: NSObjectProtocol?

    // MARK: Playback

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var periodicTimeObserver: Any?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var playbackEndedObserver: NSObjectProtocol?
    private var playbackFailedObserver: NSObjectProtocol?
    private var playbackSpeed: Float = 1.0
    private var playbackEnded = false
    private var lastKnownError: String?
    private var pendingStartPositionMilliseconds: Double = 0
    private var isTearingDown = false

    // MARK: Danmaku configuration

    private var danmakuItems: [ARDanmakuItem] = []
    private var danmakuEnabled = true
    private var danmakuConfig = ARDanmakuConfig.default
    private var superResolutionRequested = false
    private var superResolutionQuality = false
    /// True when the current item actually carries the Core Image video composition.
    private var superResolutionApplied = false
    /// Last validated media source, kept so a failed SR composition can be retried without it.
    private var lastStartSource: ARStartSource?
    private var didFallbackFromSuperResolution = false

    // MARK: Local playback

    /// Serves a local `.m3u8` + `seg_*.ts` pair; must stay alive while the session lasts.
    private var localResourceLoaderDelegate: AVAssetResourceLoaderDelegate?
    private var localHLSAsset: AVURLAsset?
    /// True when the current session plays a local file (error messages differ).
    private var isLocalPlaybackSession = false
    /// True when the current local session is HLS (playlist served via the resource loader).
    private var isLocalHLSSession = false

    // MARK: Accessory presentation retries

    private var accessoryKickWorkItem: DispatchWorkItem?
    private var startKickWorkItem: DispatchWorkItem?
    private var preRegistrationRetryCount = 0
    private var preRegistrationKickScheduled = false
    /// `true` while our own `isEnabled=false -> true` kick is in flight. A scene that connects
    /// and immediately disconnects inside this window is an expected side effect of the kick,
    /// not a user unplug: the pending `start` / player must survive it.
    private var isKickInProgress = false

    // MARK: Pending `start`

    private var startPendingResult: FlutterResult?
    private var startTimeoutWorkItem: DispatchWorkItem?

    // MARK: - Init

    private override init() {
        super.init()
    }

    /// Registers the method / event channel on the Flutter engine's messenger.
    ///
    /// Called from `AppDelegate.didInitializeImplicitFlutterEngine`, i.e. once, on the main
    /// thread, before the Dart isolate starts.
    func attach(with messenger: FlutterBinaryMessenger) {
        guard methodChannel == nil else { return }

        let channel = FlutterMethodChannel(
            name: ARDisplayManager.methodChannelName,
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            arRunOnMainActor {
                self?.handle(call: call, result: result)
            }
        }
        methodChannel = channel

        let events = FlutterEventChannel(
            name: ARDisplayManager.eventChannelName,
            binaryMessenger: messenger
        )
        let relay = ARDisplayEventRelay(sinkBox: eventSinkBox, manager: self)
        events.setStreamHandler(relay)
        eventRelay = relay
    }

    /// Schedules the permanent accessory pre-registration; called once by `AppDelegate`
    /// shortly after the implicit Flutter engine is ready.
    ///
    /// `nonisolated` on purpose: `AppDelegate.didInitializeImplicitFlutterEngine` runs on the
    /// engine callback thread and only has to hand off a delay, not touch main-actor state.
    nonisolated static func scheduleAccessoryPreRegistration(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.0, delay)) {
            arRunOnMainActor {
                ARDisplayManager.shared.prepareAccessoryRegistrationIfNeeded()
            }
        }
    }

    /// Logs a step to the device console *and* forwards it to Dart so it shows up in the
    /// in-app log page ("设置 → 日志") for on-device diagnostics.
    private func logStep(_ message: String) {
        arLog(message)
        if let sink = eventSinkBox.eventSink {
            sink(["type": "log", "message": message])
        }
    }

    /// Replays the current state when Dart (re)starts listening on the event channel.
    ///
    /// Called by `ARDisplayEventRelay.onListen`, which may run before any playback exists.
    func handleEventChannelDidStartListening() {
        if isDisplayConnected {
            sendEvent([
                "type": "connected",
                "width": screenWidth,
                "height": screenHeight,
            ])
        }
        if player != nil {
            sendStateEvent()
        }
    }

    // MARK: - Method dispatch

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getState":
            handleGetState(result: result)
        case "start":
            handleStart(arguments: call.arguments, result: result)
        case "play":
            handlePlay(result: result)
        case "pause":
            handlePause(result: result)
        case "seek":
            handleSeek(arguments: call.arguments, result: result)
        case "setDanmakuEnabled":
            handleSetDanmakuEnabled(arguments: call.arguments, result: result)
        case "setSpeed":
            handleSetSpeed(arguments: call.arguments, result: result)
        case "stop":
            handleStop(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - getState

    private func handleGetState(result: @escaping FlutterResult) {
        if #available(iOS 27.0, *) {
            let registration = registeredAccessory
            result([
                // `connected` keeps its v1 meaning: the external scene is actually connected.
                // The accessory being merely registered/enabled is reported separately.
                "connected": isDisplayConnected,
                "supported": true,
                "available": registration?.isAvailable ?? false,
                "enabled": registration?.isEnabled ?? false,
                "registered": registration != nil,
                "screens": UIScreen.screens.count,
                "screenWidth": screenWidth,
                "screenHeight": screenHeight,
                "windowVisible": isExternalWindowVisible(),
                "sceneState": externalSceneStateDescription(),
            ])
        } else {
            result([
                "supported": false,
                "connected": false,
                "screenWidth": 0,
                "screenHeight": 0,
            ])
        }
    }

    // MARK: - start

    private func handleStart(arguments: Any?, result: @escaping FlutterResult) {
        guard #available(iOS 27.0, *) else {
            result(ARDisplayManager.startFailure("当前系统版本不支持外接屏播放"))
            return
        }
        guard let payload = arguments as? [String: Any] else {
            result(ARDisplayManager.startFailure("参数无效"))
            return
        }
        guard let urlString = payload["url"] as? String, !urlString.isEmpty else {
            result(ARDisplayManager.startFailure("视频地址无效"))
            return
        }
        let isLocalFile = (payload["isLocalFile"] as? Bool) ?? false
        logStep("start: local=\(isLocalFile) url=\(String(urlString.prefix(96)))")

        // Validate (and for local files: existence + format) BEFORE touching the running
        // session, so a bad request does not stop what is already on the glasses.
        let resolution = ARDisplayManager.resolveStartSource(
            urlString: urlString,
            headers: payload["headers"],
            isLocalFile: isLocalFile
        )
        guard let source = resolution.source else {
            result(ARDisplayManager.startFailure(resolution.error ?? "视频地址无效"))
            return
        }
        guard let hostViewController = ARDisplayManager.activeFlutterViewController() else {
            result(ARDisplayManager.startFailure("无法获取当前播放页面"))
            return
        }

        // A second `start` replaces the previous session (the old call is resolved first).
        // The glasses window and the accessory registration survive: only the AVPlayer is
        // detached, so an already-connected scene is reused immediately.
        teardownPlayback()
        logStep("start: previous session torn down")

        configureAudioSession()

        lastStartSource = source
        didFallbackFromSuperResolution = false
        guard let item = makePlayerItem(
            for: source,
            superResolution: superResolutionRequested,
            quality: superResolutionQuality
        ) else {
            teardownPlayback()
            result(ARDisplayManager.startFailure("该本地视频格式不支持投放"))
            return
        }
        superResolutionApplied = item.videoComposition != nil
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.actionAtItemEnd = .pause
        logStep("start: player item ready, superResolution=\(superResolutionApplied)")

        player = newPlayer
        playerItem = item
        pendingStartPositionMilliseconds = ARDisplayManager.doubleValue(payload["positionMs"]) ?? 0
        danmakuItems = ARDisplayManager.parseDanmakuItems(payload["danmaku"])
        danmakuEnabled = (payload["danmakuEnabled"] as? Bool) ?? true
        danmakuConfig = ARDisplayManager.parseDanmakuConfig(payload)
        superResolutionRequested = (payload["superResolution"] as? Bool) ?? false
        superResolutionQuality = (payload["superResolutionQuality"] as? Bool) ?? false
        playbackSpeed = 1.0
        playbackEnded = false
        lastKnownError = nil
        installPlayerObservers(for: newPlayer, item: item)

        // The accessory is normally pre-registered ~1 s after app launch and stays enabled for
        // the whole app lifetime; this only repairs a missing registration (e.g. `start` before
        // the pre-registration timer fired).
        guard ensureAccessoryRegistration(hostViewController: hostViewController) else {
            teardownPlayback()
            result(ARDisplayManager.startFailure("外接屏不可用"))
            return
        }
        setAccessoryEnabled(true)
        logStep("start: accessory ready connected=\(isDisplayConnected) vc=\(displayViewController != nil)")

        if isDisplayConnected, displayViewController != nil {
            attachPlayerToExternalDisplay()
            result(ARDisplayManager.startSuccess())
            return
        }

        // Registered + enabled, but the scene does not exist yet: wait for it, kicking the
        // presentation once at 2.5 s, and fail after the 8 s budget.
        startPendingResult = result
        scheduleStartTimeout()
        scheduleStartKick()
    }

    private func scheduleStartTimeout() {
        startTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            arRunOnMainActor {
                self?.handleStartTimeout()
            }
        }
        startTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ARDisplayManager.startTimeoutSeconds,
            execute: workItem
        )
    }

    private func handleStartTimeout() {
        startTimeoutWorkItem = nil
        startKickWorkItem?.cancel()
        startKickWorkItem = nil
        guard startPendingResult != nil else { return }
        var available = false
        var enabled = false
        if #available(iOS 27.0, *) {
            available = registeredAccessory?.isAvailable ?? false
            enabled = registeredAccessory?.isEnabled ?? false
        }
        let screens = UIScreen.screens.count
        arLog("start timed out: available=\(available) enabled=\(enabled) screens=\(screens)")

        // Fallback 1: the accessory scene never connected, but the wired display may still be
        // exposed through the legacy UIScreen API. Try to host the player there directly.
        if attachLegacyExternalScreenIfAvailable() {
            arLog("falling back to legacy UIScreen window")
            resolvePendingStartIfPossible()
            return
        }

        guard let pending = startPendingResult else { return }
        startPendingResult = nil
        teardownPlayback()
        pending(ARDisplayManager.startFailure(
            "未检测到外接屏，请确认眼镜已用 USB‑C 连接（available=\(available) enabled=\(enabled) screens=\(screens)）"
        ))
    }

    /// Schedules the single presentation kick of a `start` that is still waiting for its scene.
    ///
    /// 2.5 s of grace before kicking: if the glasses were just plugged in, the system may be
    /// mid-handshake and an immediate disable/enable would abort it. The total budget stays at
    /// `startTimeoutSeconds` (8 s).
    private func scheduleStartKick() {
        startKickWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            arRunOnMainActor {
                self?.handleStartKick()
            }
        }
        startKickWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ARDisplayManager.startKickSeconds,
            execute: workItem
        )
    }

    private func handleStartKick() {
        startKickWorkItem = nil
        guard startPendingResult != nil, !isDisplayConnected else { return }
        logStep("start kick: scene not connected after \(ARDisplayManager.startKickSeconds)s, toggling accessory")
        kickAccessoryPresentation()
    }

    /// Classic multiple-display fallback: attach the player to `UIScreen.screens[1]`.
    ///
    /// Only used when the iOS 27 scene accessory does not connect. Returns `true` when a
    /// legacy external window is now hosting the player.
    @discardableResult
    private func attachLegacyExternalScreenIfAvailable() -> Bool {
        let screens = UIScreen.screens
        guard screens.count > 1 else { return false }
        if displayViewController != nil {
            return true
        }
        let screen = screens[1]
        let viewController = ARDisplayPlayerViewController()
        let window = UIWindow(frame: screen.bounds)
        window.screen = screen
        window.rootViewController = viewController
        window.isHidden = false
        legacyExternalWindow = window
        displayViewController = viewController
        isDisplayConnected = true
        screenWidth = Int((screen.bounds.width * screen.scale).rounded())
        screenHeight = Int((screen.bounds.height * screen.scale).rounded())
        arLog("legacy external window attached: \(screenWidth)x\(screenHeight)")
        sendEvent([
            "type": "connected",
            "width": screenWidth,
            "height": screenHeight,
        ])
        attachPlayerToExternalDisplay()
        return true
    }

    /// Pre-registers the external-display scene accessory and keeps it registered + enabled
    /// for the whole app lifetime.
    ///
    /// Device behaviour that drives this design: the system only hands the glasses scene to the
    /// app when the accessory already exists (and is enabled) *before* the external display is
    /// connected / mirrored. Registering it lazily on the first `start` therefore fails whenever
    /// the glasses were already plugged in — the scene connects but the window never presents.
    ///
    /// Called ~1 s after app launch from `AppDelegate` (via
    /// `scheduleAccessoryPreRegistration(after:)`), and again as a safety net from `start`.
    func prepareAccessoryRegistrationIfNeeded() {
        guard #available(iOS 27.0, *) else { return }
        if let registration = registeredAccessory {
            // Permanent registration: never unregister, and repair a disabled state if some
            // other component toggled it.
            if !registration.isEnabled {
                registration.isEnabled = true
                arLog("accessory was disabled; re-enabled (permanent registration)")
            }
            startObservingExternalScreens()
            return
        }
        guard let hostViewController = ARDisplayManager.activeFlutterViewController() else {
            // The root Flutter view controller is not in a window yet (~1 s after engine init
            // is usually enough, scene states can lag on cold start): retry briefly.
            schedulePreRegistrationRetry()
            return
        }
        guard ensureAccessoryRegistration(hostViewController: hostViewController) else { return }
        setAccessoryEnabled(true)
        startObservingExternalScreens()
        arLog("accessory pre-registered (enabled), available=\(registeredAccessory?.isAvailable ?? false)")
        // If the glasses were already plugged in when the app launched, the system may already
        // be mirroring: kick the presentation once shortly after pre-registration.
        schedulePreRegistrationKick()
    }

    private func schedulePreRegistrationRetry() {
        guard preRegistrationRetryCount < 20 else {
            arLog("accessory pre-registration gave up: Flutter root view controller not found")
            return
        }
        preRegistrationRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            arRunOnMainActor {
                self?.prepareAccessoryRegistrationIfNeeded()
            }
        }
    }

    private func schedulePreRegistrationKick() {
        guard !preRegistrationKickScheduled else { return }
        preRegistrationKickScheduled = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ARDisplayManager.preRegistrationKickSeconds
        ) { [weak self] in
            arRunOnMainActor {
                guard let self = self else { return }
                guard #available(iOS 27.0, *) else { return }
                guard !self.isDisplayConnected,
                      let registration = self.registeredAccessory
                else { return }
                self.logStep("pre-registration kick: scene not connected (enabled=\(registration.isEnabled))")
                self.kickAccessoryPresentation()
            }
        }
    }

    private func startObservingExternalScreens() {
        guard screenConnectObserver == nil else { return }
        screenConnectObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.didConnectNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            arLog("UIScreen did connect, count=\(UIScreen.screens.count)")
            arRunOnMainActor {
                self?.handleExternalScreenDidConnect()
            }
        }
        screenDisconnectObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.didDisconnectNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let manager = self else { return }
            arRunOnMainActor {
                guard manager.legacyExternalWindow != nil else { return }
                arLog("legacy external screen disconnected")
                manager.handleLegacyExternalScreenDisconnected()
            }
        }
    }

    /// Called when the system reports a newly attached external screen.
    ///
    /// The accessory is normally already enabled (it is kept enabled for the app lifetime), so
    /// this mostly records diagnostics; if a `start` is waiting and the registration got
    /// disabled somehow, it is re-enabled here (protocol-v2 §二.5).
    private func handleExternalScreenDidConnect() {
        guard #available(iOS 27.0, *) else {
            // iOS < 27: only the classic multiple-display path exists.
            if attachLegacyExternalScreenIfAvailable() {
                resolvePendingStartIfPossible()
            }
            return
        }
        guard let registration = registeredAccessory else {
            arLog("external screen connected but the accessory is not registered yet")
            return
        }
        if !registration.isEnabled {
            registration.isEnabled = true
            arLog("external screen connected while start pending: accessory re-enabled")
        } else {
            arLog("external screen connected: accessory enabled, pending=\(startPendingResult != nil)")
        }
    }

    /// The legacy `UIScreen` fallback lost its display; the accessory scene path is unaffected.
    private func handleLegacyExternalScreenDisconnected() {
        let wasConnected = isDisplayConnected
        if startPendingResult != nil {
            flushPendingStart(failureMessage: "外接屏已断开")
        }
        if player != nil {
            teardownPlayback()
        }
        closeLegacyExternalWindow()
        if wasConnected {
            sendEvent(["type": "disconnected"])
        }
    }

    private func resolvePendingStartIfPossible() {
        guard player != nil, isDisplayConnected else { return }
        guard let pending = startPendingResult else { return }
        startTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil
        startPendingResult = nil
        pending(ARDisplayManager.startSuccess())
    }

    private func flushPendingStart(failureMessage: String) {
        startTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil
        guard let pending = startPendingResult else { return }
        startPendingResult = nil
        pending(ARDisplayManager.startFailure(failureMessage))
    }

    // MARK: - Transport

    private func handlePlay(result: @escaping FlutterResult) {
        startPlayback()
        sendStateEvent()
        result(nil)
    }

    private func handlePause(result: @escaping FlutterResult) {
        player?.pause()
        displayViewController?.setDanmakuPaused(true)
        sendStateEvent()
        result(nil)
    }

    private func handleSeek(arguments: Any?, result: @escaping FlutterResult) {
        let payload = arguments as? [String: Any]
        if let positionMs = ARDisplayManager.doubleValue(payload?["positionMs"]) {
            playbackEnded = false
            applySeek(toMilliseconds: positionMs)
        }
        sendStateEvent()
        result(nil)
    }

    private func handleSetDanmakuEnabled(arguments: Any?, result: @escaping FlutterResult) {
        if let payload = arguments as? [String: Any],
           let enabled = payload["enabled"] as? Bool {
            danmakuEnabled = enabled
            displayViewController?.setDanmakuEnabled(enabled)
        }
        result(nil)
    }

    private func handleSetSpeed(arguments: Any?, result: @escaping FlutterResult) {
        if let payload = arguments as? [String: Any],
           let rawSpeed = ARDisplayManager.doubleValue(payload["speed"]) {
            let clamped = min(max(rawSpeed, 0.25), 4.0)
            playbackSpeed = Float(clamped)
            if let player = player, player.rate != 0 {
                player.rate = playbackSpeed
            }
            sendStateEvent()
        }
        result(nil)
    }

    private func handleStop(result: @escaping FlutterResult) {
        let positionMs = currentPositionMilliseconds()
        let durationMs = currentDurationMilliseconds()
        teardownPlayback()
        result([
            "positionMs": positionMs,
            "durationMs": durationMs,
        ])
    }

    // MARK: - Playback control

    private func startPlayback() {
        guard let player = player else { return }
        playbackEnded = false
        if let item = playerItem {
            let durationSeconds = item.duration.seconds
            let currentSeconds = player.currentTime().seconds
            if durationSeconds.isFinite,
               durationSeconds > 0,
               currentSeconds.isFinite,
               currentSeconds >= durationSeconds - 0.05 {
                applySeek(toMilliseconds: 0)
            }
        }
        if playbackSpeed != 1.0 {
            player.playImmediately(atRate: playbackSpeed)
        } else {
            player.play()
        }
        // A replay after playback-end / a `play` from the remote page: leave the idle page.
        displayViewController?.showIdleState(false)
        displayViewController?.setDanmakuPaused(false)
    }

    private func applySeek(toMilliseconds positionMs: Double) {
        guard let player = player else { return }
        let clamped = positionMs.isFinite ? max(0, positionMs) : 0
        let time = CMTime(seconds: clamped / 1000.0, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        displayViewController?.seekDanmaku(toMilliseconds: clamped)
    }

    private func attachPlayerToExternalDisplay() {
        guard let viewController = displayViewController, let player = player else { return }
        // Re-assert the window at start time too: the scene can be connected while the system
        // is still mirroring the phone (the `windowVisible` diagnostic covers this case).
        assertExternalWindowVisible()
        viewController.attach(player: player)
        viewController.configureDanmaku(
            items: danmakuItems,
            enabled: danmakuEnabled,
            config: danmakuConfig
        )
        viewController.showIdleState(false)
        applySeek(toMilliseconds: pendingStartPositionMilliseconds)
        startPlayback()
        sendStateEvent()
    }

    // MARK: - External scene lifecycle

    func handleExternalSceneConnected(windowScene: UIWindowScene, sceneDelegate: ARDisplaySceneDelegate) {
        guard accessoryRegistrationStorage != nil else {
            // A scene for an already-unregistered accessory: keep the glasses black.
            sceneDelegate.closeWindow()
            return
        }
        // If the legacy `UIScreen` fallback was hosting the player, hand the display over to
        // the accessory scene's window (it is the primary path and is now connected).
        if legacyExternalWindow != nil {
            arLog("accessory scene connected: closing the legacy external window")
            legacyExternalWindow?.isHidden = true
            legacyExternalWindow?.rootViewController = nil
            legacyExternalWindow = nil
        }
        self.sceneDelegate = sceneDelegate
        self.externalWindowScene = windowScene
        self.displayViewController = sceneDelegate.playerViewController
        isDisplayConnected = true
        isKickInProgress = false
        startKickWorkItem?.cancel()
        startKickWorkItem = nil
        updateScreenMetrics(from: windowScene)
        sendEvent([
            "type": "connected",
            "width": screenWidth,
            "height": screenHeight,
            "windowVisible": isExternalWindowVisible(),
        ])
        // Re-assert visibility on the next runloop: some iOS builds create the accessory scene
        // while the phone display is still being mirrored.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.assertExternalWindowVisible()
            self.sendStateEvent()
        }
        // A player may already exist (a `start` waiting for this scene, or a reconnect while
        // playing); otherwise the glasses show the idle page.
        attachPlayerToExternalDisplay()
        if player == nil, let viewController = displayViewController {
            viewController.showIdleState(true)
        }
        resolvePendingStartIfPossible()
    }

    func handleExternalSceneDisconnected() {
        let wasConnected = isDisplayConnected
        displayViewController = nil
        sceneDelegate = nil
        externalWindowScene = nil
        screenWidth = 0
        screenHeight = 0
        isDisplayConnected = false
        // This disconnect was caused by our own `isEnabled=false -> true` kick: the system is
        // re-presenting the accessory. Keep the pending `start` and the player so the fresh
        // scene can attach them again (a real unplug still ends via the start timeout).
        if isKickInProgress {
            arLog("external scene disconnected during an accessory kick; keeping the session")
            return
        }
        startKickWorkItem?.cancel()
        startKickWorkItem = nil
        accessoryKickWorkItem?.cancel()
        accessoryKickWorkItem = nil
        // The scene (and its window) is gone: a pending `start` can never succeed and the
        // player cannot be shown anywhere, so both are torn down exactly once here.
        if startPendingResult != nil {
            flushPendingStart(failureMessage: "外接屏已断开，请确认眼镜已用 USB‑C 连接")
        }
        if player != nil {
            teardownPlayback()
        }
        if wasConnected {
            sendEvent(["type": "disconnected"])
        }
    }

    /// Called from `ARDisplaySceneDelegate.sceneDidBecomeActive`.
    ///
    /// Re-asserts the window (some systems need it after the phone was locked or the accessory
    /// was re-presented) and refreshes the reported metrics without re-sending `connected`.
    func handleExternalSceneBecameActive(windowScene: UIWindowScene) {
        guard let currentScene = externalWindowScene, currentScene === windowScene else { return }
        updateScreenMetrics(from: windowScene)
        assertExternalWindowVisible()
        if player == nil {
            displayViewController?.showIdleState(true)
        }
        arLog("external scene became active: windowVisible=\(isExternalWindowVisible())")
    }

    /// Whether our external-display window is actually on screen (not just created).
    private func isExternalWindowVisible() -> Bool {
        if let window = sceneDelegate?.window {
            return !window.isHidden && window.windowScene != nil
        }
        if let window = legacyExternalWindow {
            return !window.isHidden
        }
        return false
    }

    private func assertExternalWindowVisible() {
        if let window = sceneDelegate?.window {
            let needsPresentation = window.isHidden || window.windowScene == nil
            if needsPresentation {
                window.isHidden = false
                if !window.isKeyWindow {
                    window.makeKey()
                }
            }
        } else if let window = legacyExternalWindow, window.isHidden {
            window.isHidden = false
        }
    }

    private func externalSceneStateDescription() -> String {
        if let scene = externalWindowScene {
            return String(describing: scene.activationState)
        }
        return legacyExternalWindow == nil ? "none" : "legacy"
    }

    private func updateScreenMetrics(from windowScene: UIWindowScene) {
        let screen = windowScene.screen
        let bounds = screen.bounds
        let scale = screen.scale
        screenWidth = Int((bounds.width * scale).rounded())
        screenHeight = Int((bounds.height * scale).rounded())
        if screenWidth <= 0 {
            screenWidth = Int(bounds.width.rounded())
        }
        if screenHeight <= 0 {
            screenHeight = Int(bounds.height.rounded())
        }
    }

    // MARK: - Accessory registration (iOS 27+)

    @available(iOS 27.0, *)
    private var registeredAccessory: UISceneAccessoryRegistration? {
        get {
            return accessoryRegistrationStorage as? UISceneAccessoryRegistration
        }
        set {
            accessoryRegistrationStorage = newValue
        }
    }

    @available(iOS 27.0, *)
    private func ensureAccessoryRegistration(hostViewController: UIViewController) -> Bool {
        if registeredAccessory != nil {
            accessoryHostViewController = hostViewController
            return true
        }
        // Follow Apple's iOS 27 sample exactly: a *nameless* configuration whose role the
        // system fills in for the accessory (a named configuration would be looked up in the
        // Info.plist scene manifest, which is the alternative wiring and did not connect in
        // our first attempt), with only the scene delegate class set.
        let configuration = UISceneConfiguration()
        configuration.delegateClass = ARDisplaySceneDelegate.self
        // Use the variant without `userInfo`: the `userInfo:` overload takes a
        // non-optional `Any` (verified by the Xcode 27 SDK build), and we do not
        // need to pass extra context to the scene delegate.
        let accessory = UISceneAccessory.externalNonInteractive(
            sceneConfiguration: configuration
        )
        let registration = hostViewController.registerSceneAccessory(accessory)
        // Start enabled: the system only hands the external-display scene to accessories that
        // are already enabled when the display (or the app) comes up.
        registration.isEnabled = true
        registeredAccessory = registration
        accessoryHostViewController = hostViewController
        startObservingExternalScreens()
        arLog("accessory registered, available=\(registration.isAvailable)")
        return true
    }

    /// Toggles `isEnabled` off/on to make the system re-evaluate presenting the accessory.
    /// Needed when the external display was already mirroring when the accessory got enabled.
    ///
    /// The accessory registration itself is permanent: after the gap it is always re-enabled.
    private func kickAccessoryPresentation() {
        guard #available(iOS 27.0, *) else { return }
        guard let registration = registeredAccessory, !isDisplayConnected else { return }
        registration.isEnabled = false
        isKickInProgress = true
        accessoryKickWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            arRunOnMainActor {
                guard let self = self else { return }
                guard #available(iOS 27.0, *) else { return }
                self.registeredAccessory?.isEnabled = true
                self.isKickInProgress = false
                self.accessoryKickWorkItem = nil
                arLog("accessory presentation kick applied (isEnabled=true)")
            }
        }
        accessoryKickWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ARDisplayManager.accessoryKickGapSeconds,
            execute: workItem
        )
    }

    @available(iOS 27.0, *)
    private func setAccessoryEnabled(_ enabled: Bool) {
        guard let registration = registeredAccessory else { return }
        if registration.isEnabled != enabled {
            registration.isEnabled = enabled
        }
    }

    // MARK: - Teardown

    /// Tears down the AVPlayer session but keeps the external window + accessory registration
    /// alive (the glasses switch to the idle page and the next `start` is immediate).
    ///
    /// The accessory is never unregistered and never disabled here: the device only presents
    /// the glasses scene to an accessory that was enabled *before* the display connected, so
    /// tearing it down on `stop` would break the next projection.
    private func teardownPlayback() {
        guard !isTearingDown else { return }
        isTearingDown = true
        defer { isTearingDown = false }

        flushPendingStart(failureMessage: "播放已停止")
        startTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil
        startKickWorkItem?.cancel()
        startKickWorkItem = nil

        removePlayerObservers()
        if let player = player {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        player = nil
        playerItem = nil
        releaseLocalPlaybackResources()
        playbackEnded = false
        lastKnownError = nil
        playbackSpeed = 1.0
        pendingStartPositionMilliseconds = 0
        danmakuItems = []

        // Keep the external window and the accessory registration alive: the glasses switch to
        // the idle page and the next `start` is available immediately (no mirroring in between).
        superResolutionApplied = false
        didFallbackFromSuperResolution = false
        if let viewController = displayViewController {
            viewController.attach(player: nil)
            viewController.configureDanmaku(items: [], enabled: danmakuEnabled, config: danmakuConfig)
            viewController.showIdleState(true)
        }
        deactivateAudioSessionIfNeeded()
    }

    /// Drops the strong references that kept a local HLS resource loader / asset alive.
    private func releaseLocalPlaybackResources() {
        localHLSAsset?.resourceLoader.setDelegate(nil, queue: nil)
        localHLSAsset = nil
        localResourceLoaderDelegate = nil
        isLocalPlaybackSession = false
        isLocalHLSSession = false
    }

    /// Closes the legacy `UIScreen` fallback window (the accessory scene path keeps its window).
    private func closeLegacyExternalWindow() {
        legacyExternalWindow?.isHidden = true
        legacyExternalWindow?.rootViewController = nil
        legacyExternalWindow = nil
        screenWidth = 0
        screenHeight = 0
        if sceneDelegate == nil {
            displayViewController = nil
            isDisplayConnected = false
        }
    }

    // MARK: - Player observers

    private func installPlayerObservers(for player: AVPlayer, item: AVPlayerItem) {
        let interval = CMTime(
            seconds: ARDisplayManager.stateEventIntervalSeconds,
            preferredTimescale: 600
        )
        periodicTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            arRunOnMainActor {
                self?.sendStateEvent()
            }
        }

        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            arRunOnMainActor {
                self?.handleTimeControlStatusChanged()
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] _, _ in
            arRunOnMainActor {
                self?.handlePlayerItemStatusChanged()
            }
        }

        playbackEndedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            arRunOnMainActor {
                self?.handlePlaybackEnded()
            }
        }

        playbackFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            // The item's `error` is read on the main actor instead of pulling the
            // notification's userInfo key apart on an unknown thread.
            arRunOnMainActor {
                self?.handlePlaybackFailed(message: nil)
            }
        }
    }

    private func removePlayerObservers() {
        if let token = periodicTimeObserver, let player = player {
            player.removeTimeObserver(token)
        }
        periodicTimeObserver = nil
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let observer = playbackEndedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        playbackEndedObserver = nil
        if let observer = playbackFailedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        playbackFailedObserver = nil
    }

    private func handleTimeControlStatusChanged() {
        guard let player = player else { return }
        if player.timeControlStatus == .playing {
            playbackEnded = false
        }
        displayViewController?.setDanmakuPaused(player.timeControlStatus == .paused)
        sendStateEvent()
    }

    private func handlePlayerItemStatusChanged() {
        guard let item = playerItem else { return }
        switch item.status {
        case .failed:
            if attemptRetryWithoutSuperResolution(reason: item.error?.localizedDescription) {
                return
            }
            handlePlaybackFailed(message: item.error?.localizedDescription)
        case .readyToPlay:
            if lastKnownError != nil {
                lastKnownError = nil
                sendStateEvent()
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func handlePlaybackEnded() {
        // Ignore late callbacks that were already in flight while the session was torn down.
        guard player != nil else { return }
        playbackEnded = true
        displayViewController?.setDanmakuPaused(true)
        displayViewController?.stopDanmaku()
        // Playback finished: the glasses go back to the idle page (the external window and the
        // accessory registration stay alive for the next `start`).
        displayViewController?.showIdleState(true)
        sendStateEvent()
    }

    private func handlePlaybackFailed(message: String?) {
        guard player != nil else { return }
        var text = message ?? playerItem?.error?.localizedDescription ?? "视频播放失败"
        if isLocalPlaybackSession && !isLocalHLSSession {
            // AVPlayer cannot decode this local container: report the documented message
            // instead of a generic AVFoundation error.
            text = "该本地视频格式不支持投放"
        }
        lastKnownError = text
        sendEvent(["type": "error", "message": text])
        sendStateEvent()
    }

    // MARK: - Events

    private func sendEvent(_ payload: [String: Any]) {
        guard let sink = eventSinkBox.eventSink else { return }
        sink(payload)
    }

    private func sendStateEvent() {
        guard let player = player else { return }
        let timeControlStatus = player.timeControlStatus
        var payload: [String: Any] = [
            "type": "state",
            "playing": timeControlStatus == .playing,
            "positionMs": currentPositionMilliseconds(),
            "durationMs": currentDurationMilliseconds(),
            "buffering": timeControlStatus == .waitingToPlayAtSpecifiedRate,
            "ended": playbackEnded,
            "windowVisible": isExternalWindowVisible(),
            "sceneState": externalSceneStateDescription(),
            "upscalerActive": superResolutionApplied,
            "speed": Double(playbackSpeed),
        ]
        if let lastKnownError = lastKnownError {
            payload["error"] = lastKnownError
        } else {
            payload["error"] = NSNull()
        }
        sendEvent(payload)
    }

    private func currentPositionMilliseconds() -> Int {
        guard let player = player else { return 0 }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * 1000.0).rounded())
    }

    private func currentDurationMilliseconds() -> Int {
        guard let item = playerItem else { return 0 }
        let seconds = item.duration.seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * 1000.0).rounded())
    }

    /// Wraps an asset into an `AVPlayerItem` and optionally applies the SR video composition.
    private func makeItem(
        asset: AVURLAsset,
        superResolution: Bool,
        quality: Bool
    ) -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        if superResolution,
           let composition = ARDisplayManager.makeSuperResolutionComposition(
               asset: asset,
               quality: quality
           ) {
            item.videoComposition = composition
        }
        return item
    }

    /// Builds the Core Image video composition used for AR-side super resolution.
    ///
    /// Apple's `AVVideoComposition(applyingCIFiltersWithHandler:)` runs the filter graph inside
    /// AVFoundation's own pipeline (timing, audio and vsync stay untouched), which is far more
    /// robust than rendering frames by hand: Lanczos upscale to the glasses' 1920x1080 output,
    /// then luminance sharpening. On unsupported assets the item simply fails and the caller
    /// retries without the composition.
    private static func makeSuperResolutionComposition(
        asset: AVAsset,
        quality: Bool
    ) -> AVVideoComposition? {
        let renderSize = CGSize(width: 1920, height: 1080)
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage
            let extent = source.extent
            guard extent.width > 1, extent.height > 1,
                  extent.width.isFinite, extent.height.isFinite
            else {
                request.finish(with: request.sourceImage, context: nil)
                return
            }
            let scale = min(renderSize.width / extent.width, renderSize.height / extent.height)
            var image = source
            if abs(scale - 1.0) > 0.001 {
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputAspectRatioKey: 1.0,
                ])
            }
            let scaledExtent = image.extent
            image = image.transformed(by: CGAffineTransform(
                translationX: (renderSize.width - scaledExtent.width) / 2 - scaledExtent.origin.x,
                y: (renderSize.height - scaledExtent.height) / 2 - scaledExtent.origin.y
            ))
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: quality ? 0.8 : 0.5,
            ])
            let target = CGRect(origin: .zero, size: renderSize)
            let background = CIImage(color: CIColor.black).cropped(to: target)
            let composed = image.composited(over: background).cropped(to: target)
            request.finish(with: composed, context: nil)
        }
        composition.renderSize = renderSize
        return composition
    }

    /// Retries the current item without the SR composition when AVFoundation rejects it.
    private func attemptRetryWithoutSuperResolution(reason: String?) -> Bool {
        guard superResolutionApplied,
              !didFallbackFromSuperResolution,
              let source = lastStartSource,
              let player = player
        else {
            return false
        }
        didFallbackFromSuperResolution = true
        let position = pendingStartPositionMilliseconds > 0
            ? pendingStartPositionMilliseconds
            : Double(currentPositionMilliseconds())
        logStep("super resolution item failed (\(reason ?? "unknown")), retrying without it")
        guard let plainItem = makePlayerItem(
            for: source,
            superResolution: false,
            quality: false
        ) else {
            return false
        }
        superResolutionApplied = false
        removePlayerObservers()
        playerItem = plainItem
        installPlayerObservers(for: player, item: plainItem)
        player.replaceCurrentItem(with: plainItem)
        applySeek(toMilliseconds: position)
        startPlayback()
        sendStateEvent()
        return true
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            // Not fatal: the glasses may still show the video even if audio routing fails.
            arLog("audio session setup failed: \(error.localizedDescription)")
        }
    }

    /// Releases the AVAudioSession we activated for external playback.
    ///
    /// Without this the session stays active/owned by the `.moviePlayback` configuration, and
    /// the phone-side media_kit / audio_service re-initialisation after "结束投屏" could hang at
    /// "播放器加载中".
    private func deactivateAudioSessionIfNeeded() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            logStep("audio session released")
        } catch {
            arLog("audio session release failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Root Flutter view controller lookup

    private static func activeFlutterViewController() -> FlutterViewController? {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = windowScenes.sorted { lhs, rhs in
            scenePriority(lhs) > scenePriority(rhs)
        }
        for windowScene in ordered {
            let windows = windowScene.windows
            let keyWindow = windows.first(where: { $0.isKeyWindow }) ?? windows.first
            guard let rootViewController = keyWindow?.rootViewController else { continue }
            if let flutterViewController = firstFlutterViewController(in: rootViewController) {
                return flutterViewController
            }
        }
        return nil
    }

    private static func scenePriority(_ scene: UIWindowScene) -> Int {
        switch scene.activationState {
        case .foregroundActive:
            return 3
        case .foregroundInactive:
            return 2
        case .background:
            return 1
        case .unattached:
            return 0
        @unknown default:
            return 0
        }
    }

    private static func firstFlutterViewController(in viewController: UIViewController) -> FlutterViewController? {
        if let flutterViewController = viewController as? FlutterViewController {
            return flutterViewController
        }
        for child in viewController.children {
            if let found = firstFlutterViewController(in: child) {
                return found
            }
        }
        if let presented = viewController.presentedViewController {
            return firstFlutterViewController(in: presented)
        }
        return nil
    }

    // MARK: - Payload parsing

    /// A validated `start` media source.
    private enum ARStartSource {
        /// Network URL played directly with the custom HTTP headers.
        case remote(url: URL, headers: [String: String])
        /// Single local file (`mp4` / `mov` / `m4v` / ...), played from a plain `file://` URL.
        case localFile(fileURL: URL)
        /// Local HLS playlist; served through `ARLocalHLSResourceLoader`.
        case localHLS(playlistURL: URL)
    }

    /// Validates the `start` arguments without touching the current session.
    ///
    /// Keys read from the payload: `url`, `headers`, `isLocalFile` (the rest of `start` is read
    /// by `handleStart`). When `isLocalFile` is true `url` is a filesystem path (an optional
    /// `file://` prefix is stripped); it is never sent through the network path.
    private static func resolveStartSource(
        urlString: String,
        headers rawHeaders: Any?,
        isLocalFile: Bool
    ) -> (source: ARStartSource?, error: String?) {
        if !isLocalFile {
            let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let url = URL(string: trimmed),
                  let scheme = url.scheme,
                  !scheme.isEmpty
            else {
                return (nil, "视频地址无效")
            }
            return (.remote(url: url, headers: headerFields(from: rawHeaders)), nil)
        }

        let path = localFilePath(from: urlString)
        guard !path.isEmpty else { return (nil, "本地视频文件不存在") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return (nil, "本地视频文件不存在")
        }
        let fileURL = URL(fileURLWithPath: path)
        let pathExtension = fileURL.pathExtension.lowercased()
        if pathExtension == "m3u8" || pathExtension == "m3u" {
            // AVPlayer cannot open a local playlist directly: serve it (and its sibling
            // segments) through the custom scheme below.
            return (.localHLS(playlistURL: fileURL), nil)
        }
        if unsupportedLocalFileExtensions.contains(pathExtension) {
            return (nil, "该本地视频格式不支持投放")
        }
        return (.localFile(fileURL: fileURL), nil)
    }

    /// Builds the `AVPlayerItem` for a validated source.
    ///
    /// Local single files use a plain `file://` URL; local HLS playlists are re-served under
    /// `kazumi-local://local/<playlist.m3u8>` so AVFoundation asks the resource loader for both
    /// the playlist and the sibling `seg_*.ts` files. Network sources keep the HTTP headers.
    private func makePlayerItem(
        for source: ARStartSource,
        superResolution: Bool,
        quality: Bool
    ) -> AVPlayerItem? {
        releaseLocalPlaybackResources()
        switch source {
        case .remote(let url, let headers):
            isLocalPlaybackSession = false
            isLocalHLSSession = false
            let asset: AVURLAsset
            if headers.isEmpty {
                asset = AVURLAsset(url: url)
            } else {
                // `AVURLAssetHTTPHeaderFieldsKey` is a private-but-widely-used AVFoundation
                // key; the app already relies on it in `openVideoWithReferer`.
                asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            }
            return makeItem(
                asset: asset,
                superResolution: superResolution,
                quality: quality
            )

        case .localFile(let fileURL):
            isLocalPlaybackSession = true
            isLocalHLSSession = false
            arLog("local file playback: \(fileURL.lastPathComponent)")
            return makeItem(
                asset: AVURLAsset(url: fileURL),
                superResolution: superResolution,
                quality: quality
            )

        case .localHLS(let playlistURL):
            isLocalPlaybackSession = true
            isLocalHLSSession = true
            var components = URLComponents()
            components.scheme = ARLocalHLSResourceLoader.customScheme
            components.host = ARLocalHLSResourceLoader.customHost
            components.path = "/" + playlistURL.lastPathComponent
            guard let customURL = components.url else { return nil }
            let loader = ARLocalHLSResourceLoader(
                directory: playlistURL.deletingLastPathComponent()
            )
            let asset = AVURLAsset(url: customURL)
            asset.resourceLoader.setDelegate(
                loader,
                queue: DispatchQueue.global(qos: .userInitiated)
            )
            localResourceLoaderDelegate = loader
            localHLSAsset = asset
            arLog("local HLS playback: \(playlistURL.lastPathComponent)")
            return makeItem(
                asset: asset,
                superResolution: superResolution,
                quality: quality
            )
        }
    }

    /// Turns the Dart `url` of a local file into an absolute filesystem path.
    ///
    /// Dart is expected to send a bare path, but a `file://` prefixed value is accepted too
    /// (protocol-v2 §五). Percent-encoded values are decoded only when they came as a file URL.
    private static func localFilePath(from raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = value.lowercased()
        if lowercased.hasPrefix("file://") {
            if let url = URL(string: value) {
                return url.path
            }
            value = String(value.dropFirst("file://".count))
            if value.lowercased().hasPrefix("localhost/") {
                value = String(value.dropFirst("localhost".count))
            }
            return value
        }
        if lowercased.hasPrefix("file:") {
            value = String(value.dropFirst("file:".count))
        }
        return value
    }

    private static func headerFields(from value: Any?) -> [String: String] {
        guard let rawHeaders = value as? [String: Any] else { return [:] }
        var headers: [String: String] = [:]
        for (key, value) in rawHeaders {
            guard let text = value as? String, !text.isEmpty else { continue }
            headers[canonicalHeaderName(key)] = text
        }
        return headers
    }

    private static func canonicalHeaderName(_ name: String) -> String {
        switch name.lowercased() {
        case "referer", "referrer":
            return "Referer"
        case "user-agent", "useragent":
            return "User-Agent"
        default:
            return name
        }
    }

    private static func parseDanmakuItems(_ value: Any?) -> [ARDanmakuItem] {
        guard let rawItems = value as? [[String: Any]], !rawItems.isEmpty else { return [] }
        var items: [ARDanmakuItem] = []
        items.reserveCapacity(rawItems.count)
        for rawItem in rawItems {
            if let item = ARDanmakuItem(payload: rawItem) {
                items.append(item)
            }
        }
        items.sort { $0.timeMs < $1.timeMs }
        return items
    }

    /// Parses the v2 `danmakuConfig` payload into the overlay's `ARDanmakuConfig` struct.
    ///
    /// The struct itself is tolerant (missing / mistyped keys fall back to its defaults), so
    /// the manager only needs to forward the dictionary. The v1 `danmakuOpacity` /
    /// `danmakuFontSize` keys are folded in as a fallback for callers that still send them.
    private static func parseDanmakuConfig(_ payload: [String: Any]) -> ARDanmakuConfig {
        var rawConfig = payload["danmakuConfig"] as? [String: Any] ?? [:]
        if rawConfig["opacity"] == nil, let legacyOpacity = doubleValue(payload["danmakuOpacity"]) {
            rawConfig["opacity"] = legacyOpacity
        }
        if rawConfig["fontScale"] == nil, let legacyFontSize = doubleValue(payload["danmakuFontSize"]) {
            rawConfig["fontScale"] = legacyFontSize
        }
        return ARDanmakuConfig(payload: rawConfig)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? String { return Double(number) }
        return nil
    }

    // MARK: - Channel responses

    private static func startSuccess() -> [String: Any] {
        return ["ok": true, "error": NSNull()]
    }

    private static func startFailure(_ message: String) -> [String: Any] {
        return ["ok": false, "error": message]
    }
}

// MARK: - Local HLS resource loader

/// Serves a locally downloaded HLS playlist and its segments to AVPlayer.
///
/// `AVPlayer` cannot open a local `.m3u8` file directly, so the asset is created with a custom
/// scheme (`kazumi-local://local/<playlist.m3u8>`) and every playlist / segment request is
/// resolved to the file with the same name inside the playlist's directory. The playlist uses
/// relative file names (`seg_000.ts`), which AVFoundation resolves against the custom base URL,
/// so `request.url.lastPathComponent` is exactly the name to look up.
///
/// The delegate must be retained by the caller for as long as the asset is in use (the
/// resource loader holds it weakly); `ARDisplayManager` keeps it in
/// `localResourceLoaderDelegate` and drops it in `releaseLocalPlaybackResources()`.
final class ARLocalHLSResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    /// Custom URL scheme for locally served HLS. Not registered with the system on purpose:
    /// AVFoundation only routes *unknown* schemes to the resource loader delegate.
    static let customScheme = "kazumi-local"
    static let customHost = "local"

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requestURL = loadingRequest.request.url,
              requestURL.scheme?.lowercased() == ARLocalHLSResourceLoader.customScheme
        else {
            return false
        }

        // `lastPathComponent` also guards against path traversal (`../` never survives it).
        let fileName = requestURL.lastPathComponent
        guard !fileName.isEmpty else {
            finish(loadingRequest, errorCode: NSURLErrorBadURL, description: "本地视频分片地址无效")
            return true
        }
        let fileURL = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            arLog("local HLS: missing file \(fileName)")
            finish(loadingRequest, errorCode: NSURLErrorFileDoesNotExist, description: "本地视频分片不存在")
            return true
        }
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            arLog("local HLS: cannot read file \(fileName)")
            finish(loadingRequest, errorCode: NSURLErrorCannotOpenFile, description: "本地视频文件无法读取")
            return true
        }

        if let contentInformation = loadingRequest.contentInformationRequest {
            contentInformation.contentType = ARLocalHLSResourceLoader.contentType(
                forPathExtension: fileURL.pathExtension
            )
            contentInformation.contentLength = Int64(data.count)
            contentInformation.isByteRangeAccessSupported = true
        }

        if let dataRequest = loadingRequest.dataRequest {
            respond(dataRequest, with: data)
        }
        loadingRequest.finishLoading()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // Every response is produced synchronously, so there is nothing to cancel.
    }

    // MARK: - Helpers

    /// Answers one byte-range data request (plain, ranged or "to end of resource").
    private func respond(_ dataRequest: AVAssetResourceLoadingDataRequest, with data: Data) {
        let totalLength = data.count
        let requestedOffset = dataRequest.requestedOffset
        guard requestedOffset >= 0 else { return }
        let offset = Int(requestedOffset)
        guard offset < totalLength else { return }

        let end: Int
        if dataRequest.requestsAllDataToEndOfResource {
            end = totalLength
        } else {
            let requestedEnd = offset + dataRequest.requestedLength
            end = min(totalLength, max(offset, requestedEnd))
        }
        guard end > offset else { return }
        dataRequest.respond(with: data.subdata(in: offset..<end))
    }

    private func finish(
        _ loadingRequest: AVAssetResourceLoadingRequest,
        errorCode: Int,
        description: String
    ) {
        loadingRequest.finishLoading(
            with: NSError(
                domain: NSURLErrorDomain,
                code: errorCode,
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        )
    }

    /// MIME type reported to AVFoundation for a served file.
    ///
    /// `.ts` uses `video/mp2t` (the value AVFoundation expects for MPEG-2 transport streams);
    /// `public.mp2t` is the UTI equivalent kept here as a fallback reference — switching to it
    /// is a one-line change if a specific iOS build rejects the MIME type.
    private static func contentType(forPathExtension pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "m3u8", "m3u":
            return "application/vnd.apple.mpegurl"
        case "ts", "m2ts":
            return "video/mp2t"
        case "m4s":
            return "video/iso.segment"
        case "mp4", "m4v", "mov":
            return "video/mp4"
        case "aac":
            return "audio/aac"
        case "mp3":
            return "audio/mpeg"
        case "key", "bin", "dat":
            // HLS encryption key / auxiliary data.
            return "application/octet-stream"
        default:
            // Extension-less segments are MPEG-TS in every local-HLS download we produce.
            return "video/mp2t"
        }
    }
}
