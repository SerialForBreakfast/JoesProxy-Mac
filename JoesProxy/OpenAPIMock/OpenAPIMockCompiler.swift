import Foundation

/// Import and compile failures. Budget breaches wrap ``OpenAPIMockPackError``.
enum OpenAPIMockCompilerError: Error, Equatable, LocalizedError {
    case pack(OpenAPIMockPackError)
    case malformedJSON(String)
    case yamlDocument
    case unsupportedVersion(String)
    case remoteRef(String)
    case refCycle(String)
    case refNotFound(String)
    case missingOrigin
    case noSupportedOperations
    case remainingTieConflict(String)
    case unsupportedSchema(Set<OpenAPIMockFeatureTag>)
    case schemaRejected(String)

    var errorDescription: String? {
        switch self {
        case .pack(let error):
            return error.errorDescription
        case .malformedJSON(let detail):
            return "OpenAPI document is not valid JSON: \(detail)"
        case .yamlDocument:
            return "YAML OpenAPI documents are not supported; provide OpenAPI 3.0 JSON."
        case .unsupportedVersion(let version):
            return "OpenAPI version \(version) is not supported; v1 accepts 3.0.x JSON only."
        case .remoteRef(let ref):
            return "Remote $ref is not allowed: \(ref)"
        case .refCycle(let ref):
            return "Cyclic $ref: \(ref)"
        case .refNotFound(let ref):
            return "Local $ref was not found: \(ref)"
        case .missingOrigin:
            return "Document has no usable servers[0].url and no origin override was supplied."
        case .noSupportedOperations:
            return "No supported operations could be compiled from this document."
        case .remainingTieConflict(let detail):
            return "Route precedence tie: \(detail)"
        case .unsupportedSchema(let tags):
            return "Schema uses unsupported features: \(tags.map(\.rawValue).sorted().joined(separator: ", "))."
        case .schemaRejected(let detail):
            return "Compiled fixture failed schema validation: \(detail)"
        }
    }
}

/// Input for a read-only compile. The document must already be local bytes — never a path.
struct OpenAPIMockCompileRequest: Equatable, Sendable {
    var document: Data
    var packID: OpenAPIMockPackID
    var originOverride: OpenAPIMockOrigin?
}

/// Immutable compiled body. AW-3 serves these bytes; disclosure uses ``variant``.
struct OpenAPIMockCompiledFixture: Equatable, Sendable, Codable {
    var variant: OpenAPIMockResponseVariant
    var status: Int
    var headers: [String: String]
    var body: Data
}

/// Per-operation preview row for the coverage report.
struct OpenAPIMockOperationPreview: Equatable, Sendable, Codable {
    var method: String
    var template: String
    var operationID: String?
    var variantCount: Int
    var defaultVariantID: String
    var generatedVariantCount: Int
    var declaredExampleCount: Int
}

/// One skipped or unsupported feature, with enough location to act on it.
struct OpenAPIMockUnsupportedItem: Equatable, Sendable, Codable {
    var method: String?
    var template: String?
    var feature: OpenAPIMockFeatureTag
    var detail: String
}

/// Bounded compile report. Counts and locations only — no fixture bodies.
struct OpenAPIMockCompileReport: Equatable, Sendable, Codable {
    var operations: [OpenAPIMockOperationPreview]
    var unsupported: [OpenAPIMockUnsupportedItem]
    var conflicts: [String]
    var estimatedFootprintBytes: Int
    var coverage: OpenAPIMockCoverageSummary
}

/// Normalized operation graph plus immutable fixtures.
struct OpenAPIMockCompiledPack: Equatable, Sendable, Codable {
    var origin: OpenAPIMockOrigin
    var routes: [OpenAPIMockRoute]
    var fixturesByVariantID: [String: OpenAPIMockCompiledFixture]
    var report: OpenAPIMockCompileReport
}

/// Read-only OpenAPI 3.0 JSON importer and deterministic fixture compiler (AW-2).
enum OpenAPIMockCompiler {
    private static let httpMethods: Set<String> = [
        "get", "put", "post", "delete", "options", "head", "patch", "trace"
    ]

