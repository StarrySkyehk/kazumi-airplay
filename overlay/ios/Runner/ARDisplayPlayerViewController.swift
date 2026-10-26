//
//  ARDisplayPlayerViewController.swift
//  Runner
//
//  Root view controller of the external (AR glasses) display window.
//  Black background + AVPlayerLayer + native danmaku overlay, and a persistent
//  "connected / idle" page shown whenever nothing is being projected.
//

import AVFoundation
import CoreImage
import Metal
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

    /// Core Image super-resolution renderer (replaces the plain AVPlayerLayer while active).
    private var upscaler: ARVideoUpscalerRenderer?

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
        upscaler?.updateLayout(
            bounds: videoContainerView.bounds,
            scale: view.window?.screen.scale ?? UIScreen.main.scale
        )
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
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let pixelWidth = Int((view.bounds.width * scale).rounded())
        let pixelHeight = Int((view.bounds.height * scale).rounded())
        idleScreenLabel.text = "外接屏 \(pixelWidth)×\(pixelHeight) · 等待播放"
    }

    // MARK: - Player

    /// Attaches (or detaches, with `nil`) the player that provides the video frames.
    func attach(player: AVPlayer?) {
        if player == nil {
            removeSuperResolutionRenderer()
        }
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

    // MARK: - Super resolution (AR-side rendering)

    /// `true` while the Core Image upscaler is actually driving the external display.
    var isSuperResolutionActive: Bool {
        return upscaler != nil
    }

    /// Enables/disables the AR-side super-resolution renderer.
    ///
    /// The video is decoded by `AVPlayer` as usual, but instead of the plain `AVPlayerLayer` the
    /// frames go through an edge-preserving upscale + luminance sharpening pass rendered into a
    /// `CAMetalLayer`; the native danmaku overlay keeps drawing on top of it.
    func setSuperResolution(enabled: Bool, quality: Bool) {
        guard enabled, let player = playerLayer.player, let item = player.currentItem else {
            removeSuperResolutionRenderer()
            return
        }
        removeSuperResolutionRenderer()
        guard let renderer = ARVideoUpscalerRenderer(
            player: player,
            item: item,
            quality: quality
        ) else {
            NSLog("[Kazumi][ARDisplay] super resolution renderer unavailable (no Metal device)")
            return
        }
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        renderer.updateLayout(bounds: videoContainerView.bounds, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoContainerView.layer.addSublayer(renderer.renderLayer)
        CATransaction.commit()
        playerLayer.isHidden = true
        upscaler = renderer
        renderer.start()
        NSLog("[Kazumi][ARDisplay] super resolution enabled (quality=%@)", quality ? "1" : "0")
    }

    func removeSuperResolutionRenderer() {
        guard upscaler != nil else {
            playerLayer.isHidden = false
            return
        }
        upscaler?.stop()
        upscaler?.renderLayer.removeFromSuperlayer()
        upscaler = nil
        playerLayer.isHidden = false
    }

    // MARK: - Idle state

    /// Shows the idle page (no playback) or the video surface.
    func showIdleState(_ showIdle: Bool) {
        idleContainerView.isHidden = !showIdle
        videoContainerView.isHidden = showIdle
        upscaler?.renderLayer.isHidden = showIdle
        danmakuOverlayView.isHidden = showIdle || !danmakuOverlayView.isDanmakuEnabled
    }
}

// MARK: - Core Image super-resolution renderer

/// Renders the AVPlayer video through a Core Image pipeline into a `CAMetalLayer`.
///
/// Pipeline: YUV pixel buffer → CIImage → edge-preserving upscale (when enlarging) →
/// luminance sharpening → composited over black at the external screen's native size.
/// This is the AR-side "super resolution"; it is intentionally independent from the mpv /
/// Anime4K shader path used by the phone player (AVPlayer gives no shader hook).
final class ARVideoUpscalerRenderer {

    private let player: AVPlayer
    private weak var playerItem: AVPlayerItem?
    private let videoOutput: AVPlayerItemVideoOutput
    private let ciContext: CIContext?
    private let commandQueue: MTLCommandQueue?
    private let quality: Bool
    let renderLayer: CAMetalLayer

    private var displayLink: CADisplayLink?
    private var displayLinkProxy: ARUpscalerDisplayLinkProxy?
    private var lastImage: CIImage?
    private var isRunning = false

    init?(player: AVPlayer, item: AVPlayerItem, quality: Bool) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let context = CIContext(
                  mtlDevice: device,
                  options: [.cacheIntermediates: false]
              )
        else {
            return nil
        }
        self.player = player
        self.playerItem = item
        self.quality = quality
        self.commandQueue = queue
        self.ciContext = context
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        self.videoOutput = output
        item.add(output)
        let layer = CAMetalLayer()
        layer.device = device
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.colorspace = CGColorSpaceCreateDeviceRGB()
        self.renderLayer = layer
    }

    deinit {
        stop()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let proxy = ARUpscalerDisplayLinkProxy(renderer: self)
        let link = CADisplayLink(
            target: proxy,
            selector: #selector(ARUpscalerDisplayLinkProxy.tick(_:))
        )
        link.add(to: .main, forMode: .common)
        displayLinkProxy = proxy
        displayLink = link
    }

    func stop() {
        isRunning = false
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        lastImage = nil
        if let item = playerItem {
            item.remove(videoOutput)
        }
    }

    func updateLayout(bounds: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderLayer.frame = bounds
        let size = CGSize(
            width: max(1.0, bounds.width * scale),
            height: max(1.0, bounds.height * scale)
        )
        if renderLayer.drawableSize != size {
            renderLayer.drawableSize = size
        }
        CATransaction.commit()
    }

    fileprivate func renderFrame() {
        guard isRunning else { return }
        var itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        if !itemTime.isValid || itemTime.seconds.isNaN {
            itemTime = player.currentTime()
        }
        if videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
           let pixelBuffer = videoOutput.copyPixelBuffer(
               forItemTime: itemTime,
               itemTimeForDisplay: nil
           ) {
            lastImage = CIImage(cvPixelBuffer: pixelBuffer)
        }
        guard let image = lastImage,
              let drawable = renderLayer.nextDrawable()
        else {
            return
        }
        render(image, drawable: drawable)
    }

    private func render(_ image: CIImage, drawable: CAMetalDrawable) {
        guard let context = ciContext,
              let commandQueue = commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }
        let target = CGRect(origin: .zero, size: renderLayer.drawableSize)
        let extent = image.extent
        guard target.width > 1, target.height > 1,
              extent.width > 1, extent.height > 1
        else {
            return
        }
        let scale = min(target.width / extent.width, target.height / extent.height)
        var output = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledWidth = extent.width * scale
        let scaledHeight = extent.height * scale
        output = output.transformed(by: CGAffineTransform(
            translationX: (target.width - scaledWidth) / 2,
            y: (target.height - scaledHeight) / 2
        ))
        if scale > 1.001,
           let upsample = CIFilter(name: "CIEdgePreserveUpsample") {
            upsample.setValue(output, forKey: kCIInputImageKey)
            upsample.setValue(image, forKey: "inputSmallImage")
            if let result = upsample.outputImage {
                output = result
            }
        }
        if let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(output, forKey: kCIInputImageKey)
            sharpen.setValue(quality ? 0.85 : 0.55, forKey: kCIInputSharpnessKey)
            if let result = sharpen.outputImage {
                output = result
            }
        }
        let background = CIImage(color: CIColor.black).cropped(to: target)
        output = output.composited(over: background).cropped(to: target)
        context.render(
            output,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: target,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// Weak display-link target for the upscaler (CADisplayLink retains its target).
private final class ARUpscalerDisplayLinkProxy: NSObject {

    private weak var renderer: ARVideoUpscalerRenderer?

    init(renderer: ARVideoUpscalerRenderer) {
        self.renderer = renderer
        super.init()
    }

    @objc func tick(_ displayLink: CADisplayLink) {
        renderer?.renderFrame()
    }
}
