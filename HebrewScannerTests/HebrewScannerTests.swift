//
//  HebrewScannerTests.swift
//  HebrewScannerTests
//
//  Created by Aviah Morag in 2026.
//

import Testing
import CoreGraphics
import ZIPFoundation
@testable import HebrewScanner

// MARK: - Test Helpers

/// Creates an OCRBox at a given position for testing
private func makeBox(text: String, lineId: Int, wordNum: Int, x: CGFloat, y: CGFloat, width: CGFloat = 100, height: CGFloat = 30) -> OCRBox {
    OCRBox(text: text, frame: CGRect(x: x, y: y, width: width, height: height), lineId: lineId, wordNum: wordNum)
}

// MARK: - Section Number Detection Tests

struct SectionNumberDetectionTests {

    @Test func detectsHebrewLetterWithPeriod() {
        #expect(detectSectionNumber(firstWord: "א.", secondWord: nil) == "א.")
        #expect(detectSectionNumber(firstWord: "ב.", secondWord: nil) == "ב.")
        #expect(detectSectionNumber(firstWord: "ת.", secondWord: nil) == "ת.")
    }

    @Test func detectsHebrewLetterInParens() {
        #expect(detectSectionNumber(firstWord: "(א)", secondWord: nil) == "(א)")
        #expect(detectSectionNumber(firstWord: "ב)", secondWord: nil) == "ב)")
    }

    @Test func detectsArabicNumerals() {
        #expect(detectSectionNumber(firstWord: "1.", secondWord: nil) == "1.")
        #expect(detectSectionNumber(firstWord: "(1)", secondWord: nil) == "(1)")
        #expect(detectSectionNumber(firstWord: "2)", secondWord: nil) == "2)")
        #expect(detectSectionNumber(firstWord: "12.", secondWord: nil) == "12.")
    }

    @Test func detectsLatinLetters() {
        #expect(detectSectionNumber(firstWord: "a.", secondWord: nil) == "a.")
        #expect(detectSectionNumber(firstWord: "(b)", secondWord: nil) == "(b)")
        #expect(detectSectionNumber(firstWord: "C.", secondWord: nil) == "C.")
    }

    @Test func detectsSplitSectionNumber() {
        // OCR may split "1" and "." into separate words
        #expect(detectSectionNumber(firstWord: "1", secondWord: ".") == "1.")
        #expect(detectSectionNumber(firstWord: "א", secondWord: ".") == "א.")
    }

    @Test func returnsNilForNonSectionText() {
        #expect(detectSectionNumber(firstWord: "שלום", secondWord: nil) == nil)
        #expect(detectSectionNumber(firstWord: "hello", secondWord: nil) == nil)
        #expect(detectSectionNumber(firstWord: "123", secondWord: nil) == nil)
        #expect(detectSectionNumber(firstWord: ".", secondWord: nil) == nil)
    }
}

// MARK: - Page Structure Analysis Tests

struct PageStructureAnalysisTests {

    @Test func emptyBoxesReturnsEmptyStructure() {
        let structure = analyzePageStructure(boxes: [])
        #expect(structure.paragraphs.isEmpty)
        #expect(structure.headerLineIds.isEmpty)
        #expect(structure.footerLineIds.isEmpty)
    }

    @Test func singleLineReturnsSingleBodyParagraph() {
        let boxes = [
            makeBox(text: "שלום", lineId: 1001001, wordNum: 1, x: 100, y: 100),
            makeBox(text: "עולם", lineId: 1001001, wordNum: 2, x: 200, y: 100),
        ]
        let structure = analyzePageStructure(boxes: boxes)
        #expect(structure.paragraphs.count == 1)
        #expect(structure.paragraphs[0].role == .body)
    }

