//
//  ContentView_iOS.swift
//  Ayin iOS
//
//  Created by Aviah Morag in 2026.
//

import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import PhotosUI
import UIKit
import CoreText

/// Collapses consecutive `[...]` placeholders (separated by whitespace) into a single `[...]`.
private func collapseConsecutivePlaceholders(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "\\[\\.\\.\\.\\](\\s+\\[\\.\\.\\.\\])+") else {
        return text
    }
    return regex.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text),
        withTemplate: "[...]"
    )
}

struct ContentView_iOS: View {
    @State private var image: UIImage?
    @State private var imageURL: URL?
    @State private var ocrText: String = ""
    @State private var isLoading = false
    @State private var ocrBoxes: [OCRBox] = []
    @State private var ocrTask: Task<Void, Never>?
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var pageStructure: PageStructure?

    // PDF support
    @State private var pdfDocument: PDFDocument?
    @State private var currentPageIndex: Int = 0
    @State private var totalPages: Int = 0

    // Image sources
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var showGalleryPicker = false

    // Export
    @State private var exportedFileURL: URL?
    @State private var showExportSheet = false
    @State private var showExportFormatPicker = false

    // About
    @State private var showAbout = false

    // Debug
    #if DEBUG
    @State private var showDebugImages = false
    #endif

    private let ocrMinZoom: CGFloat = 2.0  // Minimum zoom for OCR (~288 DPI on Retina)