    /// Compiles `request.document` into a version-independent pack. Does not activate intercept.
    static func compile(_ request: OpenAPIMockCompileRequest) throws -> OpenAPIMockCompiledPack {
        try validateDocumentBytes(request.document)
        try rejectYAML(request.document)
        let root = try parseJSONObject(request.document)
        try validateVersion(root)

        let resolver = OpenAPIMockRefResolver(root: root)
        let origin = try resolveOrigin(root: root, override: request.originOverride)

        var documentTags: Set<OpenAPIMockFeatureTag> = []
        OpenAPIMockSchemaWalker.collect(from: root, into: &documentTags)
        if root["webhooks"] != nil { documentTags.insert(.webhooks) }

        let paths = root["paths"] as? [String: Any] ?? [:]
        var routes: [OpenAPIMockRoute] = []
        var fixtures: [String: OpenAPIMockCompiledFixture] = [:]
        var previews: [OpenAPIMockOperationPreview] = []
        var unsupported: [OpenAPIMockUnsupportedItem] = []

        for pathKey in paths.keys.sorted() {
            guard let rawPathItem = paths[pathKey] else { continue }
            var stack: [String] = []
            let pathItemAny: Any
            do {
                pathItemAny = try resolver.resolveNode(rawPathItem, stack: &stack)
            } catch let error as OpenAPIMockCompilerError {
                unsupported.append(
                    OpenAPIMockUnsupportedItem(method: nil, template: pathKey, feature: feature(for: error), detail: error.localizedDescription)
                )
                continue
            }
            guard let pathItem = pathItemAny as? [String: Any] else { continue }

            for methodKey in pathItem.keys.sorted() where httpMethods.contains(methodKey.lowercased()) {
                guard let operation = pathItem[methodKey] as? [String: Any] else { continue }
                let compiled = compileOperation(
                    path: pathKey,
                    method: methodKey,
                    pathItem: pathItem,
                    operation: operation,
                    origin: origin,
                    packID: request.packID,
                    resolver: resolver
                )
                unsupported.append(contentsOf: compiled.unsupported)
                if let route = compiled.route {
                    routes.append(route)
                    for fixture in compiled.fixtures {
                        fixtures[fixture.variant.id] = fixture
                    }
                    previews.append(compiled.preview)
                }
            }
        }

        do {
            try OpenAPIMockPackBudget.validateOperationCount(routes.count)
        } catch let error as OpenAPIMockPackError {
            throw OpenAPIMockCompilerError.pack(error)
        }
        guard !routes.isEmpty else {
            throw OpenAPIMockCompilerError.noSupportedOperations
        }

        let conflicts = detectConflicts(routes)
        if let first = conflicts.first {
            throw OpenAPIMockCompilerError.remainingTieConflict(first)
        }

        let footprint = fixtures.values.reduce(0) { $0 + $1.body.count }
        let generatedCount = fixtures.values.filter { $0.variant.sourceKind == .synthetic }.count
        let declaredCount = fixtures.values.filter {
            $0.variant.sourceKind == .declaredExample || $0.variant.sourceKind == .namedError
        }.count
        let documentUnsupported = OpenAPIMockSchemaSupport.classify(Array(documentTags)).unsupported
        for tag in documentUnsupported.sorted(by: { $0.rawValue < $1.rawValue }) {
            if !unsupported.contains(where: { $0.feature == tag }) {
                unsupported.append(
                    OpenAPIMockUnsupportedItem(method: nil, template: nil, feature: tag, detail: "Document uses \(tag.rawValue)")
                )
            }
        }

        let coverage = OpenAPIMockCoverageSummary(
            supportedOperationCount: routes.count,
            variantCount: fixtures.count,
            generatedVariantCount: generatedCount,
            declaredExampleCount: declaredCount,
            unsupportedFeatureCount: unsupported.count,
            conflictCount: 0
        )
        let report = OpenAPIMockCompileReport(
            operations: previews,
            unsupported: unsupported,
            conflicts: [],
            estimatedFootprintBytes: footprint,
            coverage: coverage
        )
        return OpenAPIMockCompiledPack(
            origin: origin,
            routes: routes,
            fixturesByVariantID: fixtures,
            report: report
        )
    }

    private struct OperationCompile {
        var route: OpenAPIMockRoute?
        var fixtures: [OpenAPIMockCompiledFixture]
        var preview: OpenAPIMockOperationPreview
        var unsupported: [OpenAPIMockUnsupportedItem]
    }

