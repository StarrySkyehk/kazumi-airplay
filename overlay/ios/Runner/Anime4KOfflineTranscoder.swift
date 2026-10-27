//
//  Anime4KOfflineTranscoder.swift
//  Anime4KMetalTool
//
//  真正的 Anime4K 离线转码：
//    AVAssetReader（硬件解码，BGRA）
//      → MTLTexture → Anime4K Metal 引擎（GLSL 动态翻译，Anime4K v4 官方着色器链）
//      → 渲染到 CVPixelBuffer → AVAssetWriter（H.264 硬件编码）
//      → 直通导出把原音轨接回 mp4。
//
//  Anime4K 引擎与 GLSL 翻译器来自 imxieyi/Anime4KMetal（Apache-2.0），
//  着色器来自 bloc97/Anime4K（MIT/Apache-2.0）。
//

import AVFoundation
import CoreImage
import Metal
import MetalKit

struct TranscodeSettings {
    var presetKey: String
    /// 目标短边分辨率；0 表示保持原分辨率（仅跑修复类着色器）。
    var targetHeight: Int
}

struct TranscodeResult {
    let outputURL: URL
    let width: Int
    let height: Int
    let duration: Double
    let audioMuxFailed: Bool
}

enum TranscodeError: LocalizedError {
    case noVideoTrack
    case metalUnavailable
    case shaderMissing(String)
    case compileFailed(String)
    case readerFailed(String)
    case writerFailed(String)
    case cancelled
    case audioMuxFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "这个视频里没有视频轨道。"
        case .metalUnavailable:
            return "这台设备不支持 Metal。"
        case .shaderMissing(let name):
            return "找不到着色器：\(name)"
        case .compileFailed(let text):
            return "着色器编译失败：\(text)"
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

final class Anime4KOfflineTranscoder {

    struct Preset {
        let key: String
        let title: String
        let shaders: [String]
    }

    /// 全部来自 Anime4K 官方推荐档位（见 GLSL_Instructions）。
    static let presets: [Preset] = [
        Preset(key: "modeAFast", title: "模式 A（Fast，推荐）", shaders: [
            "Restore/Anime4K_Clamp_Highlights.glsl",
            "Restore/Anime4K_Restore_CNN_M.glsl",
            "Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
            "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
            "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
            "Upscale/Anime4K_Upscale_CNN_x2_S.glsl",
        ]),
        Preset(key: "modeBFast", title: "模式 B（Fast，线条更柔）", shaders: [
            "Restore/Anime4K_Clamp_Highlights.glsl",
            "Restore/Anime4K_Restore_CNN_Soft_M.glsl",
            "Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
            "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
            "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
            "Upscale/Anime4K_Upscale_CNN_x2_S.glsl",
        ]),
        Preset(key: "modeCFast", title: "模式 C（Fast，降噪+放大）", shaders: [
            "Restore/Anime4K_Clamp_Highlights.glsl",
            "Upscale+Denoise/Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
            "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
            "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
            "Upscale/Anime4K_Upscale_CNN_x2_S.glsl",
        ]),
        Preset(key: "modeAAFast", title: "模式 A+A（Fast，更锐）", shaders: [
            "Restore/Anime4K_Clamp_Highlights.glsl",
            "Restore/Anime4K_Restore_CNN_M.glsl",
            "Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
            "Restore/Anime4K_Restore_CNN_S.glsl",
            "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
            "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
            "Upscale/Anime4K_Upscale_CNN_x2_S.glsl",
        ]),
        Preset(key: "modeAHQ", title: "模式 A（HQ，很慢）", shaders: [
            "Restore/Anime4K_Clamp_Highlights.glsl",
            "Restore/Anime4K_Restore_CNN_VL.glsl",
            "Upscale/Anime4K_Upscale_CNN_x2_VL.glsl",
            "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
            "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
            "Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
        ]),
        Preset(key: "restore", title: "仅线条修复（不放大，最快）", shaders: [
            "Restore/Anime4K_Clamp_Highlights.glsl",
            "Restore/Anime4K_Restore_CNN_M.glsl",
        ]),
    ]

