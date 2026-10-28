//
// AutoTranslate.swift
// bitchat
//
// On-device auto-translation of incoming messages.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//
// Added by the sideload build. Design notes:
//  * translation runs on device with Apple's Translation framework; nothing
//    leaves the phone;
//  * the actual translation uses a headless `TranslationSession`, so it does
//    not depend on a SwiftUI modifier living inside a recycled list row;
//  * language packs are downloaded through the system permission flow, which
//    needs a `.translationTask` in a stable view (the settings section);
//  * every step records a short status string so failures are visible in the
//    app instead of silently doing nothing.
//

import Foundation
import NaturalLanguage
import SwiftUI

#if canImport(Translation)
import Translation
#endif

// MARK: - Target languages

/// Languages the user can translate into. The raw value is a BCP-47 tag the
/// Translation framework understands.
enum AutoTranslateTarget: String, CaseIterable, Identifiable {
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case portuguese = "pt-BR"
    case italian = "it"
    case russian = "ru"
    case arabic = "ar"
    case thai = "th"
    case vietnamese = "vi"

    var id: String { rawValue }

    /// Primary language subtag, used when matching detected languages.
    var languageCode: String {
        String(rawValue.split(separator: "-").first ?? "")
    }

    var displayName: String {
        switch self {
        case .traditionalChinese: return "繁體中文"
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .portuguese: return "Português"
        case .italian: return "Italiano"
        case .russian: return "Русский"
        case .arabic: return "العربية"
        case .thai: return "ไทย"
        case .vietnamese: return "Tiếng Việt"
        }
    }

    var localeLanguage: Locale.Language { Locale.Language(identifier: rawValue) }
}

// MARK: - Pair status

enum AutoTranslatePairStatus: String {
    case installed
    case needsDownload
    case unsupported
    case unknown

    var label: String {
        switch self {
        case .installed: return "已安装"
        case .needsDownload: return "需下载"
        case .unsupported: return "不支持"
        case .unknown: return "未知"
        }
    }
}

// MARK: - Store

/// Auto-translate state: preference, translated-message cache, a small work
/// queue and the diagnostics shown in settings.
final class AutoTranslateStore: ObservableObject {
    static let shared = AutoTranslateStore()

    static let enabledKey = "bitchat.autoTranslate.enabled"
    static let targetKey = "bitchat.autoTranslate.target"
    /// Traditional Chinese: the point of this build.
    static let defaultTarget: AutoTranslateTarget = .traditionalChinese

