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
    private static let stateEventIntervalSeconds: Double = 0.25

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
    private var danmakuOpacity: CGFloat = 1.0
    private var danmakuFontScale: CGFloat = 1.0

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
            let registrationAvailable = registeredAccessory?.isAvailable ?? false
            result([
                "supported": true,
                "connected": isDisplayConnected || registrationAvailable,
                "available": registrationAvailable,
                "screens": UIScreen.screens.count,
                "screenWidth": screenWidth,
                "screenHeight": screenHeight,
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
        guard let urlString = payload["url"] as? String,
              !urlString.isEmpty,
              let url = URL(string: urlString),
              url.scheme?.isEmpty == false
        else {
            result(ARDisplayManager.startFailure("视频地址无效"))
            return
        }
        guard let hostViewController = ARDisplayManager.activeFlutterViewController() else {
            result(ARDisplayManager.startFailure("无法获取当前播放页面"))
            return
        }

        // A second `start` replaces the previous session (the old call is resolved first).
        // When the glasses scene is already alive it is reused instead of being torn down
        // and re-created, which would otherwise be racy with the 1.5 s connect timeout.
        let reusesExistingDisplay = isDisplayConnected && displayViewController != nil
        teardownPlayback(keepingExternalDisplay: reusesExistingDisplay)

        configureAudioSession()

        let headers = ARDisplayManager.headerFields(from: payload["headers"])
        let item = ARDisplayManager.makePlayerItem(url: url, headers: headers)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.actionAtItemEnd = .pause

        player = newPlayer
        playerItem = item
        pendingStartPositionMilliseconds = ARDisplayManager.doubleValue(payload["positionMs"]) ?? 0
        danmakuItems = ARDisplayManager.parseDanmakuItems(payload["danmaku"])
        danmakuEnabled = (payload["danmakuEnabled"] as? Bool) ?? true
        danmakuOpacity = CGFloat(ARDisplayManager.doubleValue(payload["danmakuOpacity"]) ?? 1.0)
        danmakuFontScale = CGFloat(ARDisplayManager.doubleValue(payload["danmakuFontSize"]) ?? 1.0)
        playbackSpeed = 1.0
        playbackEnded = false
        lastKnownError = nil
        installPlayerObservers(for: newPlayer, item: item)

        guard ensureAccessoryRegistration(hostViewController: hostViewController) else {
            teardownPlayback(keepingExternalDisplay: false)
            result(ARDisplayManager.startFailure("外接屏不可用"))
            return
        }
        setAccessoryEnabled(true)

        if isDisplayConnected, displayViewController != nil {
            attachPlayerToExternalDisplay()
            result(ARDisplayManager.startSuccess())
            return
        }

        startPendingResult = result
        scheduleStartTimeout()
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
        teardownPlayback(keepingExternalDisplay: false)
        pending(ARDisplayManager.startFailure(
            "未检测到外接屏，请确认眼镜已用 USB‑C 连接（available=\(available) enabled=\(enabled) screens=\(screens)）"
        ))
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

    /// Pre-registers the scene accessory (disabled) so the system already knows about it when
    /// playback starts. Called shortly after app launch from `AppDelegate`.
    func prepareAccessoryRegistrationIfNeeded() {
        guard #available(iOS 27.0, *) else { return }
        guard registeredAccessory == nil else { return }
        guard let hostViewController = ARDisplayManager.activeFlutterViewController() else { return }
        _ = ensureAccessoryRegistration(hostViewController: hostViewController)
        setAccessoryEnabled(false)
        startObservingExternalScreens()
        arLog("accessory pre-registered, available=\(registeredAccessory?.isAvailable ?? false)")
    }

    private func startObservingExternalScreens() {
        guard screenConnectObserver == nil else { return }
        screenConnectObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.didConnectNotification,
            object: nil,
            queue: .main
        ) { _ in
            arLog("UIScreen did connect, count=\(UIScreen.screens.count)")
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
                manager.teardownPlayback(keepingExternalDisplay: false)
            }
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
        }
        result(nil)
    }

    private func handleStop(result: @escaping FlutterResult) {
        let positionMs = currentPositionMilliseconds()
        let durationMs = currentDurationMilliseconds()
        teardownPlayback(keepingExternalDisplay: false)
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
        viewController.attach(player: player)
        viewController.configureDanmaku(
            items: danmakuItems,
            enabled: danmakuEnabled,
            opacity: danmakuOpacity,
            fontScale: danmakuFontScale
        )
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
        self.sceneDelegate = sceneDelegate
        self.externalWindowScene = windowScene
        self.displayViewController = sceneDelegate.playerViewController
        isDisplayConnected = true
        updateScreenMetrics(from: windowScene)
        sendEvent([
            "type": "connected",
            "width": screenWidth,
            "height": screenHeight,
        ])
        attachPlayerToExternalDisplay()
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
        if wasConnected {
            sendEvent(["type": "disconnected"])
        }
        if player != nil || startPendingResult != nil {
            teardownPlayback(keepingExternalDisplay: false)
        }
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
        registeredAccessory = registration
        accessoryHostViewController = hostViewController
        startObservingExternalScreens()
        return true
    }

    @available(iOS 27.0, *)
    private func setAccessoryEnabled(_ enabled: Bool) {
        guard let registration = registeredAccessory else { return }
        registration.isEnabled = enabled
    }

    private func unregisterAccessoryRegistration() {
        if #available(iOS 27.0, *) {
            if let registration = registeredAccessory {
                registration.isEnabled = false
                if let hostViewController = accessoryHostViewController {
                    hostViewController.unregisterSceneAccessory(registration)
                } else {
                    arLog("accessory host view controller is gone; registration dropped")
                }
            }
            registeredAccessory = nil
        }
        accessoryHostViewController = nil
    }

    // MARK: - Teardown

    /// Tears down the AVPlayer session.
    ///
    /// - Parameter keepingExternalDisplay: `true` keeps the registered accessory and the
    ///   glasses window alive (used by a second `start`); `false` also unregisters the
    ///   accessory, closes the window and reports `disconnected` to Dart.
    private func teardownPlayback(keepingExternalDisplay: Bool) {
        guard !isTearingDown else { return }
        isTearingDown = true
        defer { isTearingDown = false }

        flushPendingStart(failureMessage: "播放已停止")

        removePlayerObservers()
        if let player = player {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        player = nil
        playerItem = nil
        playbackEnded = false
        lastKnownError = nil
        playbackSpeed = 1.0
        pendingStartPositionMilliseconds = 0
        danmakuItems = []

        if let viewController = displayViewController {
            viewController.attach(player: nil)
            viewController.configureDanmaku(items: [], enabled: danmakuEnabled, opacity: danmakuOpacity, fontScale: danmakuFontScale)
        }

        if keepingExternalDisplay {
            return
        }

        if let window = legacyExternalWindow {
            window.isHidden = true
            window.rootViewController = nil
            legacyExternalWindow = nil
        }
        displayViewController = nil
        sceneDelegate?.closeWindow()
        sceneDelegate = nil
        externalWindowScene = nil
        screenWidth = 0
        screenHeight = 0
        unregisterAccessoryRegistration()

        if isDisplayConnected {
            isDisplayConnected = false
            sendEvent(["type": "disconnected"])
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
        sendStateEvent()
    }

    private func handlePlaybackFailed(message: String?) {
        guard player != nil else { return }
        let text = message ?? playerItem?.error?.localizedDescription ?? "视频播放失败"
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

    private static func makePlayerItem(url: URL, headers: [String: String]) -> AVPlayerItem {
        let asset: AVURLAsset
        if headers.isEmpty {
            asset = AVURLAsset(url: url)
        } else {
            // `AVURLAssetHTTPHeaderFieldsKey` is a private-but-widely-used AVFoundation key;
            // the app already relies on it in `openVideoWithReferer`.
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }
        return AVPlayerItem(asset: asset)
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