    private static func compileOperation(
        path: String,
        method: String,
        pathItem: [String: Any],
        operation: [String: Any],
        origin: OpenAPIMockOrigin,
        packID: OpenAPIMockPackID,
        resolver: OpenAPIMockRefResolver
    ) -> OperationCompile {
        var unsupported: [OpenAPIMockUnsupportedItem] = []
        let methodUpper = method.uppercased()
        let operationID = operation["operationId"] as? String

        if operation["callbacks"] != nil {
            unsupported.append(OpenAPIMockUnsupportedItem(method: methodUpper, template: path, feature: .callbacks, detail: "callbacks are not compiled"))
        }

        let template: OpenAPIMockPathTemplate
        do {
            template = try OpenAPIMockPathTemplate.parse(path)
        } catch {
            unsupported.append(
                OpenAPIMockUnsupportedItem(method: methodUpper, template: path, feature: .openAPI31, detail: "path template is not supported in v1")
            )
            return OperationCompile(route: nil, fixtures: [], preview: OpenAPIMockOperationPreview(
                method: methodUpper, template: path, operationID: operationID,
                variantCount: 0, defaultVariantID: "", generatedVariantCount: 0, declaredExampleCount: 0
            ), unsupported: unsupported)
        }

        let query: [OpenAPIMockQueryConstraint]
        do {
            query = try queryConstraints(pathItem: pathItem, operation: operation, resolver: resolver)
        } catch {
            let compilerError = Self.asCompilerError(error)
            unsupported.append(OpenAPIMockUnsupportedItem(method: methodUpper, template: path, feature: feature(for: compilerError), detail: compilerError.localizedDescription))
            return OperationCompile(route: nil, fixtures: [], preview: emptyPreview(methodUpper, path, operationID), unsupported: unsupported)
        }

        let requestType = requestContentType(operation: operation, resolver: resolver)
        guard let rawResponses = operation["responses"] else {
            unsupported.append(OpenAPIMockUnsupportedItem(method: methodUpper, template: path, feature: .openAPI31, detail: "operation has no responses"))
            return OperationCompile(route: nil, fixtures: [], preview: emptyPreview(methodUpper, path, operationID), unsupported: unsupported)
        }
        let responsesAny: Any
        do {
            var stack: [String] = []
            responsesAny = try resolver.resolveNode(rawResponses, stack: &stack)
        } catch {
            let compilerError = Self.asCompilerError(error)
            unsupported.append(OpenAPIMockUnsupportedItem(method: methodUpper, template: path, feature: feature(for: compilerError), detail: compilerError.localizedDescription))
            return OperationCompile(route: nil, fixtures: [], preview: emptyPreview(methodUpper, path, operationID), unsupported: unsupported)
        }
        guard let responses = responsesAny as? [String: Any] else {
            return OperationCompile(route: nil, fixtures: [], preview: emptyPreview(methodUpper, path, operationID), unsupported: unsupported)
        }

        var compiledFixtures: [OpenAPIMockCompiledFixture] = []
        var successCandidates: [OpenAPIMockResponseVariant] = []

        for statusKey in responses.keys.sorted() {
            guard let status = Int(statusKey), (100...599).contains(status) else { continue }
            var stack: [String] = []
            let responseNode: Any
            do {
                responseNode = try resolver.resolveNode(responses[statusKey] as Any, stack: &stack)
            } catch {
                let compilerError = Self.asCompilerError(error)
                unsupported.append(OpenAPIMockUnsupportedItem(method: methodUpper, template: path, feature: feature(for: compilerError), detail: compilerError.localizedDescription))
                continue
            }
            guard let response = responseNode as? [String: Any] else { continue }
            let content = response["content"] as? [String: Any] ?? [:]
            if content.isEmpty { continue }

            for mediaType in content.keys.sorted() {
                let essence = OpenAPIMockRouteMatcher.contentTypeEssence(mediaType)
                if essence == "text/event-stream" {
                    unsupported.append(OpenAPIMockUnsupportedItem(method: methodUpper, template: path, feature: .eventStream, detail: mediaType))
                    continue
                }
                if essence.contains("xml") {
                    unsupported.append(OpenAPIMockUnsupportedItem(method: methodUpper, template: path, feature: .xml, detail: mediaType))
                    continue
                }
                guard isJSONMediaType(essence) else { continue }
                guard let media = content[mediaType] as? [String: Any] else { continue }

                let built = compileMedia(
                    status: status,
                    contentType: essence,
                    media: media,
                    method: methodUpper,
                    template: template.rawValue,
                    packID: packID,
                    resolver: resolver
                )
                unsupported.append(contentsOf: built.unsupported.map {
                    OpenAPIMockUnsupportedItem(method: methodUpper, template: path, feature: $0.feature, detail: $0.detail)
                })
                compiledFixtures.append(contentsOf: built.fixtures)
                if status < 400 {
                    successCandidates.append(contentsOf: built.fixtures.map(\.variant))
                }
            }
        }

        do {
            try OpenAPIMockPackBudget.validateVariantCount(operation: operationID ?? "\(methodUpper) \(path)", count: compiledFixtures.count)
        } catch {
            unsupported.append(OpenAPIMockUnsupportedItem(method: methodUpper, template: path, feature: .openAPI31, detail: error.localizedDescription))
            return OperationCompile(route: nil, fixtures: [], preview: emptyPreview(methodUpper, path, operationID), unsupported: unsupported)
        }

        for fixture in compiledFixtures {
            if fixture.body.count > OpenAPIMockPackBudget.maxCompiledBodyBytes {
                unsupported.append(OpenAPIMockUnsupportedItem(
                    method: methodUpper, template: path, feature: .binaryGeneration,
                    detail: "compiled body exceeds \(OpenAPIMockPackBudget.maxCompiledBodyBytes) bytes"
                ))
                return OperationCompile(route: nil, fixtures: [], preview: emptyPreview(methodUpper, path, operationID), unsupported: unsupported)
            }
        }

        guard !compiledFixtures.isEmpty else {
            if unsupported.isEmpty {
                unsupported.append(OpenAPIMockUnsupportedItem(method: methodUpper, template: path, feature: .eventStream, detail: "no supported JSON response"))
            }
            return OperationCompile(route: nil, fixtures: [], preview: emptyPreview(methodUpper, path, operationID), unsupported: unsupported)
        }

        let defaultID: String
        switch OpenAPIMockResponseSelector.select(candidates: successCandidates) {
        case .selected(let variant):
            defaultID = variant.id
        case .unsupported:
            defaultID = compiledFixtures.sorted { $0.variant.id < $1.variant.id }[0].variant.id
        }

        var variantIDs = compiledFixtures.map(\.variant.id).sorted()
        if let index = variantIDs.firstIndex(of: defaultID) {
            variantIDs.remove(at: index)
            variantIDs.insert(defaultID, at: 0)
        }

        let route = OpenAPIMockRoute(
            id: "\(methodUpper) \(template.rawValue)",
            origin: origin,
            method: methodUpper,
            pathTemplate: template,
            queryConstraints: query,
            requestContentType: requestType,
            variantIDs: variantIDs
        )
        let generatedCount = compiledFixtures.filter { $0.variant.sourceKind == .synthetic }.count
        let declaredCount = compiledFixtures.filter {
            $0.variant.sourceKind == .declaredExample || $0.variant.sourceKind == .namedError
        }.count
        let preview = OpenAPIMockOperationPreview(
            method: methodUpper,
            template: template.rawValue,
            operationID: operationID,
            variantCount: compiledFixtures.count,
            defaultVariantID: defaultID,
            generatedVariantCount: generatedCount,
            declaredExampleCount: declaredCount
        )
        return OperationCompile(route: route, fixtures: compiledFixtures, preview: preview, unsupported: unsupported)
    }

