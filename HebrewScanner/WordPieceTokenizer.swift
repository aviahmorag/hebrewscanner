//
//  WordPieceTokenizer.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

import Foundation

/// Pure-Swift WordPiece tokenizer compatible with DictaBERT vocabulary.
/// All members are nonisolated so the tokenizer can be used from any actor.
final class WordPieceTokenizer: Sendable {
    /// Token → ID lookup
    private let vocab: [String: Int]
    /// ID → Token reverse lookup
    private let idToToken: [Int: String]

    // Special token IDs
    nonisolated let padId: Int
    nonisolated let unkId: Int
    nonisolated let clsId: Int
    nonisolated let sepId: Int
    nonisolated let maskId: Int

    private let maxWordLen = 100

    /// Initialize from vocabulary text content (one token per line, line number = token ID).
    nonisolated init?(vocabContent: String) {
        let lines = vocabContent.components(separatedBy: .newlines)
        var v: [String: Int] = [:]
        var r: [Int: String] = [:]
        for (i, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            v[line] = i
            r[i] = line
        }
        self.vocab = v
        self.idToToken = r
        self.padId = v["[PAD]"] ?? 0
        self.unkId = v["[UNK]"] ?? 1
        self.clsId = v["[CLS]"] ?? 2
        self.sepId = v["[SEP]"] ?? 3
        self.maskId = v["[MASK]"] ?? 4
    }

    /// Tokenise text into WordPiece token IDs.
    nonisolated func tokenize(_ text: String) -> [Int] {
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var ids: [Int] = []
        for word in words {
            ids.append(contentsOf: tokenizeWord(word))
        }
        return ids
    }

    /// Encode a sentence with [CLS] … [SEP] and pad/truncate to `maxLength`.
    /// Returns (input_ids, attention_mask, token_type_ids).
    nonisolated func encode(_ text: String, maxLength: Int = 128) -> (inputIds: [Int32], attentionMask: [Int32], tokenTypeIds: [Int32]) {
        var ids = tokenize(text)

        // Truncate to fit [CLS] + tokens + [SEP]
        let maxTokens = maxLength - 2
        if ids.count > maxTokens {
            ids = Array(ids.prefix(maxTokens))
        }

        var inputIds: [Int32] = [Int32(clsId)]
        inputIds.append(contentsOf: ids.map { Int32($0) })
        inputIds.append(Int32(sepId))

        let realLen = inputIds.count
        let attentionMask = Array(repeating: Int32(1), count: realLen)
            + Array(repeating: Int32(0), count: maxLength - realLen)
        inputIds += Array(repeating: Int32(padId), count: maxLength - realLen)
        let tokenTypeIds = Array(repeating: Int32(0), count: maxLength)

        return (inputIds, attentionMask, tokenTypeIds)
    }

    /// Encode text and replace the token(s) corresponding to `wordToMask` with [MASK].
    /// Returns (input_ids, attention_mask, token_type_ids, maskIndices).
    nonisolated func encodeWithMask(_ text: String, masking wordToMask: String, maxLength: Int = 128)
        -> (inputIds: [Int32], attentionMask: [Int32], tokenTypeIds: [Int32], maskIndices: [Int])
    {
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var allTokenIds: [Int] = []
        var maskRanges: [Range<Int>] = []

        var masked = false
        for word in words {
            let wordIds = tokenizeWord(word)
            // Only mask the FIRST occurrence — masking all duplicates corrupts context
            if !masked && word.lowercased() == wordToMask.lowercased() {
                let start = allTokenIds.count
                let end = start + wordIds.count
                maskRanges.append(start..<end)
                masked = true
            }
            allTokenIds.append(contentsOf: wordIds)
        }

        // Truncate
        let maxTokens = maxLength - 2
        if allTokenIds.count > maxTokens {
            allTokenIds = Array(allTokenIds.prefix(maxTokens))
        }

        // Build input with [CLS] prefix — shift mask indices by 1
        var inputIds: [Int32] = [Int32(clsId)]
        var maskIndices: [Int] = []

        for (i, id) in allTokenIds.enumerated() {
            let isMasked = maskRanges.contains { $0.contains(i) }
            if isMasked {
                inputIds.append(Int32(maskId))
                maskIndices.append(inputIds.count - 1) // index in final array
            } else {
                inputIds.append(Int32(id))
            }
        }
        inputIds.append(Int32(sepId))

        let realLen = inputIds.count
        let attentionMask = Array(repeating: Int32(1), count: realLen)
            + Array(repeating: Int32(0), count: maxLength - realLen)
        inputIds += Array(repeating: Int32(padId), count: maxLength - realLen)
        let tokenTypeIds = Array(repeating: Int32(0), count: maxLength)

        return (inputIds, attentionMask, tokenTypeIds, maskIndices)
    }

    /// Look up a token string by ID.
    nonisolated func token(for id: Int) -> String? {
        idToToken[id]
    }

    /// Check if a word exists as a single token in the vocabulary.
    nonisolated func isInVocab(_ word: String) -> Bool {
        vocab[word.lowercased()] != nil
    }

    /// Check if a token string contains Hebrew characters.
    nonisolated func isHebrewToken(_ token: String) -> Bool {
        token.unicodeScalars.contains { $0.value >= 0x0590 && $0.value <= 0x05FF }
    }

    // MARK: - Private

    nonisolated private func tokenizeWord(_ word: String) -> [Int] {
        let lower = word.lowercased()
        guard lower.count <= maxWordLen else { return [unkId] }

        // Try whole-word lookup first
        if let id = vocab[lower] {
            return [id]
        }

        // WordPiece: greedy longest-match from left
        var tokens: [Int] = []
        var start = lower.startIndex

        while start < lower.endIndex {
            var end = lower.endIndex
            var matched = false

            while start < end {
                let substr: String
                if start == lower.startIndex {
                    substr = String(lower[start..<end])
                } else {
                    substr = "##" + String(lower[start..<end])
                }

                if let id = vocab[substr] {
                    tokens.append(id)
                    start = end
                    matched = true
                    break
                }

                // Shrink the window by one character
                end = lower.index(before: end)
            }

            if !matched {
                return [unkId]
            }
        }

        return tokens
    }
}
