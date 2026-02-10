//
//  DocumentStructure.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

import Foundation
import CoreGraphics

struct LineMetrics {
    let lineId: Int
    let minX: CGFloat
    let maxX: CGFloat
    let minY: CGFloat
    let maxY: CGFloat
    let width: CGFloat      // text span (maxX - minX)
    let wordCount: Int
    let firstWord: String
    let secondWord: String? // for split section numbers like "1" + "."
    let parNum: Int         // Tesseract's paragraph number from lineId
}

nonisolated func analyzePageStructure(boxes: [OCRBox]) -> PageStructure {
    let nonMarginBoxes = boxes.filter { !$0.isMargin }
    guard !nonMarginBoxes.isEmpty else {
        return PageStructure(paragraphs: [], headerLineIds: [], footerLineIds: [])
    }

    // Step 1: Build line metrics
    let lineMetrics = buildLineMetrics(from: nonMarginBoxes)
    guard lineMetrics.count >= 2 else {
        // Too few lines for meaningful structure analysis
        let allLineIds = lineMetrics.map { $0.lineId }
        let singleParagraph = DetectedParagraph(lineIds: allLineIds, role: .body, sectionNumber: nil, isCentered: false)
        return PageStructure(paragraphs: [singleParagraph], headerLineIds: [], footerLineIds: [])
    }

    // Step 2: Compute median inter-line gap
    let medianGap = computeMedianInterLineGap(lineMetrics)

    // Step 3: Detect headers and footers
    var (headerIds, footerIds) = detectHeaderFooter(lineMetrics: lineMetrics, medianGap: medianGap)

    // Step 3b: Content-based footer detection (catches stamps/watermarks at bottom)
    detectContentBasedFooter(boxes: nonMarginBoxes, lineMetrics: lineMetrics, existingFooterIds: &footerIds)

    // Step 4: Detect paragraph breaks among body lines
    let bodyMetrics = lineMetrics.filter { !headerIds.contains($0.lineId) && !footerIds.contains($0.lineId) }
    let bodyParagraphs = detectParagraphs(bodyMetrics: bodyMetrics, medianGap: medianGap)

    // Step 5: Detect section numbering and assign roles
    let detectedParagraphs = assignRoles(
        bodyParagraphs: bodyParagraphs,
        headerLineIds: headerIds,
        footerLineIds: footerIds,
        lineMetrics: lineMetrics
    )

    return PageStructure(
        paragraphs: detectedParagraphs,
        headerLineIds: Set(headerIds),
        footerLineIds: Set(footerIds)
    )
}

// MARK: - Step 1: Build Line Metrics

private func buildLineMetrics(from boxes: [OCRBox]) -> [LineMetrics] {
    var lineGroups: [Int: [OCRBox]] = [:]
    for box in boxes {
        lineGroups[box.lineId, default: []].append(box)
    }

    var metrics: [LineMetrics] = []
    for (lineId, lineBoxes) in lineGroups {
        let sortedByWord = lineBoxes.sorted { $0.wordNum < $1.wordNum }

        let minX = lineBoxes.map { $0.frame.minX }.min()!
        let maxX = lineBoxes.map { $0.frame.maxX }.max()!
        let minY = lineBoxes.map { $0.frame.minY }.min()!
        let maxY = lineBoxes.map { $0.frame.maxY }.max()!

        let parNum = (lineId % 1000000) / 1000

        metrics.append(LineMetrics(
            lineId: lineId,
            minX: minX,
            maxX: maxX,
            minY: minY,
            maxY: maxY,
            width: maxX - minX,
            wordCount: lineBoxes.count,
            firstWord: sortedByWord.first?.text ?? "",
            secondWord: sortedByWord.count > 1 ? sortedByWord[1].text : nil,
            parNum: parNum
        ))
    }

    // Sort by Y position (top to bottom)
    metrics.sort { $0.minY < $1.minY }
    return metrics
}

// MARK: - Step 2: Median Inter-Line Gap

private func computeMedianInterLineGap(_ lineMetrics: [LineMetrics]) -> CGFloat {
    guard lineMetrics.count >= 2 else { return 0 }

    var gaps: [CGFloat] = []
    for i in 1..<lineMetrics.count {
        let gap = lineMetrics[i].minY - lineMetrics[i - 1].maxY
        if gap > 0 {
            gaps.append(gap)
        }
    }

    guard !gaps.isEmpty else { return 0 }

    gaps.sort()
    let mid = gaps.count / 2
    if gaps.count % 2 == 0 {
        return (gaps[mid - 1] + gaps[mid]) / 2
    }
    return gaps[mid]
}

// MARK: - Step 3: Header/Footer Detection