    private struct MediaCompile {
        var fixtures: [OpenAPIMockCompiledFixture]
        var unsupported: [OpenAPIMockUnsupportedItem]
    }

    private static func compileMedia(
        status: Int,
        contentType: String,
        media: [String: Any],
        method: String,
        template: String,
        packID: OpenAPIMockPackID,
        resolver: OpenAPIMockRefResolver
    ) -> MediaCompile {
        var unsupported: [OpenAPIMockUnsupportedItem] = []
        var fixtures: [OpenAPIMockCompiledFixture] = []
        let schema = media["schema"] as? [String: Any]
        var resolvedSchema: [String: Any]?
        if let schema {
            do {
                var stack: [String] = []
                resolvedSchema = try resolver.resolveSchema(schema, stack: &stack)
            } catch {
                let compilerError = Self.asCompilerError(error)
                unsupported.append(OpenAPIMockUnsupportedItem(method: method, template: template, feature: feature(for: compilerError), detail: compilerError.localizedDescription))
            }
        }

        var candidates: [(kind: OpenAPIMockResponseSourceKind, name: String?, json: OpenAPIMockJSONValue)] = []

        if let examples = media["examples"] as? [String: Any] {
            for name in examples.keys.sorted() {
                guard let json = exampleJSON(examples[name], resolver: resolver) else { continue }
                let kind: OpenAPIMockResponseSourceKind = status >= 400 ? .namedError : .declaredExample
                candidates.append((kind, name, json))
            }
        }
        if let example = media["example"], let json = OpenAPIMockJSONValue.fromAny(example) {
            let kind: OpenAPIMockResponseSourceKind = status >= 400 ? .namedError : .declaredExample
            let name = status >= 400 ? errorName(json, fallback: "status-\(status)") : nil
            candidates.append((kind, name, json))
        }

        if candidates.isEmpty, let resolvedSchema {
            let schemaTags = OpenAPIMockSchemaSupport.classify(OpenAPIMockSchemaWalker.tags(in: resolvedSchema))
            if schemaTags.unsupported.isEmpty {
                if let example = resolvedSchema["example"], let json = OpenAPIMockJSONValue.fromAny(example) {
                    candidates.append((.schemaExample, nil, json))
                } else if let defaultValue = resolvedSchema["default"], let json = OpenAPIMockJSONValue.fromAny(defaultValue) {
                    candidates.append((.schemaDefault, nil, json))
                } else if let enums = resolvedSchema["enum"] as? [Any], !enums.isEmpty {
                    let named = enums.compactMap { item -> (String, OpenAPIMockJSONValue)? in
                        guard let json = OpenAPIMockJSONValue.fromAny(item) else { return nil }
                        return (stableJSONName(json), json)
                    }.sorted { $0.0 < $1.0 }
                    if let first = named.first {
                        candidates.append((.schemaEnum, first.0, first.1))
                    }
                } else {
                    let seed = OpenAPIMockResponseSelector.seedMaterial(
                        packID: packID,
                        method: method,
                        template: template,
                        status: status,
                        contentType: contentType,
                        variantName: nil
                    )
                    do {
                        let json = try OpenAPIMockFixtureSynthesizer.generate(
                            schema: resolvedSchema,
                            seed: seed,
                            pointer: "#",
                            resolver: resolver
                        )
                        candidates.append((.synthetic, nil, json))
                    } catch {
                        let compilerError = Self.asCompilerError(error)
                        unsupported.append(OpenAPIMockUnsupportedItem(method: method, template: template, feature: feature(for: compilerError), detail: compilerError.localizedDescription))
                    }
                }
            } else {
                for tag in schemaTags.unsupported {
                    unsupported.append(OpenAPIMockUnsupportedItem(method: method, template: template, feature: tag, detail: "schema is not in the v1 subset"))
                }
            }
        }

        for candidate in candidates {
            if let resolvedSchema {
                do {
                    try OpenAPIMockFixtureSynthesizer.validate(candidate.json, schema: resolvedSchema, resolver: resolver)
                } catch {
                    unsupported.append(OpenAPIMockUnsupportedItem(
                        method: method, template: template, feature: .object,
                        detail: "example failed schema validation and was skipped"
                    ))
                    continue
                }
            }
            do {
                let body = try candidate.json.encodedData()
                let digest = OpenAPIMockJSONValue.sha256Hex(body)
                let variantID = variantIdentifier(
                    method: method, template: template, status: status, contentType: contentType, name: candidate.name
                )
                let variant = OpenAPIMockResponseVariant(
                    id: variantID,
                    status: status,
                    contentType: contentType,
                    sourceKind: candidate.kind,
                    name: candidate.name,
                    bodyDigest: digest
                )
                fixtures.append(
                    OpenAPIMockCompiledFixture(
                        variant: variant,
                        status: status,
                        headers: ["Content-Type": contentType],
                        body: body
                    )
                )
            } catch {
                unsupported.append(OpenAPIMockUnsupportedItem(method: method, template: template, feature: .object, detail: "fixture JSON could not be encoded"))
            }
        }

        return MediaCompile(fixtures: fixtures, unsupported: unsupported)
    }

