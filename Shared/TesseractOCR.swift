//
//  TesseractOCR.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

import Foundation

/// Preprocess an image for better OCR on screen-photographed documents.
/// Converts to grayscale, downscales to destroy moiré, and applies a median
/// filter to clean residual noise. Saves debug images to tmp/ for inspection.
/// Returns the processed Pix and the scale factor applied (original → processed).
/// Callers must divide box coordinates by this scale to map back to original image space.
private nonisolated func preprocessImage(_ pix: OpaquePointer) -> (pix: OpaquePointer, scale: Float) {
    let w = pixGetWidth(pix)
    let h = pixGetHeight(pix)
    let depth = pixGetDepth(pix)
    print("🔧 preprocessImage: input \(w)×\(h) depth=\(depth)")

    let debugDir = NSTemporaryDirectory()

    // Step 1: Convert to grayscale
    var gray: OpaquePointer
    if depth > 8 {
        guard let converted = pixConvertRGBToGray(pix, 0, 0, 0) else {
            print("⚠️ preprocessImage: grayscale conversion failed, using original")
            return (pix, 1.0)
        }
        gray = converted
        pixWrite("\(debugDir)debug_1_gray.png", gray, 3) // IFF_PNG = 3
        print("🔧 preprocessImage: converted to grayscale → \(debugDir)debug_1_gray.png")
    } else {
        gray = pix
        print("🔧 preprocessImage: already grayscale, skipping conversion")
    }

    // Step 2: Downscale large images. Anti-aliased downsampling low-pass filters
    // the image, which reduces moiré from screen pixel grid interference.
    let ownGray = (gray != pix)
    var current: OpaquePointer = gray
    var ownCurrent = ownGray
    var appliedScale: Float = 1.0
    if w > 1500 {
        let scale = Float(1500) / Float(w)
        if let scaled = pixScaleSmooth(gray, scale, scale) {
            appliedScale = scale
            if ownGray { var g: OpaquePointer? = gray; pixDestroy(&g) }
            current = scaled
            ownCurrent = true
            let sw = pixGetWidth(scaled)
            let sh = pixGetHeight(scaled)
            pixWrite("\(debugDir)debug_2_scaled.png", scaled, 3)
            print("🔧 preprocessImage: downscaled to \(sw)×\(sh) (scale=\(String(format: "%.2f", scale))) → \(debugDir)debug_2_scaled.png")
        } else {
            print("⚠️ preprocessImage: downscale failed, continuing at original size")
        }
    } else {
        print("🔧 preprocessImage: width \(w) ≤ 1500, skipping downscale")
    }

    // Step 3: Normalize background to white. Handles colored backgrounds
    // (yellow signs → grey in grayscale) and uneven lighting / glare.
    guard let clean = pixCleanBackgroundToWhite(current, nil, nil, 1.0, 70, 190) else {
        print("⚠️ preprocessImage: background cleanup failed, using current image")
        return (current, appliedScale)
    }
    if ownCurrent { var p: OpaquePointer? = current; pixDestroy(&p) }
    pixWrite("\(debugDir)debug_3_bgclean.png", clean, 3)
    print("🔧 preprocessImage: normalized background → \(debugDir)debug_3_bgclean.png")

    // Step 4: Median filter to remove residual noise
    guard let filtered = pixMedianFilter(clean, 3, 3) else {
        print("⚠️ preprocessImage: median filter failed, using cleaned image")
        return (clean, appliedScale)
    }
    var cl: OpaquePointer? = clean; pixDestroy(&cl)
    pixWrite("\(debugDir)debug_4_median.png", filtered, 3)
    print("🔧 preprocessImage: applied 3×3 median filter → \(debugDir)debug_4_median.png ✓")

    return (filtered, appliedScale)
}

/// Returns recognized text, TSV output, and the preprocessing scale factor.
/// Box coordinates in the TSV are in the preprocessed image's coordinate space;
/// divide by `preprocessScale` to map them back to the original image.
func runTesseractOCR(imageURL: URL) async throws -> (text: String, tsv: String, preprocessScale: Float) {
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

    let (tsvString, preprocScale): (String, Float) = try await Task.detached {
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
        let rawPix: OpaquePointer? = pixRead(imagePath)
        guard let rawPixNN = rawPix else {
            throw NSError(domain: "OCR", code: 3, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "לא ניתן לקרוא את התמונה")
            ])
        }

        // Preprocess for screen-photographed documents
        let (processed, scale) = preprocessImage(rawPixNN)
        var pix: OpaquePointer? = processed
        defer { pixDestroy(&pix) }
        // Free the raw image if preprocessing produced a new one
        if processed != rawPixNN {
            var raw: OpaquePointer? = rawPixNN
            pixDestroy(&raw)
        }

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
        return (tsv, scale)
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

    return (recognizedText, tsvString, preprocScale)
}
