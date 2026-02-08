//
//  SelectableOverlayImageView.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//


import SwiftUI
import AppKit

class MultiTextSelectionManager: NSObject {
    weak var containerView: NSView?
    var textViews: [NSTextView] = []
    var isDragging = false
    var dragStartPoint: CGPoint = .zero
    var selectedViews: Set<NSTextView> = []
    
    func addTextView(_ textView: NSTextView) {
        textViews.append(textView)
        // Remove individual selection handling
        textView.isSelectable = false
    }
    
    func handleMouseDown(with event: NSEvent) {
        guard let containerView = containerView else { return }
        let point = containerView.convert(event.locationInWindow, from: nil)
        
        isDragging = true
        dragStartPoint = point
        selectedViews.removeAll()
        
        // Clear visual selection on all text views
        textViews.forEach { $0.backgroundColor = NSColor.clear }
        
        print("🖱️ Start drag at: \(point)")
    }
    
    func handleMouseDragged(with event: NSEvent) {
        guard isDragging, let containerView = containerView else { return }
        let currentPoint = containerView.convert(event.locationInWindow, from: nil)
        
        // Create selection rectangle
        let selectionRect = CGRect(
            x: min(dragStartPoint.x, currentPoint.x),
            y: min(dragStartPoint.y, currentPoint.y),
            width: abs(currentPoint.x - dragStartPoint.x),
            height: abs(currentPoint.y - dragStartPoint.y)
        )
        
        // Find text views that intersect with selection
        selectedViews.removeAll()
        for (index, textView) in textViews.enumerated() {
            if selectionRect.intersects(textView.frame) {
                selectedViews.insert(textView)
                textView.backgroundColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.4).withAlphaComponent(0.4) // Semi-transparent selection
            } else {  
                textView.backgroundColor = NSColor.clear // Invisible when not selected
            }
            
            // Debug first few text views
            if index < 3 {
                print("📍 TextView \(index) frame: \(textView.frame)")
            }
        }
        
        print("🔄 Drag selection: \(selectedViews.count) views, rect: \(selectionRect)")
    }
    
    func handleMouseUp(with event: NSEvent) {
        isDragging = false
        
        if !selectedViews.isEmpty {
            let combinedText = handleCopy()
            print("📋 Final selection: '\(combinedText)'")
            
            // Copy to pasteboard
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(combinedText, forType: .string)
        }
    }
    
    func handleCopy() -> String {
        // Use Tesseract's line/word numbers for proper ordering
        let views = selectedViews.compactMap { $0 as? PassThroughTextView }
        guard !views.isEmpty else { return "" }

        var lineGroups: [Int: [PassThroughTextView]] = [:]
        for view in views {
            lineGroups[view.lineId, default: []].append(view)
        }

        let sortedLineIds = lineGroups.keys.sorted()

        return sortedLineIds.map { lineId in
            let wordsInLine = lineGroups[lineId]!.sorted { $0.wordNum < $1.wordNum }
            return wordsInLine.map { $0.string }.joined(separator: " ")
        }.joined(separator: "\n")
    }
}

class PassThroughTextView: NSTextView {
    // Simple text view - no special mouse handling, overlay manages all selection
    var lineId: Int = 0
    var wordNum: Int = 0
    var isMargin: Bool = false  // True if this word is a margin annotation
}

