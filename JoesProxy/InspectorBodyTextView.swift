import SwiftUI

struct InspectorBodyTextView: View {
    let data: Data?
    let binary: Bool
    let textScale: CGFloat
    @State private var selectedPage = 0

    var body: some View {
        if let data, !data.isEmpty {
            let page = InspectorBodyPage(data: data, page: selectedPage, binary: binary)
            VStack(alignment: .leading, spacing: 6) {
                if page.pageCount > 1 || page.isBase64 {
                    Text(verbatim: "Bytes \(page.byteRange.lowerBound + 1)–\(page.byteRange.upperBound) of \(page.totalBytes) · \(page.isBase64 ? "Base64 of this page" : "UTF-8")")
                        .appFont(.caption, scale: textScale)
                    Text("Copy Body copies the full available body, not just this page.")
                        .appFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                }
                if page.pageCount > 1 {
                    HStack {
                        Button("Previous") { selectedPage = page.pageIndex - 1 }
                            .disabled(page.pageIndex == 0)
                            .accessibilityLabel("Previous body page")
                        Text(verbatim: "\(page.pageIndex + 1) / \(page.pageCount)")
                            .appFont(.caption, scale: textScale)
                            .accessibilityLabel("Body page \(page.pageIndex + 1) of \(page.pageCount)")
                        Button("Next") { selectedPage = page.pageIndex + 1 }
                            .disabled(page.pageIndex + 1 == page.pageCount)
                            .accessibilityLabel("Next body page")
                    }
                    .controlSize(.small)
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(verbatim: page.text)
                        .appFont(.body, scale: textScale, design: .monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text(data == nil ? "No body" : "Empty body")
                .appFont(.body, scale: textScale)
        }
    }
}
