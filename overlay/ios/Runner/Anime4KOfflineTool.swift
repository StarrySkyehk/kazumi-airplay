//
//  Anime4KOfflineTool.swift
//  Runner
//
//  「离线视频一键超分」：Flutter 设置页点入口后打开原生工具页。
//  用户选择 Kazumi 已下载的视频（video.mp4 / playlist.m3u8）或「文件」App 里的视频，
//  用真正的 Anime4K 着色器（GLSL → Metal，Anime4KMetal 引擎）在 GPU 上逐帧超分，
//  导出新的 mp4，可保存到相册或分享。
//

import AVFoundation
import Flutter
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Flutter bridge

final class Anime4KOfflineManager: NSObject, FlutterStreamHandler {

    static let shared = Anime4KOfflineManager()

    private var channel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    func attach(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "com.predidit.kazumi/anime4k_offline",
            binaryMessenger: messenger
        )
        let events = FlutterEventChannel(
            name: "com.predidit.kazumi/anime4k_offline_events",
            binaryMessenger: messenger
        )
        events.setStreamHandler(self)
        self.eventChannel = events
        channel.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "open":
                DispatchQueue.main.async {
                    self?.presentTool()
                }
                result(true)
            case "isAvailable":
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        self.channel = channel
    }

    /// 通知 Dart 侧：某个下载目录里的原视频已被替换（需要同步 Hive 里的本地路径）。
    func send(event: [String: Any]) {
        guard let sink = eventSink else { return }
        DispatchQueue.main.async {
            sink(event)
        }
    }

    // MARK: FlutterStreamHandler

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func presentTool() {
        guard let presenter = Anime4KOfflineManager.topViewController() else { return }
        if presenter is Anime4KOfflineToolViewController
            || presenter.presentedViewController is UINavigationController {
            return
        }
        let tool = Anime4KOfflineToolViewController()
        let navigation = UINavigationController(rootViewController: tool)
        navigation.modalPresentationStyle = .fullScreen
        presenter.present(navigation, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            guard let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
                  var top = window.rootViewController
            else {
                continue
            }
            while let presented = top.presentedViewController {
                top = presented
            }
            return top
        }
        return nil
    }
}

// MARK: - Downloaded video scanning

private struct OfflineVideoCandidate {
    let title: String
    let subtitle: String
    let url: URL
    let isPlaylist: Bool
}

private enum OfflineScan {