private func detectHeaderFooter(lineMetrics: [LineMetrics], medianGap: CGFloat) -> (headerIds: [Int], footerIds: [Int]) {
    let gapThreshold = medianGap * 3
    let maxHeaderFooterLines = 3

    var headerIds: [Int] = []
    var footerIds: [Int] = []

    // Scan from top for headers: look for a gap > 3x median
    for i in 0..<min(maxHeaderFooterLines, lineMetrics.count - 1) {
        let gapAfter = lineMetrics[i + 1].minY - lineMetrics[i].maxY
        headerIds.append(lineMetrics[i].lineId)
        if gapAfter > gapThreshold {
            break
        }
        // If we reach max lines without finding a big gap, discard (no header detected)
        if i == min(maxHeaderFooterLines, lineMetrics.count - 1) - 1 {
            headerIds.removeAll()
        }
    }

    // Scan from bottom for footers: look for a gap > 3x median
    let count = lineMetrics.count
    for i in stride(from: count - 1, through: max(count - maxHeaderFooterLines, 1), by: -1) {
        let gapBefore = lineMetrics[i].minY - lineMetrics[i - 1].maxY
        footerIds.append(lineMetrics[i].lineId)
        if gapBefore > gapThreshold {
            break
        }
        // If we reach max lines without finding a big gap, discard (no footer detected)
        if i == max(count - maxHeaderFooterLines, 1) {
            footerIds.removeAll()
        }
    }

    return (headerIds, footerIds)
}

// MARK: - Step 4: Paragraph Break Detection

private func detectParagraphs(bodyMetrics: [LineMetrics], medianGap: CGFloat) -> [[Int]] {
    guard !bodyMetrics.isEmpty else { return [] }

    // Compute reference line width: 80th percentile of body line widths
    let sortedWidths = bodyMetrics.map { $0.width }.sorted()
    let p80Index = Int(Double(sortedWidths.count - 1) * 0.8)
    let referenceWidth = sortedWidths[p80Index]
    let shortLineThreshold = referenceWidth * 0.7

    var paragraphs: [[Int]] = []
    var currentParagraph: [Int] = []

    for (i, line) in bodyMetrics.enumerated() {
        currentParagraph.append(line.lineId)

        let isLastLine = (i == bodyMetrics.count - 1)
        if isLastLine {
            break
        }

        // Check if this line ends a paragraph
        let isShortLine = line.width < shortLineThreshold

        let nextLine = bodyMetrics[i + 1]
        let gap = nextLine.minY - line.maxY
        let hasLargeGap = gap > medianGap * 1.5
        let parNumChanged = nextLine.parNum != line.parNum

        // Either signal triggers a break
        let isBreak = isShortLine || (parNumChanged && hasLargeGap)

        if isBreak {
            paragraphs.append(currentParagraph)
            currentParagraph = []
        }
    }

    // Append last paragraph
    if !currentParagraph.isEmpty {
        paragraphs.append(currentParagraph)
    }

    return paragraphs
}

// MARK: - Step 5: Section Numbering & Role Assignment

/// Regex patterns for section numbering
private let sectionPatterns: [NSRegularExpression] = {
    let patterns = [
        // Hebrew letter + period: א. ב. etc.
        "^[\u{05D0}-\u{05EA}]\\.$",
        // Hebrew letter in parens: (א) or א)
        "^\\([\u{05D0}-\u{05EA}]\\)$",
        "^[\u{05D0}-\u{05EA}]\\)$",
        // Arabic numerals: 1. (1) 1)
        "^\\d+\\.$",
        "^\\(\\d+\\)$",
        "^\\d+\\)$",
        // Latin letters: a. (a) a)
        "^[a-zA-Z]\\.$",
        "^\\([a-zA-Z]\\)$",
        "^[a-zA-Z]\\)$",
    ]
    return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
}()

func detectSectionNumber(firstWord: String, secondWord: String?) -> String? {
    let trimmed = firstWord.trimmingCharacters(in: .whitespaces)

    // Try matching first word alone
    for regex in sectionPatterns {
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if regex.firstMatch(in: trimmed, range: range) != nil {
            return trimmed
        }
    }

    // Try combining first two words (OCR may split "1" and "." into separate boxes)
    if let second = secondWord {
        let combined = trimmed + second.trimmingCharacters(in: .whitespaces)
        for regex in sectionPatterns {
            let range = NSRange(combined.startIndex..., in: combined)
            if regex.firstMatch(in: combined, range: range) != nil {
                return combined
            }
        }
    }

    return nil
}

