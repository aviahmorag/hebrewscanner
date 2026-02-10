//
//  OCRBox.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

import Foundation
import SwiftUI

struct OCRBox: Identifiable {
    let id = UUID()
    var text: String
    let frame: CGRect
    let lineId: Int      // Unique line identifier (combines block, par, line)
    let wordNum: Int
    var isMargin: Bool = false       // True if this word is in the margin column
    var isPlaceholder: Bool = false  // True if this word was replaced with [...]
}

enum StructuralRole {
    case header
    case footer
    case body
    case sectionHeading
}

struct DetectedParagraph {
    let lineIds: [Int]
    let role: StructuralRole
    let sectionNumber: String?   // e.g. "א.", "1.", "(ב)"
    let isCentered: Bool
}

struct PageStructure {
    let paragraphs: [DetectedParagraph]   // ordered top-to-bottom
    let headerLineIds: Set<Int>
    let footerLineIds: Set<Int>
}

enum ScriptClass: Equatable, CustomStringConvertible {
    case hebrew         // Contains Hebrew characters
    case hebrewMixed    // Hebrew + other scripts (common in OCR)
    case latinOnly      // Pure Latin letters only — likely garbage in Hebrew docs
    case number         // Digits, possibly with punctuation (e.g. "58-003-387-6")
    case punctuation    // Only punctuation/symbols
    case sectionMarker  // Patterns like (א), (1), א., 1. etc.
    case garbage        // Repeated chars, bidi marks only, obvious nonsense

    var description: String {
        switch self {
        case .hebrew: return "heb"
        case .hebrewMixed: return "heb+"
        case .latinOnly: return "lat"
        case .number: return "num"
        case .punctuation: return "punc"
        case .sectionMarker: return "sect"
        case .garbage: return "garb"
        }
    }
}

/// Section marker patterns for filtering (reused from DocumentStructure)
private let sectionMarkerPattern = try! NSRegularExpression(
    pattern: "^[\\(]?[\u{05D0}-\u{05EA}a-zA-Z0-9]+[\\)\\.]?$"
)

func classifyScript(_ text: String) -> ScriptClass {
    // Strip bidi control characters for analysis
    let bidiChars = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .unicodeScalars.filter { !bidiChars.contains($0) }
        .map { Character($0) }
    let str = String(cleaned)

    guard !str.isEmpty else { return .garbage }

    // Count character types
    var hebrewCount = 0
    var latinCount = 0
    var digitCount = 0
    var punctCount = 0
    var otherCount = 0

    for scalar in str.unicodeScalars {
        let v = scalar.value
        if v >= 0x0590 && v <= 0x05FF {
            hebrewCount += 1
        } else if (v >= 0x0041 && v <= 0x005A) || (v >= 0x0061 && v <= 0x007A) {
            latinCount += 1
        } else if v >= 0x0030 && v <= 0x0039 {
            digitCount += 1
        } else if CharacterSet.punctuationCharacters.contains(scalar) ||
                    CharacterSet.symbols.contains(scalar) ||
                    scalar == "-" || scalar == "(" || scalar == ")" ||
                    scalar == "." || scalar == "," || scalar == "'" ||
                    scalar == "\"" || scalar == "/" || scalar == "\\" {
            punctCount += 1
        } else {
            otherCount += 1
        }
    }

    let totalChars = str.count

    // Garbage: repeated character patterns (3+ of the same char in a row)
    if totalChars >= 4 {
        var maxRepeat = 1
        var currentRepeat = 1
        let chars = Array(str)
        for i in 1..<chars.count {
            if chars[i] == chars[i-1] {
                currentRepeat += 1
                maxRepeat = max(maxRepeat, currentRepeat)
            } else {
                currentRepeat = 1
            }
        }
        if maxRepeat >= 4 || (Double(maxRepeat) / Double(totalChars) > 0.5 && totalChars > 5) {
            return .garbage
        }
    }

    // Garbage: only bidi marks / whitespace remained
    if totalChars == 0 || (hebrewCount == 0 && latinCount == 0 && digitCount == 0 && punctCount == totalChars && totalChars <= 1) {
        return .garbage
    }

    // Section markers: (א), א., 1., (1), etc.
    // Require punctuation (parens/period) or very short (≤2 chars) — otherwise pure Hebrew
    // words like מעמר (4 chars) get misclassified and skipped by the language model.
    if totalChars <= 5 && (hebrewCount > 0 || digitCount > 0) && (punctCount > 0 || totalChars <= 2) {
        let range = NSRange(str.startIndex..., in: str)
        if sectionMarkerPattern.firstMatch(in: str, range: range) != nil {
            return .sectionMarker
        }
    }

    // Pure punctuation
    if hebrewCount == 0 && latinCount == 0 && digitCount == 0 {
        return .punctuation
    }

    // Numbers (possibly with punctuation like dashes, periods)
    if hebrewCount == 0 && latinCount == 0 && digitCount > 0 {
        return .number
    }

    // Hebrew present
    if hebrewCount > 0 {
        if latinCount > 0 {
            return .hebrewMixed
        }
        return .hebrew
    }

    // Latin only (no Hebrew at all) — likely OCR garbage in Hebrew documents
    if latinCount > 0 && hebrewCount == 0 {
        return .latinOnly
    }

    return .punctuation
}

