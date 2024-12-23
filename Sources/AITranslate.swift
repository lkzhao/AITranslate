//
//  AITranslate.swift
//
//
//  Created by Paul MacRory on 3/7/24.
//

import ArgumentParser
import OpenAI
import Foundation
import Markdown

@main
struct AITranslate: AsyncParsableCommand {
    static let systemPrompt =
    """
    You are a translator tool that translates UI strings for a software application.
    System will input a source language, a target language, and
    optionally some context to help you understand how the original text is used within
    the application.
    User will send you the original text for translation.
    In your response include only the translation. Do not wrap it in any markup or escape characters.
    If the original text is markdown, maintain its heading and format.
    Make sure that links, images, and code blocks are preserved in the translation.
    """

    static func gatherLanguages(from input: String) -> [String] {
        input.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    @Argument(transform: URL.init(fileURLWithPath:))
    var inputFile: URL

    @Option(
        name: .shortAndLong,
        help: ArgumentHelp("A comma separated list of language codes (must match the language codes used by xcstrings)"),
        transform: AITranslate.gatherLanguages(from:)
    )
    var languages: [String]

    @Option(
        name: .shortAndLong,
        help: ArgumentHelp("Your OpenAI API key, see: https://platform.openai.com/api-keys")
    )
    var openAIKey: String

    @Flag(name: .shortAndLong)
    var verbose: Bool = false

    @Flag(
        name: .shortAndLong,
        help: ArgumentHelp("By default a backup of the input will be created. When this flag is provided, the backup is skipped.")
    )
    var skipBackup: Bool = false

    @Flag(
        name: .shortAndLong,
        help: ArgumentHelp("Forces all strings to be translated, even if an existing translation is present.")
    )
    var force: Bool = false

    lazy var openAI: OpenAI = {
        let configuration = OpenAI.Configuration(
            token: openAIKey,
            organizationIdentifier: nil,
            timeoutInterval: 60.0
        )

        return OpenAI(configuration: configuration)
    }()

    var numberOfTranslationsProcessed = 0

    mutating func run() async throws {
        do {
            let dict = try JSONDecoder().decode(
                StringsDict.self,
                from: try Data(contentsOf: inputFile)
            )

            let totalNumberOfTranslations = dict.strings.count * languages.count
            let start = Date()
            var previousPercentage: Int = -1

            for entry in dict.strings {
                try await processEntry(
                    key: entry.key,
                    localizationGroup: entry.value,
                    stringsDict: dict
                )

                let fractionProcessed = (Double(numberOfTranslationsProcessed) / Double(totalNumberOfTranslations))
                let percentageProcessed = Int(fractionProcessed * 100)

                // Print the progress at 10% intervals.
                if percentageProcessed != previousPercentage, percentageProcessed % 10 == 0 {
                    print("[⏳] \(percentageProcessed)%")
                    previousPercentage = percentageProcessed
                }

                numberOfTranslationsProcessed += languages.count
            }

            try save(dict)

            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute, .second]
            formatter.unitsStyle = .full
            let formattedString = formatter.string(from: Date().timeIntervalSince(start))!

            print("[✅] 100% \n[⏰] Translations time: \(formattedString)")
        } catch let error {
            throw error
        }
    }

    mutating func processEntry(
        key: String,
        localizationGroup: LocalizationGroup,
        stringsDict: StringsDict
    ) async throws {
        for lang in languages {
            let localizationEntries = localizationGroup.localizations ?? [:]
            let unit = localizationEntries[lang]

            // Nothing to do.
            if let unit, unit.hasTranslation, force == false {
                continue
            }

            // Skip the ones with variations/substitutions since they are not supported.
            if let unit, unit.isSupportedFormat == false {
                print("[⚠️] Unsupported format in entry with key: \(key)")
                continue
            }

            // The source text can either be the key or an explicit value in the `localizations`
            // dictionary keyed by `sourceLanguage`.
            let sourceText = localizationEntries[stringsDict.sourceLanguage]?.stringUnit?.value ?? key

            let result = try await performTranslation(
                sourceText,
                to: lang,
                context: localizationGroup.comment,
                stringsDict: stringsDict,
                openAI: openAI
            )

            localizationGroup.localizations = localizationEntries
            localizationGroup.localizations?[lang] = LocalizationUnit(
                stringUnit: StringUnit(
                    state: result == nil ? "error" : "translated",
                    value: result ?? ""
                )
            )
        }
    }

    func save(_ dict: StringsDict) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(dict)

        try backupInputFileIfNecessary()
        try data.write(to: inputFile)
    }

    func backupInputFileIfNecessary() throws {
        if skipBackup == false {
            let backupFileURL = inputFile.appendingPathExtension("original")

            try? FileManager.default.trashItem(
                at: backupFileURL,
                resultingItemURL: nil
            )

            try FileManager.default.moveItem(
                at: inputFile,
                to: backupFileURL
            )
        }
    }

    func performTranslation(
        _ text: String,
        to target: String,
        context: String? = nil,
        stringsDict: StringsDict,
        openAI: OpenAI
    ) async throws -> String? {

        // Skip text that is generally not translated.
        if text.isEmpty ||
            text.trimmingCharacters(
                in: .whitespacesAndNewlines
                    .union(.symbols)
                    .union(.controlCharacters)
            ).isEmpty {
            return text
        }

        var lowerCaseKeyMap: [String: String] = [:]
        for (key, _) in stringsDict.strings where stringsDict.strings[key.lowercased()] == nil {
            lowerCaseKeyMap[key.lowercased()] = key
        }

        var existingTranslations: [String: String]?
        let strongTextInText = text.markdownStrongTexts.union((context?.markdownStrongTexts ?? []))
        if !strongTextInText.isEmpty {
            existingTranslations = strongTextInText
                .reduce(into: [String: String]()) { result, key in
                    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalKey = lowerCaseKeyMap[trimmed.lowercased()] ?? trimmed
                    result[finalKey] = stringsDict.strings[finalKey]?.localizations?[target]?.stringUnit?.value
                }
        }

        let request = RequestData(
            sourceLanguage: stringsDict.sourceLanguage,
            targetLanguage: target,
            context: context,
            existingTranslations: existingTranslations
        )

        let translationRequest = try String(data: JSONEncoder().encode(request), encoding: .utf8)

        let query = ChatQuery(
            messages: [
                .init(role: .system, content: Self.systemPrompt)!,
                .init(role: .system, content: translationRequest)!,
                .init(role: .user, content: text)!
            ],
            model: "gpt-4o"
        )

        do {
            let result = try await openAI.chats(query: query)
            let translation = result.choices.first?.message.content?.string ?? text

            if verbose {
                if let existingTranslations, !existingTranslations.isEmpty {
                    print("[🔍] Existing translations: \(existingTranslations)")
                }
                print("[\(target)] " + text + " -> " + translation)
            }

            return translation
        } catch let error {
            print("[❌] Failed to translate \(text) into \(target)")

            if verbose {
                print("[💥]" + error.localizedDescription)
            }

            return nil
        }
    }
}