class TransparentSelectionOverlay: NSView, NSMenuDelegate {
    weak var containerView: NSView?
    private var isDragging = false
    private var dragStartPoint: CGPoint = .zero
    private var selectedViews: Set<PassThroughTextView> = []
    private var isExtendingSelection = false
    private var anchorTextView: NSTextView?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Always return self to handle all mouse events
        return super.hitTest(point)
    }
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override func rightMouseDown(with event: NSEvent) {
        // Show context menu if there's a selection
        if !selectedViews.isEmpty {
            let menu = NSMenu()
            let copyItem = NSMenuItem(title: String(localized: "העתק"), action: #selector(copy(_:)), keyEquivalent: "c")
            copyItem.target = self
            menu.addItem(copyItem)
            
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
    
    @objc func copy(_ sender: Any?) {
        if !selectedViews.isEmpty {
            let combinedText = getCombinedText()
            copyToPasteboard(combinedText)
        }
    }
    
    override func keyDown(with event: NSEvent) {
        // Handle Cmd+C
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
            copy(nil)
            return
        }
        super.keyDown(with: event)
    }
    
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return !selectedViews.isEmpty
        }
        return false
    }
    
    override func mouseDown(with event: NSEvent) {
        // Make sure this view can receive keyboard events
        window?.makeFirstResponder(self)
        
        let point = convert(event.locationInWindow, from: nil)
        
        // Clear any existing text selections first
        clearAllTextSelections()
        
        // Handle double-click for word selection
        if event.clickCount >= 2 {
            if let textView = hitTestTextView(at: point) {
                handleDoubleClickSelection(textView: textView, event: event)
                return
            }
        }
        
        // Start multi-selection drag (works for single click too)
        isDragging = true
        dragStartPoint = point
        selectedViews.removeAll()
        clearAllSelections()
        
        print("🖱️ Selection drag start at: \(point)")
    }
    
    override func mouseDragged(with event: NSEvent) {
        if isExtendingSelection && anchorTextView != nil {
            handleExtendedSelection(with: event)
            return
        }
        
        guard isDragging else {
            super.mouseDragged(with: event)
            return
        }
        
        let currentPoint = convert(event.locationInWindow, from: nil)
        let selectionRect = CGRect(
            x: min(dragStartPoint.x, currentPoint.x),
            y: min(dragStartPoint.y, currentPoint.y),
            width: abs(currentPoint.x - dragStartPoint.x),
            height: abs(currentPoint.y - dragStartPoint.y)
        )
        
        updateSelection(for: selectionRect)
        print("🔄 Selection rect: \(selectionRect), selected: \(selectedViews.count)")
    }
    
    override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            if !selectedViews.isEmpty {
                let combinedText = getCombinedText()
                copyToPasteboard(combinedText)
                print("📋 Multi-selected text: '\(combinedText)'")
            }
        } else if isExtendingSelection {
            isExtendingSelection = false

            // Copy final extended selection to clipboard
            if !selectedViews.isEmpty {
                let combinedText = getCombinedText()
                copyToPasteboard(combinedText)
                print("📋 Final extended selection: '\(combinedText)'")
            }

            anchorTextView = nil
        } else {
            super.mouseUp(with: event)
        }
    }
    
    private func hitTestTextView(at point: CGPoint) -> NSTextView? {
        guard let container = containerView else { return nil }
        
        for subview in container.subviews.reversed() {
            if let textView = subview as? NSTextView, textView.frame.contains(point) {
                return textView
            }
        }
        return nil
    }
    
    private func updateSelection(for rect: CGRect) {
        guard let container = containerView else { return }

        selectedViews.removeAll()

        for subview in container.subviews {
            if let textView = subview as? PassThroughTextView {
                if rect.intersects(textView.frame) {
                    selectedViews.insert(textView)
                    textView.backgroundColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.4).withAlphaComponent(0.4)
                } else {
                    textView.backgroundColor = NSColor.clear
                }
            }
        }
    }
    
    private func clearAllSelections() {
        guard let container = containerView else { return }
        
        for subview in container.subviews {
            if let textView = subview as? NSTextView {
                textView.backgroundColor = NSColor.clear
            }
        }
    }
    
    private func clearAllTextSelections() {
        guard let container = containerView else { return }
        
        // Clear text selections and resign first responder
        for subview in container.subviews {
            if let textView = subview as? NSTextView {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                if textView.window?.firstResponder == textView {
                    textView.window?.makeFirstResponder(nil)
                }
            }
        }
    }
    
    private func getCombinedText() -> String {
        // Use Tesseract's line/word numbers for proper ordering
        let views = Array(selectedViews)
        guard !views.isEmpty else { return "" }

        // Separate main text from margin annotations
        let mainViews = views.filter { !$0.isMargin }
        let marginViews = views.filter { $0.isMargin && isSignificantText($0.string) }

        // Build main text
        let mainText = buildTextFromViews(mainViews)

        // Build margin text (if any significant words)
        let marginText = buildTextFromViews(marginViews)

        // Combine: main text first, then margin annotations (if any)
        let marginLabel = String(localized: "שוליים")
        if marginText.isEmpty {
            return mainText
        } else if mainText.isEmpty {
            return "[\(marginLabel)] " + marginText
        } else {
            return mainText + "\n\n[\(marginLabel)]\n" + marginText
        }
    }

    /// Check if text is significant (not just punctuation or single chars)
    private func isSignificantText(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if there's at least 2 Hebrew/English letters
        let letters = cleaned.unicodeScalars.filter { scalar in
            // Hebrew: U+0590 to U+05FF
            // Latin letters: a-zA-Z
            let isHebrew = scalar.value >= 0x0590 && scalar.value <= 0x05FF
            let isLatin = (scalar.value >= 0x0041 && scalar.value <= 0x005A) ||
                          (scalar.value >= 0x0061 && scalar.value <= 0x007A)
            return isHebrew || isLatin
        }

        return letters.count >= 2
    }

    private func buildTextFromViews(_ views: [PassThroughTextView]) -> String {
        guard !views.isEmpty else { return "" }

        // Group by lineId
        var lineGroups: [Int: [PassThroughTextView]] = [:]
        for view in views {
            lineGroups[view.lineId, default: []].append(view)
        }

        // Extract paragraph ID from lineId: blockNum * 1000000 + parNum * 1000 + lineNum
        // Paragraph ID = blockNum * 1000 + parNum
        func paragraphId(from lineId: Int) -> Int {
            let blockNum = lineId / 1000000
            let parNum = (lineId % 1000000) / 1000
            return blockNum * 1000 + parNum
        }

        // Group lines into paragraphs
        let sortedLineIds = lineGroups.keys.sorted()
        var paragraphs: [Int: [Int]] = [:] // paragraphId -> [lineIds]
        for lineId in sortedLineIds {
            let parId = paragraphId(from: lineId)
            paragraphs[parId, default: []].append(lineId)
        }

        // Sort paragraphs by the first lineId (preserves document order)
        let sortedParIds = paragraphs.keys.sorted { parId1, parId2 in
            guard let firstLineId1 = paragraphs[parId1]?.first,
                  let firstLineId2 = paragraphs[parId2]?.first else { return false }
            return firstLineId1 < firstLineId2
        }

        // Build paragraphs as continuous text (words joined with spaces)
        var paragraphTexts: [String] = []
        for parId in sortedParIds {
            guard let lineIds = paragraphs[parId] else { continue }

            var allWords: [String] = []
            for lineId in lineIds {
                let wordsInLine = lineGroups[lineId]!.sorted { $0.wordNum < $1.wordNum }
                allWords.append(contentsOf: wordsInLine.map { $0.string })
            }

            let paragraphText = allWords.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !paragraphText.isEmpty {
                paragraphTexts.append(paragraphText)
            }
        }

        return paragraphTexts.joined(separator: "\n\n")
    }
    
    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    private func handleDoubleClickSelection(textView: NSTextView, event: NSEvent) {
        guard let passThrough = textView as? PassThroughTextView else { return }

        // Select the word in the clicked text view
        textView.selectAll(nil)
        textView.backgroundColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.4)

        // Clear other selections
        clearAllTextSelections()
        textView.selectAll(nil)
        textView.backgroundColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.4)

        // Set up for potential drag extension
        isExtendingSelection = true
        anchorTextView = textView
        selectedViews = [passThrough]

        print("🖱️ Double-click selection on: '\(textView.string)'")
    }
    
    private func handleExtendedSelection(with event: NSEvent) {
        guard let anchor = anchorTextView as? PassThroughTextView, let container = containerView else { return }

        let currentPoint = convert(event.locationInWindow, from: nil)

        // Get all text views sorted by Tesseract's line/word numbers
        let allTextViews = container.subviews.compactMap { $0 as? PassThroughTextView }.sorted { view1, view2 in
            if view1.lineId != view2.lineId {
                return view1.lineId < view2.lineId
            }
            return view1.wordNum < view2.wordNum
        }

        guard let anchorIndex = allTextViews.firstIndex(of: anchor) else { return }
        
        // Find the closest text view to current drag point (more stable than exact hit testing)
        var targetIndex = anchorIndex
        var minDistance = CGFloat.greatestFiniteMagnitude
        
        for (index, textView) in allTextViews.enumerated() {
            let center = CGPoint(x: textView.frame.midX, y: textView.frame.midY)
            let distance = sqrt(pow(currentPoint.x - center.x, 2) + pow(currentPoint.y - center.y, 2))
            
            if distance < minDistance {
                minDistance = distance
                targetIndex = index
            }
        }
        
        // Select range between anchor and target
        let range = anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
        let newSelectedViews = Set(allTextViews[range])
        
        // Only update if selection actually changed (prevents flickering)
        if newSelectedViews != selectedViews {
            selectedViews = newSelectedViews
            
            // Update visual selection
            for textView in allTextViews {
                if newSelectedViews.contains(textView) {
                    textView.backgroundColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.4).withAlphaComponent(0.4)
                    textView.selectAll(nil)
                } else {
                    textView.backgroundColor = NSColor.clear
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                }
            }
            
            // Only print when selection changes (reduces spam)
            print("🔄 Extended selection changed: \(newSelectedViews.count) words")
        }
    }
}

