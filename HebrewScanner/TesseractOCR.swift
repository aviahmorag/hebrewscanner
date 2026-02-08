//
//  TesseractOCR.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

import Foundation

@MainActor
func runTesseractOCR(imageURL: URL) async throws -> (text: String, tsv: String) {
    guard let tesseractURL = Bundle.main.resourceURL?.appendingPathComponent("tesseract") else {
        throw NSError(domain: "OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "חסר קובץ tesseract")])
    }

    guard let tessdataURL = Bundle.main.resourceURL?.appendingPathComponent("tessdata") else {
        throw NSError(domain: "OCR", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "חסרת תיקיית tessdata")])
    }

    let tempBase = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let tempTSV = tempBase.appendingPathExtension("tsv")

    print("📥 OCR input image: \(imageURL.path)")
    print("📄 Expected output TSV: \(tempTSV.path)")
    print("⚙️ Tesseract binary: \(tesseractURL.path)")
    print("📚 tessdata folder: \(tessdataURL.path)")

    let process = Process()
    process.executableURL = tesseractURL
    process.arguments = [
        imageURL.path,
        "stdout",
        "-l", "heb+eng",
        "--tessdata-dir", tessdataURL.path,
        "--psm", "6",
        "-c", "tessedit_create_tsv=1"
    ]
    
    print("🛠️ Running Tesseract with args: \(process.arguments!.joined(separator: " "))")

    let errorPipe = Pipe()
    let outputPipe = Pipe()
    process.standardError = errorPipe
    process.standardOutput = outputPipe

    try process.run()
    process.waitUntilExit()

    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrOutput = String(data: errorData, encoding: .utf8) ?? ""
    
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let tsvString = String(data: outputData, encoding: .utf8) ?? ""

    print("📤 stderr: \(stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines))")

    if process.terminationStatus != 0 {
        throw NSError(domain: "OCR", code: Int(process.terminationStatus), userInfo: [
            NSLocalizedDescriptionKey: "Tesseract failed with code \(process.terminationStatus): \(stderrOutput)"
        ])
    }

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
