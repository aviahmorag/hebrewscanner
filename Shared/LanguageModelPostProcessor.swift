//
//  LanguageModelPostProcessor.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

import Foundation

/// Post-processes OCR boxes using DictaBERT to fix OCR errors.
///
/// Three phases:
/// 1. **Latin garbage replacement**: Tesseract frequently misreads Hebrew as Latin sequences
///    (e.g. "OR" for "אם", "WIN" for "הוועד"). Each Latin word in a Hebrew-context line is
///    masked, and DictaBERT's top Hebrew prediction replaces it.
/// 2. **Hebrew near-miss correction**: For Hebrew words, the model predicts what should be there
///    and compares via Levenshtein distance. If the edit distance is small (1), it's likely
///    a character confusion (ר↔ד, ו↔ז, ב↔כ) and the prediction replaces the OCR output.
/// 3. **Character confusion fallback**: For words the LM couldn't fix (e.g. in TOC lines with
///    no useful context), try known OCR confusion pairs (ב↔כ, ר↔ד, etc.) and check if
///    swapping one character produces a word in the BERT vocabulary.
enum LanguageModelPostProcessor {

    /// Minimum probability for the top Hebrew prediction to replace a Latin word.
    /// With 128K vocabulary the probability mass is spread thin, so 0.05 captures
    /// confident predictions like אם(0.09), הוועד(0.08) that 0.10 would reject.
    private static let latinReplacementThreshold: Float = 0.05

    /// Minimum probability for a Hebrew near-miss correction.
    /// The dist=1 same-length constraint already provides safety, so 0.15 catches
    /// common OCR confusions like ר↔ד (מעמר→מעמד) and ב↔כ (בללי→כללי).
    private static let hebrewCorrectionThreshold: Float = 0.15

    /// Maximum Levenshtein distance to consider a Hebrew word an OCR near-miss.
    /// Only single-character substitutions (dist=1) are reliable — dist=2 causes false corrections.
    private static let maxEditDistance = 1

    /// Minimum word length for Hebrew near-miss correction (short words are too ambiguous).
    private static let minWordLenForCorrection = 3

    /// Minimum number of Hebrew words in a line to consider it Hebrew context.
    private static let minHebrewWordsForContext = 2

    /// Known OCR character confusion pairs for Hebrew block script.
    /// Used by Phase 3 as a context-free fallback when the LM has no useful context.
    private static let confusionPairs: [(Character, Character)] = [
        ("ר", "ד"),  // resh ↔ dalet
        ("ב", "כ"),  // bet ↔ kaf
        ("ו", "ז"),  // vav ↔ zayin
        ("ה", "ח"),  // he ↔ chet
        ("ם", "ס"),  // final mem ↔ samech
        ("ן", "ו"),  // final nun ↔ vav
    ]