class SelectionContainerView: NSView {
    weak var selectionManager: MultiTextSelectionManager?
    
    override func mouseDown(with event: NSEvent) {
        selectionManager?.handleMouseDown(with: event)
        super.mouseDown(with: event)
    }
    
    override func mouseDragged(with event: NSEvent) {
        selectionManager?.handleMouseDragged(with: event)
        super.mouseDragged(with: event)
    }
    
    override func mouseUp(with event: NSEvent) {
        selectionManager?.handleMouseUp(with: event)
        super.mouseUp(with: event)
    }
}

class ResizableContainerView: NSView {
    var onResize: (() -> Void)?
    
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }
}

class PageNavigationView: NSView {
    var onPageNavigation: ((Bool) -> Void)?
    var onZoomChange: ((CGFloat, CGPoint) -> Void)?
    
    override func awakeFromNib() {
        super.awakeFromNib()
        setupGestures()
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGestures()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGestures()
    }
    
    private func setupGestures() {
        // Override swipe events to detect two-finger swipes
        wantsLayer = true
        allowedTouchTypes = [.indirect]
        
        // Add magnification gesture
        let magnifyGesture = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
        addGestureRecognizer(magnifyGesture)
    }
    
    private var lastMagnification: CGFloat = 0.0
    
    @objc private func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
        let location = gesture.location(in: self)
        
