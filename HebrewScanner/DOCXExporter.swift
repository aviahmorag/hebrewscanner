//
//  DOCXExporter.swift
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

import Foundation
import ZIPFoundation

enum DOCXExporter {

    /// Generates a DOCX file as in-memory Data from OCR results.
    static func export(
        pages: [(mainText: String, marginText: String, structure: PageStructure?)],
        title: String
    ) throws -> Data {
        let archive = try Archive(accessMode: .create)

        let entries: [(path: String, content: String)] = [
            ("[Content_Types].xml", contentTypesXML()),
            ("_rels/.rels", relsXML()),
            ("word/_rels/document.xml.rels", documentRelsXML()),
            ("word/styles.xml", stylesXML()),
            ("word/document.xml", documentXML(pages: pages, title: title)),
        ]

        for entry in entries {
            guard let data = entry.content.data(using: .utf8) else { continue }
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { (position: Int64, size: Int) in
                    data[Data.Index(position)..<Data.Index(position) + size]
                }
            )
        }

        guard let archiveData = archive.data else {
            throw DOCXError.archiveCreationFailed
        }
        return archiveData
    }

    enum DOCXError: Error {
        case archiveCreationFailed
    }

    // MARK: - XML Generation

    private static func contentTypesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """
    }

    private static func relsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
    }

    private static func documentRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
    }

    private static func stylesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:docDefaults>
            <w:rPrDefault>
              <w:rPr>
                <w:rFonts w:cs="David" w:ascii="David" w:hAnsi="David"/>
                <w:sz w:val="24"/>
                <w:szCs w:val="24"/>
                <w:lang w:bidi="he-IL"/>
              </w:rPr>
            </w:rPrDefault>
            <w:pPrDefault>
              <w:pPr>
                <w:bidi/>
                <w:spacing w:after="200" w:line="360" w:lineRule="auto"/>
              </w:pPr>
            </w:pPrDefault>
          </w:docDefaults>
          <w:style w:type="paragraph" w:styleId="Normal" w:default="1">
            <w:name w:val="Normal"/>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading1">
            <w:name w:val="heading 1"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr>
              <w:bidi/>
              <w:spacing w:before="240" w:after="120"/>
            </w:pPr>
            <w:rPr>
              <w:b/>
              <w:bCs/>
              <w:sz w:val="28"/>
              <w:szCs w:val="28"/>
            </w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Title">
            <w:name w:val="Title"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr>
              <w:bidi/>
              <w:jc w:val="center"/>
              <w:spacing w:after="400"/>
              <w:pBdr>
                <w:bottom w:val="single" w:sz="8" w:space="4" w:color="333333"/>
              </w:pBdr>
            </w:pPr>
            <w:rPr>
              <w:b/>
              <w:bCs/>
              <w:sz w:val="36"/>
              <w:szCs w:val="36"/>
            </w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Header">
            <w:name w:val="Header"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr>
              <w:bidi/>
              <w:jc w:val="center"/>
              <w:pBdr>
                <w:bottom w:val="single" w:sz="4" w:space="2" w:color="DDDDDD"/>
              </w:pBdr>
            </w:pPr>
            <w:rPr>
              <w:color w:val="666666"/>
              <w:sz w:val="22"/>
              <w:szCs w:val="22"/>
            </w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Footer">
            <w:name w:val="Footer"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr>
              <w:bidi/>
              <w:jc w:val="center"/>
              <w:pBdr>
                <w:top w:val="single" w:sz="4" w:space="2" w:color="DDDDDD"/>
              </w:pBdr>
            </w:pPr>
            <w:rPr>
              <w:color w:val="666666"/>
              <w:sz w:val="22"/>
              <w:szCs w:val="22"/>
            </w:rPr>
          </w:style>
        </w:styles>
        """
    }

    private static func documentXML(
        pages: [(mainText: String, marginText: String, structure: PageStructure?)],
        title: String
    ) -> String {
        var body = ""

        // Title paragraph
        body += paragraphXML(text: title, style: "Title")

        // Render each page's content (flowing text, no page breaks)
        for page in pages {
            if let structure = page.structure {
                body += structuredContentXML(structure: structure, fallbackText: page.mainText)
            } else {
                body += plainTextXML(page.mainText)
            }
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
        \(body)
          </w:body>
        </w:document>
        """
    }

    // MARK: - Content Builders

    private static func structuredContentXML(structure: PageStructure, fallbackText: String) -> String {
        let textParagraphs = fallbackText.components(separatedBy: "\n\n")

        guard structure.paragraphs.count == textParagraphs.count else {
            return plainTextXML(fallbackText)
        }

        var xml = ""
        for (i, paragraph) in structure.paragraphs.enumerated() {
            let text = textParagraphs[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            switch paragraph.role {
            case .header:
                xml += paragraphXML(text: text, style: "Header", centered: paragraph.isCentered)
            case .footer:
                xml += paragraphXML(text: text, style: "Footer", centered: paragraph.isCentered)
            case .sectionHeading:
                xml += sectionHeadingXML(text: text, sectionNumber: paragraph.sectionNumber, centered: paragraph.isCentered)
            case .body:
                xml += paragraphXML(text: text, centered: paragraph.isCentered)
            }
        }
        return xml
    }

    private static func plainTextXML(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        return paragraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { paragraphXML(text: $0) }
            .joined()
    }

    private static func paragraphXML(text: String, style: String? = nil, centered: Bool = false) -> String {
        var pPr = "<w:pPr><w:bidi/>"
        if let style {
            pPr += "<w:pStyle w:val=\"\(style)\"/>"
        }
        if centered {
            pPr += "<w:jc w:val=\"center\"/>"
        }
        pPr += "</w:pPr>"

        let runs = buildRuns(text: text)

        return "    <w:p>\(pPr)\(runs)</w:p>\n"
    }

    private static func sectionHeadingXML(text: String, sectionNumber: String?, centered: Bool = false) -> String {
        var pPr = "<w:pPr><w:pStyle w:val=\"Heading1\"/><w:bidi/>"
        if centered {
            pPr += "<w:jc w:val=\"center\"/>"
        }
        pPr += "</w:pPr>"

        var runs = ""
        if let sectionNumber, text.hasPrefix(sectionNumber) {
            // Bold run for the section number
            let boldRPr = "<w:rPr><w:rtl/><w:b/><w:bCs/><w:rFonts w:cs=\"David\"/></w:rPr>"
            runs += "<w:r>\(boldRPr)<w:t xml:space=\"preserve\">\(escapeXML(sectionNumber)) </w:t></w:r>"

            // Normal run for the body text
            let bodyText = String(text.dropFirst(sectionNumber.count)).trimmingCharacters(in: .whitespaces)
            if !bodyText.isEmpty {
                runs += buildRuns(text: bodyText, bold: true)
            }
        } else {
            runs = buildRuns(text: text, bold: true)
        }

        return "    <w:p>\(pPr)\(runs)</w:p>\n"
    }

    /// Builds run XML for text, handling `[...]` placeholders with gray/italic styling.
    private static func buildRuns(text: String, bold: Bool = false) -> String {
        let parts = text.components(separatedBy: "[...]")
        var runs = ""

        for (i, part) in parts.enumerated() {
            if !part.isEmpty {
                var rPr = "<w:rPr><w:rtl/><w:rFonts w:cs=\"David\"/>"
                if bold {
                    rPr += "<w:b/><w:bCs/>"
                }
                rPr += "</w:rPr>"
                runs += "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(escapeXML(part))</w:t></w:r>"
            }

            // Add placeholder run between parts (not after the last one)
            if i < parts.count - 1 {
                var rPr = "<w:rPr><w:rtl/><w:rFonts w:cs=\"David\"/><w:i/><w:iCs/><w:color w:val=\"999999\"/>"
                if bold {
                    rPr += "<w:b/><w:bCs/>"
                }
                rPr += "</w:rPr>"
                runs += "<w:r>\(rPr)<w:t>[...]</w:t></w:r>"
            }
        }

        return runs
    }

    // MARK: - Helpers

    static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