    private let asset: AVURLAsset
    private let videoTrack: AVAssetTrack
    private let audioTrack: AVAssetTrack?
    private let naturalSize: CGSize
    private let preferredTransform: CGAffineTransform
    private let duration: CMTime
    private let nominalFrameRate: Float

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let presentPipeline: MTLRenderPipelineState
    private let presentSampler: MTLSamplerState

    private let lock = NSLock()
    private var cancelRequested = false

    private init(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        duration: CMTime,
        nominalFrameRate: Float,
        device: MTLDevice
    ) throws {
        self.asset = asset
        self.videoTrack = videoTrack
        self.audioTrack = audioTrack
        self.naturalSize = naturalSize
        self.preferredTransform = preferredTransform
        self.duration = duration
        self.nominalFrameRate = nominalFrameRate
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw TranscodeError.metalUnavailable
        }
        self.commandQueue = queue

        var cache: CVMetalTextureCache?
        let cacheResult = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &cache
        )
        guard cacheResult == kCVReturnSuccess, let textureCache = cache else {
            throw TranscodeError.metalUnavailable
        }
        self.textureCache = textureCache

        let library = try device.makeDefaultLibrary(bundle: .main)
        guard let vertexFunction = library.makeFunction(name: "presentVertex"),
              let fragmentFunction = library.makeFunction(name: "presentFragment")
        else {
            throw TranscodeError.compileFailed("找不到 presentVertex / presentFragment")
        }
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.presentPipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw TranscodeError.metalUnavailable
        }
        self.presentSampler = sampler
    }

    static func prepare(inputURL: URL) async throws -> (Anime4KOfflineTranscoder, String) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TranscodeError.metalUnavailable
        }
        let asset = AVURLAsset(
            url: inputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else {
            throw TranscodeError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let fps = try await track.load(.nominalFrameRate)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let transcoder = try Anime4KOfflineTranscoder(
            asset: asset,
            videoTrack: track,
            audioTrack: audioTracks.first,
            naturalSize: naturalSize,
            preferredTransform: transform,
            duration: duration,
            nominalFrameRate: fps,
            device: device
        )
        let display = transcoder.displayedSize()
        let info = String(
            format: "%.0f×%.0f · %.1f 秒 · %.0f fps",
            display.width, display.height,
            max(0, duration.seconds), Double(fps > 0 ? fps : 30)
        )
        return (transcoder, info)
    }

    var sourceDurationSeconds: Double {
        max(0, duration.seconds)
    }

    func displayedSize() -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
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

    // MARK: - 主流程

    func transcode(
        settings: TranscodeSettings,
        to outputURL: URL,
        onStage: @escaping @Sendable (String) -> Void,
        progress: @escaping @Sendable (Double, Double) -> Void
    ) async throws -> TranscodeResult {
        let display = displayedSize()
        let shortSide = max(1, min(display.width, display.height))
        let scale: CGFloat = settings.targetHeight > 0
            ? CGFloat(settings.targetHeight) / shortSide
            : 1.0
        let canvasWidth = evenPixels(naturalSize.width * scale)
        let canvasHeight = evenPixels(naturalSize.height * scale)

        let preset = Self.presets.first { $0.key == settings.presetKey } ?? Self.presets[0]
        onStage("正在编译 Anime4K 着色器（首次约几秒）…")
        var engines: [Anime4K] = []
        var currentWidth = max(2, Int(naturalSize.width))
        var currentHeight = max(2, Int(naturalSize.height))
        for path in preset.shaders {
            if isCancelled {
                throw TranscodeError.cancelled
            }
            let parts = path.split(separator: "/")
            guard parts.count == 2 else { continue }
            let engine = try Anime4K(
                String(parts[1]),
                subdir: String(parts[0]),
                device: device
            )
            try engine.compileShaders(
                device,
                videoInW: max(2, Int(naturalSize.width)),
                videoInH: max(2, Int(naturalSize.height)),
                textureInW: currentWidth,
                textureInH: currentHeight,
                displayOutW: canvasWidth,
                displayOutH: canvasHeight
            )
            currentWidth = Int(engine.outputW)
            currentHeight = Int(engine.outputH)
            engines.append(engine)
        }
        guard let last = engines.last,
              last.outputW >= 2, last.outputH >= 2,
              !engines.isEmpty
        else {
            throw TranscodeError.compileFailed("着色器链没有输出")
        }
        let renderWidth = Int(last.outputW)
        let renderHeight = Int(last.outputH)

        let fileManager = FileManager.default
        let workDir = outputURL.deletingLastPathComponent()
        let tempVideoURL = workDir.appendingPathComponent("anime4k_a4k_\(UUID().uuidString).mp4")
        try? fileManager.removeItem(at: tempVideoURL)
        try? fileManager.removeItem(at: outputURL)

        onStage("开始转码…")
        try await encodeVideo(
            to: tempVideoURL,
            engines: engines,
            renderSize: CGSize(width: renderWidth, height: renderHeight),
            progress: progress
        )

        var audioMuxFailed = false
        if audioTrack != nil {
            do {
                try await mux(videoURL: tempVideoURL, outputURL: outputURL)
                try? fileManager.removeItem(at: tempVideoURL)
            } catch {
                audioMuxFailed = true
                try? fileManager.removeItem(at: outputURL)
                try fileManager.moveItem(at: tempVideoURL, to: outputURL)
            }
        } else {
            try fileManager.moveItem(at: tempVideoURL, to: outputURL)
        }

        progress(1.0, 0)
        return TranscodeResult(
            outputURL: outputURL,
            width: renderWidth,
            height: renderHeight,
            duration: max(0, duration.seconds),
            audioMuxFailed: audioMuxFailed
        )
    }

    // MARK: - 逐帧处理 + 编码

    private func encodeVideo(
        to url: URL,
        engines: [Anime4K],
        renderSize: CGSize,
        progress: @escaping @Sendable (Double, Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue(label: "anime4k.offline", qos: .userInitiated).async {
                do {
                    try self.runEncodeLoop(
                        url: url,
                        engines: engines,
                        renderSize: renderSize,
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
        engines: [Anime4K],
        renderSize: CGSize,
        progress: @escaping @Sendable (Double, Double) -> Void,
        continuation: CheckedContinuation<Void, Error>
    ) throws {
        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: readerSettings
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw TranscodeError.readerFailed("无法添加视频输出")
        }
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        let fps = Int(max(24, min(60, Int(nominalFrameRate.rounded()))))
        let bitrate = max(
            4_000_000,
            min(60_000_000, Int(Double(width * height) * 0.10 * Double(fps) / 30.0))
        )
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
        )
        guard writer.canAdd(input) else {
            throw TranscodeError.writerFailed("无法添加视频输入")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw TranscodeError.writerFailed(
                writer.error?.localizedDescription ?? "startWriting 失败"
            )
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw TranscodeError.readerFailed(
                reader.error?.localizedDescription ?? "startReading 失败"
            )
        }

        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        var finished = false
        let totalSeconds = max(0.01, duration.seconds)
        var windowStart = CACurrentMediaTime()
        var windowFrames = 0
        var currentFPS: Double = 0
        var framesSinceCacheFlush = 0

        input.requestMediaDataWhenReady(on: DispatchQueue(label: "anime4k.feed")) {
            if finished { return }
            var shouldStop = false
            while input.isReadyForMoreMediaData && !shouldStop {
                if self.isCancelled {
                    failure = TranscodeError.cancelled
                    shouldStop = true
                    break
                }
                autoreleasepool {
                    if failure != nil {
                        shouldStop = true
                        return
                    }
                    guard let sample = videoOutput.copyNextSampleBuffer() else {
                        // 没有更多数据：EOF 或读取失败，都交给下面的收尾逻辑判断。
                        shouldStop = true
                        return
                    }
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
                        return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    do {
                        try self.process(
                            imageBuffer: imageBuffer,
                            engines: engines,
                            adaptor: adaptor,
                            renderSize: renderSize,
                            presentationTime: pts
                        )
                    } catch {
                        failure = error
                        shouldStop = true
                        return
                    }
                    windowFrames += 1
                    framesSinceCacheFlush += 1
                    if framesSinceCacheFlush >= 30 {
                        framesSinceCacheFlush = 0
                        CVMetalTextureCacheFlush(self.textureCache, 0)
                    }
                    let nowTime = CACurrentMediaTime()
                    let windowElapsed = nowTime - windowStart
                    if windowElapsed >= 0.75 {
                        currentFPS = Double(windowFrames) / windowElapsed
                        windowFrames = 0
                        windowStart = nowTime
                    }
                    let seconds = max(0, CMTimeGetSeconds(pts))
                    progress(min(1.0, seconds / totalSeconds), currentFPS)
                }
            }

            if failure != nil || reader.status == .failed {
                finished = true
                reader.cancelReading()
                writer.cancelWriting()
                if let failure = failure {
                    continuation.resume(throwing: failure)
                } else {
                    continuation.resume(
                        throwing: TranscodeError.readerFailed(
                            reader.error?.localizedDescription ?? "读取中断"
                        )
                    )
                }
                semaphore.signal()
                return
            }

            let isEOF = reader.status != .reading
            if input.isReadyForMoreMediaData && (shouldStop || isEOF) {
                finished = true
                input.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: TranscodeError.writerFailed(
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

    /// 单帧：BGRA 像素缓冲 → Anime4K 链 → 渲染进输出像素缓冲。
    private func process(
        imageBuffer: CVPixelBuffer,
        engines: [Anime4K],
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        renderSize: CGSize,
        presentationTime: CMTime
    ) throws {
        let inputWidth = CVPixelBufferGetWidth(imageBuffer)
        let inputHeight = CVPixelBufferGetHeight(imageBuffer)
        var cvInput: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, imageBuffer, nil,
            .bgra8Unorm, inputWidth, inputHeight, 0, &cvInput
        )
        guard let cvInput = cvInput,
              let inputTexture = CVMetalTextureGetTexture(cvInput)
        else {
            throw TranscodeError.readerFailed("无法创建输入 Metal 纹理")
        }

        guard let pool = adaptor.pixelBufferPool else {
            throw TranscodeError.writerFailed("没有可用的像素缓冲池")
        }
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let outputBuffer = outputBuffer else {
            throw TranscodeError.writerFailed("分配输出像素缓冲失败")
        }
        var cvOutput: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, outputBuffer, nil,
            .bgra8Unorm, Int(renderSize.width), Int(renderSize.height), 0, &cvOutput
        )
        guard let cvOutput = cvOutput,
              let outputTexture = CVMetalTextureGetTexture(cvOutput)
        else {
            throw TranscodeError.writerFailed("无法创建输出 Metal 纹理")
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw TranscodeError.writerFailed("无法创建 Metal 命令缓冲")
        }

        var texture = inputTexture
        for engine in engines {
            texture = try engine.encode(device, cmdBuf: commandBuffer, input: texture)
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = outputTexture
        passDescriptor.colorAttachments[0].loadAction = .dontCare
        passDescriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            throw TranscodeError.writerFailed("无法创建渲染命令编码器")
        }
        encoder.setRenderPipelineState(presentPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(presentSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw TranscodeError.writerFailed("GPU 执行失败：\(error.localizedDescription)")
        }

        if !adaptor.append(outputBuffer, withPresentationTime: presentationTime) {
            throw TranscodeError.writerFailed("append 视频帧失败")
        }
    }

    // MARK: - 音轨直通

    private func mux(videoURL: URL, outputURL: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let compositionVideo = composition.addMutableTrack(
                  withMediaType: .video,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else {
            throw TranscodeError.audioMuxFailed("无法创建视频轨")
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
            throw TranscodeError.audioMuxFailed("无法创建导出会话")
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        if session.status != .completed {
            throw TranscodeError.audioMuxFailed(
                session.error?.localizedDescription ?? "导出失败"
            )
        }
    }

    private func evenPixels(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        return max(2, rounded - (rounded % 2))
    }
}
