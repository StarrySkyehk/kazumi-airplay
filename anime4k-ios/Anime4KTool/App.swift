//
//  App.swift
//  Anime4KTool
//
//  iPhone 端离线超分小工具：选一个视频 → Core Image 超分 → 导出到相册/分享。
//

import AVFoundation
import Photos
import PhotosUI
import SwiftUI

@main
struct Anime4KToolApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - View model

@MainActor
final class JobModel: ObservableObject {

    enum Phase {
        case idle
        case ready
        case processing
        case finished
        case failed
    }

    @Published var phase: Phase = .idle
    @Published var sourceName = ""
    @Published var sourceInfo = ""
    @Published var statusText = "从相册或文件里选一个视频"
    @Published var progress: Double = 0
    @Published var speedText = ""
    @Published var errorText: String?
    @Published var outputURL: URL?
    @Published var outputInfo = ""
    @Published var savedToPhotos = false
    @Published var targetHeight: Int = 1080
    @Published var strongMode: Bool = true

    private var inputURL: URL?
    private var upscaler: VideoUpscaler?
    private var sourceDuration: Double = 0
    private var startedAt: Date?

    var isProcessing: Bool {
        phase == .processing
    }

    func select(_ url: URL) async {
        inputURL = url
        sourceName = url.lastPathComponent
        sourceInfo = ""
        outputURL = nil
        outputInfo = ""
        savedToPhotos = false
        progress = 0
        speedText = ""
        phase = .ready
        statusText = "正在读取视频信息…"
        do {
            let (upscaler, info) = try await VideoUpscaler.prepare(inputURL: url)
            self.upscaler = upscaler
            self.sourceDuration = upscaler.sourceDurationSeconds
            self.sourceInfo = info
            self.statusText = "准备好了，点「开始超分」"
        } catch {
            phase = .failed
            self.upscaler = nil
            statusText = "读取失败"
            errorText = error.localizedDescription
        }
    }

    func start() {
        guard phase == .ready, let upscaler = upscaler else { return }
        let settings = UpscaleSettings(
            targetHeight: targetHeight,
            strongMode: strongMode
        )
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("anime4k_out_\(UUID().uuidString).mp4")
        progress = 0
        speedText = ""
        errorText = nil
        savedToPhotos = false
        outputURL = nil
        outputInfo = ""
        phase = .processing
        statusText = "处理中…（可随时取消）"
        startedAt = Date()

        let job = upscaler
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try await job.export(
                    settings: settings,
                    to: output
                ) { percent, _ in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.progress = percent
                        self.updateSpeed(percent: percent)
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.finish(with: result)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    if let upscaleError = error as? UpscaleError,
                       case .cancelled = upscaleError {
                        self.phase = .ready
                        self.statusText = "已取消，可以重新开始"
                        self.progress = 0
                        self.speedText = ""
                        return
                    }
                    self.phase = .failed
                    self.statusText = "处理失败"
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        upscaler?.cancel()
        statusText = "正在取消…"
    }

    func saveToPhotos() async {
        guard let url = outputURL else { return }
        statusText = "正在保存到相册…"
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { success, error in
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error ?? UpscaleError.writerFailed("保存失败"))
                    }
                }
            }
            savedToPhotos = true
            statusText = "已保存到相册"
        } catch {
            errorText = "保存到相册失败：\(error.localizedDescription)"
        }
    }

    private func finish(with result: UpscaleResult) {
        progress = 1
        phase = .finished
        outputURL = result.outputURL
        statusText = "完成，可以保存到相册或分享"
        speedText = ""
        let attributes = try? FileManager.default.attributesOfItem(atPath: result.outputURL.path)
        let bytes = (attributes?[.size] as? Int64) ?? 0
        var info = String(
            format: "%d×%d · %.1f 秒",
            result.width, result.height, result.duration
        )
        if bytes > 0 {
            info += " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        outputInfo = info
    }

    private func updateSpeed(percent: Double) {
        guard let startedAt = startedAt, percent > 0.01 else { return }
        let elapsed = max(0.1, Date().timeIntervalSince(startedAt))
        let processed = sourceDuration * percent
        let speed = processed / elapsed
        speedText = String(format: "%.1fx 实时", speed)
    }
}

