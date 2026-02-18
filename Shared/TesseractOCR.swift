//
//  TesseractOCR.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

import Foundation

func runTesseractOCR(imageURL: URL) async throws -> (text: String, tsv: String) {
    let fm = FileManager.default
    let tessdataPath: String
    if let resourceURL = Bundle.main.resourceURL {
        // Check common bundle locations for tessdata
        let candidates = ["tessdata", "Resources/tessdata"]
        if let found = candidates.first(where: { candidate in
            let url = resourceURL.appendingPathComponent(candidate)
            return fm.fileExists(atPath: url.appendingPathComponent("heb.traineddata").path)
        }) {
            tessdataPath = resourceURL.appendingPathComponent(found).path
        } else {
            throw NSError(domain: "OCR", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "חסרת תיקיית tessdata")])
        }
    } else {
        throw NSError(domain: "OCR", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "חסרת תיקיית tessdata")])
    }

    let imagePath = imageURL.path

    print("📥 OCR input image: \(imagePath)")
    print("📚 tessdata folder: \(tessdataPath)")

    let tsvString: String = try await Task.detached {
        // Create API handle
        guard let api = TessBaseAPICreate() else {
            throw NSError(domain: "OCR", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create Tesseract API"
            ])
        }
        defer { TessBaseAPIDelete(api) }

        // Initialize with tessdata path and languages
        let initResult = TessBaseAPIInit3(api, tessdataPath, "heb+eng")
        guard initResult == 0 else {
            throw NSError(domain: "OCR", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Tesseract init failed (code \(initResult)). tessdata path: \(tessdataPath)"
            ])
        }
        defer { TessBaseAPIEnd(api) }

        // Set page segmentation mode to single block
        TessBaseAPISetPageSegMode(api, PSM_SINGLE_BLOCK)

        // Load image via Leptonica
        var pix: OpaquePointer? = pixRead(imagePath)
        guard pix != nil else {
            throw NSError(domain: "OCR", code: 3, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "לא ניתן לקרוא את התמונה")
            ])
        }
        defer { pixDestroy(&pix) }

        // Set image and recognize
        TessBaseAPISetImage2(api, pix)

        let recognizeResult = TessBaseAPIRecognize(api, nil)
        guard recognizeResult == 0 else {
            throw NSError(domain: "OCR", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Tesseract recognition failed (code \(recognizeResult))"
            ])
        }

        // Get TSV output
        guard let tsvPtr = TessBaseAPIGetTsvText(api, 0) else {
            throw NSError(domain: "OCR", code: 5, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "לא התקבל פלט TSV מ-Tesseract")
            ])
        }
        defer { TessDeleteText(tsvPtr) }

        let tsv = String(cString: tsvPtr)
        return tsv
    }.value

    if tsvString.isEmpty {
        print("❌ No TSV output received from Tesseract.")
        throw NSError(domain: "OCR", code: 3, userInfo: [
            NSLocalizedDescriptionKey: String(localized: "לא התקבל פלט TSV מ-Tesseract")
        ])
    }

    print("✅ TSV output received successfully.")
    print("📋 TSV content preview: \(String(tsvString.prefix(200)))")

    let recognizedText = tsvString
        .components(separatedBy: .newlines)
        .compactMap { line in
            let fields = line.components(separatedBy: "\t")
            if fields.count > 11 && fields[0] == "5" {
                let word = fields[11].trimmingCharacters(in: .whitespaces)
                return word.isEmpty ? nil : word
            }
            return nil
        }
        .joined(separator: " ")

    return (recognizedText, tsvString)
}