    var body: some View {
        NavigationStack {
            ZStack {
                if let image = image {
                    SelectableOverlayImageView_iOS(
                        image: image,
                        boxes: ocrBoxes,
                        pageStructure: pageStructure
                    )
                } else {
                    emptyStateView
                }

                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .scaleEffect(1.2)
                        .frame(width: 60, height: 60)
                        .background(.regularMaterial, in: Circle())
                }

                if isExporting {
                    VStack(spacing: 12) {
                        ProgressView(value: exportProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 200)
                        Text("מייצא... \(Int(exportProgress * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("עין")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack {
                        Button {
                            showAbout = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        #if DEBUG
                        Button {
                            showDebugImages = true
                        } label: {
                            Image(systemName: "eye.trianglebadge.exclamationmark")
                        }
                        .disabled(image == nil)
                        #endif
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if image != nil {
                        Button(action: { showExportFormatPicker = true }) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(isLoading || isExporting || ocrBoxes.isEmpty)
                    }

                    Menu {
                        Button {
                            showGalleryPicker = true
                        } label: {
                            Label("בחר מהגלריה", systemImage: "photo")
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("בחר קובץ...", systemImage: "folder")
                        }
                        Button {
                            showCamera = true
                        } label: {
                            Label("צלם תמונה", systemImage: "camera")
                        }
                    } label: {
                        Image(systemName: "doc.viewfinder")
                    }
                    .disabled(isLoading)
                }

                // PDF page navigation
                if totalPages > 1 {
                    ToolbarItem(placement: .bottomBar) {
                        HStack {
                            Button(action: previousPage) {
                                Image(systemName: "chevron.right")
                            }
                            .disabled(currentPageIndex <= 0)

                            Spacer()

                            Text("עמוד \(currentPageIndex + 1) מתוך \(totalPages)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .fixedSize()

                            Spacer()

                            Button(action: nextPage) {
                                Image(systemName: "chevron.left")
                            }
                            .disabled(currentPageIndex >= totalPages - 1)
                        }
                    }
                }
            }
            .photosPicker(isPresented: $showGalleryPicker, selection: $selectedPhotoItem, matching: .images)
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                loadFromPhotosPicker(newItem)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.png, .jpeg, .tiff, .bmp, .gif, .pdf],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        loadFromFileURL(url)
                    }
                case .failure(let error):
                    print("File import error: \(error)")
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraView { capturedImage in
                    if let capturedImage {
                        loadImage(capturedImage)
                    }
                }
            }
            .sheet(isPresented: $showExportFormatPicker) {
                ExportFormatSheet { format in
                    showExportFormatPicker = false
                    exportToDocument(format: format)
                }
                .presentationDetents([.height(280)])
            }
            .sheet(isPresented: $showExportSheet) {
                if let url = exportedFileURL {
                    ShareSheet(items: [url])
                }
            }
            .sheet(isPresented: $showAbout) {
                AboutSheet()
                    .presentationDetents([.medium, .large])
            }
            #if DEBUG
            .sheet(isPresented: $showDebugImages) {
                DebugPreprocessSheet()
                    .presentationDetents([.large])
            }
            #endif
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("בחר או צלם תמונה לסריקת טקסט עברי")
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button {
                    showGalleryPicker = true
                } label: {
                    Label("גלריה", systemImage: "photo")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showCamera = true
                } label: {
                    Label("מצלמה", systemImage: "camera")
                }
                .buttonStyle(.bordered)

                Button {
                    showFileImporter = true
                } label: {
                    Label("קובץ", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    // MARK: - Image Loading

    private func loadFromPhotosPicker(_ item: PhotosPickerItem) {
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else { return }
            loadImage(uiImage)
        }
    }

    private func loadFromFileURL(_ url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        if url.pathExtension.lowercased() == "pdf" {
            loadPDF(from: url)
        } else if let data = try? Data(contentsOf: url),
                  let uiImage = UIImage(data: data) {
            self.imageURL = url
            loadImage(uiImage)
        }
    }

    private func loadImage(_ uiImage: UIImage) {
        // Reset PDF state
        self.pdfDocument = nil
        self.totalPages = 0
        self.currentPageIndex = 0

        self.image = uiImage
        self.ocrBoxes = []
        self.pageStructure = nil
        isLoading = true

        ocrTask?.cancel()
        ocrTask = Task {
            do {
                // Save UIImage to temp file for Tesseract
                let tempURL = createTempImageFile(from: uiImage)
                self.imageURL = tempURL

                try Task.checkCancellation()
                let (text, tsv, preprocessScale) = try await runTesseractOCR(imageURL: tempURL)

                try Task.checkCancellation()
                if !Task.isCancelled {
                    self.ocrText = text
                    var boxes = parseTesseractTSV(tsv, imageSize: uiImage.size)
                    // Scale coordinates from preprocessed image space back to original
                    let coordScale = CGFloat(1.0 / preprocessScale)
                    if coordScale != 1.0 {
                        for i in boxes.indices {
                            let f = boxes[i].frame
                            boxes[i].frame = CGRect(x: f.minX * coordScale, y: f.minY * coordScale,
                                                    width: f.width * coordScale, height: f.height * coordScale)
                        }
                    }
                    boxes = await LanguageModelPostProcessor.process(boxes: boxes)
                    self.ocrBoxes = boxes
                    self.pageStructure = analyzePageStructure(boxes: self.ocrBoxes)
                    print("Loaded \(self.ocrBoxes.count) boxes")
                }
            } catch is CancellationError {
                print("OCR task cancelled")
            } catch {
                if !Task.isCancelled {
                    print("❌ OCR error: \(error.localizedDescription)")
                    self.ocrText = String(localized: "שגיאה בהרצת OCR: \(error.localizedDescription)")
                    self.ocrBoxes = []
                    self.pageStructure = nil
                }
            }
            if !Task.isCancelled {
                isLoading = false
            }
        }
    }

    // MARK: - PDF Support

    private func loadPDF(from url: URL) {
        guard let pdfDoc = PDFDocument(url: url) else {
            print("Failed to load PDF")
            return
        }

        self.pdfDocument = pdfDoc
        self.totalPages = pdfDoc.pageCount
        self.currentPageIndex = 0
        self.imageURL = url

        loadPDFPage(at: 0)
    }

    private func loadPDFPage(at pageIndex: Int) {
        guard let pdfDoc = pdfDocument,
              pageIndex >= 0,
              pageIndex < pdfDoc.pageCount,
              let pdfPage = pdfDoc.page(at: pageIndex) else { return }

        let pageImage = pdfPageToImage(pdfPage, zoomLevel: 1.0)

        ocrTask?.cancel()
        self.image = pageImage
        self.currentPageIndex = pageIndex
        self.ocrBoxes = []
        self.pageStructure = nil

        // Check for native text layer (born-digital PDF) before running OCR
        if var pdfBoxes = extractBoxesFromPDFPage(pdfPage) {
            // Scale from PDF points to the coordinate space the overlay expects.
            // The overlay divides by image.scale (Retina factor), so pre-multiply to cancel.
            let retinaScale = pageImage.scale
            if retinaScale != 1.0 {
                for i in pdfBoxes.indices {
                    let f = pdfBoxes[i].frame
                    pdfBoxes[i].frame = CGRect(x: f.minX * retinaScale, y: f.minY * retinaScale,
                                                width: f.width * retinaScale, height: f.height * retinaScale)
                }
            }
            self.ocrBoxes = pdfBoxes
            self.pageStructure = analyzePageStructure(boxes: pdfBoxes)
            self.ocrText = pdfPage.string ?? ""
            isLoading = false
            print("✅ Used native PDF text (\(pdfBoxes.count) boxes), skipped OCR")
            return
        }

        isLoading = true
        ocrTask = Task {
            do {
                try Task.checkCancellation()

                let ocrZoom = ocrMinZoom
                let ocrImage: UIImage
                if let pdfPage = self.pdfDocument?.page(at: pageIndex) {
                    ocrImage = self.pdfPageToImage(pdfPage, zoomLevel: ocrZoom)
                } else {
                    ocrImage = pageImage
                }
                let tempURL = createTempImageFile(from: ocrImage)

                try Task.checkCancellation()
                let (text, tsv, preprocessScale) = try await runTesseractOCR(imageURL: tempURL)

                try Task.checkCancellation()
                if self.currentPageIndex == pageIndex && !Task.isCancelled {
                    self.ocrText = text
                    var boxes = parseTesseractTSV(tsv, imageSize: ocrImage.size)
                    // Combine PDF zoom scale with preprocessing scale
                    let coordScale = 1.0 / (ocrZoom * CGFloat(preprocessScale))
                    if coordScale != 1.0 {
                        for i in boxes.indices {
                            let f = boxes[i].frame
                            boxes[i].frame = CGRect(x: f.minX * coordScale, y: f.minY * coordScale,
                                                    width: f.width * coordScale, height: f.height * coordScale)
                        }
                    }
                    boxes = await LanguageModelPostProcessor.process(boxes: boxes)
                    self.ocrBoxes = boxes
                    self.pageStructure = analyzePageStructure(boxes: self.ocrBoxes)
                    print("Loaded \(self.ocrBoxes.count) boxes from PDF page")
                }

                try? FileManager.default.removeItem(at: tempURL)
            } catch is CancellationError {
                print("OCR task cancelled for page \(pageIndex + 1)")
            } catch {
                if self.currentPageIndex == pageIndex && !Task.isCancelled {
                    self.ocrText = String(localized: "שגיאה בהרצת OCR: \(error.localizedDescription)")
                    self.ocrBoxes = []
                    self.pageStructure = nil
                }
            }
            if !Task.isCancelled {
                isLoading = false
            }
        }
    }

    private func pdfPageToImage(_ pdfPage: PDFPage, zoomLevel: CGFloat = 1.0) -> UIImage {
        let pageRect = pdfPage.bounds(for: .mediaBox)
        let clampedZoom = min(zoomLevel, 3.0)
        let scaledSize = CGSize(
            width: pageRect.size.width * clampedZoom,
            height: pageRect.size.height * clampedZoom
        )

        let renderer = UIGraphicsImageRenderer(size: scaledSize)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: scaledSize))

            // UIGraphicsImageRenderer uses UIKit coordinates (Y-down from top-left).
            // PDFPage.draw expects standard CG coordinates (Y-up from bottom-left).
            // Flip the context to match what PDF rendering expects.
            ctx.cgContext.translateBy(x: 0, y: scaledSize.height)
            ctx.cgContext.scaleBy(x: clampedZoom, y: -clampedZoom)
            // Compensate for non-zero mediaBox origin (some PDFs offset content)
            ctx.cgContext.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
            pdfPage.draw(with: .mediaBox, to: ctx.cgContext)
        }
    }

