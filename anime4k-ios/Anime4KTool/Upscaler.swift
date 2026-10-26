//
//  Upscaler.swift
//  Anime4KTool
//
//  手机端离线超分管线：
//    AVAssetReader（硬件解码，YUV420）
//      → Core Image：Lanczos 放大 + 边缘保留放大 + 亮度锐化 + 线条 UnsharpMask
//      → AVAssetWriter（硬件 H.264 编码，旋转元数据保留）
//      → AVMutableComposition + 直通导出，把原音轨接回最终 mp4。
//
//  说明：iOS 上无法直接加载 Anime4K 的 GLSL（那是 mpv/libplacebo 的着色器），
//  这里用 Core Image 的等价思路实现「边缘感知放大 + 线条锐化」，效果方向一致。
//

import AVFoundation
import CoreImage
import Foundation

struct UpscaleSettings {
    /// 目标高度（像素）。0 表示保持原分辨率，只做修复/锐化。
    var targetHeight: Int
    /// 质量档：更粗的线条锐化。
    var strongMode: Bool
}

struct UpscaleResult {
    let outputURL: URL
    let width: Int
    let height: Int
    let duration: Double
    /// 音轨合并失败、输出为无声视频时为 true。
    let audioMuxFailed: Bool
}

enum UpscaleError: LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)
    case cancelled
    case audioMuxFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "这个视频里没有视频轨道。"
        case .readerFailed(let text):
            return "读取视频失败：\(text)"
        case .writerFailed(let text):
            return "写入视频失败：\(text)"
        case .cancelled:
            return "已取消。"
        case .audioMuxFailed(let text):
            return "合并音轨失败：\(text)"
        }
    }
}

final class VideoUpscaler {

    private let asset: AVURLAsset
    private let videoTrack: AVAssetTrack
    private let audioTrack: AVAssetTrack?
    private let naturalSize: CGSize
    private let preferredTransform: CGAffineTransform
    private let duration: CMTime
    private let nominalFrameRate: Float
    private let ciContext: CIContext

    private let lock = NSLock()
    private var cancelRequested = false

    private init(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        duration: CMTime,
        nominalFrameRate: Float
    ) {
        self.asset = asset
        self.videoTrack = videoTrack
        self.audioTrack = audioTrack
        self.naturalSize = naturalSize
        self.preferredTransform = preferredTransform
        self.duration = duration
        self.nominalFrameRate = nominalFrameRate
        self.ciContext = CIContext(options: [.cacheIntermediates: true])
    }

