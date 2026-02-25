//
//  SelectableOverlayImageView_iOS.swift
//  Ayin iOS
//
//  Created by Aviah Morag in 2026.
//

import SwiftUI
import UIKit

// MARK: - Invisible Word Label

/// A transparent label placed over each OCR word for tap selection and copy.
class WordLabel: UIView {
    let text: String
    let lineId: Int
    let wordNum: Int
    let isMargin: Bool

    var isWordSelected: Bool = false {
        didSet {
            backgroundColor = isWordSelected
                ? UIColor.systemBlue.withAlphaComponent(0.3)
                : .clear
        }
    }

    init(text: String, lineId: Int, wordNum: Int, isMargin: Bool, frame: CGRect) {
        self.text = text
        self.lineId = lineId
        self.wordNum = wordNum
        self.isMargin = isMargin
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Overlay Container

class OverlayContainerView: UIView, UIEditMenuInteractionDelegate {
    var wordLabels: [WordLabel] = []
    var selectedWords: Set<WordLabel> = []
    var pageStructure: PageStructure?

    // Gesture state
    private var dragStartPoint: CGPoint = .zero
    private var isDragging = false
    private var editMenuInteraction: UIEditMenuInteraction!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGestures()
    }

    private func setupGestures() {
        // Tap to select a single word
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        // Long press to show copy menu on selection
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        addGestureRecognizer(longPress)

        // Pan to drag-select multiple words
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.require(toFail: longPress)
        addGestureRecognizer(pan)

        // Edit menu interaction (replaces deprecated UIMenuController)
        editMenuInteraction = UIEditMenuInteraction(delegate: self)
        addInteraction(editMenuInteraction)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)

        if let wordLabel = wordLabel(at: point) {
            if wordLabel.isWordSelected {
                // Tapped on already-selected text → show copy menu
                showCopyMenu(at: point)
            } else {
                // Tapped on unselected word → select it
                clearSelection()
                wordLabel.isWordSelected = true
                selectedWords = [wordLabel]
            }
        } else {
            clearSelection()
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            let point = gesture.location(in: self)

            if let wordLabel = wordLabel(at: point) {
                if !wordLabel.isWordSelected {
                    clearSelection()
                    wordLabel.isWordSelected = true
                    selectedWords = [wordLabel]
                }
                showCopyMenu(at: point)
            }
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)

        switch gesture.state {
        case .began:
            isDragging = true
            dragStartPoint = point
            clearSelection()

        case .changed:
            guard isDragging else { return }
            let rect = CGRect(
                x: min(dragStartPoint.x, point.x),
                y: min(dragStartPoint.y, point.y),
                width: abs(point.x - dragStartPoint.x),
                height: abs(point.y - dragStartPoint.y)
            )
            updateSelection(for: rect)

        case .ended, .cancelled:
            isDragging = false

        default:
            break
        }
    }

    private func wordLabel(at point: CGPoint) -> WordLabel? {
        for label in wordLabels.reversed() {
            if label.frame.contains(point) {
                return label
            }
        }
        return nil
    }

    private func updateSelection(for rect: CGRect) {
        selectedWords.removeAll()
        for label in wordLabels {
            if rect.intersects(label.frame) {
                label.isWordSelected = true
                selectedWords.insert(label)
            } else {
                label.isWordSelected = false
            }
        }
    }

    func clearSelection() {
        for label in selectedWords {
            label.isWordSelected = false
        }
        selectedWords.removeAll()
    }

    private func showCopyMenu(at point: CGPoint) {
        becomeFirstResponder()
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
        editMenuInteraction.presentEditMenu(with: config)
    }