/// Fixes reversed parentheses from Tesseract's LTR visual-order digit output.
/// e.g. `)3(` → `(3)`, `)א(` → `(א)`, `)3` → `(3)`
func normalizeReversedParentheses(_ text: String) -> String {
    let s = text.trimmingCharacters(in: .whitespaces)

    // Full reversed: )…(  →  (…)
    if s.hasPrefix(")") && s.hasSuffix("(") && s.count >= 3 {
        let inner = s.dropFirst().dropLast()
        let allDigitsOrHebrew = inner.allSatisfy { ch in
            ch.isNumber || (ch.unicodeScalars.first.map { $0.value >= 0x05D0 && $0.value <= 0x05EA } ?? false)
        }
        if allDigitsOrHebrew {
            return "(\(inner))"
        }
    }

    // Half reversed: )…  →  (…)  (opening paren was split off by Tesseract)
    if s.hasPrefix(")") && !s.hasSuffix("(") && s.count >= 2 {
        let inner = s.dropFirst()
        let allDigitsOrHebrew = inner.allSatisfy { ch in
            ch.isNumber || (ch.unicodeScalars.first.map { $0.value >= 0x05D0 && $0.value <= 0x05EA } ?? false)
        }
        if allDigitsOrHebrew {
            return "(\(inner))"
        }
    }

    return text
}

/// What to do with a word during TSV parsing.
private enum WordAction {
    case keep        // Accept as-is
    case placeholder // Replace with [...]
    case drop        // Remove entirely
}

func parseTesseractTSV(_ tsv: String, imageSize: CGSize) -> [OCRBox] {
    var boxes: [OCRBox] = []
    let lines = tsv.components(separatedBy: .newlines).dropFirst() // drop header

    // TSV columns: level, page_num, block_num, par_num, line_num, word_num, left, top, width, height, conf, text
    for (_, line) in lines.enumerated() {
        let parts = line.components(separatedBy: "\t")

        if parts.count >= 12 && parts[0] == "5" { // level 5 = word level
            let text = normalizeReversedParentheses(parts[11].trimmingCharacters(in: .whitespaces))

            if let blockNum = Int(parts[2]),
               let parNum = Int(parts[3]),
               let lineNum = Int(parts[4]),
               let wordNum = Int(parts[5]),
               let left = Double(parts[6]),
               let top = Double(parts[7]),
               let width = Double(parts[8]),
               let height = Double(parts[9]),
               let conf = Double(parts[10]) {

                if !text.isEmpty {
                    let scriptClass = classifyScript(text)
                    let action: WordAction

                    switch scriptClass {
                    case .hebrew, .hebrewMixed:
                        // Hebrew text: accept with lower threshold (Tesseract gives Hebrew lower scores)
                        action = conf > 5 ? .keep : .placeholder
                    case .number, .punctuation, .sectionMarker:
                        // Numbers and section markers: keep at moderate threshold
                        action = conf > 20 ? .keep : .placeholder
                    case .latinOnly:
                        // Keep all Latin words — the language model decides later
                        action = .keep
                    case .garbage:
                        // Obvious garbage patterns: placeholder
                        action = .placeholder
                    }

                    if action != .drop {
                        let rect = CGRect(x: left, y: top, width: width, height: height)

                        // Check for duplicate/overlapping boxes (can happen with heb+eng)
                        let dominated = boxes.contains { existing in
                            let intersection = existing.frame.intersection(rect)
                            guard !intersection.isNull else { return false }
                            let overlapArea = intersection.width * intersection.height
                            let smallerArea = min(existing.frame.width * existing.frame.height,
                                                  rect.width * rect.height)
                            // If >50% overlap, consider it a duplicate
                            return overlapArea > smallerArea * 0.5
                        }

                        if dominated {
                            print("🔄 Skipped duplicate '\(text)' overlapping with existing box")
                        } else {
                            // Combine block, par, line into unique lineId
                            let lineId = blockNum * 1000000 + parNum * 1000 + lineNum
                            let isPlaceholder = (action == .placeholder)
                            let displayText = isPlaceholder ? "[...]" : text
                            if isPlaceholder {
                                print("⚠️ Placeholder [\(scriptClass)] '\(text)' conf=\(String(format: "%.1f", conf))")
                            }
                            boxes.append(OCRBox(text: displayText, frame: rect, lineId: lineId, wordNum: wordNum, isPlaceholder: isPlaceholder))
                        }
                    } else {
                        print("⚠️ Dropped [\(scriptClass)] '\(text)' conf=\(String(format: "%.1f", conf))")
                    }
                }
            }
        }
    }

    // Detect margin column by analyzing X-coordinate distribution
    detectMarginColumn(&boxes, imageWidth: imageSize.width)

    print("📦 Total boxes created: \(boxes.count)")
    return boxes
}