    // MARK: Preference

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            reset()
        }
    }

    @Published var target: AutoTranslateTarget {
        didSet {
            UserDefaults.standard.set(target.rawValue, forKey: Self.targetKey)
            reset()
        }
    }

    // MARK: Results

    @Published private(set) var translations: [String: String] = [:]
    @Published private(set) var failures: [String: String] = [:]
    /// Bumped when failures are cleared so visible rows retry.
    @Published private(set) var retryTick: Int = 0

    // MARK: Diagnostics (settings pane)

    @Published private(set) var statusLines: [String] = []
    @Published private(set) var prepareResult: String = ""
    @Published private(set) var pendingSources: [String] = []
    @Published private(set) var lastError: String = ""

    // MARK: Private

    private var pending: [String: String] = [:]
    private var attempted: Set<String> = []
    private var running = 0
    private let maxConcurrent = 2
    private var seenSourceCodes: Set<String> = []
    private var lastPrepareCode: String = "en"
    /// Set when the configured target cannot be used (e.g. that pair is
    /// unsupported) and a sibling Chinese variant worked instead.
    private var workingTargetOverride: AutoTranslateTarget?

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.enabledKey) == nil {
            defaults.set(true, forKey: Self.enabledKey)
        }
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        if let raw = defaults.string(forKey: Self.targetKey),
           let parsed = AutoTranslateTarget(rawValue: raw) {
            self.target = parsed
        } else {
            self.target = Self.defaultTarget
        }
    }

    // MARK: Row-facing API

    func translation(for messageID: String) -> String? { translations[messageID] }

    func failure(for messageID: String) -> String? { failures[messageID] }

    /// Called by every visible message row. Cheap when nothing needs doing.
    func request(messageID: String, text: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.request(messageID: messageID, text: text) }
            return
        }
        guard enabled else { return }
        guard translations[messageID] == nil else { return }
        guard !attempted.contains(messageID) else { return }
        guard Self.isWorthTranslating(text, target: target) else {
            attempted.insert(messageID)
            return
        }
        if let detected = Self.detectLanguage(in: text) {
            seenSourceCodes.insert(detected.languageCode)
        }
        attempted.insert(messageID)
        pending[messageID] = text
        pump()
    }

    // MARK: Settings-facing API

    /// Clears failures so every visible row asks again (after a download).
    func retryEverything() {
        let work: () -> Void = {
            self.failures.removeAll()
            self.attempted.removeAll()
            self.pending.removeAll()
            self.retryTick &+= 1
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Language code the download flow should prepare first.
    func sourceCodeToPrepare() -> String {
        let code: String
        if let first = pendingSources.first { code = first }
        else if let first = seenSourceCodes.sorted().first { code = first }
        else { code = "en" }
        lastPrepareCode = code
        return code
    }

    // MARK: Diagnostics

    func refreshDiagnostics() async {
        var lines: [String] = []
        lines.append("目标：\(target.displayName)（\(target.rawValue)）")
        lines.append("已翻译 \(translations.count) · 排队 \(pending.count) · 失败 \(failures.count) · 运行 \(running)")

        if !lastError.isEmpty {
            lines.append("最近错误：\(lastError)")
        }
        if !prepareResult.isEmpty {
            lines.append("准备语言包：\(prepareResult)")
        }
        if #available(iOS 26.0, macOS 26.0, *) {
            let availability = LanguageAvailability()
            let targetLanguage = target.localeLanguage
            let codes = Array(seenSourceCodes).sorted()
            if codes.isEmpty {
                lines.append("还没收到需要翻译的消息")
            } else {
                for code in codes.prefix(6) {
                    let source = Locale.Language(identifier: code)
                    let status = await availability.status(from: source, to: targetLanguage)
                    lines.append("\(code) → \(target.rawValue)：\(Self.label(for: status))")
                }
            }
        } else {
            lines.append("系统低于 iOS 26，本机翻译不可用")
        }
        let result = lines
        DispatchQueue.main.async { self.statusLines = result }
    }

    /// Runs the system "download language pack" flow for the first pending
    /// source language. Called from a `.translationTask` in the settings view.
    @available(iOS 18.0, macOS 15.0, *)
    func runPrepare(session: TranslationSession) async {
        var notes: [String] = []
        if #available(iOS 26.0, macOS 26.0, *) {
            notes.append("canRequest=\(session.canRequestDownloads)")
        }
        do {
            try await session.prepareTranslation()
            notes.append("download ok")
            let sample = Self.sampleTextForLanguage(self.lastPrepareCode)
            do {
                let response = try await session.translate(sample)
                notes.append("测试「\(sample)」→ \(String(response.targetText.prefix(24)))")
            } catch {
                notes.append("翻译测试失败：\(Self.describe(error))")
            }
        } catch {
            notes.append("下载失败：\(Self.describe(error))")
        }
        let summary = notes.joined(separator: " · ")
        DispatchQueue.main.async {
            self.prepareResult = summary
            self.failures.removeAll()
            self.attempted.removeAll()
            self.pending.removeAll()
            self.retryTick &+= 1
        }
    }

    /// Headless self-test of the current target (does not trigger downloads).
    func runSelfTest() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.runSelfTest() }
            return
        }
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        Task {
            var notes: [String] = []
            let availability = LanguageAvailability()
            let source = Locale.Language(identifier: "en")
            let status = await availability.status(from: source, to: self.target.localeLanguage)
            notes.append("en→\(self.target.rawValue)：\(Self.label(for: status))")
            if status != .unsupported {
                do {
                    let session = TranslationSession(installedSource: source, target: self.target.localeLanguage)
                    let response = try await session.translate(Self.sampleText)
                    notes.append("结果：\(String(response.targetText.prefix(30)))")
                } catch {
                    notes.append("失败：\(Self.describe(error))")
                }
            }
            let summary = notes.joined(separator: " · ")
            DispatchQueue.main.async { self.prepareResult = summary }
        }
    }

    // MARK: Queue

    private func pump() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.pump() }
            return
        }
        guard enabled else { return }
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        while running < maxConcurrent {
            guard let key = pending.keys.first, let text = pending.removeValue(forKey: key) else { return }
            running += 1
            Task { await self.translate(id: key, text: text) }
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func translate(id: String, text: String) async {
        defer {
            DispatchQueue.main.async {
                self.running = max(0, self.running - 1)
                self.pump()
            }
        }
        guard let detected = Self.detectLanguage(in: text) else {
            DispatchQueue.main.async { self.recordFailure(id, "无法识别语言") }
            return
        }
        let source = detected.localeLanguage
        let availability = LanguageAvailability()
        var lastProblem = "未知错误"

        for candidate in candidateTargets() {
            let status = await availability.status(from: source, to: candidate.localeLanguage)
            switch status {
            case .installed:
                do {
                    let session = TranslationSession(installedSource: source, target: candidate.localeLanguage)
                    let response = try await session.translate(text)
                    let translated = response.targetText
                    DispatchQueue.main.async {
                        self.recordSuccess(id, translated, usedTarget: candidate)
                    }
                    return
                } catch {
                    lastProblem = "\(candidate.displayName)：\(Self.describe(error))"
                }
            case .supported:
                lastProblem = "需下载 \(detected.displayName)→\(candidate.displayName) 语言包"
                DispatchQueue.main.async {
                    self.recordNeedsDownload(id, sourceCode: detected.languageCode)
                }
            case .unsupported:
                lastProblem = "不支持 \(detected.displayName)→\(candidate.displayName)"
            @unknown default:
                lastProblem = "未知语言状态"
            }
        }
        let problem = lastProblem
        DispatchQueue.main.async { self.recordFailure(id, problem) }
    }

    private func candidateTargets() -> [AutoTranslateTarget] {
        var list: [AutoTranslateTarget] = []
        if let override = workingTargetOverride { list.append(override) }
        list.append(target)
        switch target {
        case .traditionalChinese: list.append(.simplifiedChinese)
        case .simplifiedChinese: list.append(.traditionalChinese)
        default: break
        }
        var seen = Set<AutoTranslateTarget>()
        return list.filter { seen.insert($0).inserted }
    }

    // MARK: Recording

    private func recordSuccess(_ id: String, _ translation: String, usedTarget: AutoTranslateTarget) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.recordSuccess(id, translation, usedTarget: usedTarget) }
            return
        }
        translations[id] = translation
        failures.removeValue(forKey: id)
        if usedTarget != target {
            workingTargetOverride = usedTarget
            lastError = "目标 \(target.displayName) 不可用，已改用 \(usedTarget.displayName)"
        }
    }

    private func recordFailure(_ id: String, _ reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.recordFailure(id, reason) }
            return
        }
        failures[id] = reason
        lastError = reason
    }

    private func recordNeedsDownload(_ id: String, sourceCode: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.recordNeedsDownload(id, sourceCode: sourceCode) }
            return
        }
        failures[id] = "需下载语言包（\(sourceCode)→\(target.rawValue)）"
        if !pendingSources.contains(sourceCode) {
            pendingSources.append(sourceCode)
        }
        lastError = ""
    }

    private func reset() {
        let work: () -> Void = {
            self.translations.removeAll()
            self.failures.removeAll()
            self.attempted.removeAll()
            self.pending.removeAll()
            self.pendingSources.removeAll()
            self.statusLines = []
            self.workingTargetOverride = nil
            self.lastError = ""
            self.retryTick &+= 1
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: Helpers

    static let sampleText = "Good morning, how are you?"

    static func sampleTextForLanguage(_ code: String) -> String {
        let table: [String: String] = [
            "fr": "Bonjour, comment allez-vous ?",
            "en": "Good morning, how are you?",
            "de": "Guten Morgen, wie geht es dir?",
            "es": "Buenos días, ¿cómo estás?",
            "it": "Buongiorno, come stai?",
            "pt": "Bom dia, como você está?",
            "ru": "Доброе утро, как дела?",
            "ja": "おはようございます、元気ですか？",
            "ko": "좋은 아침입니다, 어떻게 지내세요?",
            "zh": "早上好，你好吗？",
            "ar": "صباح الخير، كيف حالك؟",
            "th": "สวัสดีตอนเช้า สบายดีไหม",
            "vi": "Chào buổi sáng, bạn khỏe không?"
        ]
        return table[code] ?? Self.sampleText
    }

    static func detectLanguage(in text: String) -> AutoTranslateTarget? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        let raw = language.rawValue
        if let exact = AutoTranslateTarget(rawValue: raw) { return exact }
        return AutoTranslateTarget.allCases.first { $0.languageCode == raw }
    }

    static func isWorthTranslating(_ text: String, target: AutoTranslateTarget) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        guard !trimmed.hasPrefix("/") else { return false }
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return false }
        if let detected = detectLanguage(in: trimmed), detected == target { return false }
        return true
    }

    @available(iOS 18.0, macOS 15.0, *)
    static func label(for status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed: return AutoTranslatePairStatus.installed.label
        case .supported: return AutoTranslatePairStatus.needsDownload.label
        case .unsupported: return AutoTranslatePairStatus.unsupported.label
        @unknown default: return AutoTranslatePairStatus.unknown.label
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)(\(ns.code)) \(ns.localizedDescription)"
    }
}

