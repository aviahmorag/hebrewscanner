//
//  LanguageModelPostProcessor.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

import Foundation

/// Post-processes OCR boxes using DictaBERT to fix OCR errors.
///
/// Two phases:
/// 1. **Latin garbage replacement**: Tesseract frequently misreads Hebrew as Latin sequences
///    (e.g. "OR" for "אם", "WIN" for "הוועד"). Each Latin word in a Hebrew-context line is
///    masked, and DictaBERT's top Hebrew prediction replaces it.
/// 2. **Hebrew near-miss correction**: For Hebrew words, the model predicts what should be there
///    and compares via Levenshtein distance. If the edit distance is small (1-2), it's likely
///    a character confusion (ר↔ד, ו↔ז, ב↔כ) and the prediction replaces the OCR output.
enum LanguageModelPostProcessor {

    /// Minimum probability for the top Hebrew prediction to replace a Latin word.
    private static let latinReplacementThreshold: Float = 0.10

    /// Minimum probability for a Hebrew near-miss correction.
    private static let hebrewCorrectionThreshold: Float = 0.30

    /// Maximum Levenshtein distance to consider a Hebrew word an OCR near-miss.
    /// Only single-character substitutions (dist=1) are reliable — dist=2 causes false corrections.
    private static let maxEditDistance = 1

    /// Minimum word length for Hebrew near-miss correction (short words are too ambiguous).
    private static let minWordLenForCorrection = 3

    /// Minimum number of Hebrew words in a line to consider it Hebrew context.
    private static let minHebrewWordsForContext = 2

    /// Process OCR boxes: replace Latin garbage and correct Hebrew near-misses.
    static func process(boxes: [OCRBox]) async -> [OCRBox] {
        let model = HebrewLanguageModel.shared

        guard await model.isReady else {
            print("⚠️ LM: Model not ready, skipping post-processing")
            return boxes
        }

        // Group boxes by lineId
        var lineGroups: [Int: [Int]] = [:]
        for (i, box) in boxes.enumerated() {
            lineGroups[box.lineId, default: []].append(i)
        }

        var result = boxes
        var latinReplacedCount = 0
        var hebrewCorrectedCount = 0
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
                    print("🤖 LM: '\(word)' → '\(token)' (prob=\(f2(prob)), top=[\(top3)])")
                    result[idx].text = token
                    result[idx].isPlaceholder = false
                    latinReplacedCount += 1
                } else {
                    let top3 = formatTop3(prediction.topTokens)
                    print("🤖 LM: '\(word)' → [...] (top=[\(top3)])")
                    result[idx].text = "[...]"
                    result[idx].isPlaceholder = true
                    placeholderCount += 1
                }
            }

            // Phase 2: Correct Hebrew near-misses via Levenshtein distance
            // Only single-character substitutions (dist=1, same length) to avoid false corrections.
            for idx in hebrewIndices {
                let word = result[idx].text
                // Skip short words — too ambiguous for edit-distance correction
                guard word.count >= minWordLenForCorrection else { continue }

                let lineText = sortedIndices.map { result[$0].text }.joined(separator: " ")

                guard let prediction = await model.predictMasked(
                    lineText: lineText, wordToMask: word
                ) else { continue }

                // The top-1 prediction must itself be Hebrew (not just any Hebrew in top-K)
                guard let topToken = prediction.topTokens.first,
                      isHebrew(topToken.token),
                      !topToken.token.hasPrefix("##"),
                      topToken.token != word,
                      topToken.probability >= hebrewCorrectionThreshold else { continue }

                // Require same length (pure substitution, not insertion/deletion)
                guard topToken.token.count == word.count else { continue }

                let dist = levenshtein(word, topToken.token)
                if dist == maxEditDistance {
                    let top3 = formatTop3(prediction.topTokens)
                    print("🤖 LM fix: '\(word)' → '\(topToken.token)' (dist=\(dist), prob=\(f2(topToken.probability)), top=[\(top3)])")
                    result[idx].text = topToken.token
                    hebrewCorrectedCount += 1
                }
            }
        }

        print("🤖 LM summary: \(latinReplacedCount) Latin→Hebrew, \(hebrewCorrectedCount) Hebrew corrected, \(placeholderCount) → [...]")
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
            .map { "\($0.token)(\(f2($0.probability)))" }
            .joined(separator: ", ")
    }
}
