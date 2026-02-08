# HebrewScanner

A macOS app for OCR scanning of Hebrew text documents. Load an image or PDF, and HebrewScanner extracts the text using Tesseract OCR with full Hebrew language support.

## Features

- **Hebrew & English OCR** — Powered by embedded Tesseract with Hebrew and English language data
- **PDF support** — Multi-page PDF navigation with arrow keys and swipe gestures
- **Text selection** — Click and drag to select recognized words directly on the image
- **Auto-copy** — Selected text is automatically copied to the clipboard
- **HTML export** — Export scanned documents to formatted HTML with margin note separation
- **Zoom** — Pinch, Cmd+/-, or double-click to zoom
- **Drag & drop** — Drop images or PDFs directly into the window
- **Localized** — Hebrew and English UI

## Supported Formats

Images: PNG, JPEG, TIFF, BMP, GIF
Documents: PDF

## Requirements

- macOS 26.0 or later

## Building

Open `HebrewScanner.xcodeproj` in Xcode and build. All dependencies (Tesseract, Leptonica, and supporting libraries) are bundled in the project — no Homebrew or external installs needed.

## Creating a DMG for Distribution

After archiving and notarizing in Xcode:

```bash
# Install dependencies
brew install fileicon

# Build the DMG (requires Pillow: pip3 install Pillow)
./scripts/build_dmg.sh /path/to/exported/HebrewScanner.app
```

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+O | Open file |
| Cmd++ | Zoom in |
| Cmd+- | Zoom out |
| Cmd+0 | Reset zoom |
| Cmd+C | Copy selected text |
| Arrow keys | Navigate PDF pages |

## Architecture

HebrewScanner runs an embedded Tesseract binary bundled inside the app. When you load an image or PDF page:

1. The image is passed to Tesseract with Hebrew+English language data
2. Tesseract returns word-level bounding boxes in TSV format
3. Invisible text views are overlaid on each word for native text selection
4. Margin annotations are detected and separated from main text

All processing happens locally — no data is sent to any server.

## License

Copyright (c) 2026 Aviah Morag. All rights reserved.

See [LICENSE](LICENSE) for details.