private func assignRoles(
    bodyParagraphs: [[Int]],
    headerLineIds: [Int],
    footerLineIds: [Int],
    lineMetrics: [LineMetrics]
) -> [DetectedParagraph] {
    // Build a lookup for line metrics by lineId
    let metricsLookup = Dictionary(uniqueKeysWithValues: lineMetrics.map { ($0.lineId, $0) })

    // Compute page extents for centering detection
    let allMinX = lineMetrics.map { $0.minX }.min() ?? 0
    let allMaxX = lineMetrics.map { $0.maxX }.max() ?? 0
    let pageWidth = allMaxX - allMinX
    let pageCenter = allMinX + pageWidth / 2

    // Reference width: 80th percentile of body line widths
    let bodyLineWidths = lineMetrics
        .filter { !headerLineIds.contains($0.lineId) && !footerLineIds.contains($0.lineId) }
        .map { $0.width }
        .sorted()
    let referenceWidth: CGFloat = bodyLineWidths.isEmpty ? pageWidth : bodyLineWidths[Int(Double(bodyLineWidths.count - 1) * 0.8)]

    var result: [DetectedParagraph] = []

    // Add header paragraph(s)
    if !headerLineIds.isEmpty {
        let centered = isCenteredParagraph(lineIds: headerLineIds, metricsLookup: metricsLookup, pageCenter: pageCenter, referenceWidth: referenceWidth)
        result.append(DetectedParagraph(lineIds: headerLineIds, role: .header, sectionNumber: nil, isCentered: centered))
    }

    // Add body paragraphs with section numbering detection
    for lineIds in bodyParagraphs {
        guard let firstLineId = lineIds.first,
              let firstLineMetrics = metricsLookup[firstLineId] else { continue }

        let sectionNum = detectSectionNumber(
            firstWord: firstLineMetrics.firstWord,
            secondWord: firstLineMetrics.secondWord
        )
        let role: StructuralRole = sectionNum != nil ? .sectionHeading : .body

        let centered = isCenteredParagraph(lineIds: lineIds, metricsLookup: metricsLookup, pageCenter: pageCenter, referenceWidth: referenceWidth)

        result.append(DetectedParagraph(lineIds: lineIds, role: role, sectionNumber: sectionNum, isCentered: centered))
    }

    // Add footer paragraph(s)
    if !footerLineIds.isEmpty {
        let centered = isCenteredParagraph(lineIds: footerLineIds, metricsLookup: metricsLookup, pageCenter: pageCenter, referenceWidth: referenceWidth)
        result.append(DetectedParagraph(lineIds: footerLineIds, role: .footer, sectionNumber: nil, isCentered: centered))
    }

    return result
}

/// Determines if all lines of a paragraph are centered on the page.
/// A line is centered if it's shorter than 70% of the reference width AND
/// its midpoint is within 5% of the page center.
private func isCenteredParagraph(
    lineIds: [Int],
    metricsLookup: [Int: LineMetrics],
    pageCenter: CGFloat,
    referenceWidth: CGFloat
) -> Bool {
    guard referenceWidth > 0 else { return false }
    let tolerance = referenceWidth * 0.08

    for lineId in lineIds {
        guard let metrics = metricsLookup[lineId] else { return false }
        // Only consider lines that are shorter than the full width
        guard metrics.width < referenceWidth * 0.7 else { return false }
        let lineMid = metrics.minX + metrics.width / 2
        guard abs(lineMid - pageCenter) < tolerance else { return false }
    }
    return true
}

// MARK: - Step 3b: Content-Based Footer Detection

/// Scans bottom lines upward to detect non-content lines (stamps, watermarks, Latin garbage)
/// and marks them as footer. Stops when it encounters a real content line.
private func detectContentBasedFooter(
    boxes: [OCRBox],
    lineMetrics: [LineMetrics],
    existingFooterIds: inout [Int]
) {
    let existingFooterSet = Set(existingFooterIds)
    let maxScanLines = 8

    // Group boxes by lineId for content analysis
    var lineBoxes: [Int: [OCRBox]] = [:]
    for box in boxes {
        lineBoxes[box.lineId, default: []].append(box)
    }

    // Scan from bottom upward
    let sortedMetrics = lineMetrics.sorted { $0.minY < $1.minY }
    var scannedCount = 0

    for metric in sortedMetrics.reversed() {
        guard scannedCount < maxScanLines else { break }

        // Skip lines already marked as footer by gap-based detection
        if existingFooterSet.contains(metric.lineId) { continue }

        scannedCount += 1

        guard let words = lineBoxes[metric.lineId] else { continue }
        let nonPlaceholderWords = words.filter { !$0.isPlaceholder }

        var hebrewWordCount = 0
        var latinWordCount = 0
        let nonPlaceholderCount = nonPlaceholderWords.count

        for word in nonPlaceholderWords {
            let sc = classifyScript(word.text)
            switch sc {
            case .hebrew, .hebrewMixed:
                hebrewWordCount += 1
            case .latinOnly:
                latinWordCount += 1
            default:
                break
            }
        }

        // A line is "non-content" if:
        // - (≤3 non-placeholder words AND 0 Hebrew words), OR
        // - (≥3 Latin words AND ≤1 Hebrew word)
        let isNonContent =
            (nonPlaceholderCount <= 3 && hebrewWordCount == 0) ||
            (latinWordCount >= 3 && hebrewWordCount <= 1)

        if isNonContent {
            existingFooterIds.append(metric.lineId)
            print("🦶 Content-based footer: lineId=\(metric.lineId) (heb=\(hebrewWordCount), lat=\(latinWordCount), total=\(nonPlaceholderCount))")
        } else {
            // Hit a real content line — stop scanning
            break
        }
    }
}
