import ArgumentParser
import Foundation
import PDFKit

struct PdfCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "Extract text and metadata from PDF files",
        subcommands: [Text.self, Info.self]
    )

    // MARK: - Text
    struct Text: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Extract text from a PDF")

        @Option(name: .long, help: "Path to PDF file")
        var path: String

        @Option(name: .long, help: "Page number 1-indexed (default: all pages)")
        var page: Int?

        @Flag(name: .long, help: "Output JSON array of {page, text} objects")
        var json = false

        func run() throws {
            try Auth.check("pdf.read")
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            guard let doc = PDFDocument(url: url) else {
                throw ValidationError("Could not open PDF at: \(path)")
            }

            let pageCount = doc.pageCount
            if let p = page, (p < 1 || p > pageCount) {
                throw ValidationError("Page \(p) out of range — document has \(pageCount) pages")
            }

            let indices = page.map { [$0 - 1] } ?? Array(0..<pageCount)
            var pages: [[String: Any]] = []

            for i in indices {
                guard let pdfPage = doc.page(at: i) else { continue }
                pages.append([
                    "page": i + 1,
                    "text": pdfPage.string ?? ""
                ])
            }

            if json {
                printJSON(pages)
            } else {
                for p in pages {
                    if pageCount > 1 { print("--- Page \(p["page"]!) ---") }
                    print(p["text"] as? String ?? "")
                }
            }
        }
    }

    // MARK: - Info
    struct Info: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get PDF metadata")

        @Option(name: .long, help: "Path to PDF file")
        var path: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            try Auth.check("pdf.read")
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            guard let doc = PDFDocument(url: url) else {
                throw ValidationError("Could not open PDF at: \(path)")
            }

            var out: [String: Any] = [
                "path": expanded,
                "page_count": doc.pageCount,
                "encrypted": doc.isEncrypted,
            ]

            if let attrs = doc.documentAttributes {
                if let v = attrs[PDFDocumentAttribute.titleAttribute]    as? String { out["title"]    = v }
                if let v = attrs[PDFDocumentAttribute.authorAttribute]   as? String { out["author"]   = v }
                if let v = attrs[PDFDocumentAttribute.subjectAttribute]  as? String { out["subject"]  = v }
                if let v = attrs[PDFDocumentAttribute.creatorAttribute]  as? String { out["creator"]  = v }
                if let v = attrs[PDFDocumentAttribute.producerAttribute] as? String { out["producer"] = v }
                if let d = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date {
                    out["created"] = ISO8601DateFormatter().string(from: d)
                }
                if let d = attrs[PDFDocumentAttribute.modificationDateAttribute] as? Date {
                    out["modified"] = ISO8601DateFormatter().string(from: d)
                }
            }

            if json {
                printJSON(out)
            } else {
                print("Pages: \(doc.pageCount)")
                if let t = out["title"]   { print("Title:   \(t)") }
                if let a = out["author"]  { print("Author:  \(a)") }
                if let s = out["subject"] { print("Subject: \(s)") }
                if doc.isEncrypted { print("Encrypted: yes") }
            }
        }
    }
}
