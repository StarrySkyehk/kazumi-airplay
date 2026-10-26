//
//  ARDisplayPlayerViewController.swift
//  Runner
//
//  Root view controller of the external (AR glasses) display window.
//  Black background + AVPlayerLayer + native danmaku overlay, and a persistent
//  "connected / idle" page shown whenever nothing is being projected.
//

import AVFoundation
import QuartzCore
import UIKit

/// Hosts the AVPlayer video layer and the native danmaku overlay on the external screen.
///
/// The manager owns the `AVPlayer`; this controller only displays it. The controller lives as
/// long as the external-display window: between playback sessions the glasses show the idle
/// page instead of falling back to mirroring the phone screen.
final class ARDisplayPlayerViewController: UIViewController {

    // MARK: - Subviews

    private let videoContainerView = UIView()
    private let playerLayer = AVPlayerLayer()
    let danmakuOverlayView = ARDanmakuOverlayView()

    private let idleContainerView = UIView()
    private let idleTitleLabel = UILabel()
    private let idleSubtitleLabel = UILabel()
    private let idleScreenLabel = UILabel()

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

        setUpIdleView()
        showIdleState(true)
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
        layoutIdleView()
        CATransaction.commit()
        danmakuOverlayView.updateMetricsIfNeeded()
    }

    // MARK: - Idle page

    private func setUpIdleView() {
        idleContainerView.backgroundColor = .black
        idleContainerView.isUserInteractionEnabled = false

        idleTitleLabel.text = "Kazumi"
        idleTitleLabel.textColor = .white
        idleTitleLabel.textAlignment = .center
        idleTitleLabel.font = UIFont.systemFont(ofSize: 96, weight: .heavy)

        idleSubtitleLabel.text = "AR 眼镜已连接 · 在手机上播放后点击 AirPlay 图标"
        idleSubtitleLabel.textColor = UIColor(white: 0.72, alpha: 1.0)
        idleSubtitleLabel.textAlignment = .center
        idleSubtitleLabel.font = UIFont.systemFont(ofSize: 28, weight: .medium)

        idleScreenLabel.textColor = UIColor(white: 0.5, alpha: 1.0)
        idleScreenLabel.textAlignment = .center
        idleScreenLabel.font = UIFont.systemFont(ofSize: 22, weight: .regular)

        idleContainerView.addSubview(idleTitleLabel)
        idleContainerView.addSubview(idleSubtitleLabel)
        idleContainerView.addSubview(idleScreenLabel)
        view.addSubview(idleContainerView)
    }

    private func layoutIdleView() {
        idleContainerView.frame = view.bounds
        let width = view.bounds.width
        let titleHeight: CGFloat = 120
        let subtitleHeight: CGFloat = 44
        let screenHeight: CGFloat = 32
        let totalHeight = titleHeight + subtitleHeight + screenHeight + 24
        let top = max(0, (view.bounds.height - totalHeight) / 2)
        idleTitleLabel.frame = CGRect(x: 0, y: top, width: width, height: titleHeight)
        idleSubtitleLabel.frame = CGRect(
            x: 0,
            y: top + titleHeight + 8,
            width: width,
            height: subtitleHeight
        )
        idleScreenLabel.frame = CGRect(
            x: 0,
            y: top + titleHeight + subtitleHeight + 16,
            width: width,
            height: screenHeight
        )
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let pixelWidth = Int((view.bounds.width * scale).rounded())
        let pixelHeight = Int((view.bounds.height * scale).rounded())
        idleScreenLabel.text = "外接屏 \(pixelWidth)×\(pixelHeight) · 等待播放"
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
        config: ARDanmakuConfig
    ) {
        danmakuOverlayView.setItems(items)
        danmakuOverlayView.apply(config: config)
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

    /// Stops emission and drops every label (used when playback reaches the end).
    func stopDanmaku() {
        danmakuOverlayView.stopAndClear()
    }

    // MARK: - Idle state

    /// Shows the idle page (no playback) or the video surface.
    func showIdleState(_ showIdle: Bool) {
        idleContainerView.isHidden = !showIdle
        videoContainerView.isHidden = showIdle
        danmakuOverlayView.isHidden = showIdle || !danmakuOverlayView.isDanmakuEnabled
    }
}