    private static func exampleJSON(_ raw: Any?, resolver: OpenAPIMockRefResolver) -> OpenAPIMockJSONValue? {
        guard let raw else { return nil }
        var stack: [String] = []
        let resolved = (try? resolver.resolveNode(raw, stack: &stack)) ?? raw
        if let dictionary = resolved as? [String: Any] {
            if let value = dictionary["value"] {
                return OpenAPIMockJSONValue.fromAny(value)
            }
            if dictionary["$ref"] == nil {
                return OpenAPIMockJSONValue.fromAny(dictionary)
            }
        }
        return OpenAPIMockJSONValue.fromAny(resolved)
    }

    private static func queryConstraints(
        pathItem: [String: Any],
        operation: [String: Any],
        resolver: OpenAPIMockRefResolver
    ) throws -> [OpenAPIMockQueryConstraint] {
        var merged: [String: [String: Any]] = [:]
        for list in [pathItem["parameters"], operation["parameters"]] {
            guard let items = list as? [Any] else { continue }
            for item in items {
                var stack: [String] = []
                let resolvedAny = try resolver.resolveNode(item, stack: &stack)
                guard let parameter = resolvedAny as? [String: Any],
                      let name = parameter["name"] as? String,
                      let location = parameter["in"] as? String else { continue }
                merged["\(location):\(name)"] = parameter
            }
        }
        return merged.values.compactMap { parameter -> OpenAPIMockQueryConstraint? in
            guard parameter["in"] as? String == "query", let name = parameter["name"] as? String else {
                return nil
            }
            let required = parameter["required"] as? Bool ?? false
            var allowed: [String]?
            if let schema = parameter["schema"] as? [String: Any] {
                var stack: [String] = []
                let resolved = (try? resolver.resolveSchema(schema, stack: &stack)) ?? schema
                if let enums = resolved["enum"] as? [Any] {
                    allowed = enums.compactMap { $0 as? String }.sorted()
                }
            }
            return OpenAPIMockQueryConstraint(name: name, isRequired: required, allowedValues: allowed)
        }
        .sorted { $0.name < $1.name }
    }

