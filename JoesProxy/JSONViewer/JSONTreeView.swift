//
//  JSONTreeView.swift
//  JoesProxy
//
//  SwiftUI view that displays a JSON tree in a folder-like structure with expandable nodes.
//  Uses horizontal tree lines (├ └ │) for clear hierarchy alignment.
//

import SwiftUI

/// Displays a JSON tree with expandable object and array nodes.
struct JSONTreeView: View {
    let root: JSONTreeNode
    var expandedIDs: Binding<Set<String>>? = nil
    var scrollAnchorPath: String? = nil
    /// Surgical preview overrides keyed by JSON dot path; does not mutate the tree model.
    var previewOverridesByPath: [String: BookmarkJSONValue] = [:]
    var onAddFieldRewrite: ((String, String) -> Void)? = nil
    @State private var localExpandedIDs: Set<String> = ["root"]

    private var expandedIDsBinding: Binding<Set<String>> {
        if let expandedIDs {
            return expandedIDs
        }
        return $localExpandedIDs
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                JSONTreeNodeRow(
                    node: root,
                    nodeID: "root",
                    dotPath: "",
                    depth: 0,
                    isLast: true,
                    parentConnectors: [],
                    expandedIDs: expandedIDsBinding,
                    previewOverridesByPath: previewOverridesByPath,
                    onAddFieldRewrite: onAddFieldRewrite
                )
                .padding(.leading, 4)
            }
            .onAppear {
                expandedIDsBinding.wrappedValue.insert("root")
                scrollToAnchorIfNeeded(proxy: proxy)
            }
            .onChange(of: scrollAnchorPath) { _, _ in
                scrollToAnchorIfNeeded(proxy: proxy)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity, alignment: .topLeading)
    }

    private func scrollToAnchorIfNeeded(proxy: ScrollViewProxy) {
        guard let scrollAnchorPath, !scrollAnchorPath.isEmpty else {
            return
        }

        var expanded = expandedIDsBinding.wrappedValue
        expanded.formUnion(
            JSONTreeExpansion.nodeIDs(
                toward: scrollAnchorPath,
                in: root,
                nodeID: "root",
                currentDotPath: ""
            )
        )
        expandedIDsBinding.wrappedValue = expanded

        DispatchQueue.main.async {
            withAnimation(.none) {
                proxy.scrollTo(scrollAnchorPath, anchor: .center)
            }
        }
    }
}

/// Computes which tree node IDs must be expanded to reveal a JSON dot path.
private enum JSONTreeExpansion {
    static func nodeIDs(
        toward dotPath: String,
        in node: JSONTreeNode,
        nodeID: String,
        currentDotPath: String
    ) -> Set<String> {
        var ids: Set<String> = [nodeID]
        if currentDotPath == dotPath {
            return ids
        }

        guard pathPrefix(currentDotPath).isEmpty || dotPath.hasPrefix(pathPrefix(currentDotPath)) else {
            return []
        }

        for (index, child) in node.children.enumerated() {
            let childDotPath = JSONPathResolver.childPath(
                parentPath: currentDotPath,
                segmentKey: child.segmentKey
            )
            guard dotPath == childDotPath || dotPath.hasPrefix(childDotPath + ".") || dotPath.hasPrefix(childDotPath + "[") else {
                continue
            }
            ids.formUnion(
                nodeIDs(
                    toward: dotPath,
                    in: child,
                    nodeID: "\(nodeID).\(index)",
                    currentDotPath: childDotPath
                )
            )
        }

        return ids
    }

    private static func pathPrefix(_ path: String) -> String {
        path.isEmpty ? "" : path + "."
    }
}

/// On-demand legend explaining icon colors by JSON type (Workstream AC-1).
struct JSONTypeLegendView: View {
    private struct LegendItem: Identifiable {
        let label: String
        let icon: String
        let color: Color

        var id: String { label }
    }

    private let items = [
        LegendItem(label: "Object", icon: "folder.fill", color: .blue),
        LegendItem(label: "Array", icon: "square.stack.3d.up.fill", color: .blue),
        LegendItem(label: "String", icon: "text.quote", color: .green),
        LegendItem(label: "Number", icon: "number", color: .orange),
        LegendItem(label: "Boolean", icon: "checkmark.circle", color: .purple),
        LegendItem(label: "Null", icon: "questionmark.circle", color: .secondary)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("JSON Types")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            HStack(spacing: 10) {
                ForEach(items) { item in
                    legendItem(item)
                }
            }
        }
        .padding(10)
        .frame(width: 190, alignment: .leading)
    }

    private func legendItem(_ item: LegendItem) -> some View {
        Image(systemName: item.icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(item.color)
            .frame(width: 20, height: 20)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
            .help(item.label)
            .accessibilityLabel(item.label)
    }
}

/// DisclosureGroupStyle that does not add content indentation so tree lines align.
private struct JSONTreeDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    configuration.label
                    Spacer(minLength: 0)
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(configuration.isExpanded ? "Collapse" : "Expand")
            .accessibilityHint("Toggles visibility of child nodes.")
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

