//
//  main.swift — CI smoke test for the Anime4K offline transcoder (macOS runner).
//
//  Modes:
//    translate <glslDir> <outDir>   → 把 Anime4K GLSL 翻译成 Metal，逐个 .metal 落盘（随后用 xcrun metal 校验）
//    smoke     <out.mp4> <glslDir>  → 生成测试视频 → 跑完整 transcode 管线 → 校验输出
//

import AVFoundation
import CoreImage
import Foundation
import Metal

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("HARNESS_FAIL: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func note(_ message: String) {
    print("[harness] " + message)
    fflush(stdout)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fail("usage: harness translate|smoke ...")
}
let mode = arguments[1]

// MARK: - translate mode

if mode == "translate" {
    let glslDir = arguments[2]
    let outDir = arguments[3]
    try? FileManager.default.createDirectory(
        atPath: outDir, withIntermediateDirectories: true
    )
    let subdirs = ["Restore", "Upscale", "Upscale+Denoise"]
    var total = 0
    for subdir in subdirs {
        let dir = (glslDir as NSString).appendingPathComponent(subdir)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            fail("missing shader dir: " + dir)
        }
        for file in files where file.hasSuffix(".glsl") {
            let path = (dir as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: path),
                  let glsl = String(data: data, encoding: .utf8)
            else {
                fail("cannot read " + path)
            }
            do {
                let shaders = try MPVShader.parse(glsl)
                for shader in shaders {
                    let name = subdir + "_" + shader.functionName + ".metal"
                    let outPath = (outDir as NSString).appendingPathComponent(name)
                    try shader.metalCode.write(
                        toFile: outPath, atomically: true, encoding: .utf8
                    )
                    total += 1
                }
            } catch {
                fail("parse failed for " + path + ": \(error)")
            }
        }
    }
    note("translated \(total) shader stages")
    print("TRANSLATE_OK")
    exit(0)
}

// MARK: - smoke mode