/// Detects margin text by finding a gap in X-coordinates between main content and margin annotations
private func detectMarginColumn(_ boxes: inout [OCRBox], imageWidth: CGFloat) {
    guard boxes.count > 10 else { return }

    // For Hebrew RTL: main text is on the RIGHT, margin annotations on the LEFT
    // Note: OCRBox frames are in TSV coordinates (2x display resolution for Retina)

    // Find the actual coordinate range from the boxes themselves
    let allX = boxes.map { $0.frame.minX }
    guard let maxX = allX.max() else { return }

    // The actual image width in TSV coordinates (roughly 2x display width)
    let tsvWidth = maxX * 1.1  // Add 10% margin for edge detection

    // Look for the largest gap in the expected column boundary region (30-45% from left)
    let searchMin = tsvWidth * 0.30
    let searchMax = tsvWidth * 0.45

    let leftEdges = allX.sorted()

    var maxGap: CGFloat = 0
    var gapStart: CGFloat = 0
    var gapEnd: CGFloat = 0

    for i in 1..<leftEdges.count {
        let gap = leftEdges[i] - leftEdges[i-1]
        let gapMidpoint = (leftEdges[i] + leftEdges[i-1]) / 2

        // Only consider gaps in the expected column boundary region
        if gapMidpoint >= searchMin && gapMidpoint <= searchMax && gap > maxGap {
            maxGap = gap
            gapStart = leftEdges[i-1]
            gapEnd = leftEdges[i]
        }
    }

    let gapPosition = (gapStart + gapEnd) / 2
    let minGapThreshold = tsvWidth * 0.03  // At least 3% gap

    print("📐 TSV width estimate: \(Int(tsvWidth)), searching for gap in X:\(Int(searchMin))-\(Int(searchMax))")
    print("📐 Found gap: \(Int(maxGap))px between X:\(Int(gapStart)) and X:\(Int(gapEnd))")

    if maxGap > minGapThreshold {
        print("📐 Detected margin boundary at X:\(Int(gapPosition)) (gap: \(Int(maxGap))px)")

        // Mark boxes whose LEFT edge is to the left of the gap as margin text
        var marginCount = 0
        var marginWords: [String] = []
        for i in 0..<boxes.count {
            if boxes[i].frame.minX < gapPosition {
                boxes[i].isMargin = true
                marginCount += 1
                if marginWords.count < 10 {
                    marginWords.append(boxes[i].text)
                }
            }
        }
        print("📝 Marked \(marginCount) words as margin: \(marginWords.joined(separator: ", "))")
    } else {
        print("📐 No significant margin column detected in expected region")
    }
}
