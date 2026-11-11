import Foundation

enum ArtifactToolSchema {
    static func input(_ name: String) -> [String: Any] {
        let identity: [String: Any] = ["type": "string", "maxLength": 128]
        let pointer: [String: Any] = ["type": "string", "maxLength": 512]
        switch name {
        case "capture_calculate":
            let filter = object(["startedAfter": ["type": "string", "format": "date-time"],
                "startedBefore": ["type": "string", "format": "date-time"], "method": ["type": "string"],
                "domain": ["type": "string"], "path": ["type": "string"]], required: ["startedAfter", "startedBefore"])
            var schema = object(["filter": filter, "sessionIDs": ["type": "array", "minItems": 1, "maxItems": 256,
                "uniqueItems": true, "items": ["type": "string", "format": "uuid"]],
                "dataset": ["type": "string", "enum": ["responseJSON", "sessionMetadata"]],
                "selectionPointer": pointer, "operation": operation,
                "operations": ["type": "array", "minItems": 1, "maxItems": 4, "items": operation],
                "approval": ["type": "object"]],
                required: ["dataset", "selectionPointer"])
            schema["oneOf"] = [["required": ["sessionIDs"]], ["required": ["filter"]]]
            return schema
        case "artifact_inventory", "artifact_search":
            var fields: [String: Any] = ["handle": identity, "snapshotRevision": identity, "cursor": identity,
                "limit": ["type": "integer", "minimum": 1, "maximum": 50], "method": ["type": "string", "maxLength": 256],
                "statusCode": ["type": "integer", "minimum": 100, "maximum": 599],
                "recordIndices": ["type": "array", "minItems": 1, "maxItems": 256, "uniqueItems": true,
                                  "items": ["type": "integer", "minimum": 0, "maximum": 999]]]
            var required = ["handle", "snapshotRevision"]
            if name == "artifact_search" {
                fields["literal"] = ["type": "string", "maxLength": 4096, "description": "3–4096 UTF-8 bytes, exact case and spelling."]
                fields["dataset"] = ["type": "string", "enum": ["sourceUTF8", "responseJSON"]]
                required += ["literal", "dataset"]
            }
            return object(fields, required: required)
        case "artifact_compare_responses":
            let side = object(["handle": identity, "snapshotRevision": identity,
                "recordIndex": ["type": "integer", "minimum": 0, "maximum": 999]], required: ["handle", "snapshotRevision", "recordIndex"])
            return object(["baseline": side, "candidate": side, "selectionPointer": pointer], required: ["baseline", "candidate"])
        case "artifact_response_brief":
            return object(["handle": identity, "snapshotRevision": identity,
                "recordIndex": ["type": "integer", "minimum": 0, "maximum": 999],
                "selectionPointer": pointer, "includeStructure": ["type": "boolean", "default": false]],
                required: ["handle", "snapshotRevision", "recordIndex"])
        case "artifact_calculate":
            return object(["handle": identity, "snapshotRevision": identity,
                "dataset": ["oneOf": [object(["kind": ["const": "json"]], required: ["kind"]),
                    object(["kind": ["const": "responseJSON"], "recordIndex": ["type": "integer", "minimum": 0, "maximum": 999]], required: ["kind", "recordIndex"]),
                    object(["kind": ["const": "sessionMetadata"], "recordIndices": ["type": "array", "minItems": 1, "maxItems": 256,
                        "uniqueItems": true, "items": ["type": "integer", "minimum": 0, "maximum": 999]]], required: ["kind"])]],
                "selectionPointer": pointer, "operation": operation,
                "operations": ["type": "array", "minItems": 1, "maxItems": 4, "items": operation]],
                required: ["handle", "snapshotRevision", "dataset", "selectionPointer"])
        case "artifact_source_register":
            return object(["requestKey": ["type": "string", "format": "uuid"],
                "kind": ["type": "string", "enum": ArtifactSourceKind.allCases.map(\.rawValue)],
                "scopes": ["type": "array", "minItems": 1, "maxItems": 4, "uniqueItems": true,
                    "items": ["type": "string", "enum": ["metadata-v1", "calculations-v1", "search-v1", "brief-v1"]]],
                "ttlSeconds": ["type": "integer", "minimum": 60, "maximum": 3600, "default": 1800],
                "approval": ["type": "object"]], required: ["requestKey", "kind", "scopes"])
        case "artifact_source_status": return object(["requestKey": ["type": "string", "format": "uuid"]], required: ["requestKey"])
        default: return object(["handle": identity], required: ["handle"])
        }
    }

    private static var predicateSchema: [String: Any] {
        object([
            "fieldPointer": ["type": "string", "maxLength": 512],
            "op": ["type": "string", "enum": ArtifactCalculation.Predicate.Operator.allCases.map(\.rawValue)],
            "operator": ["type": "string", "enum": ArtifactCalculation.Predicate.Operator.allCases.map(\.rawValue)],
            "value": ["oneOf": [["type": "string", "maxLength": 256], ["type": "number"], ["type": "boolean"]]]
        ], required: ["fieldPointer"])
    }

    private static var operation: [String: Any] {
        ["oneOf": ArtifactCalculation.Kind.allCases.map { kind in
            var properties: [String: Any] = ["kind": ["const": kind.rawValue], "where": predicateSchema]
            var required = ["kind"]
            if kind != .rowCount {
                properties["fieldPointer"] = ["type": "string", "maxLength": 512]
                required.append("fieldPointer")
            }
            if kind == .groupCount || kind == .topRows { properties["limit"] = ["type": "integer", "minimum": 1, "maximum": 20] }
            if kind == .topRows { properties["order"] = ["type": "string", "enum": ["asc", "desc"]] }
            return object(properties, required: required)
        }]
    }

    private static func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
}