        if gesture.state == .began {
            lastMagnification = 0.0
        } else if gesture.state == .changed {
            let delta = gesture.magnification - lastMagnification
            lastMagnification = gesture.magnification
            
            // Scale down the delta to make it more controllable
            let scaledDelta = 1.0 + (delta * 0.5)
            onZoomChange?(scaledDelta, location)
        }
    }
    
    override func swipe(with event: NSEvent) {
        // Only handle if we have page navigation callback
        guard onPageNavigation != nil else {
            super.swipe(with: event)
            return
        }
        
        // Check for two-finger swipe
        if event.phase == .ended || event.phase == .cancelled {
            let deltaX = event.deltaX
            let deltaY = event.deltaY
            
            // Require significant movement
            let threshold: Double = 0.5
            
            if abs(deltaX) > abs(deltaY) && abs(deltaX) > threshold {
                // Horizontal swipe (RTL: left = next, right = previous)
                if deltaX < 0 {
                    onPageNavigation?(true) // Left swipe = next page
                } else {
                    onPageNavigation?(false) // Right swipe = previous page
                }
            } else if abs(deltaY) > threshold {
                // Vertical swipe (down = next, up = previous)  
                if deltaY < 0 {
                    onPageNavigation?(true) // Down swipe = next page
                } else {
                    onPageNavigation?(false) // Up swipe = previous page
                }
            }
        }
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Pass through to child views for text selection
        let result = super.hitTest(point)
        // Only return self if no child view can handle it
        return result == self ? nil : result
    }
    
}