if mode == "smoke" {
    guard arguments.count >= 4 else {
        fail("usage: harness smoke <out.mp4> <glslDir>")
    }
    let outputURL = URL(fileURLWithPath: arguments[2])
    let glslRoot = arguments[3]
    let inputURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("anime4k_harness_input.mp4")

    guard MTLCreateSystemDefaultDevice() != nil else {
        note("SKIP: no Metal device available on this runner")
        print("SMOKE_SKIPPED")
        exit(0)
    }

    // 资源注入：glsl 目录在 Anime4KMetalTool/ 下，metallib 由 run.sh 编译到 build/default.metallib
    guard let resourceBundle = Bundle(path: glslRoot) else {
        fail("cannot open resource bundle at " + glslRoot)
    }
    Anime4K.bundleOverride = resourceBundle

    let metallibPath = ProcessInfo.processInfo.environment["A4K_METALLIB"] ?? ""
    if !metallibPath.isEmpty, FileManager.default.fileExists(atPath: metallibPath) {
        do {
            Anime4K.libraryOverride = try MTLCreateSystemDefaultDevice()?.makeLibrary(
                URL: URL(fileURLWithPath: metallibPath)
            )
        } catch {
            fail("cannot load default.metallib: \(error)")
        }
    } else {
        fail("default.metallib not found at " + metallibPath)
    }

    do {
        try makeTestMovie(at: inputURL, width: 640, height: 360, seconds: 1.0, fps: 24)
        note("test movie created")

        let semaphore = DispatchSemaphore(value: 0)
        var resultError: Error?
        var resultURL: URL?
        var resultSize: CGSize = .zero
        let started = Date()

        Task {
            do {
                let (transcoder, info) = try await OfflineTranscoder.prepare(inputURL: inputURL)
                note("input: " + info)
                let settings = TranscodeSettings(presetKey: "modeAFast", targetHeight: 720)
                let result = try await transcoder.transcode(settings: settings, to: outputURL) { percent, _ in
                    if percent >= 1.0 { note("progress 100%") }
                }
                resultURL = result.outputURL
                resultSize = CGSize(width: result.width, height: result.height)
            } catch {
                resultError = error
            }
            semaphore.signal()
        }
        semaphore.wait()

        if let error = resultError {
            fail("transcode failed: \(error.localizedDescription)")
        }
        guard let resultURL = resultURL else {
            fail("no output produced")
        }
        let elapsed = Date().timeIntervalSince(started)
        note(String(format: "transcode finished in %.2fs, size %dx%d",
                    elapsed, Int(resultSize.width), Int(resultSize.height)))

        // 校验输出文件
        let asset = AVURLAsset(url: resultURL)
        let sem2 = DispatchSemaphore(value: 0)
        var videoSize: CGSize = .zero
        var duration: Double = 0
        Task {
            do {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    fail("output has no video track")
                }
                videoSize = try await track.load(.naturalSize)
                duration = try await asset.load(.duration).seconds
            } catch {
                fail("cannot inspect output: \(error)")
            }
            sem2.signal()
        }
        sem2.wait()
        note(String(format: "output: %.0fx%.0f, %.2fs",
                    videoSize.width, videoSize.height, duration))
        if videoSize.width < 100 || videoSize.height < 100 {
            fail("output resolution too small")
        }
        if duration < 0.5 {
            fail("output duration too short")
        }

        // 校验首帧不是黑屏
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let sem3 = DispatchSemaphore(value: 0)
        var luminance: Double = 0
        generator.generateCGImagesAsynchronously(
            forTimes: [NSValue(time: CMTime(value: 12, timescale: 24))]
        ) { _, image, _, _, _ in
            if let image = image {
                let ci = CIImage(cgImage: image)
                let context = CIContext()
                var pixel = [UInt8](repeating: 0, count: 4)
                context.render(
                    ci,
                    toBitmap: &pixel,
                    rowBytes: 4,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8,
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )
                luminance = Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])
            }
            sem3.signal()
        }
        sem3.wait()
        note(String(format: "first frame luminance sum: %.0f", luminance))
        if luminance <= 0 {
            fail("output first frame is black")
        }
        print("SMOKE_OK")
        exit(0)
    } catch {
        fail("harness error: \(error)")
    }
}

fail("unknown mode: " + mode)

// MARK: - 测试视频生成

func makeTestMovie(
    at url: URL,
    width: Int,
    height: Int,
    seconds: Double,
    fps: Int
) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
    )
    guard writer.canAdd(input) else {
        throw NSError(domain: "harness", code: 1)
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw writer.error ?? NSError(domain: "harness", code: 2)
    }
    writer.startSession(atSourceTime: .zero)

    let context = CIContext()
    let frames = Int(seconds * Double(fps))
    let w = CGFloat(width)
    let h = CGFloat(height)
    for index in 0..<frames {
        guard let pool = adaptor.pixelBufferPool else {
            throw NSError(domain: "harness", code: 3)
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else {
            throw NSError(domain: "harness", code: 4)
        }
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.005)
        }
        let t = CGFloat(index) / CGFloat(max(1, frames))
        let background = CIImage(color: CIColor(red: 0.08, green: 0.10, blue: 0.16))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let stripe = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95))
            .cropped(to: CGRect(x: w * (0.1 + t * 0.6), y: h * 0.35, width: w * 0.08, height: h * 0.3))
        let accent = CIImage(color: CIColor(red: 0.2, green: 0.9, blue: 0.5))
            .cropped(to: CGRect(x: w * 0.6, y: h * 0.1 + t * h * 0.6, width: w * 0.2, height: h * 0.08))
        let image = stripe.composited(over: accent.composited(over: background))
        context.render(image, to: buffer)
        let pts = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
        if !adaptor.append(buffer, withPresentationTime: pts) {
            throw NSError(domain: "harness", code: 5)
        }
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    if writer.status != .completed {
        throw writer.error ?? NSError(domain: "harness", code: 6)
    }
}
