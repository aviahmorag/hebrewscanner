//
//  HTMLExporter.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

import Foundation

enum HTMLExporter {

    /// Generates an HTML document string from OCR results.
    static func export(
        pages: [(mainText: String, marginText: String, structure: PageStructure?)],
        title: String
    ) -> String {
        var html = """
        <!DOCTYPE html>
        <html lang="he" dir="rtl">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(escapeHTML(title))</title>
            <style>
                * { box-sizing: border-box; }
                body {
                    font-family: "David", "Times New Roman", serif;
                    font-size: 12pt;
                    line-height: 1.8;
                    margin: 0; padding: 20px;
                    background: #f5f5f5;
                    direction: rtl;
                }
                .container {
                    max-width: 1000px; margin: 0 auto;
                    background: white; padding: 40px;
                    box-shadow: 0 2px 10px rgba(0,0,0,0.1);
                }
                h1 { font-size: 18pt; text-align: center; }
                h2 { font-size: 14pt; }
                .page {
                    margin-bottom: 40px; padding-bottom: 20px;
                    border-bottom: 1px dashed #ccc;
                }
                .page:last-child { border-bottom: none; }
                .content-table { width: 100%; border-collapse: collapse; }
                .main-column { width: 75%; vertical-align: top; padding-left: 20px; }
                .margin-column {
                    width: 25%; vertical-align: top;
                    padding-right: 20px;
                    border-right: 2px solid #ddd;
                    font-size: 10pt; color: #555;
                }
                .margin-text { white-space: pre-wrap; font-style: italic; }
                .margin-label { font-weight: bold; color: #888; font-size: 9pt; margin-bottom: 8px; }
                footer p { font-size: 10pt; color: #888; text-align: center; }
                .placeholder { color: #999; font-style: italic; }
                @media print {
                    body { background: white; padding: 0; }
                    .container { box-shadow: none; padding: 20px; }
                    .page { page-break-after: always; }
                    .page:last-child { page-break-after: avoid; }
                }
            </style>
        </head>
        <body>
            <div class="container">
        """

        for page in pages {
            let hasMargin = !page.marginText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            html += """
                        <div class="page">
            """

            let mainContentHTML: String
            if let structure = page.structure {
                mainContentHTML = structuredHTML(structure: structure, fallbackText: page.mainText)
            } else {
                mainContentHTML = escapeHTMLWithPlaceholders(page.mainText)
                    .components(separatedBy: "\n\n")
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { "<p>\($0)</p>" }
                    .joined(separator: "\n")
            }

            if hasMargin {
                html += """
                            <table class="content-table">
                                <tr>
                                    <td class="main-column">
                                        \(mainContentHTML)
                                    </td>
                                    <td class="margin-column">
                                        <div class="margin-label">\(escapeHTML(String(localized: "הערות שוליים")))</div>
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

    // MARK: - Structured Content

    private static func structuredHTML(structure: PageStructure, fallbackText: String) -> String {
        let textParagraphs = fallbackText.components(separatedBy: "\n\n")

        guard structure.paragraphs.count == textParagraphs.count else {
            return escapeHTMLWithPlaceholders(fallbackText)
                .components(separatedBy: "\n\n")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { "<p>\($0)</p>" }
                .joined(separator: "\n")
        }

        var htmlParts: [String] = []
        for (i, paragraph) in structure.paragraphs.enumerated() {
            let text = textParagraphs[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let escaped = escapeHTMLWithPlaceholders(text)

            switch paragraph.role {
            case .header:
                htmlParts.append("<h1>\(escaped)</h1>")
            case .footer:
                htmlParts.append("<footer><p>\(escaped)</p></footer>")
            case .sectionHeading:
                if let sectionNum = paragraph.sectionNumber {
                    let escapedNum = escapeHTML(sectionNum)
                    let bodyText = text.hasPrefix(sectionNum)
                        ? String(text.dropFirst(sectionNum.count)).trimmingCharacters(in: .whitespaces)
                        : text
                    let escapedBody = escapeHTMLWithPlaceholders(bodyText)
                    htmlParts.append("<h2>\(escapedNum) \(escapedBody)</h2>")
                } else {
                    htmlParts.append("<h2>\(escaped)</h2>")
                }
            case .body:
                htmlParts.append("<p>\(escaped)</p>")
            }
        }

        return htmlParts.joined(separator: "\n")
    }

    // MARK: - HTML Escaping

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func escapeHTMLWithPlaceholders(_ text: String) -> String {
        let escaped = escapeHTML(text)
        return escaped.replacingOccurrences(
            of: "[...]",
            with: "<span class=\"placeholder\">[...]</span>"
        )
    }
}