    static func prepare(inputURL: URL) async throws -> (VideoUpscaler, String) {
        let asset = AVURLAsset(
            url: inputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else {
            throw UpscaleError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let fps = try await track.load(.nominalFrameRate)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let upscaler = VideoUpscaler(
            asset: asset,
            videoTrack: track,
            audioTrack: audioTracks.first,
            naturalSize: naturalSize,
            preferredTransform: transform,
            duration: duration,
            nominalFrameRate: fps
        )
        let display = upscaler.displayedSize()
        let info = String(
            format: "%.0f×%.0f · %.1f 秒 · %.0f fps",
            display.width, display.height,
            max(0, duration.seconds), Double(fps > 0 ? fps : 30)
        )
        return (upscaler, info)
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        let value = cancelRequested
        lock.unlock()
        return value
    }

    /// 源视频时长（秒）。
    var sourceDurationSeconds: Double {
        return max(0, duration.seconds)
    }

    /// 屏幕显示尺寸（应用旋转元数据后的宽高）。
    func displayedSize() -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// 处理并导出到 `outputURL`（mp4）。
    func export(
        settings: UpscaleSettings,
        to outputURL: URL,
        progress: @escaping @Sendable (Double, Double) -> Void
    ) async throws -> UpscaleResult {
        let display = displayedSize()
        // 以「短边」对齐目标分辨率：横屏 720p→1080p 放大，竖屏 1080p 保持原样而不是被缩小。
        let shortSide = max(1, min(display.width, display.height))
        let scale: CGFloat = settings.targetHeight > 0
            ? CGFloat(settings.targetHeight) / shortSide
            : 1.0

        var renderWidth = evenPixels(naturalSize.width * scale)
        var renderHeight = evenPixels(naturalSize.height * scale)
        if settings.targetHeight <= 0 {
            renderWidth = evenPixels(naturalSize.width)
            renderHeight = evenPixels(naturalSize.height)
        }
        let renderSize = CGSize(width: renderWidth, height: renderHeight)
        let effectiveScale = renderSize.height / max(1, naturalSize.height)

        let fileManager = FileManager.default
        let workDir = outputURL.deletingLastPathComponent()
        let tempVideoURL = workDir.appendingPathComponent("anime4k_video_\(UUID().uuidString).mp4")
        try? fileManager.removeItem(at: tempVideoURL)
        try? fileManager.removeItem(at: outputURL)

        try await encodeVideo(
            to: tempVideoURL,
            renderSize: renderSize,
            scale: effectiveScale,
            strong: settings.strongMode,
            progress: progress
        )

        var audioMuxFailed = false
        if let _ = audioTrack {
            do {
                try await mux(videoURL: tempVideoURL, outputURL: outputURL)
                try? fileManager.removeItem(at: tempVideoURL)
            } catch {
                // 音轨合并失败时保底：直接使用无声视频，避免整次处理白做。
                audioMuxFailed = true
                try? fileManager.removeItem(at: outputURL)
                try fileManager.moveItem(at: tempVideoURL, to: outputURL)
            }
        } else {
            try fileManager.moveItem(at: tempVideoURL, to: outputURL)
        }

        progress(1.0, 0)
        return UpscaleResult(
            outputURL: outputURL,
            width: renderWidth,
            height: renderHeight,
            duration: max(0, duration.seconds),
            audioMuxFailed: audioMuxFailed
        )
    }

    // MARK: - 视频编码

    private func encodeVideo(
        to url: URL,
        renderSize: CGSize,
        scale: CGFloat,
        strong: Bool,
        progress: @escaping @Sendable (Double, Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "anime4k.encoder", qos: .userInitiated)
            queue.async {
                do {
                    try self.runEncodeLoop(
                        url: url,
                        renderSize: renderSize,
                        scale: scale,
                        strong: strong,
                        progress: progress,
                        continuation: continuation
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runEncodeLoop(
        url: URL,
        renderSize: CGSize,
        scale: CGFloat,
        strong: Bool,
        progress: @escaping @Sendable (Double, Double) -> Void,
        continuation: CheckedContinuation<Void, Error>
    ) throws {
        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: readerSettings
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw UpscaleError.readerFailed("无法添加视频输出")
        }
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let targetWidth = Int(renderSize.width)
        let targetHeight = Int(renderSize.height)
        let fps = Int(max(24, min(60, Int(nominalFrameRate.rounded()))))
        var bitrate = Int(Double(targetWidth * targetHeight) * 4.0)
        bitrate = max(2_000_000, min(40_000_000, bitrate))
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight,
            AVVideoCompressionPropertiesKey: compression,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                kCVPixelBufferWidthKey as String: targetWidth,
                kCVPixelBufferHeightKey as String: targetHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
        )
        guard writer.canAdd(input) else {
            throw UpscaleError.writerFailed("无法添加视频输入")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw UpscaleError.writerFailed(writer.error?.localizedDescription ?? "startWriting 失败")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw UpscaleError.readerFailed(reader.error?.localizedDescription ?? "startReading 失败")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        var finished = false
        let totalSeconds = max(0.01, duration.seconds)
        let targetRect = CGRect(origin: .zero, size: renderSize)
        let ciContext = self.ciContext

        input.requestMediaDataWhenReady(on: DispatchQueue(label: "anime4k.feed")) {
            if finished { return }
            while input.isReadyForMoreMediaData {
                if self.isCancelled {
                    failure = UpscaleError.cancelled
                    break
                }
                guard let sample = videoOutput.copyNextSampleBuffer() else {
                    break
                }
                guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
                    continue
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                guard let pool = adaptor.pixelBufferPool else {
                    failure = UpscaleError.writerFailed("没有可用的像素缓冲池")
                    break
                }
                var outBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
                guard let outBuffer = outBuffer else {
                    failure = UpscaleError.writerFailed("分配输出像素缓冲失败")
                    break
                }
                let sourceImage = CIImage(cvPixelBuffer: imageBuffer)
                let processed = self.process(sourceImage, scale: scale, strong: strong)
                ciContext.render(
                    processed,
                    to: outBuffer,
                    bounds: targetRect,
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )
                if !adaptor.append(outBuffer, withPresentationTime: pts) {
                    failure = UpscaleError.writerFailed(
                        writer.error?.localizedDescription ?? "append 失败"
                    )
                    break
                }
                let seconds = max(0, CMTimeGetSeconds(pts))
                let percent = min(1.0, seconds / totalSeconds)
                progress(percent, 0)
            }

            if failure != nil || reader.status == .failed {
                finished = true
                reader.cancelReading()
                writer.cancelWriting()
                if let failure = failure {
                    continuation.resume(throwing: failure)
                } else {
                    continuation.resume(
                        throwing: UpscaleError.readerFailed(
                            reader.error?.localizedDescription ?? "读取中断"
                        )
                    )
                }
                semaphore.signal()
                return
            }

            if input.isReadyForMoreMediaData {
                finished = true
                input.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: UpscaleError.writerFailed(
                                writer.error?.localizedDescription ?? "写入失败"
                            )
                        )
                    }
                    semaphore.signal()
                }
            }
        }
        semaphore.wait()
    }

    // MARK: - Core Image 处理

    private func process(_ image: CIImage, scale: CGFloat, strong: Bool) -> CIImage {
        var output = image
        if scale > 1.001 {
            output = output.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1.0,
            ])
            if let edge = CIFilter(name: "CIEdgePreserveUpsample") {
                edge.setValue(output, forKey: kCIInputImageKey)
                edge.setValue(image, forKey: "inputSmallImage")
                if let result = edge.outputImage {
                    output = result
                }
            }
        }
        output = output.applyingFilter("CISharpenLuminance", parameters: [
            kCIInputSharpnessKey: strong ? 0.9 : 0.6,
        ])
        output = output.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: strong ? 2.6 : 1.8,
            kCIInputIntensityKey: strong ? 0.85 : 0.5,
        ])
        output = output.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1.02,
        ])
        return output
    }

    // MARK: - 音轨直通合并

    private func mux(videoURL: URL, outputURL: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let compositionVideo = composition.addMutableTrack(
                  withMediaType: .video,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else {
            throw UpscaleError.audioMuxFailed("无法创建视频轨")
        }
        let videoRange = try await sourceVideo.load(.timeRange)
        try compositionVideo.insertTimeRange(videoRange, of: sourceVideo, at: .zero)
        compositionVideo.preferredTransform = preferredTransform

        if let audioSource = try await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let audioRange = try await audioSource.load(.timeRange)
            try compositionAudio.insertTimeRange(audioRange, of: audioSource, at: .zero)
        }

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw UpscaleError.audioMuxFailed("无法创建导出会话")
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw UpscaleError.cancelled
        default:
            throw UpscaleError.audioMuxFailed(
                session.error?.localizedDescription ?? "导出失败"
            )
        }
    }

    // MARK: - 工具

    private func evenPixels(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        let even = rounded - (rounded % 2)
        return max(2, even)
    }
}