    @Test func detectsHeaderWithLargeGap() {
        // Header line at top, then big gap, then body lines with small gaps
        let boxes = [
            // Header line (y=10)
            makeBox(text: "עמוד", lineId: 1001001, wordNum: 1, x: 200, y: 10, height: 20),
            makeBox(text: "1", lineId: 1001001, wordNum: 2, x: 300, y: 10, height: 20),
            // Body lines (y=200, y=240, y=280 - gaps of ~10px each)
            makeBox(text: "טקסט", lineId: 1002001, wordNum: 1, x: 100, y: 200, height: 20),
            makeBox(text: "ראשי", lineId: 1002001, wordNum: 2, x: 200, y: 200, height: 20),
            makeBox(text: "שורה", lineId: 1002002, wordNum: 1, x: 100, y: 230, height: 20),
            makeBox(text: "שנייה", lineId: 1002002, wordNum: 2, x: 200, y: 230, height: 20),
            makeBox(text: "שורה", lineId: 1002003, wordNum: 1, x: 100, y: 260, height: 20),
            makeBox(text: "שלישית", lineId: 1002003, wordNum: 2, x: 200, y: 260, height: 20),
        ]
        let structure = analyzePageStructure(boxes: boxes)
        #expect(structure.headerLineIds.contains(1001001))
        #expect(!structure.headerLineIds.contains(1002001))
    }

    @Test func detectsFooterWithLargeGap() {
        // Body lines with small gaps, then big gap, then footer line
        let boxes = [
            // Body lines (y=10, y=40, y=70)
            makeBox(text: "שורה", lineId: 1001001, wordNum: 1, x: 100, y: 10, height: 20),
            makeBox(text: "ראשונה", lineId: 1001001, wordNum: 2, x: 200, y: 10, height: 20),
            makeBox(text: "שורה", lineId: 1001002, wordNum: 1, x: 100, y: 40, height: 20),
            makeBox(text: "שנייה", lineId: 1001002, wordNum: 2, x: 200, y: 40, height: 20),
            makeBox(text: "שורה", lineId: 1001003, wordNum: 1, x: 100, y: 70, height: 20),
            makeBox(text: "שלישית", lineId: 1001003, wordNum: 2, x: 200, y: 70, height: 20),
            // Footer line (y=500 - large gap from body)
            makeBox(text: "עמוד", lineId: 1002001, wordNum: 1, x: 200, y: 500, height: 20),
            makeBox(text: "1", lineId: 1002001, wordNum: 2, x: 300, y: 500, height: 20),
        ]
        let structure = analyzePageStructure(boxes: boxes)
        #expect(structure.footerLineIds.contains(1002001))
        #expect(!structure.footerLineIds.contains(1001003))
    }

    @Test func detectsParagraphBreakOnShortLine() {
        // Two paragraphs: first ends with short line, second starts after
        let fullWidth: CGFloat = 500
        let boxes = [
            // Paragraph 1: two full lines + one short line
            makeBox(text: "שורה", lineId: 1001001, wordNum: 1, x: 100, y: 10, width: fullWidth, height: 20),
            makeBox(text: "שורה", lineId: 1001002, wordNum: 1, x: 100, y: 40, width: fullWidth, height: 20),
            makeBox(text: "קצרה", lineId: 1001003, wordNum: 1, x: 100, y: 70, width: 150, height: 20), // short!
            // Paragraph 2: full lines
            makeBox(text: "פסקה", lineId: 1001004, wordNum: 1, x: 100, y: 100, width: fullWidth, height: 20),
            makeBox(text: "שנייה", lineId: 1001005, wordNum: 1, x: 100, y: 130, width: fullWidth, height: 20),
        ]
        let structure = analyzePageStructure(boxes: boxes)

        // Should have 2 body paragraphs (short line triggers break)
        let bodyParagraphs = structure.paragraphs.filter { $0.role == .body || $0.role == .sectionHeading }
        #expect(bodyParagraphs.count == 2)
    }

    @Test func detectsSectionHeadingParagraph() {
        let boxes = [
            // Section heading paragraph starting with "א."
            makeBox(text: "א.", lineId: 1001001, wordNum: 1, x: 100, y: 10, width: 30, height: 20),
            makeBox(text: "מבוא", lineId: 1001001, wordNum: 2, x: 140, y: 10, width: 60, height: 20),
            // Make this a short line to force paragraph break
            // Then body paragraph
            makeBox(text: "טקסט", lineId: 1001002, wordNum: 1, x: 100, y: 40, width: 500, height: 20),
            makeBox(text: "גוף", lineId: 1001003, wordNum: 1, x: 100, y: 70, width: 500, height: 20),
        ]
        let structure = analyzePageStructure(boxes: boxes)

        let sectionHeadings = structure.paragraphs.filter { $0.role == .sectionHeading }
        #expect(sectionHeadings.count >= 1)
        #expect(sectionHeadings.first?.sectionNumber == "א.")
    }