    private func nextPage() {
        guard totalPages > 1, currentPageIndex < totalPages - 1 else { return }
        loadPDFPage(at: currentPageIndex + 1)
    }

    private func previousPage() {
        guard totalPages > 1, currentPageIndex > 0 else { return }
        loadPDFPage(at: currentPageIndex - 1)
    }

    // MARK: - Image Helpers

    private func createTempImageFile(from image: UIImage) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        // Redraw to apply camera orientation so Leptonica reads correctly-oriented pixels
        let normalized: UIImage
        if image.imageOrientation == .up {
            normalized = image
        } else {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0  // native pixels, not 3x screen scale
            let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
            normalized = renderer.image { _ in image.draw(at: .zero) }
        }
        if let pngData = normalized.pngData() {
            try? pngData.write(to: tempURL)
        }
        return tempURL
    }

    // MARK: - Export

    private func exportToDocument(format: String) {
        isExporting = true
        exportProgress = 0

        Task {
            do {
                let title = exportTitle()
                let tempDir = FileManager.default.temporaryDirectory
                let exportURL: URL

                let pages = try await generateDocumentPages()

                if format == "pdf" {
                    let html = HTMLExporter.export(pages: pages, title: title)
                    exportURL = tempDir.appendingPathComponent("\(title).pdf")
                    try renderHTMLToPDF(html, to: exportURL)
                } else if format == "html" {
                    let html = HTMLExporter.export(pages: pages, title: title)
                    exportURL = tempDir.appendingPathComponent("\(title).html")
                    try html.write(to: exportURL, atomically: true, encoding: .utf8)
                } else {
                    let docxData = try DOCXExporter.export(pages: pages, title: title)
                    exportURL = tempDir.appendingPathComponent("\(title).docx")
                    try docxData.write(to: exportURL)
                }

                await MainActor.run {
                    self.exportedFileURL = exportURL
                    self.showExportSheet = true
                }
            } catch {
                print("Export failed: \(error.localizedDescription)")
            }

            await MainActor.run {
                isExporting = false
                exportProgress = 0
            }
        }
    }

    /// Renders HTML to a paginated PDF using NSAttributedString + Core Text.
    @MainActor
    private func renderHTMLToPDF(_ html: String, to url: URL) throws {
        guard let htmlData = html.data(using: .utf8),
              let attrString = try? NSAttributedString(
                  data: htmlData,
                  options: [.documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil) else {
            throw NSError(domain: "Export", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to parse HTML for PDF"])
        }

        // A4 page at 72 DPI
        let pageWidth: CGFloat = 595
        let pageHeight: CGFloat = 842
        let margin: CGFloat = 50
        let contentRect = CGRect(x: margin, y: margin,
                                  width: pageWidth - margin * 2,
                                  height: pageHeight - margin * 2)

        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        let data = renderer.pdfData { context in
            let framesetter = CTFramesetterCreateWithAttributedString(attrString as CFAttributedString)
            var currentIndex = 0
            let totalLength = attrString.length

            while currentIndex < totalLength {
                context.beginPage()

                let path = CGPath(rect: contentRect, transform: nil)
                let frame = CTFramesetterCreateFrame(
                    framesetter, CFRange(location: currentIndex, length: 0), path, nil)

                // Core Text uses bottom-left origin; flip for UIKit's top-left origin
                let cgContext = context.cgContext
                cgContext.saveGState()
                cgContext.translateBy(x: 0, y: pageHeight)
                cgContext.scaleBy(x: 1.0, y: -1.0)
                CTFrameDraw(frame, cgContext)
                cgContext.restoreGState()

                let visibleRange = CTFrameGetVisibleStringRange(frame)
                if visibleRange.length == 0 { break }
                currentIndex += visibleRange.length
            }
        }

        try data.write(to: url)
    }

    private func generateDocumentPages() async throws -> [(mainText: String, marginText: String, structure: PageStructure?)] {
        var pages: [(mainText: String, marginText: String, structure: PageStructure?)] = []

        if let pdfDoc = pdfDocument {
            let pageCount = pdfDoc.pageCount

            for pageIndex in 0..<pageCount {
                exportProgress = Double(pageIndex) / Double(pageCount) * 0.9

                guard let pdfPage = pdfDoc.page(at: pageIndex) else { continue }

                // Try native text first (born-digital PDF)
                if let nativeBoxes = extractBoxesFromPDFPage(pdfPage) {
                    let structure = analyzePageStructure(boxes: nativeBoxes)
                    let (main, margin) = extractTextFromBoxes(nativeBoxes, structure: structure)
                    pages.append((main, margin, structure))
                    print("📄 Export page \(pageIndex + 1): native text (\(nativeBoxes.count) boxes)")
                    continue
                }

                let ocrImage = pdfPageToImage(pdfPage, zoomLevel: ocrMinZoom)
                let tempURL = createTempImageFile(from: ocrImage)

                let (_, tsv, _) = try await runTesseractOCR(imageURL: tempURL)
                var boxes = parseTesseractTSV(tsv, imageSize: ocrImage.size)
                boxes = await LanguageModelPostProcessor.process(boxes: boxes)
                let structure = analyzePageStructure(boxes: boxes)
                let (main, margin) = extractTextFromBoxes(boxes, structure: structure)
                pages.append((main, margin, structure))

                try? FileManager.default.removeItem(at: tempURL)
            }
        } else if let currentImage = image {
            exportProgress = 0.5

            let tempURL = createTempImageFile(from: currentImage)
            let (_, tsv, _) = try await runTesseractOCR(imageURL: tempURL)
            var boxes = parseTesseractTSV(tsv, imageSize: currentImage.size)
            boxes = await LanguageModelPostProcessor.process(boxes: boxes)
            let structure = analyzePageStructure(boxes: boxes)
            let (main, margin) = extractTextFromBoxes(boxes, structure: structure)
            pages.append((main, margin, structure))

            try? FileManager.default.removeItem(at: tempURL)
        }

        exportProgress = 1.0
        return pages
    }

    private func exportTitle() -> String {
        let words = ocrText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .prefix(3)
        if words.isEmpty {
            return "Document"
        }
        let joined = words.joined(separator: " ")
        let sanitized = joined.replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "", options: .regularExpression)
        return sanitized.isEmpty ? "Document" : sanitized
    }

    // MARK: - Text Extraction (shared logic)

    private func extractTextFromBoxes(_ boxes: [OCRBox], structure: PageStructure? = nil) -> (main: String, margin: String) {
        let mainBoxes = boxes.filter { !$0.isMargin }
        let marginBoxes = boxes.filter { $0.isMargin && isSignificantText($0.text) }

        let mainText: String
        if let structure = structure {
            mainText = buildStructuredText(boxes: mainBoxes, structure: structure)
        } else {
            mainText = buildTextFromBoxes(mainBoxes)
        }
        let marginText = buildTextFromBoxes(marginBoxes)

        return (mainText, marginText)
    }

    private func isSignificantText(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = cleaned.unicodeScalars.filter { scalar in
            let isHebrew = scalar.value >= 0x0590 && scalar.value <= 0x05FF
            let isLatin = (scalar.value >= 0x0041 && scalar.value <= 0x005A) ||
                          (scalar.value >= 0x0061 && scalar.value <= 0x007A)
            return isHebrew || isLatin
        }
        return letters.count >= 2
    }

    private func buildTextFromBoxes(_ boxes: [OCRBox]) -> String {
        guard !boxes.isEmpty else { return "" }

        var lineGroups: [Int: [OCRBox]] = [:]
        for box in boxes {
            lineGroups[box.lineId, default: []].append(box)
        }

        let sortedLineIds = lineGroups.keys.sorted { id1, id2 in
            let avgY1 = lineGroups[id1]!.map { $0.frame.midY }.reduce(0, +) / CGFloat(lineGroups[id1]!.count)
            let avgY2 = lineGroups[id2]!.map { $0.frame.midY }.reduce(0, +) / CGFloat(lineGroups[id2]!.count)
            return avgY1 < avgY2
        }

        func paragraphId(from lineId: Int) -> Int {
            let blockNum = lineId / 1000000
            let parNum = (lineId % 1000000) / 1000
            return blockNum * 1000 + parNum
        }

        var paragraphs: [Int: [Int]] = [:]
        for lineId in sortedLineIds {
            let parId = paragraphId(from: lineId)
            paragraphs[parId, default: []].append(lineId)
        }

        let sortedParIds = paragraphs.keys.sorted { parId1, parId2 in
            guard let firstLineId1 = paragraphs[parId1]?.first,
                  let firstLineId2 = paragraphs[parId2]?.first else { return false }
            let avgY1 = lineGroups[firstLineId1]!.map { $0.frame.midY }.reduce(0, +) / CGFloat(lineGroups[firstLineId1]!.count)
            let avgY2 = lineGroups[firstLineId2]!.map { $0.frame.midY }.reduce(0, +) / CGFloat(lineGroups[firstLineId2]!.count)
            return avgY1 < avgY2
        }

        var paragraphTexts: [String] = []
        for parId in sortedParIds {
            guard let lineIds = paragraphs[parId] else { continue }
            var allWords: [String] = []
            for lineId in lineIds {
                let wordsInLine = lineGroups[lineId]!.sorted { $0.wordNum < $1.wordNum }
                allWords.append(contentsOf: wordsInLine.map { $0.text })
            }
            let paragraphText = allWords.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !paragraphText.isEmpty {
                paragraphTexts.append(paragraphText)
            }
        }

        return collapseConsecutivePlaceholders(paragraphTexts.joined(separator: "\n\n"))
    }

    private func buildStructuredText(boxes: [OCRBox], structure: PageStructure) -> String {
        var lineGroups: [Int: [OCRBox]] = [:]
        for box in boxes {
            lineGroups[box.lineId, default: []].append(box)
        }

        var parts: [String] = []
        for paragraph in structure.paragraphs {
            var allWords: [String] = []
            for lineId in paragraph.lineIds {
                guard let lineBoxes = lineGroups[lineId] else { continue }
                let sorted = lineBoxes.sorted { $0.wordNum < $1.wordNum }
                allWords.append(contentsOf: sorted.map { $0.text })
            }
            let text = allWords.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            parts.append(text)
        }

        return collapseConsecutivePlaceholders(parts.joined(separator: "\n\n"))
    }
}