class TransparentTextView: NSTextView {
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setupTransparency()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTransparency()
    }
    
    private func setupTransparency() {
        backgroundColor = NSColor.red.withAlphaComponent(0.3) // More visible red for debugging
        drawsBackground = true
        isEditable = false
        isSelectable = true
        textColor = NSColor.black // Fully visible black text for debugging
        insertionPointColor = .systemBlue
        selectedTextAttributes = [
            .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.7),
            .foregroundColor: NSColor.white
        ]
        textContainerInset = NSSize(width: 2, height: 2)
        textContainer?.lineFragmentPadding = 2
        font = NSFont.systemFont(ofSize: 16)
        
        // Ensure it can become first responder and receive mouse events
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticLinkDetectionEnabled = false
    }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
    
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        if range.length > 0 {
            let selectedText = (string as NSString).substring(with: range)
            if !selectedText.isEmpty {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(selectedText, forType: .string)
            }
        }
    }
    
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return selectedRange().length > 0
        }
        return super.validateUserInterfaceItem(item)
    }
    
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
            copy(nil)
            return
        }
        super.keyDown(with: event)
    }
}

struct SelectableOverlayImageView: NSViewRepresentable {
    let image: NSImage
    let boxes: [OCRBox]
    let zoomLevel: CGFloat
    let onPageNavigation: ((Bool) -> Void)? // true for next, false for previous
    let onZoomChange: ((CGFloat, CGPoint) -> Void)?

    class Coordinator {
        var layoutTask: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = PageNavigationView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.onPageNavigation = onPageNavigation
        container.onZoomChange = onZoomChange
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Cancel any pending layout task
        context.coordinator.layoutTask?.cancel()

        // Update the callbacks
        if let pageNavView = nsView as? PageNavigationView {
            pageNavView.onPageNavigation = onPageNavigation
            pageNavView.onZoomChange = onZoomChange
        }

        nsView.subviews.forEach { $0.removeFromSuperview() }