/// A single row in the JSON tree; recursively contains child rows for objects and arrays.
/// Uses horizontal tree lines (├ └ │) for hierarchy alignment.
private struct JSONTreeNodeRow: View {
    let node: JSONTreeNode
    let nodeID: String
    let dotPath: String
    let depth: Int
    let isLast: Bool
    let parentConnectors: [Bool]
    @Binding var expandedIDs: Set<String>
    var previewOverridesByPath: [String: BookmarkJSONValue] = [:]
    var onAddFieldRewrite: ((String, String) -> Void)? = nil

    private static let indentWidth: CGFloat = 20

    private var isPreviewPatched: Bool {
        !dotPath.isEmpty && previewOverridesByPath[dotPath] != nil
    }
    private static let treeLineFont = Font.system(size: 11, design: .monospaced)

    var body: some View {
        switch node {
        case .object, .array:
            if node.isExpandable {
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedIDs.contains(nodeID) },
                    set: { if $0 { expandedIDs.insert(nodeID) } else { expandedIDs.remove(nodeID) } }
                )) {
                    ForEach(Array(node.children.enumerated()), id: \.offset) { index, child in
                        let childIsLast = index == node.children.count - 1
                        let childConnectors = parentConnectors + [!childIsLast]
                        let childDotPath = JSONPathResolver.childPath(
                            parentPath: dotPath,
                            segmentKey: child.segmentKey
                        )
                        JSONTreeNodeRow(
                            node: child,
                            nodeID: "\(nodeID).\(index)",
                            dotPath: childDotPath,
                            depth: depth + 1,
                            isLast: childIsLast,
                            parentConnectors: childConnectors,
                            expandedIDs: $expandedIDs,
                            previewOverridesByPath: previewOverridesByPath,
                            onAddFieldRewrite: onAddFieldRewrite
                        )
                    }
                } label: {
                    treeRowContent
                }
                .disclosureGroupStyle(JSONTreeDisclosureStyle())
            } else {
                treeRowContent
            }
        case .string, .number, .bool, .null:
            treeRowContent
        }
    }

    private var treeRowContent: some View {
        HStack(alignment: .top, spacing: 0) {
            treeLines
            NodeLabelView(
                node: node,
                label: displayLabel,
                isPreviewPatched: isPreviewPatched
            )
                .contextMenu {
                    if node.isRewriteableLeaf,
                       let onAddFieldRewrite,
                       !dotPath.isEmpty,
                       let value = node.leafRewriteValue {
                        Button("Add Field Rewrite") {
                            onAddFieldRewrite(dotPath, value)
                        }
                    }
                }
        }
        .id(dotPath.isEmpty ? nodeID : dotPath)
    }

    private var displayLabel: String {
        guard let override = previewOverridesByPath[dotPath] else {
            return node.label
        }
        return BookmarkJSONPreviewOverlay.patchedTreeLabel(for: node, dotPath: dotPath, override: override)
    }

    @ViewBuilder
    private var treeLines: some View {
        if depth > 0 {
            HStack(spacing: 0) {
                ForEach(Array(parentConnectors.enumerated()), id: \.offset) { _, hasSiblingBelow in
                    connectorSlot(hasLine: hasSiblingBelow)
                }
                connectorSlot(hasLine: true, character: isLast ? "└" : "├")
            }
        }
    }

    private func connectorSlot(hasLine: Bool, character: String? = nil) -> some View {
        let content: String
        if let character {
            content = character
        } else {
            content = hasLine ? "│" : " "
        }
        return ZStack(alignment: .leading) {
            Color.clear.frame(width: Self.indentWidth, height: 1)
            Text(content)
                .font(Self.treeLineFont)
                .foregroundStyle(.tertiary)
                .opacity(character != nil || hasLine ? 1 : 0)
        }
        .frame(width: Self.indentWidth, alignment: .leading)
    }
}

/// Label for a single JSON tree node with icon and text.
private struct NodeLabelView: View {
    let node: JSONTreeNode
    let label: String
    var isPreviewPatched: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.iconName)
                .font(.system(size: 12))
                .foregroundStyle(nodeColor)
                .frame(width: 16, alignment: .center)

            Text(label)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(isPreviewPatched ? .teal : .primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if isPreviewPatched {
                Text("preview")
                    .font(.caption2)
                    .foregroundStyle(.teal)
            }
        }
        .padding(.vertical, 2)
    }

    private var nodeColor: Color {
        switch node {
        case .object, .array:
            return .blue
        case .string:
            return .green
        case .number:
            return .orange
        case .bool:
            return .purple
        case .null:
            return .secondary
        }
    }
}

#Preview {
    let sample = """
    {
        "name": "JoesProxy",
        "version": "1.0",
        "features": ["HTTP", "HTTPS", "Capture"],
        "config": {
            "port": 9090,
            "enabled": true
        }
    }
    """
    let root = try! JSONTreeParser.parse(sample)
    return JSONTreeView(root: root)
        .frame(width: 400, height: 400)
}