// MARK: - Export Format Sheet

struct ExportFormatSheet: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect("pdf")
                } label: {
                    Label("PDF", systemImage: "doc.richtext")
                }
                Button {
                    onSelect("docx")
                } label: {
                    Label("DOCX", systemImage: "doc.text")
                }
                Button {
                    onSelect("html")
                } label: {
                    Label("HTML", systemImage: "globe")
                }
            }
            .navigationTitle("שיתוף בפורמט")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ביטול") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Camera View (UIImagePickerController wrapper)

struct CameraView: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void

        init(onCapture: @escaping (UIImage?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            picker.dismiss(animated: true) { [self] in
                onCapture(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) { [self] in
                onCapture(nil)
            }
        }
    }
}

// MARK: - About Sheet

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private static let acknowledgements: [(name: String, copyright: String, license: String, url: String?)] = [
        ("Tesseract OCR", "© 2006–2024 Google LLC", "Apache License 2.0", "https://github.com/tesseract-ocr/tesseract"),
        ("DictaBERT", "© 2023 DICTA: The Israel Center for Text Analysis", "CC BY 4.0", "https://huggingface.co/dicta-il/dictabert"),
        ("Leptonica", "© 2001–2024 Dan Bloomberg", "BSD 2-Clause License", "http://leptonica.org"),
        ("libpng", "© 1995–2024 PNG Reference Library Authors", "libpng License", nil),
        ("libjpeg", "© 1991–2024 Thomas G. Lane, Guido Vollbeding", "IJG License", nil),
        ("libtiff", "© 1988–2024 Sam Leffler, Silicon Graphics, Inc.", "BSD-like License", nil),
        ("libgif", "© 1997 Eric S. Raymond", "MIT License", nil),
        ("libwebp", "© 2010–2024 Google LLC", "BSD 3-Clause License", nil),
        ("OpenJPEG", "© 2002–2024 UCL", "BSD 2-Clause License", nil),
        ("libarchive", "© 2003–2024 Tim Kientzle", "BSD License", nil),
        ("Zstandard", "© 2016–2024 Facebook, Inc.", "BSD License", nil),
        ("LZ4", "© 2011–2024 Yann Collet", "BSD 2-Clause License", nil),
        ("XZ Utils (liblzma)", "", "Public Domain / BSD Zero Clause", nil),
        ("ZIPFoundation", "© 2017–2024 Thomas Rasche", "MIT License", "https://github.com/weichsel/ZIPFoundation"),
        ("BLAKE2 (libb2)", "© 2012–2024 Samuel Neves", "CC0 1.0 / Apache 2.0", nil),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image("AboutIcon")
                        .resizable()
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 26))
                        .shadow(radius: 4, y: 2)

                    Text("עין")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("סורק טקסט עברי")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("גרסה \(appVersion) (\(buildNumber))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Link(destination: URL(string: "https://aviahmorag.com")!) {
                        Text("aviahmorag.com")
                            .font(.footnote)
                    }

                    Divider()
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("קוד פתוח")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .center)

                        ForEach(Self.acknowledgements, id: \.name) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                if let urlString = item.url, let url = URL(string: urlString) {
                                    Link(item.name, destination: url)
                                        .font(.subheadline.bold())
                                } else {
                                    Text(item.name)
                                        .font(.subheadline.bold())
                                }
                                if !item.copyright.isEmpty {
                                    Text(item.copyright)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(item.license)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal)

                    Text("© 2026 אביה מורג. כל הזכויות שמורות.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 16)
                }
                .padding(.top, 24)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("סגור") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Debug Preprocess Sheet

#if DEBUG
struct DebugPreprocessSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedStep = "debug_4_median"

    private let steps = [
        ("debug_1_gray", "1. Gray"),
        ("debug_2_scaled", "2. Scale"),
        ("debug_3_bgclean", "3. BG Clean"),
        ("debug_4_median", "4. Median"),
    ]

    private func loadImage(_ name: String) -> UIImage? {
        let path = NSTemporaryDirectory() + name + ".png"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Step", selection: $selectedStep) {
                    ForEach(steps, id: \.0) { step in
                        Text(step.1).tag(step.0)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                if let img = loadImage(selectedStep) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(4)
                    Text("\(Int(img.size.width))×\(Int(img.size.height))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                } else {
                    Spacer()
                    Text("No image for this step")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .navigationTitle("Preprocessing Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
#endif

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
