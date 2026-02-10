//
//  ContentView.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

import SwiftUI
import UniformTypeIdentifiers
import PDFKit

/// Collapses consecutive `[...]` placeholders (separated by whitespace) into a single `[...]`.
func collapseConsecutivePlaceholders(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "\\[\\.\\.\\.\\](\\s+\\[\\.\\.\\.\\])+") else {
        return text
    }
    return regex.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text),
        withTemplate: "[...]"
    )
}

struct ContentView: View {
    @State private var image: NSImage?
    @State private var imageURL: URL?
    @State private var ocrText: String = ""
    @State private var isLoading = false
    @State private var ocrBoxes: [OCRBox] = []
    @State private var resizeTask: Task<Void, Never>?
    @State private var ocrTask: Task<Void, Never>?
    @State private var lastOCRCompletionTime: Date?
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var pageStructure: PageStructure?
    
    // PDF support
    @State private var pdfDocument: PDFDocument?
    @State private var currentPageIndex: Int = 0
    @State private var totalPages: Int = 0
    
    // Zoom support
    @State private var zoomLevel: CGFloat = 1.0
    @State private var lastMagnification: CGFloat = 1.0
    @State private var zoomAnchor: UnitPoint = .center
    private let minZoom: CGFloat = 0.1
    private let ocrMinZoom: CGFloat = 2.0  // Minimum zoom for OCR (~288 DPI on Retina)
    private let maxZoom: CGFloat = 5.0
    private let zoomStep: CGFloat = 0.25

