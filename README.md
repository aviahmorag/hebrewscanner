# Ayin (עין) — Hebrew OCR Scanner

A macOS app for OCR scanning of Hebrew text documents. Load an image or PDF, and Ayin extracts the text using Tesseract OCR with DictaBERT language model post-processing for improved accuracy.

## Features

- **Hebrew & English OCR** — Powered by embedded Tesseract with Hebrew and English language data
- **Language model correction** — DictaBERT (Core ML) fixes OCR errors: Latin garbage replacement, Hebrew near-miss correction, and character confusion resolution (ר↔ד, ב↔כ, etc.)
- **PDF support** — Multi-page PDF navigation with arrow keys and swipe gestures
- **Text selection** — Click and drag to select recognized words directly on the image
- **Auto-copy** — Selected text is automatically copied to the clipboard
- **DOCX export** — Export scanned documents to Word format with margin note separation and watermark detection
- **Zoom** — Pinch, Cmd+/-, or double-click to zoom
- **Drag & drop** — Drop images or PDFs directly into the window
- **Localized** — Hebrew and English UI

## Supported Formats

Images: PNG, JPEG, TIFF, BMP, GIF
Documents: PDF

## Requirements

- macOS 26.0 or later

## Building

Open `HebrewScanner.xcodeproj` in Xcode and build. All dependencies are bundled in the project — no Homebrew or external installs needed:

- **Tesseract & Leptonica** — Pre-built dylibs in `Frameworks/`
- **tessdata** — Hebrew and English trained data in `Resources/tessdata/`
- **DictaBERT** — Pre-converted Core ML model in `Resources/DictaBERT.mlpackage/`
- **ZIPFoundation** — Resolved automatically via Swift Package Manager

### Regenerating the Core ML Model (Optional)

The DictaBERT model is already included. To regenerate it from the HuggingFace source:

```bash
pip install torch transformers coremltools
python scripts/convert_dictabert_coreml.py
```

## Creating a DMG for Distribution

After archiving and notarizing in Xcode:

```bash
# Install dependencies
brew install fileicon

# Build the DMG (requires Pillow: pip3 install Pillow)
./scripts/build_dmg.sh /path/to/exported/Ayin.app
```

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+O | Open file |
| Cmd+E | Export to DOCX |
| Cmd++ | Zoom in |
| Cmd+- | Zoom out |
| Cmd+0 | Reset zoom |
| Cmd+C | Copy selected text |
| Arrow keys | Navigate PDF pages |

## Architecture

Ayin bundles Tesseract OCR and a DictaBERT language model for fully offline Hebrew text recognition. When you load an image or PDF page:

1. PDF pages are rendered at 2x resolution (~288 DPI) for optimal OCR accuracy
2. Tesseract returns word-level bounding boxes in TSV format
3. DictaBERT post-processes the results: replaces Latin garbage with Hebrew predictions, corrects character confusions, and fixes near-miss OCR errors
4. Invisible text views are overlaid on each word for native text selection
5. Margin annotations are detected and separated from main content

Multi-page DOCX export processes pages concurrently for faster throughput.

All processing happens locally — no data is sent to any server.

## Acknowledgements

- [Tesseract OCR](https://github.com/tesseract-ocr/tesseract) — Apache License 2.0
- [DictaBERT](https://huggingface.co/dicta-il/dictabert) by DICTA: The Israel Center for Text Analysis — CC BY 4.0
- [Leptonica](http://leptonica.org) — BSD 2-Clause License
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) — MIT License

See the app's About window for full third-party credits.

## License

Copyright (c) 2026 Aviah Morag. All rights reserved.

See [LICENSE](LICENSE) for details.
