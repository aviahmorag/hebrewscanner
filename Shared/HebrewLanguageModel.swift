//
//  HebrewLanguageModel.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

import Foundation
import CoreML

/// Result of masked language model prediction for a single [MASK] position.
struct MaskPrediction: Sendable {
    let topTokens: [(token: String, probability: Float)]
    let hebrewProbability: Float   // Sum of probabilities for Hebrew tokens in top-K
}

/// Manages the DictaBERT Core ML model for masked Hebrew language prediction.
/// Thread-safe via actor isolation.
actor HebrewLanguageModel {

    static let shared = HebrewLanguageModel()

    enum ModelState {
        case notLoaded
        case loading
        case ready
        case failed(Error)
    }

    private(set) var state: ModelState = .notLoaded
    private var model: MLModel?
    private var tokenizer: WordPieceTokenizer?

    private let maxSeqLen = 128
    private let topK = 20

    // MARK: - Loading

    /// Load the model and vocabulary from the app bundle. Call once at startup.
    func loadModel() async {
        guard case .notLoaded = state else { return }
        state = .loading

        do {
            // Find compiled model in bundle (Xcode compiles .mlpackage → .mlmodelc)
            guard let modelURL = Bundle.main.url(forResource: "DictaBERT", withExtension: "mlmodelc")
                    ?? Bundle.main.url(forResource: "DictaBERT", withExtension: "mlpackage") else {
                print("❌ Bundle contents: \(Bundle.main.bundleURL.path)")
                throw ModelError.modelNotFound
            }
            guard let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "txt") else {
                throw ModelError.vocabNotFound
            }
            let vocabContent = try String(contentsOf: vocabURL, encoding: .utf8)
            guard let tok = WordPieceTokenizer(vocabContent: vocabContent) else {
                throw ModelError.vocabLoadFailed
            }

            let config = MLModelConfiguration()
            config.computeUnits = .all   // Use Neural Engine when available
            let loadedModel = try MLModel(contentsOf: modelURL, configuration: config)

            self.model = loadedModel
            self.tokenizer = tok
            self.state = .ready
            print("✅ DictaBERT model loaded successfully")
        } catch {
            self.state = .failed(error)
            print("❌ DictaBERT model load failed: \(error)")
        }
    }

    /// Whether the model is ready for inference.
    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    // MARK: - Inference

    /// Predict what should fill the masked position of `wordToMask` in `lineText`.
    /// Returns nil if model isn't ready.
    func predictMasked(lineText: String, wordToMask: String) async -> MaskPrediction? {
        guard let model = model, let tokenizer = tokenizer else { return nil }

        let (inputIds, attentionMask, tokenTypeIds, maskIndices) =
            tokenizer.encodeWithMask(lineText, masking: wordToMask, maxLength: maxSeqLen)

        guard !maskIndices.isEmpty else { return nil }

        do {
            // Build MLMultiArray inputs
            let idsArray = try createMultiArray(from: inputIds)
            let maskArray = try createMultiArray(from: attentionMask)
            let typeArray = try createMultiArray(from: tokenTypeIds)

            let input = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: idsArray),
                "attention_mask": MLFeatureValue(multiArray: maskArray),
                "token_type_ids": MLFeatureValue(multiArray: typeArray),
            ])

            let output = try await model.prediction(from: input)

            // Extract logits: shape (1, seq_len, vocab_size)
            guard let logitsValue = output.featureValue(for: "logits"),
                  let logits = logitsValue.multiArrayValue else {
                return nil
            }

            // Use the first mask position
            let maskIdx = maskIndices[0]
            let vocabSize = logits.shape[2].intValue

            // Extract logits for the masked position.
            // The model may output Float16 or Float32 depending on compute precision.
            var rawLogits = [Float](repeating: 0, count: vocabSize)
            let offset = maskIdx * vocabSize
            if logits.dataType == .float16 {
                let ptr = logits.dataPointer.assumingMemoryBound(to: Float16.self)
                for i in 0..<vocabSize {
                    rawLogits[i] = Float(ptr[offset + i])
                }
            } else {
                let ptr = logits.dataPointer.assumingMemoryBound(to: Float.self)
                for i in 0..<vocabSize {
                    rawLogits[i] = ptr[offset + i]
                }
            }

            // Softmax
            let maxLogit = rawLogits.max() ?? 0
            let exps = rawLogits.map { exp($0 - maxLogit) }
            let sumExps = exps.reduce(0, +)
            let probs = exps.map { $0 / sumExps }

            // Top-K
            let indexed = probs.enumerated().sorted { $0.element > $1.element }
            let topEntries = indexed.prefix(topK).compactMap { (idx, prob) -> (String, Float)? in
                guard let tok = tokenizer.token(for: idx) else { return nil }
                return (tok, prob)
            }

            // Hebrew probability: sum of probabilities where the predicted token is Hebrew
            var hebrewProb: Float = 0
            for (idx, prob) in indexed.prefix(topK) {
                if let tok = tokenizer.token(for: idx), tokenizer.isHebrewToken(tok) {
                    hebrewProb += prob
                }
            }

            return MaskPrediction(
                topTokens: topEntries,
                hebrewProbability: hebrewProb
            )
        } catch {
            print("⚠️ DictaBERT inference error: \(error)")
            return nil
        }
    }

    // MARK: - Confusion-Based Correction

    /// Try to correct a word using known OCR character confusion pairs.
    /// Returns the correction if the original is NOT in the vocabulary and exactly one
    /// single-character substitution produces a vocabulary word.
    func correctByConfusion(_ word: String, pairs: [(Character, Character)]) -> String? {
        guard let tokenizer = tokenizer else { return nil }
        guard !tokenizer.isInVocab(word) else { return nil }

        let chars = Array(word)
        var candidates: Set<String> = []
        for (i, ch) in chars.enumerated() {
            for (a, b) in pairs {
                var replacement: Character?
                if ch == a { replacement = b }
                else if ch == b { replacement = a }
                guard let rep = replacement else { continue }
                var newChars = chars
                newChars[i] = rep
                let candidate = String(newChars)
                if tokenizer.isInVocab(candidate) {
                    candidates.insert(candidate)
                }
            }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    // MARK: - Helpers

    private func createMultiArray(from array: [Int32]) throws -> MLMultiArray {
        let mlArray = try MLMultiArray(shape: [1, NSNumber(value: array.count)], dataType: .int32)
        let ptr = mlArray.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<array.count {
            ptr[i] = array[i]
        }
        return mlArray
    }

    enum ModelError: LocalizedError {
        case modelNotFound
        case vocabNotFound
        case vocabLoadFailed

        var errorDescription: String? {
            switch self {
            case .modelNotFound: return "DictaBERT.mlmodelc not found in bundle"
            case .vocabNotFound: return "vocab.txt not found in bundle"
            case .vocabLoadFailed: return "Failed to parse vocab.txt"
            }
        }
    }
}