// MARK: - Message row decoration

/// Shows the translation of one message underneath the original text, or the
/// reason it could not be translated.
struct AutoTranslatedMessageView: View {
    let messageID: String
    let text: String

    @ObservedObject private var store = AutoTranslateStore.shared
    @ThemedPalette private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let translated = store.translation(for: messageID) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "character.bubble")
                        .font(.bitchatSystem(size: 9))
                        .foregroundColor(palette.secondary)
                    Text(verbatim: translated)
                        .font(.bitchatSystem(size: 13))
                        .foregroundColor(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 3)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(translated)
            } else if let failure = store.failure(for: messageID) {
                Text(verbatim: "⚠︎ " + failure)
                    .font(.bitchatSystem(size: 10))
                    .foregroundColor(palette.alertRed.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { store.request(messageID: messageID, text: text) }
        .onChange(of: store.retryTick) { _ in
            store.request(messageID: messageID, text: text)
        }
        .onChange(of: store.enabled) { _ in
            store.request(messageID: messageID, text: text)
        }
        .onChange(of: store.target) { _ in
            store.request(messageID: messageID, text: text)
        }
    }
}

// MARK: - Settings section

#if canImport(Translation)

@available(iOS 18.0, macOS 15.0, *)
struct AutoTranslateSettingsSection: View {
    @ObservedObject private var store = AutoTranslateStore.shared
    @ThemedPalette private var palette
    @State private var prepareConfiguration: TranslationSession.Configuration?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(verbatim: "AUTO-TRANSLATE")

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $store.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "translate incoming messages")
                            .font(.bitchatSystem(size: 12, weight: .semibold))
                            .foregroundColor(palette.primary)
                        Text(verbatim: "messages in another language are translated on this device and shown under the original. download the language pack once, then it works offline.")
                            .font(.bitchatSystem(size: 11))
                            .foregroundColor(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(IRCToggleStyle(accent: palette.accent, onLabel: "on", offLabel: "off"))

                targetMenu

                if !store.statusLines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.statusLines, id: \.self) { line in
                            Text(verbatim: line)
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !store.prepareResult.isEmpty {
                    Text(verbatim: "调试：" + store.prepareResult)
                        .font(.bitchatSystem(size: 10))
                        .foregroundColor(palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Button {
                        let code = store.sourceCodeToPrepare()
                        prepareConfiguration = TranslationSession.Configuration(
                            source: Locale.Language(identifier: code),
                            target: store.target.localeLanguage
                        )
                    } label: {
                        Text(verbatim: "下载语言包")
                            .font(.bitchatSystem(size: 11, weight: .semibold))
                            .foregroundColor(palette.accent)
                    }
                    .buttonStyle(.plain)

                    Button {
                        store.runSelfTest()
                    } label: {
                        Text(verbatim: "测试翻译")
                            .font(.bitchatSystem(size: 11, weight: .semibold))
                            .foregroundColor(palette.accent)
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await store.refreshDiagnostics() }
                    } label: {
                        Text(verbatim: "刷新")
                            .font(.bitchatSystem(size: 11))
                            .foregroundColor(palette.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .disabled(!store.enabled)
                .opacity(store.enabled ? 1 : 0.5)
            }
            .padding(12)
            .background(palette.secondary.opacity(0.12))
            .cornerRadius(8)
        }
        .task { await store.refreshDiagnostics() }
        .translationTask(prepareConfiguration) { session in
            await store.runPrepare(session: session)
        }
    }

    private var targetMenu: some View {
        Menu {
            ForEach(AutoTranslateTarget.allCases) { target in
                Button {
                    store.target = target
                } label: {
                    HStack {
                        Text(verbatim: target.displayName)
                        if store.target == target {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(verbatim: "target language")
                    .font(.bitchatSystem(size: 12, weight: .semibold))
                    .foregroundColor(palette.primary)
                Spacer()
                Text(verbatim: store.target.displayName)
                    .font(.bitchatSystem(size: 12))
                    .foregroundColor(palette.accent)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(palette.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!store.enabled)
        .opacity(store.enabled ? 1 : 0.5)
    }
}

#endif
