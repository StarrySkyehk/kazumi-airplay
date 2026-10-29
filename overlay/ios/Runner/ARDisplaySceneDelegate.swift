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
        self.window = window
        self.playerViewController = viewController
        // The system keeps mirroring the phone screen until the accessory scene presents a
        // visible window; `makeKeyAndVisible()` is what Apple's sample uses here, and it is
        // required for the external display to switch from mirroring to our content.
        window.makeKeyAndVisible()

        ARDisplayManager.shared.handleExternalSceneConnected(
            windowScene: windowScene,
            sceneDelegate: self
        )
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // The glasses were unplugged / the system took the scene away. Playback cannot continue
        // without a picture; the manager stops it exactly once and keeps the accessory
        // registration alive for the next connection.
        ARDisplayManager.shared.handleExternalSceneDisconnected()
        teardownWindow()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // 眼镜重插时系统可能复用同一个 scene（只回调 didBecomeActive）：窗口在断联时
        // 已被 teardown，这里重建窗口并把会话挂回管理器，避免必须「结束投屏再投屏」。
        if window == nil || playerViewController == nil {
            rebuildWindow(windowScene: windowScene)
        }
        // Re-assert the external window on activation: when the scene connects while the phone
        // display is still being mirrored, the window must be visible to take over the screen.
        ARDisplayManager.shared.handleExternalSceneBecameActive(windowScene: windowScene)
        ARDisplayManager.shared.handleExternalSceneReactivatedIfNeeded(
            windowScene: windowScene,
            sceneDelegate: self
        )
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        if window == nil || playerViewController == nil {
            rebuildWindow(windowScene: windowScene)
        }
    }

    // MARK: - Window

    /// 断联会关闭窗口；重插（复用同一 scene）时重建窗口并让它接管外接屏。
    private func rebuildWindow(windowScene: UIWindowScene) {
        let newWindow = UIWindow(windowScene: windowScene)
        let viewController = ARDisplayPlayerViewController()
        newWindow.rootViewController = viewController
        window = newWindow
        playerViewController = viewController
        newWindow.makeKeyAndVisible()
    }

    /// Closes the external window (only used when the scene is genuinely going away, never on
    /// `stop`: the window is permanent so the next projection does not fall back to mirroring).
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