    private static func requestContentType(operation: [String: Any], resolver: OpenAPIMockRefResolver) -> String? {
        guard let rawBody = operation["requestBody"] else { return nil }
        var stack: [String] = []
        guard let body = (try? resolver.resolveNode(rawBody, stack: &stack)) as? [String: Any],
              let content = body["content"] as? [String: Any] else { return nil }
        let jsonTypes = content.keys.map(OpenAPIMockRouteMatcher.contentTypeEssence).filter(isJSONMediaType).sorted()
        return jsonTypes.first
    }

    private static func detectConflicts(_ routes: [OpenAPIMockRoute]) -> [String] {
        var conflicts: [String] = []
        for index in routes.indices {
            for other in (index + 1)..<routes.count {
                let left = routes[index]
                let right = routes[other]
                guard left.method == right.method, left.origin == right.origin else { continue }
                guard templatesCanCoMatch(left.pathTemplate, right.pathTemplate) else { continue }
                if precedence(left) == precedence(right) {
                    conflicts.append("\(left.method) \(left.pathTemplate.rawValue) ties \(right.pathTemplate.rawValue)")
                }
            }
        }
        return conflicts
    }

    private static func templatesCanCoMatch(_ left: OpenAPIMockPathTemplate, _ right: OpenAPIMockPathTemplate) -> Bool {
        guard left.segmentCount == right.segmentCount else { return false }
        for (lhs, rhs) in zip(left.segments, right.segments) {
            if case .literal(let a) = lhs, case .literal(let b) = rhs, a != b {
                return false
            }
        }
        return true
    }

    private static func precedence(_ route: OpenAPIMockRoute) -> (Int, Int, Int, Int) {
        (
            route.pathTemplate.literalSegmentCount,
            route.pathTemplate.segmentCount,
            route.queryConstraints.count,
            route.requestContentType == nil ? 0 : 1
        )
    }

