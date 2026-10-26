//
//  App.swift
//  Anime4KMetalTool
//
//  iPhone 端离线 Anime4K 超分：选一个视频 → 真 Anime4K 着色器链（Metal）→ 导出到相册/分享。
//

import AVFoundation
import Photos
import PhotosUI
import SwiftUI
import UIKit

@main
struct Anime4KMetalToolApp: App {
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
    @Published var fpsText = ""
    @Published var etaText = ""
    @Published var errorText: String?
    @Published var outputURL: URL?
    @Published var outputInfo = ""
    @Published var savedToPhotos = false
    @Published var presetKey: String = OfflineTranscoder.presets[0].key
    @Published var targetHeight: Int = 1080

    private var inputURL: URL?
    private var transcoder: OfflineTranscoder?
    private var sourceDuration: Double = 0
    private var startedAt: Date?
    private var lastPercent: Double = 0
    private var lastSampleTime: Date?
    private var smoothedSpeed: Double = 0

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
        etaText = ""
        phase = .ready
        statusText = "正在读取视频信息…"
        do {
            let (transcoder, info) = try await OfflineTranscoder.prepare(inputURL: url)
            self.transcoder = transcoder
            self.sourceDuration = transcoder.sourceDurationSeconds
            self.sourceInfo = info
            self.statusText = "准备好了，点「开始超分」"
        } catch {
            phase = .failed
            self.transcoder = nil
            statusText = "读取失败"
            errorText = error.localizedDescription
        }
    }

    func start() {
        guard phase == .ready, let transcoder = transcoder else { return }
        let settings = TranscodeSettings(
            presetKey: presetKey,
            targetHeight: targetHeight
        )
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("anime4k_out_\(UUID().uuidString).mp4")
        progress = 0
        speedText = ""
        fpsText = ""
        etaText = ""
        errorText = nil
        savedToPhotos = false
        outputURL = nil
        outputInfo = ""
        phase = .processing
        statusText = "正在准备…"
        startedAt = nil
        lastPercent = 0
        lastSampleTime = nil
        smoothedSpeed = 0
        UIApplication.shared.isIdleTimerDisabled = true

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try await transcoder.transcode(
                    settings: settings,
                    to: output,
                    onStage: { stage in
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            self.statusText = stage
                            if stage.hasPrefix("开始转码") {
                                // 从这里开始计时，编译着色器的时间不算进速度。
                                self.startedAt = Date()
                                self.lastSampleTime = Date()
                                self.lastPercent = 0
                                self.smoothedSpeed = 0
                            }
                        }
                    }
                ) { percent, fps in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.progress = percent
                        if fps > 0 {
                            self.fpsText = String(format: "%.0f fps", fps)
                        }
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
                    if let error = error as? TranscodeError,
                       case .cancelled = error {
                        UIApplication.shared.isIdleTimerDisabled = false
                        self.phase = .ready
                        self.statusText = "已取消，可以重新开始"
                        self.progress = 0
                        self.speedText = ""
                        self.fpsText = ""
                        self.etaText = ""
                        return
                    }
                    UIApplication.shared.isIdleTimerDisabled = false
                    self.phase = .failed
                    self.statusText = "处理失败"
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        transcoder?.cancel()
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
                        continuation.resume(
                            throwing: TranscodeError.writerFailed("保存失败")
                        )
                    }
                }
            }
            savedToPhotos = true
            statusText = "已保存到相册"
        } catch {
            errorText = "保存到相册失败：\(error.localizedDescription)"
        }
    }

    private func finish(with result: TranscodeResult) {
        UIApplication.shared.isIdleTimerDisabled = false
        progress = 1
        phase = .finished
        outputURL = result.outputURL
        statusText = "完成，可以保存到相册或分享"
        speedText = ""
        fpsText = ""
        etaText = ""
        let attributes = try? FileManager.default.attributesOfItem(atPath: result.outputURL.path)
        let bytes = (attributes?[.size] as? Int64) ?? 0
        var info = String(
            format: "%d×%d · %.1f 秒",
            result.width, result.height, result.duration
        )
        if bytes > 0 {
            info += " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        if result.audioMuxFailed {
            info += "\n（音轨合并失败：输出为无声视频）"
        }
        outputInfo = info
    }

    private func updateSpeed(percent: Double) {
        let now = Date()
        guard let lastTime = lastSampleTime else {
            lastSampleTime = now
            lastPercent = percent
            return
        }
        let deltaTime = now.timeIntervalSince(lastTime)
        let deltaPercent = percent - lastPercent
        guard deltaTime > 0.2 else { return }
        lastSampleTime = now
        lastPercent = percent
        guard deltaPercent > 0.0001 else { return }
        // 瞬时速度：这段时间实际处理掉的视频秒数 / 真实耗时
        let instantSpeed = (sourceDuration * deltaPercent) / deltaTime
        smoothedSpeed = smoothedSpeed > 0
            ? smoothedSpeed * 0.65 + instantSpeed * 0.35
            : instantSpeed
        speedText = String(format: "%.2fx 实时", smoothedSpeed)
        let speed = smoothedSpeed
        if speed > 0.001 {
            let remaining = (sourceDuration - processed) / speed
            if remaining > 1 {
                etaText = "剩余约 " + Self.durationText(remaining)
            } else {
                etaText = ""
            }
        }
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        }
        if minutes > 0 {
            return "\(minutes) 分 \(secs) 秒"
        }
        return "\(secs) 秒"
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

                Picker("Anime4K 档位", selection: $job.presetKey) {
                    ForEach(OfflineTranscoder.presets, id: \.key) { preset in
                        Text(preset.title).tag(preset.key)
                    }
                }
                .pickerStyle(.menu)
                .disabled(job.isProcessing)

                Picker("目标分辨率", selection: $job.targetHeight) {
                    Text("1080p（推荐）").tag(1080)
                    Text("1440p（2K）").tag(1440)
                    Text("2160p（4K，很慢）").tag(2160)
                    Text("保持原分辨率").tag(0)
                }
                .pickerStyle(.menu)
                .disabled(job.isProcessing)

                Text("这是真正的 Anime4K 着色器链（GLSL → Metal 动态翻译），和 Kazumi 手机端播放时用的是同一套动画修复算法。\"仅线条修复\"最快的档位。")
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
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(job.speedText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(job.fpsText)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if !job.etaText.isEmpty {
                        Text(job.etaText)
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
                        Label(job.savedToPhotos ? "已保存到相册" : "保存到相册",
                              systemImage: "square.and.arrow.down")
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
            Text("着色器链：bloc97/Anime4K v4 官方 GLSL，经 Anime4KMetal（Apache-2.0）动态翻译成 Metal，在 GPU 上逐帧执行后由 AVAssetWriter 编码成 H.264 mp4。全程本地处理、不联网。\n\n处理期间请保持 App 在前台（我已自动禁止锁屏，但切走 App 会暂停）。速度取决于机型：模式 A（Fast）在 A15 及以上通常不慢于实时，HQ 档明显更慢。")
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
        job.etaText = ""
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