    @Test func noHeaderFooterWhenGapsAreUniform() {
        // All lines evenly spaced - no header/footer should be detected
        let boxes = (0..<6).flatMap { i -> [OCRBox] in
            let y = CGFloat(10 + i * 30)
            let lineId = 1001001 + i
            return [
                makeBox(text: "מילה", lineId: lineId, wordNum: 1, x: 100, y: y, width: 400, height: 20),
                makeBox(text: "נוספת", lineId: lineId, wordNum: 2, x: 300, y: y, width: 100, height: 20),
            ]
        }
        let structure = analyzePageStructure(boxes: boxes)
        #expect(structure.headerLineIds.isEmpty)
        #expect(structure.footerLineIds.isEmpty)
    }

    @Test func marginBoxesAreExcludedFromStructure() {
        var marginBox = makeBox(text: "הערה", lineId: 2001001, wordNum: 1, x: 10, y: 100)
        marginBox.isMargin = true

        let boxes = [
            makeBox(text: "טקסט", lineId: 1001001, wordNum: 1, x: 200, y: 100, width: 400, height: 20),
            marginBox,
        ]
        let structure = analyzePageStructure(boxes: boxes)

        // Only the non-margin line should appear
        let allLineIds = structure.paragraphs.flatMap { $0.lineIds }
        #expect(allLineIds.contains(1001001))
        #expect(!allLineIds.contains(2001001))
    }
}

// MARK: - Script Classification Tests

struct ScriptClassificationTests {

    @Test func classifiesHebrewText() {
        #expect(classifyScript("שלום") == .hebrew)
        #expect(classifyScript("עולם") == .hebrew)
    }

    @Test func classifiesLatinOnly() {
        #expect(classifyScript("FUSER") == .latinOnly)
        #expect(classifyScript("hello") == .latinOnly)
        #expect(classifyScript("POD") == .latinOnly)
    }

    @Test func classifiesHebrewMixed() {
        #expect(classifyScript("שלוםworld") == .hebrewMixed)
    }

    @Test func classifiesNumbers() {
        #expect(classifyScript("123") == .number)
        #expect(classifyScript("58-003-387-6") == .number)
    }

    @Test func classifiesGarbage() {
        #expect(classifyScript("aaaa") == .garbage)
        #expect(classifyScript("") == .garbage)
    }

    @Test func classifiesPunctuation() {
        #expect(classifyScript("...") == .punctuation)
    }
}

// MARK: - OCRBox Placeholder Tests

struct OCRBoxPlaceholderTests {

    @Test func placeholderBoxHasCorrectProperties() {
        let box = OCRBox(text: "[...]", frame: .zero, lineId: 1001001, wordNum: 1, isPlaceholder: true)
        #expect(box.isPlaceholder)
        #expect(box.text == "[...]")
    }

    @Test func nonPlaceholderBoxDefaultsFalse() {
        let box = OCRBox(text: "שלום", frame: .zero, lineId: 1001001, wordNum: 1)
        #expect(!box.isPlaceholder)
    }

    @Test func parseTSVKeepsAllLatinWords() {
        // Build a minimal TSV where a Latin word has low confidence
        // The parser should still keep it (the LM decides later)
        let header = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext"
        let word1 = "5\t1\t1\t1\t1\t1\t100\t100\t80\t30\t90\tשלום"
        let word2 = "5\t1\t1\t1\t1\t2\t200\t100\t80\t30\t30\tFUSER"  // Low confidence Latin
        let tsv = [header, word1, word2].joined(separator: "\n")

        let boxes = parseTesseractTSV(tsv, imageSize: CGSize(width: 1000, height: 1000))

        // Both should be kept: Hebrew passes conf>5, Latin is always kept for LM
        let texts = boxes.map { $0.text }
        #expect(texts.contains("שלום"))
        #expect(texts.contains("FUSER"))  // Kept, not dropped or placeholdered
    }