    private static func resolveOrigin(root: [String: Any], override: OpenAPIMockOrigin?) throws -> OpenAPIMockOrigin {
        if let override { return override }
        guard let servers = root["servers"] as? [[String: Any]],
              let urlString = servers.first?["url"] as? String,
              let url = URL(string: urlString),
              let host = url.host,
              let schemeRaw = url.scheme,
              let scheme = SessionScheme(rawValue: schemeRaw.lowercased())
        else {
            throw OpenAPIMockCompilerError.missingOrigin
        }
        return OpenAPIMockOrigin(scheme: scheme, host: host, port: url.port)
    }

    private static func validateVersion(_ root: [String: Any]) throws {
        if let swagger = root["swagger"] as? String {
            throw OpenAPIMockCompilerError.unsupportedVersion(swagger)
        }
        guard let version = root["openapi"] as? String else {
            throw OpenAPIMockCompilerError.unsupportedVersion("missing")
        }
        if version.hasPrefix("3.1") {
            throw OpenAPIMockCompilerError.unsupportedVersion(version)
        }
        guard version.hasPrefix("3.0") else {
            throw OpenAPIMockCompilerError.unsupportedVersion(version)
        }
    }

    private static func validateDocumentBytes(_ data: Data) throws {
        do {
            try OpenAPIMockPackBudget.validateDocumentBytes(data.count)
        } catch let error as OpenAPIMockPackError {
            throw OpenAPIMockCompilerError.pack(error)
        }
    }

    private static func rejectYAML(_ data: Data) throws {
        let prefix = String(data: data.prefix(96), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if prefix.hasPrefix("---") || prefix.hasPrefix("openapi:") || prefix.hasPrefix("swagger:") {
            throw OpenAPIMockCompilerError.yamlDocument
        }
    }

    private static func parseJSONObject(_ data: Data) throws -> [String: Any] {
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any] else {
                throw OpenAPIMockCompilerError.malformedJSON("top-level value must be an object")
            }
            return dictionary
        } catch let error as OpenAPIMockCompilerError {
            throw error
        } catch {
            throw OpenAPIMockCompilerError.malformedJSON(error.localizedDescription)
        }
    }

    private static func isJSONMediaType(_ essence: String) -> Bool {
        essence == "application/json" || essence.hasSuffix("+json")
    }

    private static func errorName(_ json: OpenAPIMockJSONValue, fallback: String) -> String {
        if case .object(let object) = json, case .string(let error) = object["error"] {
            return error
        }
        return fallback
    }

    private static func variantIdentifier(
        method: String,
        template: String,
        status: Int,
        contentType: String,
        name: String?
    ) -> String {
        "\(method)|\(template)|\(status)|\(contentType)|\(name ?? "_")"
    }

    private static func stableJSONName(_ value: OpenAPIMockJSONValue) -> String {
        (try? String(data: value.encodedData(), encoding: .utf8)) ?? ""
    }

    private static func emptyPreview(_ method: String, _ path: String, _ operationID: String?) -> OpenAPIMockOperationPreview {
        OpenAPIMockOperationPreview(
            method: method,
            template: path,
            operationID: operationID,
            variantCount: 0,
            defaultVariantID: "",
            generatedVariantCount: 0,
            declaredExampleCount: 0
        )
    }

    private static func asCompilerError(_ error: Error) -> OpenAPIMockCompilerError {
        if let compilerError = error as? OpenAPIMockCompilerError {
            return compilerError
        }
        if let packError = error as? OpenAPIMockPackError {
            return .pack(packError)
        }
        return .malformedJSON(error.localizedDescription)
    }

    private static func feature(for error: OpenAPIMockCompilerError) -> OpenAPIMockFeatureTag {
        switch error {
        case .remoteRef: return .remoteRef
        case .refCycle, .refNotFound: return .remoteRef
        case .pack(.refDepthExceeded): return .remoteRef
        case .yamlDocument: return .yaml
        case .unsupportedVersion(let version) where version.hasPrefix("2"): return .openAPI2
        case .unsupportedVersion(let version) where version.hasPrefix("3.1"): return .openAPI31
        case .unsupportedSchema(let tags): return tags.sorted { $0.rawValue < $1.rawValue }.first ?? .openAPI31
        default: return .openAPI31
        }
    }
}
