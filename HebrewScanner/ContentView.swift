//
//  ContentView.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

import SwiftUI
import UniformTypeIdentifiers
import PDFKit

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
                        Button(action: exportToHTML) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title2)
                                .foregroundColor(.primary)
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading || isExporting)
                        .help("ייצא ל-HTML")

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

            if pdfDocument != nil {
                // PDF: create temp PNG from current image
                tempURL = createTempImageFile(from: image)
                ocrURL = tempURL!
            } else if let imageURL = imageURL {
                // Regular image: use original URL
                ocrURL = imageURL
            } else {
                return
            }

            let (text, tsv) = try await runTesseractOCR(imageURL: ocrURL)
            self.ocrText = text
            var boxes = parseTesseractTSV(tsv, imageSize: image.size)
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
                
                // Create temporary image file for OCR
                let tempURL = createTempImageFile(from: pageImage)
                
                // Check if cancelled before OCR
                try Task.checkCancellation()
                
                let (text, tsv) = try await runTesseractOCR(imageURL: tempURL)
                
                // Check if cancelled before updating UI
                try Task.checkCancellation()
                
                // Only update if we're still on the same page and task wasn't cancelled
                if self.currentPageIndex == pageIndex && !Task.isCancelled {
                    self.ocrText = text
                    var boxes = parseTesseractTSV(tsv, imageSize: pageImage.size)
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

    private func exportToHTML() {
        // Show save panel first
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.html]
        savePanel.nameFieldStringValue = (imageURL?.deletingPathExtension().lastPathComponent ?? "document") + ".html"
        savePanel.title = String(localized: "ייצא ל-HTML")

        guard savePanel.runModal() == .OK, let saveURL = savePanel.url else {
            return
        }

        isExporting = true
        exportProgress = 0

        Task {
            do {
                let html = try await generateHTMLForDocument()
                try html.write(to: saveURL, atomically: true, encoding: .utf8)
                print("✅ Exported HTML to \(saveURL.path)")

                // Open the file in browser
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

    private func generateHTMLForDocument() async throws -> String {
        var pages: [(mainText: String, marginText: String, structure: PageStructure?)] = []

        if let pdfDoc = pdfDocument {
            // Process all PDF pages
            let pageCount = pdfDoc.pageCount
            for pageIndex in 0..<pageCount {
                await MainActor.run {
                    exportProgress = Double(pageIndex) / Double(pageCount)
                }

                guard let pdfPage = pdfDoc.page(at: pageIndex) else { continue }

                let pageImage = pdfPageToImage(pdfPage, zoomLevel: 1.0)
                let tempURL = createTempImageFile(from: pageImage)

                do {
                    let (_, tsv) = try await runTesseractOCR(imageURL: tempURL)
                    var boxes = parseTesseractTSV(tsv, imageSize: pageImage.size)
                    boxes = await LanguageModelPostProcessor.process(boxes: boxes)
                    let structure = analyzePageStructure(boxes: boxes)
                    let (main, margin) = extractTextFromBoxes(boxes, structure: structure)
                    pages.append((main, margin, structure))
                    print("📄 Exported page \(pageIndex + 1)/\(pageCount)")
                } catch {
                    print("⚠️ OCR failed for page \(pageIndex + 1): \(error)")
                    pages.append(("", "", nil))
                }

                try? FileManager.default.removeItem(at: tempURL)
            }
        } else if let currentImage = image {
            // Single image
            await MainActor.run {
                exportProgress = 0.5
            }

            let tempURL = createTempImageFile(from: currentImage)
            let (_, tsv) = try await runTesseractOCR(imageURL: tempURL)
            var boxes = parseTesseractTSV(tsv, imageSize: currentImage.size)
            boxes = await LanguageModelPostProcessor.process(boxes: boxes)
            let structure = analyzePageStructure(boxes: boxes)
            let (main, margin) = extractTextFromBoxes(boxes, structure: structure)
            pages.append((main, margin, structure))

            try? FileManager.default.removeItem(at: tempURL)
        }

        await MainActor.run {
            exportProgress = 1.0
        }

        return buildHTML(pages: pages)
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

        return paragraphTexts.joined(separator: "\n\n")
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

        return parts.joined(separator: "\n\n")
    }

    private func buildHTML(pages: [(mainText: String, marginText: String, structure: PageStructure?)]) -> String {
        let documentTitle = imageURL?.deletingPathExtension().lastPathComponent ?? String(localized: "מסמך")

        var html = """
        <!DOCTYPE html>
        <html lang="he" dir="rtl">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(escapeHTML(documentTitle))</title>
            <style>
                * {
                    box-sizing: border-box;
                }
                body {
                    font-family: "David", "Times New Roman", serif;
                    font-size: 16px;
                    line-height: 1.8;
                    margin: 0;
                    padding: 20px;
                    background: #f5f5f5;
                    direction: rtl;
                }
                .container {
                    max-width: 1000px;
                    margin: 0 auto;
                    background: white;
                    padding: 40px;
                    box-shadow: 0 2px 10px rgba(0,0,0,0.1);
                }
                h1 {
                    text-align: center;
                    border-bottom: 2px solid #333;
                    padding-bottom: 20px;
                    margin-bottom: 30px;
                }
                .page {
                    margin-bottom: 40px;
                    padding-bottom: 20px;
                    border-bottom: 1px dashed #ccc;
                }
                .page:last-child {
                    border-bottom: none;
                }
                .page-header {
                    font-size: 14px;
                    color: #666;
                    margin-bottom: 15px;
                }
                .content-table {
                    width: 100%;
                    border-collapse: collapse;
                }
                .main-column {
                    width: 75%;
                    vertical-align: top;
                    padding-left: 20px;
                }
                .margin-column {
                    width: 25%;
                    vertical-align: top;
                    padding-right: 20px;
                    border-right: 2px solid #ddd;
                    font-size: 14px;
                    color: #555;
                }
                .margin-text {
                    white-space: pre-wrap;
                    font-style: italic;
                }
                .margin-label {
                    font-weight: bold;
                    color: #888;
                    font-size: 12px;
                    margin-bottom: 8px;
                }
                .header-text {
                    text-align: center;
                    font-size: 14px;
                    color: #666;
                    padding-bottom: 8px;
                    margin-bottom: 12px;
                    border-bottom: 1px solid #ddd;
                }
                .footer-text {
                    text-align: center;
                    font-size: 14px;
                    color: #666;
                    padding-top: 8px;
                    margin-top: 12px;
                    border-top: 1px solid #ddd;
                }
                .section-heading {
                    font-weight: bold;
                    margin: 1em 0 0.5em 0;
                }
                .section-number {
                    font-weight: bold;
                }
                .main-text {
                    white-space: pre-wrap;
                }
                .placeholder {
                    color: #999;
                    font-style: italic;
                }
                @media print {
                    body {
                        background: white;
                        padding: 0;
                    }
                    .container {
                        box-shadow: none;
                        padding: 20px;
                    }
                    .page {
                        page-break-after: always;
                    }
                    .page:last-child {
                        page-break-after: avoid;
                    }
                }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>\(escapeHTML(documentTitle))</h1>

        """

        for (index, page) in pages.enumerated() {
            let pageNumber = index + 1
            let hasMargin = !page.marginText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            html += """
                        <div class="page">
                            <div class="page-header">\(String(localized: "עמוד \(pageNumber)"))</div>

            """

            let mainContentHTML: String
            if let structure = page.structure {
                mainContentHTML = buildStructuredHTML(structure: structure, fallbackText: page.mainText)
            } else {
                mainContentHTML = "<div class=\"main-text\">\(escapeHTMLWithPlaceholders(page.mainText))</div>"
            }

            if hasMargin {
                html += """
                            <table class="content-table">
                                <tr>
                                    <td class="main-column">
                                        \(mainContentHTML)
                                    </td>
                                    <td class="margin-column">
                                        <div class="margin-label">\(String(localized: "הערות שוליים"))</div>
                                        <div class="margin-text">\(escapeHTML(page.marginText))</div>
                                    </td>
                                </tr>
                            </table>

                """
            } else {
                html += """
                            \(mainContentHTML)

                """
            }

            html += """
                        </div>

            """
        }

        html += """
            </div>
        </body>
        </html>
        """

        return html
    }

    private func buildStructuredHTML(structure: PageStructure, fallbackText: String) -> String {
        // Build HTML from the plain-text paragraphs that were already assembled
        // We split by \n\n to reconstruct paragraph boundaries
        let textParagraphs = fallbackText.components(separatedBy: "\n\n")

        // If structure paragraph count matches text paragraph count, pair them
        guard structure.paragraphs.count == textParagraphs.count else {
            // Mismatch - fall back to pre-wrap
            return "<div class=\"main-text\">\(escapeHTMLWithPlaceholders(fallbackText))</div>"
        }

        var htmlParts: [String] = []
        for (i, paragraph) in structure.paragraphs.enumerated() {
            let text = textParagraphs[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let escaped = escapeHTMLWithPlaceholders(text)

            switch paragraph.role {
            case .header:
                htmlParts.append("<div class=\"header-text\">\(escaped)</div>")
            case .footer:
                htmlParts.append("<div class=\"footer-text\">\(escaped)</div>")
            case .sectionHeading:
                if let sectionNum = paragraph.sectionNumber {
                    let escapedNum = escapeHTML(sectionNum)
                    // Remove the section number from the start of text to wrap it separately
                    let bodyText = text.hasPrefix(sectionNum)
                        ? String(text.dropFirst(sectionNum.count)).trimmingCharacters(in: .whitespaces)
                        : text
                    let escapedBody = escapeHTMLWithPlaceholders(bodyText)
                    htmlParts.append("<p class=\"section-heading\"><span class=\"section-number\">\(escapedNum)</span> \(escapedBody)</p>")
                } else {
                    htmlParts.append("<p class=\"section-heading\">\(escaped)</p>")
                }
            case .body:
                htmlParts.append("<p>\(escaped)</p>")
            }
        }

        return htmlParts.joined(separator: "\n")
    }

    private func escapeHTML(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Escape HTML and wrap `[...]` placeholders in styled spans.
    private func escapeHTMLWithPlaceholders(_ text: String) -> String {
        let escaped = escapeHTML(text)
        return escaped.replacingOccurrences(
            of: "[...]",
            with: "<span class=\"placeholder\">[...]</span>"
        )
    }
}

#Preview {
    ContentView()
}