    @Test func parseTSVTurnsGarbageIntoPlaceholder() {
        let header = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext"
        // Repeated chars = garbage pattern
        let garbageWord = "5\t1\t1\t1\t1\t1\t100\t100\t80\t30\t90\taaaaaaa"
        let tsv = [header, garbageWord].joined(separator: "\n")

        let boxes = parseTesseractTSV(tsv, imageSize: CGSize(width: 1000, height: 1000))

        // Garbage should become a placeholder
        #expect(boxes.count == 1)
        #expect(boxes[0].text == "[...]")
        #expect(boxes[0].isPlaceholder)
    }

    @Test func parseTSVTurnsLowConfHebrewIntoPlaceholder() {
        let header = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext"
        // Hebrew word with conf=2 (below threshold of 5)
        let lowConfWord = "5\t1\t1\t1\t1\t1\t100\t100\t80\t30\t2\tשלום"
        let tsv = [header, lowConfWord].joined(separator: "\n")

        let boxes = parseTesseractTSV(tsv, imageSize: CGSize(width: 1000, height: 1000))

        #expect(boxes.count == 1)
        #expect(boxes[0].text == "[...]")
        #expect(boxes[0].isPlaceholder)
    }
}

// MARK: - WordPiece Tokenizer Tests

struct WordPieceTokenizerTests {

    /// Create a minimal vocab string for testing
    private func makeTestVocab() -> String {
        return """
        [PAD]
        [UNK]
        [CLS]
        [SEP]
        [MASK]
        hello
        world
        ##ing
        ##ed
        test
        שלום
        עולם
        """
    }

    @Test func initializesFromVocabFile() {
        let vocab = makeTestVocab()

        let tok = WordPieceTokenizer(vocabContent: vocab)
        #expect(tok != nil)
    }

    @Test func specialTokenIdsAreCorrect() {
        let vocab = makeTestVocab()

        let tok = WordPieceTokenizer(vocabContent: vocab)!
        #expect(tok.padId == 0)
        #expect(tok.unkId == 1)
        #expect(tok.clsId == 2)
        #expect(tok.sepId == 3)
        #expect(tok.maskId == 4)
    }

    @Test func tokenizesKnownWords() {
        let vocab = makeTestVocab()

        let tok = WordPieceTokenizer(vocabContent: vocab)!
        let ids = tok.tokenize("hello world")
        #expect(ids == [5, 6])  // hello=5, world=6
    }

    @Test func tokenizesUnknownWordAsUNK() {
        let vocab = makeTestVocab()

        let tok = WordPieceTokenizer(vocabContent: vocab)!
        let ids = tok.tokenize("foobar")
        #expect(ids == [1])  // [UNK]
    }

    @Test func tokenizesHebrewWords() {
        let vocab = makeTestVocab()

        let tok = WordPieceTokenizer(vocabContent: vocab)!
        let ids = tok.tokenize("שלום עולם")
        #expect(ids == [10, 11])  // שלום=10, עולם=11
    }

    @Test func encodeAddsSpecialTokensAndPads() {
        let vocab = makeTestVocab()

        let tok = WordPieceTokenizer(vocabContent: vocab)!
        let (ids, mask, types) = tok.encode("hello", maxLength: 8)

        #expect(ids.count == 8)
        #expect(ids[0] == Int32(tok.clsId))   // [CLS]
        #expect(ids[1] == 5)                   // hello
        #expect(ids[2] == Int32(tok.sepId))   // [SEP]
        #expect(ids[3] == Int32(tok.padId))   // [PAD]

        // Attention mask: 1 for real tokens, 0 for padding
        #expect(mask[0] == 1)
        #expect(mask[1] == 1)
        #expect(mask[2] == 1)
        #expect(mask[3] == 0)

        // Token type IDs: all zeros for single sentence
        #expect(types.allSatisfy { $0 == 0 })
    }

    @Test func encodeWithMaskReplacesTargetWord() {
        let vocab = makeTestVocab()

        let tok = WordPieceTokenizer(vocabContent: vocab)!
        let (ids, _, _, maskIndices) = tok.encodeWithMask(
            "שלום hello עולם", masking: "hello", maxLength: 16
        )

        // Should have exactly one mask position
        #expect(maskIndices.count == 1)
        let maskIdx = maskIndices[0]
        #expect(ids[maskIdx] == Int32(tok.maskId))

        // [CLS] שלום [MASK] עולם [SEP]
        #expect(ids[0] == Int32(tok.clsId))
        #expect(ids[1] == 10)   // שלום
        #expect(ids[3] == 11)   // עולם
        #expect(ids[4] == Int32(tok.sepId))
    }

