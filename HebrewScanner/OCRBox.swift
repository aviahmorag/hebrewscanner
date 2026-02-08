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
    let text: String
    let frame: CGRect
    let lineId: Int      // Unique line identifier (combines block, par, line)
    let wordNum: Int
    var isMargin: Bool = false  // True if this word is in the margin column
}

func parseTesseractTSV(_ tsv: String, imageSize: CGSize) -> [OCRBox] {
    var boxes: [OCRBox] = []
    let lines = tsv.components(separatedBy: .newlines).dropFirst() // drop header

    // TSV columns: level, page_num, block_num, par_num, line_num, word_num, left, top, width, height, conf, text
    for (_, line) in lines.enumerated() {
        let parts = line.components(separatedBy: "\t")

        if parts.count >= 12 && parts[0] == "5" { // level 5 = word level
            let text = parts[11].trimmingCharacters(in: .whitespaces)

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
                    if conf > 30 {
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
                            boxes.append(OCRBox(text: text, frame: rect, lineId: lineId, wordNum: wordNum))
                        }
                    } else {
                        print("⚠️ Dropped word '\(text)' with confidence \(conf)")
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