    var body: some View {
        ZStack {
            if let image = image {
                let imageContent = SelectableOverlayImageView(
                    image: image,
                    boxes: ocrBoxes,
                    zoomLevel: zoomLevel,
                    pageStructure: pageStructure,
                    onPageNavigation: totalPages > 1 ? { isNext in
                        if isNext {
                            nextPage()
                        } else {
                            previousPage()
                        }
                    } : nil,
                    onZoomChange: { magnification, location in
                        let newZoom = zoomLevel * magnification
                        let clampedZoom = max(minZoom, min(maxZoom, newZoom))
                        updateZoom(to: clampedZoom)
                    }
                )
                .frame(
                    width: image.size.width * zoomLevel,
                    height: image.size.height * zoomLevel
                )
                .clipped()
                
                let scrollContent = GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        imageContent
                            .frame(
                                width: max(image.size.width * zoomLevel, geometry.size.width),
                                height: max(image.size.height * zoomLevel, geometry.size.height),
                                alignment: .center
                            )
                    }
                }
                .background(Color(NSColor.controlBackgroundColor))
                
                scrollContent
                    .onTapGesture(count: 2) {
                        resetZoom()
                    }
                    .focusable()
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "photo")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("בחר תמונה לסריקת טקסט עברי")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    
                    Button("בחר קובץ...") {
                        selectImageAndRunOCR()
                    }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(isLoading)
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers)
                }
            }
            
            // Floating controls
            VStack {
                // Top controls - only show when image is loaded
                if image != nil {
                    HStack {
                        Spacer()

                        // Export button
                        Button(action: exportToDocument) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title2)
                                .foregroundColor(.primary)
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading || isExporting)
                        .help("ייצא למסמך")

                        Button(action: selectImageAndRunOCR) {
                            Image(systemName: "folder")
                                .font(.title2)
                                .foregroundColor(.primary)
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading || isExporting)
                    }
                    .padding()
                }
                
                // Hidden zoom shortcut buttons
                Button("", action: zoomIn)
                    .keyboardShortcut("+", modifiers: .command)
                    .hidden()
                Button("", action: zoomIn)
                    .keyboardShortcut("=", modifiers: .command)
                    .hidden()
                Button("", action: zoomOut)
                    .keyboardShortcut("-", modifiers: .command)
                    .hidden()
                Button("", action: resetZoom)
                    .keyboardShortcut("0", modifiers: .command)
                    .hidden()
                
                Spacer()
                
                // PDF page navigation controls (bottom)
                if totalPages > 1 {
                    HStack(spacing: 12) {
                        Button(action: previousPage) {
                            Image(systemName: "chevron.right")
                                .font(.title2)
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(currentPageIndex <= 0)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .keyboardShortcut(.upArrow, modifiers: [])
                        
                        Text("עמוד \(currentPageIndex + 1) מתוך \(totalPages)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                        
                        Button(action: nextPage) {
                            Image(systemName: "chevron.left")
                                .font(.title2)
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(currentPageIndex >= totalPages - 1)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .keyboardShortcut(.downArrow, modifiers: [])
                    }
                    .padding()
                }
            }
            
            // Centered loading spinner
            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .scaleEffect(1.2)
                    .frame(width: 60, height: 60)
                    .background(.regularMaterial, in: Circle())
            }

            // Export progress overlay
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
        .frame(minWidth: 400, minHeight: 300)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in
            guard imageURL != nil else { return }

            // Skip resize OCR if:
            // 1. An OCR is already in progress (prevents double-spinner)
            // 2. We just completed an OCR (prevents resize after initial load)
            if isLoading {
                return
            }
            if let lastTime = lastOCRCompletionTime,
               Date().timeIntervalSince(lastTime) < 2.0 {
                return
            }

            resizeTask?.cancel()
            resizeTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await rerunOCR()
            }
        }
    }
    
    private func rerunOCR() async {
        guard let image = image else { return }

        print("🔄 Window resized - rerunning OCR process")
        isLoading = true

        do {
            // For PDFs, create a temp image file; for images, use the original URL
            let ocrURL: URL
            var tempURL: URL? = nil
            var ocrImageSize = image.size
            var coordScale: CGFloat = 1.0

            if let pdfDoc = pdfDocument,
               let pdfPage = pdfDoc.page(at: currentPageIndex) {
                // PDF: render high-res image for OCR
                let ocrZoom = max(zoomLevel, ocrMinZoom)
                let ocrImage = pdfPageToImage(pdfPage, zoomLevel: ocrZoom)
                tempURL = createTempImageFile(from: ocrImage)
                ocrURL = tempURL!
                ocrImageSize = ocrImage.size
                coordScale = zoomLevel / ocrZoom
            } else if let imageURL = imageURL {
                // Regular image: use original URL
                ocrURL = imageURL
            } else {
                return
            }

            let (text, tsv) = try await runTesseractOCR(imageURL: ocrURL)
            self.ocrText = text
            var boxes = parseTesseractTSV(tsv, imageSize: ocrImageSize)
            // Scale box coordinates from OCR space to display space
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
            self.lastOCRCompletionTime = Date()
            print("✅ Reloaded \(self.ocrBoxes.count) boxes after resize")

            // Clean up temp file if created
            if let tempURL = tempURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
        } catch {
            self.ocrText = String(localized: "⚠️ שגיאה בהרצת OCR: \(error.localizedDescription)")
            self.ocrBoxes = []
            self.pageStructure = nil
        }
        isLoading = false
    }

    private func selectImageAndRunOCR() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = String(localized: "בחר תמונה לסריקה")

        if panel.runModal() == .OK, let url = panel.url {
            // Check if it's a PDF or image
            if url.pathExtension.lowercased() == "pdf" {
                loadPDF(from: url)
            } else if let nsImage = NSImage(contentsOf: url) {
                loadImage(nsImage, from: url)
            }
        }
    }
    
    private func loadPDF(from url: URL) {
        guard let pdfDoc = PDFDocument(url: url) else {
            print("❌ Failed to load PDF")
            return
        }
        
        // Reset zoom
        self.zoomLevel = 1.0
        self.lastMagnification = 1.0
        
        self.pdfDocument = pdfDoc
        self.totalPages = pdfDoc.pageCount
        self.currentPageIndex = 0
        self.imageURL = url
        
        print("📄 Loaded PDF with \(totalPages) pages")
        
        // Load first page
        loadPDFPage(at: 0)
    }
    
    private func loadImage(_ nsImage: NSImage, from url: URL) {
        // Reset PDF state
        self.pdfDocument = nil
        self.totalPages = 0
        self.currentPageIndex = 0
        
        // Reset zoom
        self.zoomLevel = 1.0
        self.lastMagnification = 1.0
        
        self.image = nsImage
        self.imageURL = url
        self.ocrBoxes = []
        self.pageStructure = nil
        isLoading = true
        
        // Resize window to match image aspect ratio
        resizeWindowToFitImage(nsImage)

        // Cancel any existing OCR task
        ocrTask?.cancel()
        
        ocrTask = Task {
            do {
                try Task.checkCancellation()
                
                let (text, tsv) = try await runTesseractOCR(imageURL: url)
                
                try Task.checkCancellation()
                
                if !Task.isCancelled {
                    self.ocrText = text
                    var boxes = parseTesseractTSV(tsv, imageSize: nsImage.size)
                    boxes = await LanguageModelPostProcessor.process(boxes: boxes)
                    self.ocrBoxes = boxes
                    self.pageStructure = analyzePageStructure(boxes: self.ocrBoxes)
                    self.lastOCRCompletionTime = Date()
                    print("✅ Loaded \(self.ocrBoxes.count) boxes")
                }
            } catch is CancellationError {
                print("🚫 OCR task cancelled for image")
            } catch {
                if !Task.isCancelled {
                    self.ocrText = String(localized: "⚠️ שגיאה בהרצת OCR: \(error.localizedDescription)")
                    self.ocrBoxes = []
                    self.pageStructure = nil
                }
            }

            if !Task.isCancelled {
                isLoading = false
            }
        }
    }

    private func loadPDFPage(at pageIndex: Int) {
        guard let pdfDoc = pdfDocument,
              pageIndex >= 0,
              pageIndex < pdfDoc.pageCount,
              let pdfPage = pdfDoc.page(at: pageIndex) else {
            print("❌ Invalid PDF page index: \(pageIndex)")
            return
        }
        
        // Convert PDF page to NSImage at current zoom level
        let pageImage = pdfPageToImage(pdfPage, zoomLevel: zoomLevel)
        
        // Cancel any existing OCR task
        ocrTask?.cancel()
        
        // Update UI immediately (non-blocking)
        self.image = pageImage
        self.currentPageIndex = pageIndex
        self.ocrBoxes = [] // Clear old OCR boxes immediately
        self.pageStructure = nil
        
        // Keep window size stable when navigating pages
        // resizeWindowToFitImage(pageImage)
        
        print("📄 Loading PDF page \(pageIndex + 1) of \(totalPages)")
        
        // Run OCR in background without blocking navigation
        isLoading = true
        ocrTask = Task {
            do {
                // Check if cancelled before starting
                try Task.checkCancellation()
                
                // Render high-res image for OCR (min 2.0x for ~288 DPI on Retina)
                let ocrZoom = max(self.zoomLevel, self.ocrMinZoom)
                let ocrImage: NSImage
                if ocrZoom == self.zoomLevel {
                    ocrImage = pageImage
                } else if let pdfPage = self.pdfDocument?.page(at: pageIndex) {
                    ocrImage = self.pdfPageToImage(pdfPage, zoomLevel: ocrZoom)
                } else {
                    ocrImage = pageImage
                }
                let tempURL = createTempImageFile(from: ocrImage)

                // Check if cancelled before OCR
                try Task.checkCancellation()

                let (text, tsv) = try await runTesseractOCR(imageURL: tempURL)

                // Check if cancelled before updating UI
                try Task.checkCancellation()

                // Only update if we're still on the same page and task wasn't cancelled
                if self.currentPageIndex == pageIndex && !Task.isCancelled {
                    self.ocrText = text
                    var boxes = parseTesseractTSV(tsv, imageSize: ocrImage.size)
                    // Scale box coordinates from OCR space to display space
                    let coordScale = self.zoomLevel / ocrZoom
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
                    self.lastOCRCompletionTime = Date()
                    print("✅ Loaded \(self.ocrBoxes.count) boxes from PDF page")
                }
                
                // Clean up temp file
                try? FileManager.default.removeItem(at: tempURL)
            } catch is CancellationError {
                print("🚫 OCR task cancelled for page \(pageIndex + 1)")
            } catch {
                if self.currentPageIndex == pageIndex && !Task.isCancelled {
                    self.ocrText = String(localized: "⚠️ שגיאה בהרצת OCR: \(error.localizedDescription)")
                    self.ocrBoxes = []
                    self.pageStructure = nil
                }
            }

            if !Task.isCancelled {
                isLoading = false
            }
        }
    }

    private func pdfPageToImage(_ pdfPage: PDFPage, zoomLevel: CGFloat = 1.0) -> NSImage {
        let pageRect = pdfPage.bounds(for: .mediaBox)
        
        // Clamp zoom level for performance - very high zoom uses too much memory
        let clampedZoom = min(zoomLevel, 3.0)
        
        let scaledSize = CGSize(
            width: pageRect.size.width * clampedZoom,
            height: pageRect.size.height * clampedZoom
        )
        let image = NSImage(size: scaledSize)
        
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            // Scale the context to render at the desired zoom level
            context.scaleBy(x: clampedZoom, y: clampedZoom)
            context.setFillColor(NSColor.white.cgColor)
            
            // Fill the scaled rect, not the original pageRect
            let scaledRect = CGRect(
                x: 0, y: 0, 
                width: pageRect.size.width, 
                height: pageRect.size.height
            )
            context.fill(scaledRect)
            pdfPage.draw(with: .mediaBox, to: context)
        }
        image.unlockFocus()
        
        print("🖼️ Generated PDF page image at \(Int(clampedZoom * 100))% zoom (\(Int(scaledSize.width))x\(Int(scaledSize.height)))")
        return image
    }
    
    private func createTempImageFile(from image: NSImage) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        
        if let tiffData = image.tiffRepresentation,
           let bitmapRep = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: tempURL)
        }
        
        return tempURL
    }
    
    private func nextPage() {
        guard totalPages > 1, currentPageIndex < totalPages - 1 else { return }
        loadPDFPage(at: currentPageIndex + 1)
    }
    
    private func previousPage() {
        guard totalPages > 1, currentPageIndex > 0 else { return }
        loadPDFPage(at: currentPageIndex - 1)
    }
    
    private func zoomIn() {
        let newZoom = min(zoomLevel + zoomStep, maxZoom)
        updateZoom(to: newZoom)
    }
    
    private func zoomOut() {
        let newZoom = max(zoomLevel - zoomStep, minZoom)
        updateZoom(to: newZoom)
    }
    
    private func resetZoom() {
        updateZoom(to: 1.0)
    }
    
    private func updateZoom(to newZoom: CGFloat) {
        zoomLevel = newZoom
        
        // If we're viewing a PDF, regenerate the page at the new zoom level
        if let pdfDoc = pdfDocument,
           currentPageIndex >= 0,
           currentPageIndex < pdfDoc.pageCount,
           let pdfPage = pdfDoc.page(at: currentPageIndex) {
            
            let pageImage = pdfPageToImage(pdfPage, zoomLevel: zoomLevel)
            self.image = pageImage
        }
    }
    
    
    private func handlePageNavigation(_ isNext: Bool) {
        if isNext {
            nextPage()
        } else {
            previousPage()
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                
                DispatchQueue.main.async {
                    // Check if it's a supported file type
                    let supportedExtensions = ["png", "jpg", "jpeg", "tiff", "bmp", "gif", "pdf"]
                    let fileExtension = url.pathExtension.lowercased()
                    
                    if supportedExtensions.contains(fileExtension) {
                        if fileExtension == "pdf" {
                            self.loadPDF(from: url)
                        } else if let nsImage = NSImage(contentsOf: url) {
                            self.loadImage(nsImage, from: url)
                        }
                    }
                }
            }
            return true
        }
        return false
    }
    
    private func resizeWindowToFitImage(_ image: NSImage) {
        guard let window = NSApplication.shared.windows.first else { return }
        
        let imageSize = image.size
        let screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        
        // Account for window chrome (title bar, etc.) - typically about 28 points for title bar
        let titleBarHeight: CGFloat = 28
        let windowBorderPadding: CGFloat = 20 // Extra padding for floating button and margins
        
        // Calculate maximum content size (85% of screen minus chrome)
        let maxContentWidth = screenSize.width * 0.85 - windowBorderPadding
        let maxContentHeight = screenSize.height * 0.85 - titleBarHeight - windowBorderPadding
        
        // Calculate content size maintaining aspect ratio
        let imageAspect = imageSize.width / imageSize.height
        var contentWidth: CGFloat
        var contentHeight: CGFloat
        
        if imageSize.width > maxContentWidth || imageSize.height > maxContentHeight {
            // Scale down to fit screen
            if imageAspect > maxContentWidth / maxContentHeight {
                // Image is wider - fit to width
                contentWidth = maxContentWidth
                contentHeight = maxContentWidth / imageAspect
            } else {
                // Image is taller - fit to height
                contentHeight = maxContentHeight
                contentWidth = maxContentHeight * imageAspect
            }
        } else {
            // Use actual image size but add some breathing room
            contentWidth = imageSize.width + 40 // Extra space for UI
            contentHeight = imageSize.height + 40
        }
        
        // Calculate final window size including chrome
        let windowWidth = max(contentWidth + windowBorderPadding, 500) // Minimum 500px wide
        let windowHeight = max(contentHeight + titleBarHeight + windowBorderPadding, 400) // Minimum 400px tall
        
        // Center the window on screen
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let newX = screenFrame.midX - windowWidth / 2
        let newY = screenFrame.midY - windowHeight / 2
        
        let newFrame = NSRect(x: newX, y: newY, width: windowWidth, height: windowHeight)
        
        // Animate the resize
        window.setFrame(newFrame, display: true, animate: true)
    }

    private func exportToDocument() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "docx")!]
        savePanel.nameFieldStringValue = (imageURL?.deletingPathExtension().lastPathComponent ?? "document") + ".docx"
        savePanel.title = String(localized: "ייצא למסמך")

        guard savePanel.runModal() == .OK, let saveURL = savePanel.url else {
            return
        }

        isExporting = true
        exportProgress = 0

        Task {
            do {
                let pages = try await generateDocumentPages()
                let title = imageURL?.deletingPathExtension().lastPathComponent ?? String(localized: "מסמך")
                let docxData = try DOCXExporter.export(pages: pages, title: title)
                try docxData.write(to: saveURL)
                print("✅ Exported DOCX to \(saveURL.path)")

                NSWorkspace.shared.open(saveURL)
            } catch {
                print("❌ Export failed: \(error.localizedDescription)")
            }

            await MainActor.run {
                isExporting = false
                exportProgress = 0
            }
        }
    }

    private func generateDocumentPages() async throws -> [(mainText: String, marginText: String, structure: PageStructure?)] {
        var pages: [(mainText: String, marginText: String, structure: PageStructure?)] = []

        if let pdfDoc = pdfDocument {
            let pageCount = pdfDoc.pageCount

            // Phase 1: Pre-render all page images at 2.0x and create temp files (serial, main actor)
            var pageInputs: [(index: Int, tempURL: URL, imageSize: CGSize)] = []
            for pageIndex in 0..<pageCount {
                exportProgress = Double(pageIndex) / Double(pageCount) * 0.1  // 0-10% for pre-render
                guard let pdfPage = pdfDoc.page(at: pageIndex) else { continue }
                let pageImage = pdfPageToImage(pdfPage, zoomLevel: ocrMinZoom)
                let tempURL = createTempImageFile(from: pageImage)
                pageInputs.append((pageIndex, tempURL, pageImage.size))
            }
            exportProgress = 0.1

            // Phase 2: OCR + LM processing (concurrent, up to 4 pages at a time)
            struct PageOCRResult: Sendable {
                let index: Int
                let boxes: [OCRBox]
                let structure: PageStructure?
            }
            var ocrResults = [(boxes: [OCRBox], structure: PageStructure?)](
                repeating: ([], nil), count: pageCount
            )
            let maxConcurrent = 4
            var completedCount = 0

            await withTaskGroup(of: PageOCRResult.self) { group in
                var nextIndex = 0

                // Launch initial batch
                for _ in 0..<min(maxConcurrent, pageInputs.count) {
                    let input = pageInputs[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        do {
                            let (_, tsv) = try await runTesseractOCR(imageURL: input.tempURL)
                            var boxes = parseTesseractTSV(tsv, imageSize: input.imageSize)
                            boxes = await LanguageModelPostProcessor.process(boxes: boxes)
                            let structure = analyzePageStructure(boxes: boxes)
                            return PageOCRResult(index: input.index, boxes: boxes, structure: structure)
                        } catch {
                            print("⚠️ OCR failed for page \(input.index + 1): \(error)")
                            return PageOCRResult(index: input.index, boxes: [], structure: nil)
                        }
                    }
                }

                // Process completions and launch next pages
                for await result in group {
                    ocrResults[result.index] = (result.boxes, result.structure)
                    completedCount += 1
                    exportProgress = 0.1 + Double(completedCount) / Double(pageCount) * 0.85  // 10-95%
                    print("📄 Exported page \(result.index + 1)/\(pageCount)")

                    if nextIndex < pageInputs.count {
                        let input = pageInputs[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            do {
                                let (_, tsv) = try await runTesseractOCR(imageURL: input.tempURL)
                                var boxes = parseTesseractTSV(tsv, imageSize: input.imageSize)
                                boxes = await LanguageModelPostProcessor.process(boxes: boxes)
                                let structure = analyzePageStructure(boxes: boxes)
                                return PageOCRResult(index: input.index, boxes: boxes, structure: structure)
                            } catch {
                                print("⚠️ OCR failed for page \(input.index + 1): \(error)")
                                return PageOCRResult(index: input.index, boxes: [], structure: nil)
                            }
                        }
                    }
                }
            }

            // Phase 3: Extract text (serial, fast)
            for result in ocrResults {
                let (main, margin) = extractTextFromBoxes(result.boxes, structure: result.structure)
                pages.append((main, margin, result.structure))
            }

            // Cleanup temp files
            for input in pageInputs {
                try? FileManager.default.removeItem(at: input.tempURL)
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

        return stripRepeatingParagraphs(pages)
    }

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

        // Group by lineId and sort words within each line by wordNum
        var lineGroups: [Int: [OCRBox]] = [:]
        for box in boxes {
            lineGroups[box.lineId, default: []].append(box)
        }

        // Sort lines by their average Y position (top to bottom)
        let sortedLineIds = lineGroups.keys.sorted { id1, id2 in
            let avgY1 = lineGroups[id1]!.map { $0.frame.midY }.reduce(0, +) / CGFloat(lineGroups[id1]!.count)
            let avgY2 = lineGroups[id2]!.map { $0.frame.midY }.reduce(0, +) / CGFloat(lineGroups[id2]!.count)
            return avgY1 < avgY2
        }

        // Extract paragraph ID from lineId: blockNum * 1000000 + parNum * 1000 + lineNum
        // Paragraph ID = blockNum * 1000 + parNum
        func paragraphId(from lineId: Int) -> Int {
            let blockNum = lineId / 1000000
            let parNum = (lineId % 1000000) / 1000
            return blockNum * 1000 + parNum
        }

        // Group lines into paragraphs
        var paragraphs: [Int: [Int]] = [:] // paragraphId -> [lineIds]
        for lineId in sortedLineIds {
            let parId = paragraphId(from: lineId)
            paragraphs[parId, default: []].append(lineId)
        }

        // Sort paragraphs by the Y position of their first line
        let sortedParIds = paragraphs.keys.sorted { parId1, parId2 in
            guard let firstLineId1 = paragraphs[parId1]?.first,
                  let firstLineId2 = paragraphs[parId2]?.first else { return false }
            let avgY1 = lineGroups[firstLineId1]!.map { $0.frame.midY }.reduce(0, +) / CGFloat(lineGroups[firstLineId1]!.count)
            let avgY2 = lineGroups[firstLineId2]!.map { $0.frame.midY }.reduce(0, +) / CGFloat(lineGroups[firstLineId2]!.count)
            return avgY1 < avgY2
        }

        // Build paragraphs as continuous text
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
        // Group boxes by lineId
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

            switch paragraph.role {
            case .header:
                parts.append("[כותרת עליונה] " + text)
            case .footer:
                parts.append("[כותרת תחתונה] " + text)
            case .sectionHeading, .body:
                parts.append(text)
            }
        }

        return collapseConsecutivePlaceholders(parts.joined(separator: "\n\n"))
    }

    /// Extracts only Hebrew characters from a paragraph to create a normalized signature.
    private func hebrewSignature(_ text: String) -> String {
        let hebrewWords = text.split(separator: " ").filter { word in
            word.unicodeScalars.contains { $0.value >= 0x0590 && $0.value <= 0x05FF }
        }
        return hebrewWords.joined(separator: " ")
    }

    /// Removes paragraphs that repeat on >50% of pages (watermarks, stamps).
    /// Requires ≥3 pages to have enough data for detection.
    private func stripRepeatingParagraphs(
        _ pages: [(mainText: String, marginText: String, structure: PageStructure?)]
    ) -> [(mainText: String, marginText: String, structure: PageStructure?)] {
        guard pages.count >= 3 else { return pages }

        // Split each page's main text into paragraphs and compute signatures
        let pageParas: [[String]] = pages.map {
            $0.mainText.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        let pageSigs: [[String]] = pageParas.map { paras in
            paras.map { hebrewSignature($0) }
        }

        // Count how many pages each signature appears on (deduplicated per page)
        var sigPageCount: [String: Int] = [:]
        for sigs in pageSigs {
            let uniqueSigs = Set(sigs)
            for sig in uniqueSigs {
                sigPageCount[sig, default: 0] += 1
            }
        }

        // Identify watermark signatures: >50% of pages AND ≥4 Hebrew characters
        let threshold = pages.count / 2
        let watermarkSigs = Set(sigPageCount.filter { sig, count in
            count > threshold && sig.unicodeScalars.filter({ $0.value >= 0x0590 && $0.value <= 0x05FF }).count >= 4
        }.keys)

        guard !watermarkSigs.isEmpty else { return pages }
        print("🔁 Detected \(watermarkSigs.count) repeating watermark paragraph(s)")

        // Strip matching paragraphs from all pages
        var result = pages
        for (pageIdx, sigs) in pageSigs.enumerated() {
            let parasToKeep = pageParas[pageIdx].enumerated().filter { idx, _ in
                !watermarkSigs.contains(sigs[idx])
            }

            let newMainText = parasToKeep.map { $0.element }.joined(separator: "\n\n")
            result[pageIdx] = (newMainText, result[pageIdx].marginText, result[pageIdx].structure)

            // Update PageStructure paragraph indices to match remaining paragraphs
            if let structure = result[pageIdx].structure {
                let keptIndices = Set(parasToKeep.map { $0.offset })
                let filteredParagraphs = structure.paragraphs.enumerated()
                    .filter { keptIndices.contains($0.offset) }
                    .map { $0.element }
                let newStructure = PageStructure(
                    paragraphs: filteredParagraphs,
                    headerLineIds: structure.headerLineIds,
                    footerLineIds: structure.footerLineIds
                )
                result[pageIdx] = (newMainText, result[pageIdx].marginText, newStructure)
            }
        }

        return result
    }

}

#Preview {
    ContentView()
}