    @Test func isHebrewTokenDetectsHebrew() {
        let vocab = makeTestVocab()

        let tok = WordPieceTokenizer(vocabContent: vocab)!
        #expect(tok.isHebrewToken("שלום"))
        #expect(!tok.isHebrewToken("hello"))
        #expect(!tok.isHebrewToken("123"))
    }
}

// MARK: - Language Model Post-Processor Tests

struct LanguageModelPostProcessorTests {

    @Test func skipsProcessingWhenModelNotReady() async {
        // Model won't be loaded in test environment — should return boxes unchanged
        // This line has 2 Hebrew + 1 Latin, so Phase 4 threshold (≤1 Hebrew, ≥3 Latin)
        // is NOT met — Latin word is preserved.
        let boxes = [
            OCRBox(text: "שלום", frame: .zero, lineId: 1001001, wordNum: 1),
            OCRBox(text: "FUSER", frame: .zero, lineId: 1001001, wordNum: 2),
            OCRBox(text: "עולם", frame: .zero, lineId: 1001001, wordNum: 3),
        ]

        let result = await LanguageModelPostProcessor.process(boxes: boxes)

        // Without model, boxes are returned unchanged (Phase 4 doesn't trigger here)
        #expect(result.count == 3)
        #expect(result[0].text == "שלום")
        #expect(result[1].text == "FUSER")  // Not replaced since model isn't available
        #expect(result[2].text == "עולם")
    }

    @Test func preservesPlaceholderBoxes() async {
        let boxes = [
            OCRBox(text: "[...]", frame: .zero, lineId: 1001001, wordNum: 1, isPlaceholder: true),
            OCRBox(text: "שלום", frame: .zero, lineId: 1001001, wordNum: 2),
        ]

        let result = await LanguageModelPostProcessor.process(boxes: boxes)

        #expect(result[0].text == "[...]")
        #expect(result[0].isPlaceholder)
    }
}

// MARK: - Reversed Parentheses Tests

struct ReversedParenthesesTests {

    @Test func fixesFullReversedDigit() {
        #expect(normalizeReversedParentheses(")3(") == "(3)")
        #expect(normalizeReversedParentheses(")12(") == "(12)")
    }

    @Test func fixesFullReversedHebrew() {
        #expect(normalizeReversedParentheses(")א(") == "(א)")
        #expect(normalizeReversedParentheses(")ב(") == "(ב)")
    }

    @Test func fixesHalfReversed() {
        // Opening paren was split off by Tesseract
        #expect(normalizeReversedParentheses(")3") == "(3)")
        #expect(normalizeReversedParentheses(")א") == "(א)")
    }

    @Test func preservesCorrectParentheses() {
        #expect(normalizeReversedParentheses("(3)") == "(3)")
        #expect(normalizeReversedParentheses("(א)") == "(א)")
    }

    @Test func preservesNonParenText() {
        #expect(normalizeReversedParentheses("שלום") == "שלום")
        #expect(normalizeReversedParentheses("hello") == "hello")
        #expect(normalizeReversedParentheses("123") == "123")
    }

    @Test func preservesSingleCloseParen() {
        // Just a closing paren alone — no inner content
        #expect(normalizeReversedParentheses(")") == ")")
    }
}

// MARK: - Latin Garbage Cleanup Tests

struct LatinGarbageCleanupTests {

    @Test func cleansLineWithMostlyLatin() async {
        // Line with 1 Hebrew + 4 Latin → Latin should become [...]
        let boxes = [
            OCRBox(text: "שלום", frame: .zero, lineId: 1001001, wordNum: 1),
            OCRBox(text: "Zeer", frame: .zero, lineId: 1001001, wordNum: 2),
            OCRBox(text: "sarees", frame: .zero, lineId: 1001001, wordNum: 3),
            OCRBox(text: "ergo", frame: .zero, lineId: 1001001, wordNum: 4),
            OCRBox(text: "loom", frame: .zero, lineId: 1001001, wordNum: 5),
        ]

        let result = await LanguageModelPostProcessor.process(boxes: boxes)

        #expect(result[0].text == "שלום")  // Hebrew preserved
        #expect(result[1].text == "[...]")  // Latin → placeholder
        #expect(result[1].isPlaceholder)
        #expect(result[2].text == "[...]")
        #expect(result[3].text == "[...]")
        #expect(result[4].text == "[...]")
    }

