//
//  ARDisplaySceneDelegate.swift
//  Runner
//
//  Delegate of the external (non-interactive) display scene that iOS 27 creates for
//  the `UISceneAccessory.externalNonInteractive` accessory registered by
//  `ARDisplayManager`.
//
//  It only builds / tears down the external window; playback control stays in the
//  manager so the Flutter channel keeps a single source of truth.
//

import UIKit

/// Creates the window for the AR glasses display and reports its lifecycle to the manager.
///
/// Inherits from `UIResponder` (same shape as Apple's own `SceneDelegate` template) so the
/// scene delegate callbacks are main-actor isolated like the UIKit calls they perform.
@objc(ARDisplaySceneDelegate)
final class ARDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {

    /// Required by `UIWindowSceneDelegate`; the scene system may also assign it.
    var window: UIWindow?

    private(set) var playerViewController: ARDisplayPlayerViewController?

    // MARK: - UIWindowSceneDelegate

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        let viewController = ARDisplayPlayerViewController()
        window.rootViewController = viewController
        window.isHidden = false

        self.window = window
        self.playerViewController = viewController

        ARDisplayManager.shared.handleExternalSceneConnected(
            windowScene: windowScene,
            sceneDelegate: self
        )
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        ARDisplayManager.shared.handleExternalSceneDisconnected()
        teardownWindow()
    }

    // MARK: - Window

    /// Closes the external window immediately (used when playback stops, before the
    /// runtime disconnects the scene).
    func closeWindow() {
        teardownWindow()
    }

    private func teardownWindow() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        playerViewController = nil
    }
}
