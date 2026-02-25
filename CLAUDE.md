# Ayin (עין) — Hebrew OCR Scanner

## Project Structure

```
HebrewScanner.xcodeproj
HebrewScanner/          # macOS target source (ContentView.swift, HebrewScannerApp.swift)
AyiniOS/                # iOS target source (ContentView_iOS.swift, HebrewScannerApp_iOS.swift)
Shared/                 # Cross-platform code (OCR, language model, exporters, tokenizer)
Frameworks/             # Pre-built native libs (dylibs for macOS, xcframework for iOS)
Resources/              # tessdata/ and DictaBERT.mlpackage/
scripts/                # build_dmg.sh, build_ios_libs.sh, convert_dictabert_coreml.py
```

## Targets & Schemes

| Target | Scheme | SDK | Notes |
|--------|--------|-----|-------|
| Ayin | Ayin | macOS | Uses dylibs (libtesseract, libleptonica) |
| Ayin iOS | Ayin iOS | iOS | Uses TesseractIOS.xcframework |
| AyinTests | Ayin | macOS | Unit tests |
| AyinUITests | Ayin | macOS | UI tests |

## Build Commands

```bash
# macOS
xcodebuild -scheme Ayin -destination 'generic/platform=macOS' build 2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)"

# iOS
xcodebuild -scheme "Ayin iOS" -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)"
```

## Architecture

- **OCR pipeline:** Image → Tesseract (C API via TesseractOCR.swift) → word bounding boxes → DictaBERT post-processing → overlay
- **Platform split:** macOS and iOS have separate UI files (ContentView.swift vs ContentView_iOS.swift), sharing all OCR/model/export code via the Shared/ directory
- **No `#if os()` conditionals** — platform differences are handled by separate source files per target
- **All processing is offline** — Tesseract and DictaBERT run locally, no network calls

## Key Shared Files

- `TesseractOCR.swift` — C API bindings for Tesseract OCR
- `HebrewLanguageModel.swift` — Core ML DictaBERT loader and inference
- `LanguageModelPostProcessor.swift` — OCR error correction (Latin garbage, character confusions)
- `WordPieceTokenizer.swift` — BERT tokenization
- `DocumentStructure.swift` — Page layout analysis (body vs margin text)
- `OCRBox.swift` — Word bounding box model with TSV parsing
- `DOCXExporter.swift` — Word document export
- `HTMLExporter.swift` — HTML export

## Dependencies

- **ZIPFoundation** — via SPM (for DOCX export)
- **Tesseract OCR** — embedded (dylibs on macOS, xcframework on iOS)
- **DictaBERT** — pre-converted Core ML model in Resources/

## Conventions

- Author: Aviah Morag, year 2026
- Source language is Hebrew; English is the translation
- Localization via Localizable.xcstrings (Hebrew and English)
- No Claude mentions in commits
- Ask user before building — they often prefer to test changes themselves