    static func downloadedVideos() -> [OfflineVideoCandidate] {
        let fileManager = FileManager.default
        guard let support = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return []
        }
        let root = support.appendingPathComponent("downloads", isDirectory: true)
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              )
        else {
            return []
        }

        var candidates: [OfflineVideoCandidate] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            guard name == "video.mp4" || name == "playlist.m3u8" else { continue }
            let directory = url.deletingLastPathComponent()
            var title = directory.path
            if let range = title.range(of: root.path) {
                title = String(title[range.upperBound...])
            }
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if title.isEmpty {
                title = directory.lastPathComponent
            }
            let bytes = OfflineScan.directorySize(directory)
            let kind = name == "playlist.m3u8" ? "HLS 分片" : "MP4"
            let detail = "\(kind) · \(OfflineScan.formatBytes(bytes))"
            candidates.append(OfflineVideoCandidate(
                title: title,
                subtitle: detail,
                url: url,
                isPlaylist: name == "playlist.m3u8"
            ))
        }
        return candidates.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func directorySize(_ directory: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Candidate picker (downloaded episodes)

private final class OfflineVideoPickerController: UITableViewController {

    private let candidates: [OfflineVideoCandidate]
    private let onSelect: (OfflineVideoCandidate) -> Void

    init(candidates: [OfflineVideoCandidate], onSelect: @escaping (OfflineVideoCandidate) -> Void) {
        self.candidates = candidates
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
        title = "选择已下载的视频"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        candidates.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let candidate = candidates[indexPath.row]
        cell.textLabel?.text = candidate.title
        cell.textLabel?.numberOfLines = 2
        cell.detailTextLabel?.text = candidate.subtitle
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let candidate = candidates[indexPath.row]
        dismiss(animated: true) {
            self.onSelect(candidate)
        }
    }
}

// MARK: - Main tool screen

final class Anime4KOfflineToolViewController: UIViewController {

    private let presetTitles = ["效率档", "质量档", "仅线条修复"]
    private let presetKeys = ["modeAFast", "modeAHQ", "restore"]
    private let resolutionTitles = ["1080p", "1440p", "4K", "原分辨率"]
    private let resolutionHeights = [1080, 1440, 2160, 0]

    private var presetIndex = 0
    private var resolutionIndex = 0

    private var inputURL: URL?
    private var inputIsPlaylist = false
    /// 从「Kazumi 已下载视频」里选择时，记录该集所在的目录，用于完成后自动替换。
    private var inputSourceDirectory: URL?
    private var replaceResultText: String = ""
    private var transcoder: Anime4KOfflineTranscoder?
    private var hlsLoader: ARLocalHLSResourceLoader?
    private var remuxSession: AVAssetExportSession?
    private var tempInputURL: URL?
    private var outputURL: URL?
    private var isRunning = false

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let sourceLabel = UILabel()
    private let chooseFileButton = UIButton(type: .system)
    private let choosePhotoButton = UIButton(type: .system)
    private let chooseDownloadedButton = UIButton(type: .system)
    private let replaceSwitch = UISwitch()
    private let replaceRow = UIStackView()
    private let replaceHintLabel = UILabel()
    private let presetControl = UISegmentedControl(items: ["效率档", "质量档", "仅线条修复"])
    private let resolutionControl = UISegmentedControl(items: ["1080p", "1440p", "4K", "原分辨率"])
    private let startButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let progressLabel = UILabel()
    private let detailLabel = UILabel()
    private let savePhotosButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let savedLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "离线视频 Anime4K 超分"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(dismissTool)
        )
        buildUI()
        updateSourceUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = isRunning
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    deinit {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: UI

    private func buildUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 16, left: 18, bottom: 32, right: 18)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        // 说明
        let intro = UILabel()
        intro.numberOfLines = 0
        intro.font = .preferredFont(forTextStyle: .footnote)
        intro.textColor = .secondaryLabel
        intro.text = "用真正的 Anime4K 着色器（GLSL → Metal）在手机 GPU 上超分，导出新的 mp4。"
            + "处理期间请保持本页面在前台。首次会先编译着色器，约几秒。"
        contentStack.addArrangedSubview(intro)

        // 来源
        contentStack.addArrangedSubview(sectionTitle("1. 选择视频"))
        sourceLabel.numberOfLines = 2
        sourceLabel.font = .preferredFont(forTextStyle: .subheadline)
        sourceLabel.textColor = .secondaryLabel
        sourceLabel.text = "尚未选择视频"
        contentStack.addArrangedSubview(sourceLabel)

        configureButtons()
        let sourceRow = UIStackView(arrangedSubviews: [chooseDownloadedButton, chooseFileButton, choosePhotoButton])
        sourceRow.axis = .vertical
        sourceRow.spacing = 8
        contentStack.addArrangedSubview(sourceRow)

        // 下载视频：完成后自动替换原视频（写入同目录的 video.mp4，原文件备份）
        let replaceTitle = UILabel()
        replaceTitle.text = "完成后自动替换原视频"
        replaceTitle.font = .preferredFont(forTextStyle: .body)
        replaceRow.axis = .horizontal
        replaceRow.spacing = 12
        replaceRow.alignment = .center
        replaceRow.addArrangedSubview(replaceTitle)
        replaceRow.addArrangedSubview(UIView())
        replaceRow.addArrangedSubview(replaceSwitch)
        replaceSwitch.isOn = true
        replaceHintLabel.numberOfLines = 0
        replaceHintLabel.font = .preferredFont(forTextStyle: .caption1)
        replaceHintLabel.textColor = .secondaryLabel
        replaceHintLabel.text = "把超分结果写回该集下载目录的 video.mp4（原文件备份为 video_backup.mp4），"
            + "Kazumi 的下载列表会直接播放新视频，不需要手动导出。"
        replaceRow.isHidden = true
        replaceHintLabel.isHidden = true
        contentStack.addArrangedSubview(replaceRow)
        contentStack.addArrangedSubview(replaceHintLabel)

        // 设置
        contentStack.addArrangedSubview(sectionTitle("2. 超分设置"))
        presetControl.selectedSegmentIndex = presetIndex
        presetControl.addTarget(self, action: #selector(presetChanged), for: .valueChanged)
        contentStack.addArrangedSubview(presetControl)

        resolutionControl.selectedSegmentIndex = resolutionIndex
        resolutionControl.addTarget(self, action: #selector(resolutionChanged), for: .valueChanged)
        contentStack.addArrangedSubview(resolutionControl)

        let hint = UILabel()
        hint.numberOfLines = 0
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabel
        hint.text = "1080p 以上建议用「原分辨率」只做线条修复；720p 升 1080p 提升最明显。HQ 档明显更慢。"
        contentStack.addArrangedSubview(hint)

        // 操作
        contentStack.addArrangedSubview(sectionTitle("3. 开始处理"))
        startButton.setTitle("开始超分", for: .normal)
        startButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        startButton.backgroundColor = .systemGreen
        startButton.setTitleColor(.black, for: .normal)
        startButton.layer.cornerRadius = 12
        startButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(startButton)

        progressView.progress = 0
        contentStack.addArrangedSubview(progressView)

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        progressLabel.text = " "
        contentStack.addArrangedSubview(progressLabel)

        detailLabel.numberOfLines = 0
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.textColor = .secondaryLabel
        detailLabel.text = " "
        contentStack.addArrangedSubview(detailLabel)

        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.isHidden = true
        contentStack.addArrangedSubview(cancelButton)

        // 导出
        contentStack.addArrangedSubview(sectionTitle("4. 导出结果"))
        let exportRow = UIStackView(arrangedSubviews: [savePhotosButton, shareButton])
        exportRow.axis = .horizontal
        exportRow.spacing = 10
        exportRow.distribution = .fillEqually
        configureExportButton(savePhotosButton, title: "保存到相册", systemImage: "square.and.arrow.down")
        configureExportButton(shareButton, title: "分享 / 存储", systemImage: "square.and.arrow.up")
        savePhotosButton.addTarget(self, action: #selector(saveToPhotosTapped), for: .touchUpInside)
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(exportRow)
        savePhotosButton.isHidden = true
        shareButton.isHidden = true

        savedLabel.numberOfLines = 0
        savedLabel.font = .preferredFont(forTextStyle: .caption1)
        savedLabel.textColor = .secondaryLabel
        savedLabel.text = " "
        contentStack.addArrangedSubview(savedLabel)
    }

    private func configureButtons() {
        for button in [chooseDownloadedButton, chooseFileButton, choosePhotoButton] {
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.layer.cornerRadius = 10
            button.backgroundColor = .secondarySystemBackground
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        }
        chooseDownloadedButton.setTitle("从 Kazumi 已下载视频中选择", for: .normal)
        chooseFileButton.setTitle("从「文件」App 选择视频", for: .normal)
        choosePhotoButton.setTitle("从相册选择视频", for: .normal)
        chooseDownloadedButton.addTarget(self, action: #selector(chooseDownloadedTapped), for: .touchUpInside)
        chooseFileButton.addTarget(self, action: #selector(chooseFileTapped), for: .touchUpInside)
        choosePhotoButton.addTarget(self, action: #selector(choosePhotoTapped), for: .touchUpInside)
    }

    private func configureExportButton(_ button: UIButton, title: String, systemImage: String) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.image = UIImage(systemName: systemImage)
        config.imagePadding = 6
        config.cornerStyle = .medium
        button.configuration = config
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    private func sectionTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .headline)
        return label
    }

    private func updateSourceUI() {
        if let inputURL = inputURL {
            sourceLabel.textColor = .label
            sourceLabel.text = "已选择：" + (inputIsPlaylist
                ? inputURL.deletingLastPathComponent().lastPathComponent + "（HLS 分片，会先合并成 mp4）"
                : inputURL.lastPathComponent)
        } else {
            sourceLabel.textColor = .secondaryLabel
            sourceLabel.text = "尚未选择视频"
        }
        startButton.isEnabled = inputURL != nil && !isRunning
        startButton.alpha = startButton.isEnabled ? 1 : 0.4
    }

    private func setRunning(_ running: Bool) {
        isRunning = running
        UIApplication.shared.isIdleTimerDisabled = running
        for control in [chooseDownloadedButton, chooseFileButton, choosePhotoButton] {
            control.isEnabled = !running
            control.alpha = running ? 0.4 : 1
        }
        presetControl.isEnabled = !running
        resolutionControl.isEnabled = !running
        startButton.isEnabled = !running && inputURL != nil
        cancelButton.isHidden = !running
    }

    // MARK: Actions

    @objc private func dismissTool() {
        if isRunning {
            let alert = UIAlertController(
                title: "正在处理",
                message: "确认取消并关闭吗？",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "继续处理", style: .cancel))
            alert.addAction(UIAlertAction(title: "取消并关闭", style: .destructive) { _ in
                self.transcoder?.cancel()
                self.remuxSession?.cancelExport()
                self.dismiss(animated: true)
            })
            present(alert, animated: true)
            return
        }
        dismiss(animated: true)
    }

    @objc private func presetChanged() {
        presetIndex = presetControl.selectedSegmentIndex
    }

    @objc private func resolutionChanged() {
        resolutionIndex = resolutionControl.selectedSegmentIndex
    }

    @objc private func chooseDownloadedTapped() {
        let candidates = OfflineScan.downloadedVideos()
        guard !candidates.isEmpty else {
            showMessage("没有找到已下载的视频", detail: "先在 Kazumi 里下载剧集，或改用「文件」/相册选择。")
            return
        }
        let picker = OfflineVideoPickerController(candidates: candidates) { [weak self] candidate in
            self?.setInput(
                url: candidate.url,
                isPlaylist: candidate.isPlaylist,
                sourceDirectory: candidate.url.deletingLastPathComponent()
            )
        }
        let navigation = UINavigationController(rootViewController: picker)
        present(navigation, animated: true)
    }

    @objc private func chooseFileTapped() {
        let types: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video, .audiovisualContent]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    @objc private func choosePhotoTapped() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func setInput(url: URL, isPlaylist: Bool, sourceDirectory: URL? = nil) {
        inputURL = url
        inputIsPlaylist = isPlaylist
        inputSourceDirectory = sourceDirectory
        replaceResultText = ""
        replaceRow.isHidden = sourceDirectory == nil
        replaceHintLabel.isHidden = sourceDirectory == nil
        outputURL = nil
        updateSourceUI()
        savePhotosButton.isHidden = true
        shareButton.isHidden = true
        savedLabel.text = " "
        let fileSize = OfflineScan.directorySize(url.deletingLastPathComponent())
        detailLabel.text = isPlaylist
            ? "已选择 HLS 分片目录（\(OfflineScan.formatBytes(fileSize))），开始后会先合并为 mp4"
            : "已选择视频文件"
    }

    @objc private func startTapped() {
        guard let inputURL = inputURL, !isRunning else { return }
        setRunning(true)
        startButton.setTitle("处理中…", for: .normal)
        progressView.progress = 0
        progressLabel.text = "准备中…"
        detailLabel.text = " "
        outputURL = nil
        savePhotosButton.isHidden = true
        shareButton.isHidden = true
        savedLabel.text = " "

        let presetKey = presetKeys[max(0, min(presetKeys.count - 1, presetIndex))]
        let height = resolutionHeights[max(0, min(resolutionHeights.count - 1, resolutionIndex))]
        let targetHeight = presetKey == "restore" ? 0 : height
        let isPlaylist = inputIsPlaylist

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let preparedURL = try await self.prepareInput(inputURL, isPlaylist: isPlaylist)
                let (transcoder, _) = try await Anime4KOfflineTranscoder.prepare(inputURL: preparedURL)
                self.transcoder = transcoder
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent("kazumi_anime4k_\(UUID().uuidString).mp4")
                let settings = TranscodeSettings(presetKey: presetKey, targetHeight: targetHeight)
                let result = try await transcoder.transcode(
                    settings: settings,
                    to: output,
                    onStage: { [weak self] stage in
                        Task { @MainActor in
                            self?.progressLabel.text = stage
                        }
                    },
                    progress: { [weak self] percent, fps in
                        Task { @MainActor in
                            self?.updateProgress(percent: percent, fps: fps)
                        }
                    }
                )
                await MainActor.run {
                    self.finish(with: result)
                }
            } catch {
                await MainActor.run {
                    self.fail(error)
                }
            }
        }
    }

    private func updateProgress(percent: Double, fps: Double) {
        progressView.progress = Float(percent)
        var text = String(format: "%.0f%%", percent * 100)
        if fps > 0 {
            text += String(format: " · %.0f fps", fps)
        }
        progressLabel.text = text
    }

    private func finish(with result: TranscodeResult) {
        setRunning(false)
        startButton.setTitle("开始超分", for: .normal)
        progressView.progress = 1
        let attributes = try? FileManager.default.attributesOfItem(atPath: result.outputURL.path)
        let outputBytes = (attributes?[.size] as? Int64) ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: outputBytes, countStyle: .file)
        progressLabel.text = "完成"
        detailLabel.text = "\(result.width)×\(result.height) · \(String(format: "%.1f", result.duration)) 秒 · \(sizeText)"
        if result.audioMuxFailed {
            detailLabel.text = (detailLabel.text ?? "") + "\n（音轨合并失败：输出为无声视频）"
        }
        outputURL = result.outputURL
        performReplaceIfNeeded(result: result)
        savePhotosButton.isHidden = false
        shareButton.isHidden = false
        savedLabel.text = " "
        updateSourceUI()
    }

    /// 把超分结果写回下载目录：video.mp4（原文件备份为 video_backup.mp4），并通知 Dart 更新 Hive。
    private func performReplaceIfNeeded(result: TranscodeResult) {
        guard replaceSwitch.isOn, let directory = inputSourceDirectory else { return }
        let fileManager = FileManager.default
        let target = directory.appendingPathComponent("video.mp4")
        do {
            if fileManager.fileExists(atPath: target.path) {
                let backup = directory.appendingPathComponent("video_backup.mp4")
                try? fileManager.removeItem(at: backup)
                try fileManager.moveItem(at: target, to: backup)
            }
            do {
                try fileManager.moveItem(at: result.outputURL, to: target)
            } catch {
                try fileManager.copyItem(at: result.outputURL, to: target)
                try? fileManager.removeItem(at: result.outputURL)
            }
            outputURL = target
            replaceResultText = "已替换原视频：\(target.path)\n（原文件备份为 video_backup.mp4）"
            Anime4KOfflineManager.shared.send(event: [
                "type": "replaced",
                "directory": directory.path,
                "videoPath": target.path,
            ])
        } catch {
            replaceResultText = "替换原视频失败：" + error.localizedDescription
        }
        if !replaceResultText.isEmpty {
            detailLabel.text = (detailLabel.text ?? "") + "\n" + replaceResultText
        }
    }

    private func fail(_ error: Error) {
        setRunning(false)
        startButton.setTitle("开始超分", for: .normal)
        progressLabel.text = "失败"
        detailLabel.text = error.localizedDescription
        updateSourceUI()
    }

    private func prepareInput(_ url: URL, isPlaylist: Bool) async throws -> URL {
        if !isPlaylist {
            return url
        }
        await MainActor.run {
            self.progressLabel.text = "正在合并 HLS 分片…"
            self.progressView.progress = 0
        }
        let directory = url.deletingLastPathComponent()
        let loader = ARLocalHLSResourceLoader(directory: directory)
        hlsLoader = loader
        var components = URLComponents()
        components.scheme = ARLocalHLSResourceLoader.customScheme
        components.host = ARLocalHLSResourceLoader.customHost
        components.path = "/" + url.lastPathComponent
        guard let customURL = components.url else {
            throw TranscodeError.readerFailed("本地 HLS 地址无效")
        }
        let asset = AVURLAsset(url: customURL)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue.global(qos: .userInitiated))
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("kazumi_anime4k_hls_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: output)

        if let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) {
            remuxSession = session
            session.outputURL = output
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
            remuxSession = nil
            if session.status == .completed {
                tempInputURL = output
                return output
            }
        }
        // 直通失败时退回重新封装（H.264/AAC）
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw TranscodeError.readerFailed("无法创建 HLS 合并会话")
        }
        remuxSession = session
        session.outputURL = output
        session.outputFileType = .mp4
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        remuxSession = nil
        guard session.status == .completed else {
            throw TranscodeError.readerFailed(
                session.error?.localizedDescription ?? "HLS 分片合并失败"
            )
        }
        tempInputURL = output
        return output
    }

    @objc private func cancelTapped() {
        transcoder?.cancel()
        remuxSession?.cancelExport()
        progressLabel.text = "正在取消…"
    }

    @objc private func saveToPhotosTapped() {
        guard let outputURL = outputURL else { return }
        savePhotosButton.isEnabled = false
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
        } completionHandler: { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.savePhotosButton.isEnabled = true
                if success {
                    self.savedLabel.text = "已保存到相册"
                } else {
                    self.savedLabel.text = "保存失败：" + (error?.localizedDescription ?? "未知错误")
                }
            }
        }
    }

    @objc private func shareTapped() {
        guard let outputURL = outputURL else { return }
        let activity = UIActivityViewController(activityItems: [outputURL], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        present(activity, animated: true)
    }

    private func showMessage(_ title: String, detail: String) {
        let alert = UIAlertController(title: title, message: detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - Document / photo pickers

extension Anime4KOfflineToolViewController: UIDocumentPickerDelegate {

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else { return }
        let isPlaylist = url.pathExtension.lowercased() == "m3u8"
        setInput(url: url, isPlaylist: isPlaylist)
    }
}

extension Anime4KOfflineToolViewController: PHPickerViewControllerDelegate {

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        else {
            return
        }
        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
            guard let url = url else { return }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("kazumi_anime4k_photo_\(UUID().uuidString)")
                .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                DispatchQueue.main.async {
                    self?.setInput(url: destination, isPlaylist: false)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showMessage("无法读取该相册视频", detail: error.localizedDescription)
                }
            }
        }
    }
}