    @Test func preservesLatinWhenEnoughHebrew() async {
        // Line with 3 Hebrew + 2 Latin → Latin preserved (not garbage)
        let boxes = [
            OCRBox(text: "שלום", frame: .zero, lineId: 1001001, wordNum: 1),
            OCRBox(text: "עולם", frame: .zero, lineId: 1001001, wordNum: 2),
            OCRBox(text: "טוב", frame: .zero, lineId: 1001001, wordNum: 3),
            OCRBox(text: "PDF", frame: .zero, lineId: 1001001, wordNum: 4),
            OCRBox(text: "HTML", frame: .zero, lineId: 1001001, wordNum: 5),
        ]

        let result = await LanguageModelPostProcessor.process(boxes: boxes)

        // Latin words preserved because hebrewCount(3) > 1
        #expect(result[3].text == "PDF")
        #expect(result[4].text == "HTML")
        #expect(!result[3].isPlaceholder)
        #expect(!result[4].isPlaceholder)
    }
}

// MARK: - Content-Based Footer Detection Tests

struct ContentBasedFooterTests {

    @Test func detectsLatinGarbageAtBottom() {
        // Simulate a page with body text at top and Latin garbage at bottom
        let boxes = [
            // Body lines (Hebrew content)
            makeBox(text: "שורה", lineId: 1001001, wordNum: 1, x: 100, y: 10, height: 20),
            makeBox(text: "ראשונה", lineId: 1001001, wordNum: 2, x: 200, y: 10, height: 20),
            makeBox(text: "שורה", lineId: 1001002, wordNum: 1, x: 100, y: 40, height: 20),
            makeBox(text: "שנייה", lineId: 1001002, wordNum: 2, x: 200, y: 40, height: 20),
            makeBox(text: "שורה", lineId: 1001003, wordNum: 1, x: 100, y: 70, height: 20),
            makeBox(text: "שלישית", lineId: 1001003, wordNum: 2, x: 200, y: 70, height: 20),
            // Bottom garbage lines (Latin-heavy, no Hebrew)
            makeBox(text: "Certified", lineId: 1002001, wordNum: 1, x: 100, y: 500, height: 20),
            makeBox(text: "Digital", lineId: 1002001, wordNum: 2, x: 200, y: 500, height: 20),
            makeBox(text: "Signature", lineId: 1002001, wordNum: 3, x: 300, y: 500, height: 20),
        ]

        let structure = analyzePageStructure(boxes: boxes)

        // The Latin garbage line at the bottom should be detected as footer
        #expect(structure.footerLineIds.contains(1002001))
    }

    @Test func stopsAtRealContentLine() {
        // Last line is Hebrew content — should NOT be marked as footer
        let boxes = [
            makeBox(text: "שורה", lineId: 1001001, wordNum: 1, x: 100, y: 10, height: 20),
            makeBox(text: "ראשונה", lineId: 1001001, wordNum: 2, x: 200, y: 10, height: 20),
            makeBox(text: "שורה", lineId: 1001002, wordNum: 1, x: 100, y: 40, height: 20),
            makeBox(text: "שנייה", lineId: 1001002, wordNum: 2, x: 200, y: 40, height: 20),
            makeBox(text: "שורה", lineId: 1001003, wordNum: 1, x: 100, y: 70, height: 20),
            makeBox(text: "אחרונה", lineId: 1001003, wordNum: 2, x: 200, y: 70, height: 20),
        ]

        let structure = analyzePageStructure(boxes: boxes)

        // No content-based footer should be detected — all lines are Hebrew
        #expect(!structure.footerLineIds.contains(1001003))
    }
}

// MARK: - Placeholder Collapsing Tests

struct PlaceholderCollapsingTests {

    @Test func collapsesConsecutivePlaceholders() {
        let input = "[...] [...] [...]"
        #expect(collapseConsecutivePlaceholders(input) == "[...]")
    }