// MARK: - Views

struct ContentView: View {

    @StateObject private var job = JobModel()
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceSection
                    settingsSection
                    actionSection
                    if job.outputURL != nil {
                        resultSection
                    }
                    footnote
                }
                .padding(18)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Anime4K 超分")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if job.phase == .finished {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("新视频") { reset() }
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.movie],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .onChange(of: photoItem) { _, newValue in
                guard let item = newValue else { return }
                Task {
                    if let movie = try? await item.loadTransferable(type: ImportedMovie.self) {
                        await job.select(movie.url)
                    } else {
                        job.errorText = "无法读取相册里的这个视频。"
                    }
                    photoItem = nil
                }
            }
            .alert("出错了", isPresented: Binding(
                get: { job.errorText != nil },
                set: { if !$0 { job.errorText = nil } }
            )) {
                Button("好", role: .cancel) { job.errorText = nil }
            } message: {
                Text(job.errorText ?? "")
            }
        }
    }

    // MARK: Sections

    private var sourceSection: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("1. 选择视频")
                    .font(.headline)
                if job.sourceName.isEmpty {
                    Text("支持相册里的视频，或「文件」App 里的视频文件。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(job.sourceName)
                        .font(.subheadline)
                        .lineLimit(2)
                    Text(job.sourceInfo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    PhotosPicker(
                        selection: $photoItem,
                        matching: .videos,
                        photoLibrary: .shared()
                    ) {
                        Label("从相册选择", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(job.isProcessing)

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("从文件选择", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(job.isProcessing)
                }
            }
        }
    }

    private var settingsSection: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("2. 超分设置")
                    .font(.headline)
                Picker("目标分辨率", selection: $job.targetHeight) {
                    Text("1080p（推荐）").tag(1080)
                    Text("1440p（2K）").tag(1440)
                    Text("2160p（4K，很慢）").tag(2160)
                    Text("保持原分辨率").tag(0)
                }
                .pickerStyle(.menu)
                .disabled(job.isProcessing)

                Toggle("质量档（线条更强，速度稍慢）", isOn: $job.strongMode)
                    .disabled(job.isProcessing)

                Text("1080p 以上建议用「保持原分辨率」只做线条修复；720p 源升到 1080p 提升最明显。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionSection: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                if job.isProcessing {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                    HStack {
                        Text(String(format: "%.0f%%", job.progress * 100))
                            .font(.system(.title3, design: .rounded).bold())
                        Spacer()
                        Text(job.speedText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(job.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        job.cancel()
                    } label: {
                        Label("取消", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        job.start()
                    } label: {
                        Label("开始超分", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(job.phase != .ready)

                    Text(job.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var resultSection: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("3. 导出")
                    .font(.headline)
                Text(job.outputInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        Task { await job.saveToPhotos() }
                    } label: {
                        Label(job.savedToPhotos ? "已保存到相册" : "保存到相册", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(job.savedToPhotos)

                    if let url = job.outputURL {
                        ShareLink(item: url) {
                            Label("分享/存储", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("实现说明")
                .font(.footnote.bold())
            Text("iOS 端用 Core Image 做「边缘保留放大 + 线条锐化」，不是 mpv/Anime4K 的 GLSL 着色器（iOS 无法直接加载）。观感方向一致：线条更干净、更锐；对 720p→1080p 最明显。处理完全在手机本地完成，不联网、不上传。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: Helpers

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func reset() {
        job.phase = .idle
        job.sourceName = ""
        job.sourceInfo = ""
        job.outputURL = nil
        job.outputInfo = ""
        job.progress = 0
        job.speedText = ""
        job.savedToPhotos = false
        job.statusText = "从相册或文件里选一个视频"
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let fileManager = FileManager.default
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            let destination = fileManager.temporaryDirectory
                .appendingPathComponent("anime4k_file_\(UUID().uuidString)")
                .appendingPathExtension(ext)
            do {
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: url, to: destination)
                Task { await job.select(destination) }
            } catch {
                job.errorText = "无法读取这个文件：\(error.localizedDescription)"
            }
        case .failure(let error):
            job.errorText = error.localizedDescription
        }
    }
}