    /// Process OCR boxes: replace Latin garbage, correct Hebrew near-misses, and clean garbage lines.
    static func process(boxes: [OCRBox]) async -> [OCRBox] {
        let model = HebrewLanguageModel.shared

        var result = boxes

        if await model.isReady {
            // Group boxes by lineId
            var lineGroups: [Int: [Int]] = [:]
            for (i, box) in result.enumerated() {
                lineGroups[box.lineId, default: []].append(i)
            }

            var latinReplacedCount = 0
            var hebrewCorrectedCount = 0
            var confusionCorrectedCount = 0
            var placeholderCount = 0

            for (_, indices) in lineGroups {
                var hebrewCount = 0
                var latinIndices: [Int] = []
                var hebrewIndices: [Int] = []

                for idx in indices {
                    let box = result[idx]
                    if box.isPlaceholder { continue }

                    let sc = classifyScript(box.text)
                    switch sc {
                    case .hebrew:
                        hebrewCount += 1
                        hebrewIndices.append(idx)
                    case .hebrewMixed:
                        hebrewCount += 1
                    case .latinOnly:
                        latinIndices.append(idx)
                    default:
                        break
                    }
                }

                guard hebrewCount >= minHebrewWordsForContext else { continue }

                let sortedIndices = indices.sorted { result[$0].wordNum < result[$1].wordNum }

                // Phase 1: Replace Latin garbage with Hebrew predictions
                for idx in latinIndices {
                    let word = result[idx].text
                    let lineText = sortedIndices.map { result[$0].text }.joined(separator: " ")

                    guard let prediction = await model.predictMasked(
                        lineText: lineText, wordToMask: word
                    ) else { continue }

                    let bestHebrew = prediction.topTokens.first { token, _ in
                        isHebrew(token) && !token.hasPrefix("##")
                    }

                    if let (token, prob) = bestHebrew, prob >= latinReplacementThreshold {
                        let top3 = formatTop3(prediction.topTokens)
                        print("🤖 LM: '\u{200E}\(word)\u{200E}' → '\u{200E}\(token)\u{200E}' (prob=\(f2(prob)), top=[\(top3)])")
                        result[idx].text = token
                        result[idx].isPlaceholder = false
                        latinReplacedCount += 1
                    } else {
                        let top3 = formatTop3(prediction.topTokens)
                        print("🤖 LM: '\u{200E}\(word)\u{200E}' → [...] (top=[\(top3)])")
                        result[idx].text = "[...]"
                        result[idx].isPlaceholder = true
                        placeholderCount += 1
                    }
                }

                // Phase 2: Correct Hebrew near-misses via Levenshtein distance.
                // Scan top-K predictions for a near-miss (dist=1, same length) — the correction
                // may not be the rank-1 prediction (e.g. מעמד at rank 2 behind תוקף at rank 1).
                for idx in hebrewIndices {
                    let word = result[idx].text
                    // Skip short words — too ambiguous for edit-distance correction
                    guard word.count >= minWordLenForCorrection else { continue }

                    let lineText = sortedIndices.map { result[$0].text }.joined(separator: " ")

                    guard let prediction = await model.predictMasked(
                        lineText: lineText, wordToMask: word
                    ) else { continue }

                    // Scan top-K for the best near-miss candidate
                    let top3 = formatTop3(prediction.topTokens)
                    var bestCandidate: (token: String, probability: Float)?
                    for (token, prob) in prediction.topTokens {
                        guard prob >= hebrewCorrectionThreshold,
                              isHebrew(token),
                              !token.hasPrefix("##"),
                              token != word,
                              token.count == word.count else { continue }
                        let dist = levenshtein(word, token)
                        if dist <= maxEditDistance {
                            bestCandidate = (token, prob)
                            break  // Take the highest-probability match
                        }
                    }

                    if let candidate = bestCandidate {
                        let dist = levenshtein(word, candidate.token)
                        print("🤖 LM fix: '\u{200E}\(word)\u{200E}' → '\u{200E}\(candidate.token)\u{200E}' (dist=\(dist), prob=\(f2(candidate.probability)), top=[\(top3)])")
                        result[idx].text = candidate.token
                        hebrewCorrectedCount += 1
                    }
                }
            }

            // Phase 3: Character confusion fallback for words the LM couldn't fix.
            // Useful for TOC lines and other low-context situations where the model
            // predicts punctuation instead of real Hebrew words.
            for i in 0..<result.count {
                let word = result[i].text
                guard word.count >= minWordLenForCorrection,
                      isHebrew(word),
                      !result[i].isPlaceholder else { continue }

                if let corrected = await model.correctByConfusion(word, pairs: confusionPairs) {
                    print("🤖 LM confusion: '\u{200E}\(word)\u{200E}' → '\u{200E}\(corrected)\u{200E}'")
                    result[i].text = corrected
                    confusionCorrectedCount += 1
                }
            }

            print("🤖 LM summary: \(latinReplacedCount) Latin→Hebrew, \(hebrewCorrectedCount) Hebrew corrected, \(confusionCorrectedCount) confusion fixed, \(placeholderCount) → [...]")
        } else {
            print("⚠️ LM: Model not ready, skipping phases 1-3")
        }

        // Phase 4: Rule-based Latin garbage cleanup (no model needed).
        // Catches garbage-heavy lines that Phase 1 skips due to minHebrewWordsForContext.
        result = cleanLatinGarbageLines(result)

        return result
    }

    /// Replaces Latin words with `[...]` on lines dominated by Latin garbage.
    /// A line qualifies if it has ≤1 Hebrew word AND ≥3 Latin words.
    static func cleanLatinGarbageLines(_ boxes: [OCRBox]) -> [OCRBox] {
        // Group boxes by lineId
        var lineGroups: [Int: [Int]] = [:]
        for (i, box) in boxes.enumerated() {
            lineGroups[box.lineId, default: []].append(i)
        }

        var result = boxes
        var cleanedCount = 0

        for (_, indices) in lineGroups {
            var hebrewCount = 0
            var latinIndices: [Int] = []

            for idx in indices {
                let box = result[idx]
                if box.isPlaceholder { continue }

                let sc = classifyScript(box.text)
                switch sc {
                case .hebrew, .hebrewMixed:
                    hebrewCount += 1
                case .latinOnly:
                    latinIndices.append(idx)
                default:
                    break
                }
            }

            // Line with ≤1 Hebrew word and ≥3 Latin words → Latin is garbage
            if hebrewCount <= 1 && latinIndices.count >= 3 {
                for idx in latinIndices {
                    result[idx].text = "[...]"
                    result[idx].isPlaceholder = true
                    cleanedCount += 1
                }
            }
        }

        if cleanedCount > 0 {
            print("🧹 Phase 4: cleaned \(cleanedCount) Latin garbage words")
        }
        return result
    }

    // MARK: - Levenshtein Distance

    /// Standard Levenshtein edit distance between two strings.
    private static func levenshtein(_ s: String, _ t: String) -> Int {
        let sChars = Array(s)
        let tChars = Array(t)
        let m = sChars.count
        let n = tChars.count

        if m == 0 { return n }
        if n == 0 { return m }

        // Single-row DP
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = sChars[i - 1] == tChars[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,       // deletion
                    curr[j - 1] + 1,   // insertion
                    prev[j - 1] + cost  // substitution
                )
            }
            swap(&prev, &curr)
        }

        return prev[n]
    }

    // MARK: - Helpers

    private static func isHebrew(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x0590 && $0.value <= 0x05FF }
    }

    private static func f2(_ v: Float) -> String {
        String(format: "%.2f", v)
    }

    private static func formatTop3(_ tokens: [(token: String, probability: Float)]) -> String {
        tokens.prefix(3)
            .map { "\u{200E}\($0.token)\u{200E}(\(f2($0.probability)))" }
            .joined(separator: ", ")
    }
}