    @Test func collapsesWithNewlines() {
        let input = "[...]\n[...]"
        #expect(collapseConsecutivePlaceholders(input) == "[...]")
    }

    @Test func preservesSinglePlaceholder() {
        let input = "[...]"
        #expect(collapseConsecutivePlaceholders(input) == "[...]")
    }

    @Test func preservesSeparatedPlaceholders() {
        // Placeholders separated by real text should not collapse
        let input = "[...] שלום [...]"
        #expect(collapseConsecutivePlaceholders(input) == "[...] שלום [...]")
    }

    @Test func collapsesMultipleGroups() {
        let input = "[...] [...] שלום [...] [...]"
        let result = collapseConsecutivePlaceholders(input)
        #expect(result == "[...] שלום [...]")
    }
}

// MARK: - DOCX Exporter Tests

struct DOCXExporterTests {

    private func singlePage(_ text: String, structure: PageStructure? = nil) -> [(mainText: String, marginText: String, structure: PageStructure?)] {
        [(mainText: text, marginText: "", structure: structure)]
    }

    @Test func generatesValidZipData() throws {
        let data = try DOCXExporter.export(pages: singlePage("שלום עולם"), title: "בדיקה")
        // ZIP files start with PK magic bytes (0x50, 0x4B)
        #expect(data.count > 4)
        #expect(data[0] == 0x50)
        #expect(data[1] == 0x4B)
    }

    @Test func containsRequiredEntries() throws {
        let data = try DOCXExporter.export(pages: singlePage("טקסט"), title: "מסמך")
        let archive = try Archive(data: data, accessMode: .read)

        let paths = Set(archive.map { $0.path })
        #expect(paths.contains("[Content_Types].xml"))
        #expect(paths.contains("_rels/.rels"))
        #expect(paths.contains("word/document.xml"))
        #expect(paths.contains("word/styles.xml"))
        #expect(paths.contains("word/_rels/document.xml.rels"))
    }

    @Test func hebrewTextAppearsInDocumentXml() throws {
        let hebrewText = "הנה טקסט בעברית"
        let data = try DOCXExporter.export(pages: singlePage(hebrewText), title: "מסמך")
        let archive = try Archive(data: data, accessMode: .read)

        var documentContent = ""
        guard let entry = archive["word/document.xml"] else {
            Issue.record("word/document.xml not found")
            return
        }
        _ = try archive.extract(entry) { chunk in
            documentContent += String(data: chunk, encoding: .utf8) ?? ""
        }

        #expect(documentContent.contains("הנה טקסט בעברית"))
    }

    @Test func sectionHeadingIsBold() throws {
        let structure = PageStructure(
            paragraphs: [
                DetectedParagraph(lineIds: [1001001], role: .sectionHeading, sectionNumber: "א.", isCentered: false),
            ],
            headerLineIds: [],
            footerLineIds: []
        )
        let data = try DOCXExporter.export(
            pages: [(mainText: "א. מבוא", marginText: "", structure: structure)],
            title: "מסמך"
        )
        let archive = try Archive(data: data, accessMode: .read)

        var documentContent = ""
        guard let entry = archive["word/document.xml"] else {
            Issue.record("word/document.xml not found")
            return
        }
        _ = try archive.extract(entry) { chunk in
            documentContent += String(data: chunk, encoding: .utf8) ?? ""
        }

        #expect(documentContent.contains("<w:b/>"))
        #expect(documentContent.contains("<w:bCs/>"))
        #expect(documentContent.contains("Heading1"))
    }

    @Test func xmlEscapesSpecialCharacters() {
        let escaped = DOCXExporter.escapeXML("a < b & c > d")
        #expect(escaped == "a &lt; b &amp; c &gt; d")
    }

    @Test func rtlMarkupPresent() throws {
        let data = try DOCXExporter.export(pages: singlePage("שלום"), title: "מסמך")
        let archive = try Archive(data: data, accessMode: .read)

        var documentContent = ""
        guard let entry = archive["word/document.xml"] else {
            Issue.record("word/document.xml not found")
            return
        }
        _ = try archive.extract(entry) { chunk in
            documentContent += String(data: chunk, encoding: .utf8) ?? ""
        }

        #expect(documentContent.contains("<w:bidi/>"))
        #expect(documentContent.contains("<w:rtl/>"))
    }