        let imageView = NSImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        nsView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: nsView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: nsView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: nsView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: nsView.bottomAnchor),
        ])

        // Wait for layout and then position text views
        context.coordinator.layoutTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self.positionTextViews(in: nsView, with: imageView)
        }
    }
    
    private func positionTextViews(in containerView: NSView, with imageView: NSImageView) {
        // Remove existing text views
        containerView.subviews.filter { $0 is NSTextView }.forEach { $0.removeFromSuperview() }
        
        // Calculate the actual image rect within the NSImageView for scaleProportionallyUpOrDown
        let imageViewBounds = imageView.bounds
        let imageSize = image.size
        
        // Guard against zero-sized bounds (layout not ready)
        guard imageViewBounds.width > 0 && imageViewBounds.height > 0 else {
            print("⚠️ ImageView bounds not ready yet: \(imageViewBounds)")
            return
        }
        
        // Calculate aspect ratios
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = imageViewBounds.width / imageViewBounds.height
        
        let imageRect: CGRect
        if imageAspect > viewAspect {
            // Image is wider - fit to width, center vertically
            let scaledHeight = imageViewBounds.width / imageAspect
            let yOffset = (imageViewBounds.height - scaledHeight) / 2
            imageRect = CGRect(x: 0, y: yOffset, width: imageViewBounds.width, height: scaledHeight)
        } else {
            // Image is taller - fit to height, center horizontally
            let scaledWidth = imageViewBounds.height * imageAspect
            let xOffset = (imageViewBounds.width - scaledWidth) / 2
            imageRect = CGRect(x: xOffset, y: 0, width: scaledWidth, height: imageViewBounds.height)
        }
        
        let scaleX = imageRect.width / imageSize.width
        let scaleY = imageRect.height / imageSize.height
        
        print("🖼️ Original image: \(imageSize)")
        print("📏 ImageView bounds: \(imageViewBounds)")
        print("🎯 Calculated image rect: \(imageRect)")
        print("📐 Scale X: \(scaleX), Scale Y: \(scaleY)")
        print("🔍 Zoom level: \(zoomLevel)")

        // Scale factor for 2x Retina resolution difference
        let scaleFactor: CGFloat = 0.5

        // First pass: collect ALL heights and per-line baselines
        var allHeights: [CGFloat] = []
        var baselinesPerLine: [Int: [CGFloat]] = [:]
        for box in boxes {
            // Use actual OCR height, properly scaled for display
            let scaledHeight = box.frame.height * scaleFactor * scaleY
            allHeights.append(scaledHeight)

            // Baseline = bottom of OCR box in view coordinates
            let scaledBottom = (box.frame.origin.y + box.frame.height) * scaleFactor
            let baseline = imageRect.maxY - scaledBottom * scaleY
            baselinesPerLine[box.lineId, default: []].append(baseline)
        }

        // Calculate GLOBAL median height (one consistent height for all boxes)
        let sortedAllHeights = allHeights.sorted()
        let midH = sortedAllHeights.count / 2
        let globalMedianHeight: CGFloat = sortedAllHeights.isEmpty ? 10 :
            (sortedAllHeights.count % 2 == 0 ? (sortedAllHeights[midH - 1] + sortedAllHeights[midH]) / 2 : sortedAllHeights[midH])

        // Use global height with padding (consistent for ALL boxes)
        let uniformHeight = globalMedianHeight + 4  // +2px top, +2px bottom

        // Calculate median baseline per line (for vertical alignment)
        var medianBaselinePerLine: [Int: CGFloat] = [:]
        for (lineId, baselines) in baselinesPerLine {
            let sortedB = baselines.sorted()
            let midB = sortedB.count / 2
            medianBaselinePerLine[lineId] = sortedB.count % 2 == 0 ? (sortedB[midB - 1] + sortedB[midB]) / 2 : sortedB[midB]
        }

        // Log height info
        print("📊 Global median height: \(String(format: "%.2f", globalMedianHeight)) → uniform: \(String(format: "%.2f", uniformHeight)) (\(boxes.count) boxes, \(medianBaselinePerLine.count) lines)")

        // Second pass: create text views with consistent per-line heights
        for (index, box) in boxes.enumerated() {
            let scaledBox = CGRect(
                x: box.frame.origin.x * scaleFactor,
                y: box.frame.origin.y * scaleFactor,
                width: box.frame.width * scaleFactor,
                height: box.frame.height * scaleFactor
            )

            let x = imageRect.minX + scaledBox.origin.x * scaleX
            let width = scaledBox.width * scaleX

            // Use GLOBAL uniform height for all boxes (perfect consistency)
            // Use per-line baseline for vertical alignment
            let height = uniformHeight
            let baseY = medianBaselinePerLine[box.lineId] ?? (imageRect.maxY - (scaledBox.origin.y + scaledBox.height) * scaleY)
            let y = baseY - 2  // Shift down 2px to center the padding

            let frame = CGRect(x: x, y: y, width: width, height: height)

            // Log first 10 boxes and any containing "את" or "מבקש"
            if index < 10 || box.text.contains("את") || box.text.contains("מבקש") {
                print("🔢 Box \(index) '\(box.text)' lineId:\(box.lineId) finalH:\(String(format: "%.2f", height)) y:\(String(format: "%.1f", y))")
            }

            if imageRect.intersects(frame) {
                let textView = PassThroughTextView(frame: frame)
                textView.string = box.text
                textView.lineId = box.lineId
                textView.wordNum = box.wordNum
                textView.isMargin = box.isMargin
                // Use fixed tiny font - text is invisible, we just need it for copy
                // This prevents NSTextView from auto-expanding due to font metrics
                textView.font = NSFont.systemFont(ofSize: 4)
                textView.backgroundColor = NSColor.clear
                textView.textColor = NSColor.clear
                textView.isEditable = false
                textView.isSelectable = false
                textView.drawsBackground = true
                // Zero insets to prevent frame expansion
                textView.textContainerInset = NSSize.zero
                textView.textContainer?.lineFragmentPadding = 0

                containerView.addSubview(textView)

                // Debug: log actual frame for first 5 boxes
                if index < 5 {
                    let marginTag = box.isMargin ? " [MARGIN]" : ""
                    print("📐 TextView '\(box.text)'\(marginTag) frame: \(textView.frame)")
                }
            }
        }
        
        // Add transparent selection overlay on top (must be added last to be on top)
        let selectionOverlay = TransparentSelectionOverlay()
        selectionOverlay.frame = containerView.bounds
        selectionOverlay.autoresizingMask = [.width, .height]
        selectionOverlay.containerView = containerView
        selectionOverlay.wantsLayer = true
        selectionOverlay.layer?.zPosition = 1000 // Ensure it's on top
        containerView.addSubview(selectionOverlay)
        
        let createdCount = containerView.subviews.filter { $0 is NSTextView }.count
        print("✅ Created \(createdCount)/\(boxes.count) text views for Hebrew word selection")
    }
}
