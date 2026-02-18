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
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(action: previousPage) {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(currentPageIndex <= 0)

                        Text("עמוד \(currentPageIndex + 1) מתוך \(totalPages)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button(action: nextPage) {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(currentPageIndex >= totalPages - 1)
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
                let (text, tsv) = try await runTesseractOCR(imageURL: tempURL)

                try Task.checkCancellation()
                if !Task.isCancelled {
                    self.ocrText = text
                    var boxes = parseTesseractTSV(tsv, imageSize: uiImage.size)
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
                let (text, tsv) = try await runTesseractOCR(imageURL: tempURL)

                try Task.checkCancellation()
                if self.currentPageIndex == pageIndex && !Task.isCancelled {
                    self.ocrText = text
                    var boxes = parseTesseractTSV(tsv, imageSize: ocrImage.size)
                    let coordScale = 1.0 / ocrZoom
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
        if let pngData = image.pngData() {
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
                let title = imageURL?.deletingPathExtension().lastPathComponent ?? "מסמך"
                let tempDir = FileManager.default.temporaryDirectory
                let exportURL: URL

                if format == "pdf" {
                    exportURL = tempDir.appendingPathComponent("\(title).pdf")
                    try exportToPDF(url: exportURL)
                    exportProgress = 1.0
                } else {
                    let pages = try await generateDocumentPages()

                    if format == "html" {
                        let html = HTMLExporter.export(pages: pages, title: title)
                        exportURL = tempDir.appendingPathComponent("\(title).html")
                        try html.write(to: exportURL, atomically: true, encoding: .utf8)
                    } else {
                        let docxData = try DOCXExporter.export(pages: pages, title: title)
                        exportURL = tempDir.appendingPathComponent("\(title).docx")
                        try docxData.write(to: exportURL)
                    }
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

    private func exportToPDF(url: URL) throws {
        // If the source is already a PDF, copy it directly
        if let pdfDoc = pdfDocument, let data = pdfDoc.dataRepresentation() {
            try data.write(to: url)
            return
        }

        // For images, render as a single-page PDF
        guard let currentImage = image else {
            throw NSError(domain: "Export", code: 1, userInfo: [NSLocalizedDescriptionKey: "No image to export"])
        }

        let imageSize = currentImage.size
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: imageSize))
        let data = pdfRenderer.pdfData { context in
            context.beginPage()
            currentImage.draw(in: CGRect(origin: .zero, size: imageSize))
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
                let ocrImage = pdfPageToImage(pdfPage, zoomLevel: ocrMinZoom)
                let tempURL = createTempImageFile(from: ocrImage)

                let (_, tsv) = try await runTesseractOCR(imageURL: tempURL)
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
            let (_, tsv) = try await runTesseractOCR(imageURL: tempURL)
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

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
