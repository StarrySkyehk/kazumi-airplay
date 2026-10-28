//
// AutoTranslate.swift
// bitchat
//
// On-device auto-translation of incoming messages.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//
// Added by the sideload build: every message that is not already in the target
// language is translated on-device with Apple's Translation framework and shown
// underneath the original text. Default target: Traditional Chinese.
//

import Foundation
import NaturalLanguage
import SwiftUI

#if canImport(Translation)
import Translation
#endif

// MARK: - Target languages

/// Languages the user can translate into. The raw value is a BCP-47 tag that
/// the Translation framework understands.
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

    /// Endonym, so the picker reads naturally in every app language.
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

// MARK: - Store

/// Holds the auto-translate preference plus the translated-message cache.
///
/// The store is deliberately free of Translation-framework types so it can be
/// referenced from views that only run on older systems; the actual translation
/// happens in `AutoTranslatedMessageView` (iOS 18+).
final class AutoTranslateStore: ObservableObject {
    static let shared = AutoTranslateStore()

    static let enabledKey = "bitchat.autoTranslate.enabled"
    static let targetKey = "bitchat.autoTranslate.target"
    /// Traditional Chinese is the default target: most other-language traffic
    /// in the channels this build is used in is English.
    static let defaultTarget: AutoTranslateTarget = .traditionalChinese

    /// Whether incoming messages are translated at all.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if !enabled {
                resetCache()
            }
        }
    }

    /// Language translated into.
    @Published var target: AutoTranslateTarget {
        didSet {
            UserDefaults.standard.set(target.rawValue, forKey: Self.targetKey)
            resetCache()
        }
    }

    /// message id -> translated text, for the current target language.
    @Published private(set) var translations: [String: String] = [:]

    /// Bumped whenever a translation completes or fails, so queued rows can
    /// retry (the network of sessions is serialised to keep the system's
    /// language-download prompt from appearing once per visible message).
    @Published private(set) var activityTick: Int = 0

    private var busy = false
    private var currentRequestID: String?
    private var failedIDs: Set<String> = []
    private var attemptedIDs: Set<String> = []

    /// Only one translation session runs at a time. The first foreign-language
    /// message may raise the system's "download language" sheet; letting a
    /// dozen rows start sessions at once would queue a dozen sheets.
    private static let watchdogSeconds: Double = 30

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

    // MARK: Reading

    func translation(for messageID: String) -> String? {
        translations[messageID]
    }

    /// True when `text` looks like something worth translating: non-empty,
    /// not a command, contains letters, and is not already in the target
    /// language.
    func shouldTranslate(_ text: String) -> Bool {
        guard enabled else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        guard !trimmed.hasPrefix("/") else { return false }
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return false }
        if let detected = Self.detectLanguage(in: trimmed), detected == target {
            return false
        }
        return true
    }

    /// Best-effort language detection; nil when the recogniser is unsure.
    static func detectLanguage(in text: String) -> AutoTranslateTarget? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        let raw = language.rawValue
        if let exact = AutoTranslateTarget(rawValue: raw) {
            return exact
        }
        // "zh" and friends: fall back to the script-agnostic match.
        return AutoTranslateTarget.allCases.first { $0.languageCode == raw }
    }

    func detectedLanguage(in text: String) -> AutoTranslateTarget? {
        Self.detectLanguage(in: text)
    }

    func hasFailed(_ messageID: String) -> Bool {
        failedIDs.contains(messageID)
    }

    // MARK: Session serialisation

    /// Claims the single translation slot. Returns false when another message
    /// is being translated; the caller retries on the next `activityTick`.
    func beginRequest(_ messageID: String) -> Bool {
        guard Thread.isMainThread else { return false }
        guard !busy else { return false }
        guard !attemptedIDs.contains(messageID) else { return false }
        attemptedIDs.insert(messageID)
        busy = true
        currentRequestID = messageID
        // If a session never reports back (view recycled mid-flight), release
        // the slot so the rest of the conversation is not blocked for ever.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchdogSeconds) { [weak self] in
            guard let self, self.currentRequestID == messageID else { return }
            self.finishRequest(messageID, translation: nil)
        }
        return true
    }

    /// Releases the slot and publishes the result (nil = failed/declined).
    func finishRequest(_ messageID: String, translation: String?) {
        let complete = {
            if self.currentRequestID == messageID {
                self.currentRequestID = nil
                self.busy = false
            } else if self.currentRequestID == nil {
                self.busy = false
            }
            if let translation, !translation.isEmpty {
                self.translations[messageID] = translation
            } else {
                self.failedIDs.insert(messageID)
            }
            self.activityTick &+= 1
        }
        if Thread.isMainThread {
            complete()
        } else {
            DispatchQueue.main.async(execute: complete)
        }
    }

    /// Forgets a message's failure so it can be retried (e.g. after the user
    /// downloaded the language pack).
    func clearFailure(_ messageID: String) {
        let work = {
            self.failedIDs.remove(messageID)
            self.attemptedIDs.remove(messageID)
            self.activityTick &+= 1
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: Private

    private func resetCache() {
        let work = {
            self.translations.removeAll()
            self.failedIDs.removeAll()
            self.attemptedIDs.removeAll()
            self.busy = false
            self.currentRequestID = nil
            self.activityTick &+= 1
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

// MARK: - Per-message translated text

#if canImport(Translation)

/// Shows the translation of one message underneath the original text.
/// Runs entirely on device; the first message in a given language may raise
/// the system's language-download prompt once.
@available(iOS 18.0, macOS 15.0, *)
struct AutoTranslatedMessageView: View {
    let messageID: String
    let text: String

    @ObservedObject private var store = AutoTranslateStore.shared
    @ThemedPalette private var palette
    @State private var configuration: TranslationSession.Configuration?
    @State private var attempted = false

    var body: some View {
        Group {
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
            }
        }
        .onAppear { attempt() }
        .onChange(of: store.activityTick) { _ in attempt() }
        .onChange(of: store.target) { _ in
            configuration = nil
            attempted = false
            attempt()
        }
        .onChange(of: store.enabled) { _ in
            configuration = nil
            attempted = false
            attempt()
        }
        .translationTask(configuration) { session in
            await run(session: session)
        }
    }

    private func attempt() {
        guard !attempted else { return }
        guard store.enabled else { return }
        guard store.translation(for: messageID) == nil else { return }
        guard !store.hasFailed(messageID) else { return }
        guard store.shouldTranslate(text) else { return }
        attempted = true
        guard store.beginRequest(messageID) else {
            // Another row holds the single session slot; retry when it frees.
            attempted = false
            return
        }
        let source = store.detectedLanguage(in: text)?.localeLanguage
        configuration = TranslationSession.Configuration(
            source: source,
            target: store.target.localeLanguage
        )
    }

    private func run(session: TranslationSession) async {
        let id = messageID
        let source = text
        // Ask the system to prepare the language pair; this is what raises the
        // one-time "download translation languages" sheet. A refusal is not
        // fatal: `translate` below decides the outcome.
        try? await session.prepareTranslation()
        do {
            let response = try await session.translate(source)
            store.finishRequest(id, translation: response.targetText)
        } catch {
            store.finishRequest(id, translation: nil)
        }
    }
}

#endif