    override var canBecomeFirstResponder: Bool { true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) {
            return !selectedWords.isEmpty
        }
        return false
    }

    override func copy(_ sender: Any?) {
        copyToPasteboard()
    }

    // MARK: - UIEditMenuInteractionDelegate

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard !selectedWords.isEmpty else { return nil }
        return nil  // Return nil to use the standard system edit menu (Copy based on canPerformAction)
    }

    private func copyToPasteboard() {
        let text = getCombinedText()
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    func getCombinedText() -> String {
        let words = Array(selectedWords)
        guard !words.isEmpty else { return "" }

        let mainWords = words.filter { !$0.isMargin }
        let marginWords = words.filter { $0.isMargin && isSignificantText($0.text) }

        let mainText: String
        if let structure = pageStructure {
            mainText = buildStructuredText(mainWords, structure: structure)
        } else {
            mainText = buildText(from: mainWords)
        }

        let marginText = buildText(from: marginWords)

        let marginLabel = String(localized: "שוליים")
        if marginText.isEmpty {
            return mainText
        } else if mainText.isEmpty {
            return "[\(marginLabel)] " + marginText
        } else {
            return mainText + "\n\n[\(marginLabel)]\n" + marginText
        }
    }

    private func isSignificantText(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { scalar in
            let v = scalar.value
            return (v >= 0x0590 && v <= 0x05FF) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
        }
        return letters.count >= 2
    }

    private func buildText(from words: [WordLabel]) -> String {
        guard !words.isEmpty else { return "" }

        var lineGroups: [Int: [WordLabel]] = [:]
        for w in words {
            lineGroups[w.lineId, default: []].append(w)
        }

        let sortedLineIds = lineGroups.keys.sorted()
        return sortedLineIds.map { lineId in
            let sorted = lineGroups[lineId]!.sorted { $0.wordNum < $1.wordNum }
            return sorted.map { $0.text }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    private func buildStructuredText(_ words: [WordLabel], structure: PageStructure) -> String {
        guard !words.isEmpty else { return "" }

        let selectedLineIds = Set(words.map { $0.lineId })
        var lineGroups: [Int: [WordLabel]] = [:]
        for w in words {
            lineGroups[w.lineId, default: []].append(w)
        }

        var parts: [String] = []
        for paragraph in structure.paragraphs {
            let matchingLineIds = paragraph.lineIds.filter { selectedLineIds.contains($0) }
            guard !matchingLineIds.isEmpty else { continue }

            var allWords: [String] = []
            for lineId in matchingLineIds {
                guard let lineWords = lineGroups[lineId] else { continue }
                let sorted = lineWords.sorted { $0.wordNum < $1.wordNum }
                allWords.append(contentsOf: sorted.map { $0.text })
            }

            let text = allWords.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            parts.append(text)
        }

        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Zoom-to-fit scroll view

/// UIScrollView subclass that applies zoom-to-fit when a new image is loaded.
/// Uses the container's unzoomed bounds (not contentSize, which changes with zoom)
/// and defers the fit to after SwiftUI has finalized layout.
class FittingScrollView: UIScrollView {
    /// The unzoomed (scale=1) size of the content. Set explicitly when the image changes,
    /// because UIScrollView.contentSize shifts with zoomScale.
    var originalContentSize: CGSize = .zero

    /// When true, the next layoutSubviews applies zoom-to-fit and clears the flag.
    var needsZoomToFit = false

    /// Tracks the available size we last fitted to, so rotation triggers a re-fit.
    private var lastFitAvailableSize: CGSize = .zero

    /// Resets fit state for a new image. Call before scheduling a new zoom-to-fit.
    func resetFitState() {
        needsZoomToFit = true
        lastFitAvailableSize = .zero
    }

    func applyZoomToFit() {
        guard needsZoomToFit,
              bounds.width > 0, bounds.height > 0,
              originalContentSize.width > 0, originalContentSize.height > 0 else { return }

        let insets = adjustedContentInset
        let availableWidth = bounds.width - insets.left - insets.right
        let availableHeight = bounds.height - insets.top - insets.bottom
        guard availableWidth > 0, availableHeight > 0 else { return }

        let availableSize = CGSize(width: availableWidth, height: availableHeight)
        guard availableSize != lastFitAvailableSize else { return }
        lastFitAvailableSize = availableSize

        let scaleW = availableWidth / originalContentSize.width
        let scaleH = availableHeight / originalContentSize.height
        let fitScale = min(scaleW, scaleH)

        minimumZoomScale = min(fitScale, 0.5)
        maximumZoomScale = max(5.0, fitScale * 3)
        setZoomScale(fitScale, animated: false)
        needsZoomToFit = false

        centerContent()
    }

    func centerContent() {
        guard let container = viewWithTag(100) else { return }
        let insets = adjustedContentInset
        let availableWidth = bounds.width - insets.left - insets.right
        let availableHeight = bounds.height - insets.top - insets.bottom
        let offsetX = max((availableWidth - container.frame.width) / 2 + insets.left, insets.left)
        let offsetY = max((availableHeight - container.frame.height) / 2 + insets.top, insets.top)
        container.frame.origin = CGPoint(x: offsetX, y: offsetY)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if needsZoomToFit {
            applyZoomToFit()
        }
    }
}

// MARK: - SwiftUI UIViewRepresentable

struct SelectableOverlayImageView_iOS: UIViewRepresentable {
    let image: UIImage
    let boxes: [OCRBox]
    let pageStructure: PageStructure?

    func makeUIView(context: Context) -> FittingScrollView {
        let scrollView = FittingScrollView()
        scrollView.minimumZoomScale = 0.5
        scrollView.maximumZoomScale = 5.0
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.contentInsetAdjustmentBehavior = .always

        let container = OverlayContainerView()
        container.tag = 100
        scrollView.addSubview(container)

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.tag = 200
        container.addSubview(imageView)

        return scrollView
    }

    func updateUIView(_ scrollView: FittingScrollView, context: Context) {
        guard let container = scrollView.viewWithTag(100) as? OverlayContainerView,
              let imageView = container.viewWithTag(200) as? UIImageView else { return }

        let imageSize = image.size
        let imageChanged = imageView.image !== image

        if imageChanged {
            // Reset to clean state before reconfiguring — old zoomScale would
            // distort contentSize and break the fit calculation.
            scrollView.zoomScale = 1.0

            imageView.image = image
            imageView.frame = CGRect(origin: .zero, size: imageSize)
            container.frame = CGRect(origin: .zero, size: imageSize)
            scrollView.contentSize = imageSize
            scrollView.originalContentSize = imageSize

            // Schedule zoom-to-fit. Reset lastFitAvailableSize so the fit
            // recalculates even if the screen size hasn't changed. Use async
            // to ensure SwiftUI has finished laying out the scroll view's bounds
            // (they may still be zero when updateUIView runs for a newly inserted view).
            scrollView.resetFitState()
            scrollView.setNeedsLayout()
            DispatchQueue.main.async {
                if scrollView.needsZoomToFit {
                    scrollView.applyZoomToFit()
                }
            }
        }

        // Only rebuild word labels if boxes actually changed
        let boxCount = boxes.count
        let currentLabelCount = container.wordLabels.count
        let boxesChanged = imageChanged || boxCount != currentLabelCount

        guard boxesChanged else {
            container.pageStructure = pageStructure
            return
        }

        // Remove old word labels
        container.wordLabels.forEach { $0.removeFromSuperview() }
        container.wordLabels.removeAll()
        container.selectedWords.removeAll()
        container.pageStructure = pageStructure

        guard !boxes.isEmpty else { return }

        // Position word labels
        // On iOS, UIImage.size is in points (= pixels for scale=1 images from UIImage(data:))
        // Tesseract coordinates match the PNG pixel dimensions = image.size for scale=1
        let scaleFactor: CGFloat = 1.0 / image.scale

        // Compute uniform height from median box height
        var allHeights: [CGFloat] = []
        for box in boxes {
            allHeights.append(box.frame.height * scaleFactor)
        }
        let sortedHeights = allHeights.sorted()
        let midH = sortedHeights.count / 2
        let medianHeight: CGFloat = sortedHeights.isEmpty ? 10 :
            (sortedHeights.count % 2 == 0 ? (sortedHeights[midH - 1] + sortedHeights[midH]) / 2 : sortedHeights[midH])
        let uniformHeight = medianHeight + 4

        // Compute per-line median baseline
        var baselinesPerLine: [Int: [CGFloat]] = [:]
        for box in boxes {
            let baseline = (box.frame.origin.y + box.frame.height) * scaleFactor
            baselinesPerLine[box.lineId, default: []].append(baseline)
        }
        var medianBaseline: [Int: CGFloat] = [:]
        for (lineId, baselines) in baselinesPerLine {
            let sorted = baselines.sorted()
            let mid = sorted.count / 2
            medianBaseline[lineId] = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        }

        for box in boxes {
            let scaledBox = CGRect(
                x: box.frame.origin.x * scaleFactor,
                y: box.frame.origin.y * scaleFactor,
                width: box.frame.width * scaleFactor,
                height: box.frame.height * scaleFactor
            )

            let x = scaledBox.origin.x
            let width = scaledBox.width
            let baseY = medianBaseline[box.lineId] ?? (scaledBox.origin.y + scaledBox.height)
            let y = baseY - uniformHeight + 2  // Top-left origin (iOS)

            let frame = CGRect(x: x, y: y, width: width, height: uniformHeight)

            let wordLabel = WordLabel(
                text: box.text,
                lineId: box.lineId,
                wordNum: box.wordNum,
                isMargin: box.isMargin,
                frame: frame
            )
            container.addSubview(wordLabel)
            container.wordLabels.append(wordLabel)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.viewWithTag(100)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if let fittingScrollView = scrollView as? FittingScrollView {
                fittingScrollView.centerContent()
            }
        }
    }
}
