//
//  ARDisplayPlayerViewController.swift
//  Runner
//
//  Root view controller of the external (AR glasses) display window.
//  Black background + AVPlayerLayer + native danmaku overlay.
//

import AVFoundation
import QuartzCore
import UIKit

/// Hosts the AVPlayer video layer and the native danmaku overlay on the external screen.
///
/// The manager owns the `AVPlayer`; this controller only displays it. The controller is
/// retained by its window and is torn down by `ARDisplaySceneDelegate`.
final class ARDisplayPlayerViewController: UIViewController {

    // MARK: - Subviews

    private let videoContainerView = UIView()
    private let playerLayer = AVPlayerLayer()
    let danmakuOverlayView = ARDanmakuOverlayView()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true

        videoContainerView.backgroundColor = .black
        videoContainerView.isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
        videoContainerView.layer.addSublayer(playerLayer)
        view.addSubview(videoContainerView)

        view.addSubview(danmakuOverlayView)
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoContainerView.frame = view.bounds
        playerLayer.frame = videoContainerView.bounds
        danmakuOverlayView.frame = view.bounds
        CATransaction.commit()
        danmakuOverlayView.updateMetricsIfNeeded()
    }

    // MARK: - Player

    /// Attaches (or detaches, with `nil`) the player that provides the video frames.
    func attach(player: AVPlayer?) {
        playerLayer.player = player
        danmakuOverlayView.attach(player: player)
    }

    // MARK: - Danmaku

    func configureDanmaku(
        items: [ARDanmakuItem],
        enabled: Bool,
        opacity: CGFloat,
        fontScale: CGFloat
    ) {
        danmakuOverlayView.setItems(items)
        danmakuOverlayView.setOpacity(opacity)
        danmakuOverlayView.setFontScale(fontScale)
        danmakuOverlayView.setDanmakuEnabled(enabled)
    }

    func setDanmakuEnabled(_ enabled: Bool) {
        danmakuOverlayView.setDanmakuEnabled(enabled)
    }

    func setDanmakuPaused(_ paused: Bool) {
        danmakuOverlayView.setPaused(paused)
    }

    func seekDanmaku(toMilliseconds positionMs: Double) {
        danmakuOverlayView.seek(toMilliseconds: positionMs)
    }

    func stopDanmaku() {
        danmakuOverlayView.stopAndClear()
    }
}