    @Test func placeholderRenderedWithItalicGray() throws {
        let data = try DOCXExporter.export(pages: singlePage("טקסט [...] עוד"), title: "מסמך")
        let archive = try Archive(data: data, accessMode: .read)

        var documentContent = ""
        guard let entry = archive["word/document.xml"] else {
            Issue.record("word/document.xml not found")
            return
        }
        _ = try archive.extract(entry) { chunk in
            documentContent += String(data: chunk, encoding: .utf8) ?? ""
        }

        // Placeholder should have italic and gray color properties
        #expect(documentContent.contains("<w:i/>"))
        #expect(documentContent.contains("<w:iCs/>"))
        #expect(documentContent.contains("<w:color w:val=\"999999\"/>"))
        #expect(documentContent.contains("[...]"))
    }
}

// MARK: - Centered Line Detection Tests

struct CenteredLineDetectionTests {

    @Test func detectsCenteredShortLine() {
        // Page with body lines spanning full width, and one short centered line
        let fullWidth: CGFloat = 500
        let pageLeft: CGFloat = 100
        let pageRight = pageLeft + fullWidth

        let boxes = [
            // Full-width body lines
            makeBox(text: "שורה", lineId: 1001001, wordNum: 1, x: pageLeft, y: 10, width: fullWidth, height: 20),
            makeBox(text: "שורה", lineId: 1001002, wordNum: 1, x: pageLeft, y: 40, width: fullWidth, height: 20),
            // Short centered line (200px wide, centered at pageLeft + 250 = 350)
            // center at 350, so left = 250, right = 450 → symmetric within page
            makeBox(text: "כותרת", lineId: 1001003, wordNum: 1, x: 250, y: 70, width: 200, height: 20),
            // More full-width lines
            makeBox(text: "שורה", lineId: 1001004, wordNum: 1, x: pageLeft, y: 100, width: fullWidth, height: 20),
            makeBox(text: "שורה", lineId: 1001005, wordNum: 1, x: pageLeft, y: 130, width: fullWidth, height: 20),
        ]

        let structure = analyzePageStructure(boxes: boxes)

        // Find the paragraph containing the short centered line
        let centeredParas = structure.paragraphs.filter { $0.isCentered }
        #expect(centeredParas.count >= 1)
    }

    @Test func doesNotCenterFullWidthLines() {
        // All lines are full-width — none should be centered
        let boxes = (0..<6).flatMap { i -> [OCRBox] in
            let y = CGFloat(10 + i * 30)
            let lineId = 1001001 + i
            return [
                makeBox(text: "מילה", lineId: lineId, wordNum: 1, x: 100, y: y, width: 500, height: 20),
            ]
        }

        let structure = analyzePageStructure(boxes: boxes)
        let centeredParas = structure.paragraphs.filter { $0.isCentered }
        #expect(centeredParas.isEmpty)
    }

    @Test func doesNotCenterLeftAlignedShortLine() {
        // Short line at the right edge (RTL left-aligned) — NOT centered
        let boxes = [
            makeBox(text: "שורה", lineId: 1001001, wordNum: 1, x: 100, y: 10, width: 500, height: 20),
            makeBox(text: "שורה", lineId: 1001002, wordNum: 1, x: 100, y: 40, width: 500, height: 20),
            // Short line, flush right (for RTL that's "left-aligned")
            makeBox(text: "קצרה", lineId: 1001003, wordNum: 1, x: 100, y: 70, width: 200, height: 20),
            makeBox(text: "שורה", lineId: 1001004, wordNum: 1, x: 100, y: 100, width: 500, height: 20),
            makeBox(text: "שורה", lineId: 1001005, wordNum: 1, x: 100, y: 130, width: 500, height: 20),
        ]

        let structure = analyzePageStructure(boxes: boxes)

        // The short line's midpoint is at 200 (x=100, width=200 → center=200)
        // But page center is at 350 (100 + 500/2), so it should NOT be centered
        let centeredParas = structure.paragraphs.filter { $0.isCentered }
        #expect(centeredParas.isEmpty)
    }
}
