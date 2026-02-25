//
//  OCRBox.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

import Foundation
import SwiftUI
import PDFKit

struct OCRBox: Identifiable, Sendable {
    let id = UUID()
    var text: String
    var frame: CGRect
    let lineId: Int      // Unique line identifier (combines block, par, line)
    let wordNum: Int
    var isMargin: Bool = false       // True if this word is in the margin column
    var isPlaceholder: Bool = false  // True if this word was replaced with [...]
}

enum StructuralRole: Sendable {
    case header
    case footer
    case body
    case sectionHeading
}

struct DetectedParagraph: Sendable {
    let lineIds: [Int]
    let role: StructuralRole
    let sectionNumber: String?   // e.g. "א.", "1.", "(ב)"
    let isCentered: Bool
}

struct PageStructure: Sendable {
    let paragraphs: [DetectedParagraph]   // ordered top-to-bottom
    let headerLineIds: Set<Int>
    let footerLineIds: Set<Int>
}

nonisolated enum ScriptClass: Sendable, Equatable, CustomStringConvertible {
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
private nonisolated let sectionMarkerPattern = try! NSRegularExpression(
    pattern: "^[\\(]?[\u{05D0}-\u{05EA}a-zA-Z0-9]+[\\)\\.]?$"
)

nonisolated func classifyScript(_ text: String) -> ScriptClass {
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
nonisolated func normalizeReversedParentheses(_ text: String) -> String {
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
private nonisolated enum WordAction: Sendable {
    case keep        // Accept as-is
    case placeholder // Replace with [...]
    case drop        // Remove entirely
}

nonisolated func parseTesseractTSV(_ tsv: String, imageSize: CGSize) -> [OCRBox] {
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
nonisolated func detectMarginColumn(_ boxes: inout [OCRBox], imageWidth: CGFloat) {
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
    let minGapThreshold = tsvWidth * 0.08  // At least 8% gap (avoids false positives from normal word spacing)

    print("📐 TSV width estimate: \(Int(tsvWidth)), searching for gap in X:\(Int(searchMin))-\(Int(searchMax))")
    print("📐 Found gap: \(Int(maxGap))px between X:\(Int(gapStart)) and X:\(Int(gapEnd))")

    if maxGap > minGapThreshold {
        // Count how many words would be marked as margin
        let candidateCount = boxes.filter { $0.frame.minX < gapPosition }.count
        let marginRatio = Double(candidateCount) / Double(boxes.count)

        // A real margin column is a small minority of the text (< 25%).
        // If too many words fall in the "margin", it's just normal text with a gap.
        if marginRatio > 0.25 {
            print("📐 Rejected margin: \(Int(marginRatio * 100))% of words would be margin (too many)")
            return
        }

        print("📐 Detected margin boundary at X:\(Int(gapPosition)) (gap: \(Int(maxGap))px, \(Int(marginRatio * 100))% of words)")

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

/// Returns true if the PDF page contains a large raster image (i.e. it's a scanned page).
/// Scanned pages should always use Tesseract OCR, even if they have an embedded text layer.
private nonisolated func pdfPageIsScanned(_ pdfPage: PDFPage) -> Bool {
    guard let cgPage = pdfPage.pageRef,
          let pageDict = cgPage.dictionary else { return false }

    var resourcesDict: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resourcesDict),
          let resources = resourcesDict else { return false }

    var xobjectDict: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjectDict),
          let xobjects = xobjectDict else { return false }

    let pageSize = pdfPage.bounds(for: .mediaBox).size

    // Check if any XObject is an image larger than the page (indicating a scan).
    // Pass pageSize via info pointer since CGPDFDictionaryApplyBlock uses a C block.
    struct ScanCheckContext {
        var hasLargeImage: Bool
        let pageWidth: Int
        let pageHeight: Int
    }
    var ctx = ScanCheckContext(hasLargeImage: false,
                               pageWidth: Int(pageSize.width),
                               pageHeight: Int(pageSize.height))
    withUnsafeMutablePointer(to: &ctx) { ctxPtr in
        CGPDFDictionaryApplyBlock(xobjects, { _, value, info in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream),
                  let stream = stream,
                  let dict = CGPDFStreamGetDictionary(stream) else { return true }

            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype),
                  let subtype = subtype,
                  String(cString: subtype) == "Image" else { return true }

            var width: CGPDFInteger = 0
            var height: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(dict, "Width", &width)
            CGPDFDictionaryGetInteger(dict, "Height", &height)

            // A scanned page image at any reasonable DPI (>=100) will have pixel
            // dimensions larger than the page point dimensions (72 DPI).
            // E.g. A4 at 72pt = 595x842, but a scan at 150 DPI = 1240x1754 pixels.
            let context = info!.assumingMemoryBound(to: ScanCheckContext.self)
            if width > context.pointee.pageWidth && height > context.pointee.pageHeight {
                context.pointee.hasLargeImage = true
                return false // stop iterating
            }
            return true // continue
        }, ctxPtr)
    }

    return ctx.hasLargeImage
}

/// Extracts OCRBox array from a PDF page's native text layer (for born-digital PDFs).
/// Returns nil if the page has no meaningful native text (caller should fall back to OCR).
nonisolated func extractBoxesFromPDFPage(_ pdfPage: PDFPage) -> [OCRBox]? {
    // If the page contains a large raster image, it's a scan — use OCR instead
    if pdfPageIsScanned(pdfPage) {
        print("📄 PDF page contains scan image, falling back to OCR")
        return nil
    }

    guard let fullString = pdfPage.string else { return nil }

    // Count Hebrew/Latin characters to decide if there's meaningful text
    let meaningfulCount = fullString.unicodeScalars.filter { scalar in
        let v = scalar.value
        return (v >= 0x0590 && v <= 0x05FF) ||  // Hebrew
               (v >= 0x0041 && v <= 0x005A) ||  // Latin uppercase
               (v >= 0x0061 && v <= 0x007A)     // Latin lowercase
    }.count
    guard meaningfulCount >= 20 else { return nil }

    let charCount = pdfPage.numberOfCharacters
    guard charCount > 0 else { return nil }

    let mediaBox = pdfPage.bounds(for: .mediaBox)

    // Collect per-character info: character + bounds
    struct CharInfo {
        let char: Character
        let bounds: CGRect
    }

    var charInfos: [CharInfo] = []
    // Map from PDFKit character index to string index
    var stringIndex = fullString.startIndex
    for i in 0..<charCount {
        let bounds = pdfPage.characterBounds(at: i)
        // Get the character from the string at corresponding position
        if stringIndex < fullString.endIndex {
            let ch = fullString[stringIndex]
            charInfos.append(CharInfo(char: ch, bounds: bounds))
            stringIndex = fullString.index(after: stringIndex)
        }
    }

    // Group characters into words (split on whitespace/newlines)
    struct WordInfo {
        var text: String
        var unionBounds: CGRect
    }

    var words: [WordInfo] = []
    var currentWord = ""
    var currentBounds: CGRect = .null

    for info in charInfos {
        if info.char.isWhitespace || info.char.isNewline {
            if !currentWord.isEmpty && !currentBounds.isNull {
                words.append(WordInfo(text: currentWord, unionBounds: currentBounds))
            }
            currentWord = ""
            currentBounds = .null
        } else {
            currentWord.append(info.char)
            if info.bounds.width > 0 && info.bounds.height > 0 {
                if currentBounds.isNull {
                    currentBounds = info.bounds
                } else {
                    currentBounds = currentBounds.union(info.bounds)
                }
            }
        }
    }
    // Flush last word
    if !currentWord.isEmpty && !currentBounds.isNull {
        words.append(WordInfo(text: currentWord, unionBounds: currentBounds))
    }

    guard !words.isEmpty else { return nil }

    // Convert PDF coordinates (bottom-left origin) to image coordinates (top-left origin)
    // imageX = pdfX - mediaBox.origin.x
    // imageY = mediaBox.maxY - pdfY - pdfH
    var convertedWords: [(text: String, frame: CGRect)] = []
    for word in words {
        let pdfRect = word.unionBounds
        let imageX = pdfRect.minX - mediaBox.origin.x
        let imageY = mediaBox.maxY - pdfRect.maxY  // flip Y: top-left origin
        let imageW = pdfRect.width
        let imageH = pdfRect.height
        let frame = CGRect(x: imageX, y: imageY, width: imageW, height: imageH)
        convertedWords.append((word.text, frame))
    }

    // Cluster words into lines by Y-midpoint proximity
    // Compute median character height for threshold
    let heights = convertedWords.map { $0.frame.height }.sorted()
    let medianHeight: CGFloat
    if heights.isEmpty {
        return nil
    } else if heights.count % 2 == 0 {
        medianHeight = (heights[heights.count / 2 - 1] + heights[heights.count / 2]) / 2
    } else {
        medianHeight = heights[heights.count / 2]
    }
    let lineThreshold = medianHeight * 0.5  // Words within 50% of median height are same line

    // Sort by Y midpoint, then cluster
    let sortedByY = convertedWords.enumerated().sorted { $0.element.frame.midY < $1.element.frame.midY }

    var lineAssignments = [Int](repeating: 0, count: convertedWords.count)
    var currentLineId = 0
    var currentLineY = sortedByY.first?.element.frame.midY ?? 0

    for (originalIndex, word) in sortedByY {
        if abs(word.frame.midY - currentLineY) > lineThreshold {
            currentLineId += 1
            currentLineY = word.frame.midY
        }
        lineAssignments[originalIndex] = currentLineId
    }

    // Assign sequential wordNum within each line (sorted by X for RTL ordering)
    var lineWords: [Int: [(index: Int, frame: CGRect)]] = [:]
    for (i, lineId) in lineAssignments.enumerated() {
        lineWords[lineId, default: []].append((i, convertedWords[i].frame))
    }

    var wordNums = [Int](repeating: 0, count: convertedWords.count)
    for (_, indices) in lineWords {
        // Sort by X position within the line
        let sorted = indices.sorted { $0.frame.minX < $1.frame.minX }
        for (wordNum, entry) in sorted.enumerated() {
            wordNums[entry.index] = wordNum + 1
        }
    }

    // Build OCRBox array
    var boxes: [OCRBox] = []
    for (i, word) in convertedWords.enumerated() {
        boxes.append(OCRBox(
            text: word.text,
            frame: word.frame,
            lineId: lineAssignments[i],
            wordNum: wordNums[i]
        ))
    }

    // Detect margin column
    let pageWidth = mediaBox.width
    detectMarginColumn(&boxes, imageWidth: pageWidth)

    print("📄 Extracted \(boxes.count) native text boxes from PDF page")
    return boxes
}
