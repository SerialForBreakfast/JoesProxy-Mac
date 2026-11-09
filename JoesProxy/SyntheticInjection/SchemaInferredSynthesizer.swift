//
//  SchemaInferredSynthesizer.swift
//  JoesProxy
//
//  Extracts schema templates from existing collection elements and synthesizes
//  valid, fully conforming clone items with bound assets and field overrides.
//

import Foundation

enum SchemaInferredSynthesizer {

    /// Synthesizes a new item by cloning a template item's structure and applying typed field overrides.
    static func synthesizeItem(
        from templateItem: [String: Any],
        overrides: [String: String],
        boundAssetURL: String? = nil
    ) -> [String: Any] {
        var synthesized: [String: Any] = [:]

        // 1. Deep clone template structure
        for (key, val) in templateItem {
            synthesized[key] = cloneValue(val)
        }

        // 2. Apply field overrides
        for (overrideKey, overrideVal) in overrides {
            let resolvedVal: String
            if overrideVal == "$ASSET_URL" || overrideVal.contains("$ASSET_URL") {
                resolvedVal = overrideVal.replacingOccurrences(of: "$ASSET_URL", with: boundAssetURL ?? "")
            } else {
                resolvedVal = overrideVal
            }

            // Check original field type in template
            if let origVal = templateItem[overrideKey] {
                if origVal is Bool {
                    synthesized[overrideKey] = (resolvedVal.lowercased() == "true" || resolvedVal == "1")
                } else if origVal is NSNumber, let num = Double(resolvedVal) {
                    if let _ = origVal as? Int {
                        synthesized[overrideKey] = Int(num)
                    } else {
                        synthesized[overrideKey] = num
                    }
                } else {
                    synthesized[overrideKey] = resolvedVal
                }
            } else {
                // New field
                if resolvedVal.lowercased() == "true" || resolvedVal.lowercased() == "false" {
                    synthesized[overrideKey] = (resolvedVal.lowercased() == "true")
                } else if let num = Int(resolvedVal) {
                    synthesized[overrideKey] = num
                } else {
                    synthesized[overrideKey] = resolvedVal
                }
            }
        }

        return synthesized
    }

    /// Injects a synthesized item into the target collection array within a JSON object tree.
    static func injectItem(
        into jsonObject: Any,
        at keypath: String,
        synthesizedItem: [String: Any],
        position: CollectionInjectionPosition
    ) -> (modifiedObject: Any, countBefore: Int, countAfter: Int)? {
        let cleanKeypath = keypath.trimmingCharacters(in: .whitespacesAndNewlines)

        // Case A: Root Array ($)
        if cleanKeypath == "$" || cleanKeypath.isEmpty {
            guard var rootArray = jsonObject as? [Any] else { return nil }
            let before = rootArray.count
            applyPosition(item: synthesizedItem, position: position, array: &rootArray)
            return (rootArray, before, rootArray.count)
        }

        // Case B: Nested Keypath (e.g. $.channels or $.data.items)
        guard var rootDict = jsonObject as? [String: Any] else { return nil }
        let pathComponents = cleanKeypath.replacingOccurrences(of: "$", with: "")
            .components(separatedBy: ".")
            .filter { !$0.isEmpty }

        guard !pathComponents.isEmpty else { return nil }

        var beforeCount = 0
        var afterCount = 0

        guard let modifiedDict = mutateNestedArray(
            dict: rootDict,
            keys: pathComponents,
            item: synthesizedItem,
            position: position,
            beforeCount: &beforeCount,
            afterCount: &afterCount
        ) else {
            return nil
        }

        return (modifiedDict, beforeCount, afterCount)
    }

    // MARK: - Array Mutation Helpers

    private static func mutateNestedArray(
        dict: [String: Any],
        keys: [String],
        item: [String: Any],
        position: CollectionInjectionPosition,
        beforeCount: inout Int,
        afterCount: inout Int
    ) -> [String: Any]? {
        var mutableDict = dict
        let currentKey = keys[0]

        if keys.count == 1 {
            guard var targetArray = mutableDict[currentKey] as? [Any] else { return nil }
            beforeCount = targetArray.count
            applyPosition(item: item, position: position, array: &targetArray)
            afterCount = targetArray.count
            mutableDict[currentKey] = targetArray
            return mutableDict
        } else {
            guard let childDict = mutableDict[currentKey] as? [String: Any] else { return nil }
            let remainingKeys = Array(keys.dropFirst())
            guard let updatedChild = mutateNestedArray(
                dict: childDict,
                keys: remainingKeys,
                item: item,
                position: position,
                beforeCount: &beforeCount,
                afterCount: &afterCount
            ) else {
                return nil
            }
            mutableDict[currentKey] = updatedChild
            return mutableDict
        }
    }

    private static func applyPosition(
        item: [String: Any],
        position: CollectionInjectionPosition,
        array: inout [Any]
    ) {
        switch position {
        case .prepend:
            array.insert(item, at: 0)
        case .append:
            array.append(item)
        case .replaceIndex(let idx):
            if idx >= 0 && idx < array.count {
                array[idx] = item
            } else {
                array.append(item)
            }
        case .replaceWhereKey(let key, let val):
            var replaced = false
            for (idx, element) in array.enumerated() {
                if let dict = element as? [String: Any], let elemVal = dict[key] as? String, elemVal == val {
                    array[idx] = item
                    replaced = true
                    break
                }
            }
            if !replaced {
                array.insert(item, at: 0)
            }
        }
    }

    private static func cloneValue(_ val: Any) -> Any {
        if let d = val as? [String: Any] {
            var newD: [String: Any] = [:]
            for (k, v) in d {
                newD[k] = cloneValue(v)
            }
            return newD
        } else if let a = val as? [Any] {
            return a.map { cloneValue($0) }
        }
        return val
    }
}
