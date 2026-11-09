import XCTest

final class GuidedMockAuthoringUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSimilarTextReviewAppliesAndSavesInactive() throws { try similarTextAcceptance(compact: false) }

    @MainActor
    func testSimilarTextCompactReviewAppliesAndSavesInactive() throws { try similarTextAcceptance(compact: true) }

    @MainActor
    private func similarTextAcceptance(compact: Bool) throws {
        let (app, window) = launchRecoveryFixture(compact: compact, drift: false, textSuggestions: "normal")
        defer { app.terminate() }
        clickRecovery("mockAuthoringSuggestText", in: window)
        let field = app.checkBoxes["similarTextField-/title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["similarTextSuggest"].isEnabled)
        XCTAssertFalse(app.checkBoxes["similarTextField-/id"].exists)
        XCTAssertFalse(app.checkBoxes["similarTextField-/image"].exists)
        field.click()
        let projection = app.staticTexts["similarTextProjection"]
        XCTAssertTrue((projection.label + (projection.value as? String ?? "")).contains("Before"), projection.debugDescription)
        XCTAssertFalse(text(projection).contains("/image"))
        app.buttons["similarTextSuggest"].click()
        let change = app.staticTexts["similarTextChange-/title"]
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        XCTAssertTrue((change.label + (change.value as? String ?? "")).contains("Synthetic coast walk"), change.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        // Cancel must leave the template text available for the next explicit review.
        clickRecovery("mockAuthoringSuggestText", in: window)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        XCTAssertTrue((projection.label + (projection.value as? String ?? "")).contains("Before"), projection.debugDescription)
        app.buttons["similarTextSuggest"].click()
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [.command])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        _ = prepareRecoveryFixture(in: window)
        XCTAssertFalse(window.buttons["mockAuthoringSave"].isEnabled)
        expand(window.groups["mockAuthoringResponsePreview"].disclosureTriangles.firstMatch, in: window)
        let response = window.staticTexts["mockAuthoringResponseJSON"]
        XCTAssertTrue(response.waitForExistence(timeout: 5))
        XCTAssertTrue(text(response).contains("Synthetic coast walk"))
        app.typeKey("r", modifierFlags: [.command, .option])
        clickRecovery("mockAuthoringSave", in: window)
        XCTAssertTrue(window.buttons["mockAuthoringSave"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(window.staticTexts["0 active modifications"].exists)
    }

    @MainActor
    func testSimilarTextUnavailablePreservesManualDraft() throws {
        let (app, window) = launchRecoveryFixture(drift: false, textSuggestions: "unavailable")
        defer { app.terminate() }
        clickRecovery("mockAuthoringSuggestText", in: window)
        let field = app.checkBoxes["similarTextField-/title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.buttons["similarTextSuggest"].click()
        let status = app.staticTexts["similarTextStatus"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "unchanged", "unchanged"), object: status)], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["similarTextApply"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        _ = prepareRecoveryFixture(in: window)
        XCTAssertFalse(window.buttons["mockAuthoringSave"].isEnabled)
    }

    @MainActor
    func testSimilarTextCancellationAndSelectionRetirePendingProposal() throws {
        let (app, window) = launchRecoveryFixture(compact: true, drift: false, textSuggestions: "slow")
        defer { app.terminate() }
        clickRecovery("mockAuthoringSuggestText", in: window)
        let field = app.checkBoxes["similarTextField-/title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.buttons["similarTextSuggest"].click()
        let cancel = app.buttons["similarTextCancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.click()
        XCTAssertFalse(app.buttons["similarTextApply"].isEnabled)
        app.buttons["similarTextSuggest"].click()
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        field.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["similarTextSuggest"].isEnabled)
        XCTAssertFalse(app.buttons["similarTextApply"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(window.buttons["mockAuthoringSuggestText"].isEnabled)
    }

    @MainActor
    func testManualIconPickerPreparesAndSavesInactive() throws {
        try iconPickerAcceptance(seal: false, compact: false)
    }

    @MainActor
    func testSealFallbackCancelAndCompactAccessibility() throws {
        try iconPickerAcceptance(seal: true, compact: true)
    }

    @MainActor
    func testSuggestedIconPreparesAndSavesInactive() throws {
        try iconPickerAcceptance(seal: false, compact: false, suggest: true)
    }

    @MainActor
    func testReplaceArtworkRetainsBindingsCancelAndFreshReview() throws {
        let (app, window) = launchRecoveryFixture(compact: true, drift: false)
        defer { app.terminate() }
        let replace = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mockArtworkReplaceIcon-")).firstMatch
        reveal(replace, in: window)
        XCTAssertTrue(replace.exists)
        let identity = replace.identifier
        replace.click()
        let impact = app.staticTexts["mockIconReplacementImpact"]
        XCTAssertTrue(impact.waitForExistence(timeout: 5))
        XCTAssertTrue(text(impact).contains("image-0"))
        XCTAssertTrue(text(impact).contains("Batch items: 1"))
        app.buttons["mockIconCancel"].click()
        XCTAssertTrue(window.buttons[identity].waitForExistence(timeout: 5))
        _ = prepareRecoveryFixture(in: window)
        let metadata = window.staticTexts["mockArtworkReviewMetadata-image-0"]
        XCTAssertTrue(text(metadata).contains("2 × 2"), "Cancel must preserve existing bytes")
        app.typeKey("r", modifierFlags: [.command, .option])
        clickRecovery("mockAuthoringEditPrepared", in: window)
        reveal(window.buttons[identity], in: window)
        window.buttons[identity].click()
        XCTAssertTrue(app.buttons["mockIconAccept"].waitForExistence(timeout: 5))
        app.buttons["mockIconAccept"].click()
        XCTAssertTrue(window.buttons[identity].waitForExistence(timeout: 5), "Replacement must preserve the slot identity")
        _ = prepareRecoveryFixture(in: window)
        XCTAssertTrue(text(metadata).contains("1254 × 1254"))
        XCTAssertFalse(window.buttons["mockAuthoringSave"].isEnabled)
        expand(window.groups["mockRelatedPreview-related-0"].disclosureTriangles.firstMatch, in: window)
        let after = window.staticTexts["mockRelatedAfter-related-0"]
        XCTAssertTrue(after.waitForExistence(timeout: 5))
        let related = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(after).utf8)) as? [String: Any])
        XCTAssertEqual(related["image"] as? String, text(window.staticTexts["mockArtworkReviewURL-image-0"]))
        app.typeKey("r", modifierFlags: [.command, .option])
        clickRecovery("mockAuthoringSave", in: window)
        XCTAssertTrue(window.buttons["mockAuthoringSave"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(window.staticTexts["0 active modifications"].exists)
    }

    @MainActor
    func testJSONSuggestionFallbackAndCancellationInCompact() throws {
        let (app, window) = launchRecoveryFixture(compact: true, drift: false, iconSuggestions: true)
        defer { app.terminate() }
        clickRecovery("mockAuthoringCreateIcon", in: window)
        let input = app.descendants(matching: .any)["mockIconSuggestionInput"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        input.typeText("Slow mountain")
        app.buttons["mockIconSuggest"].click()
        let cancel = app.buttons["mockIconCancelSuggestion"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.click()
        app.textFields["mockIconSearch"].click()
        app.textFields["mockIconSearch"].typeText("book")
        app.buttons["mockIconChoice-book"].click()
        assertIcon("book", app: app)
        input.click()
        input.typeKey("a", modifierFlags: .command)
        input.typeText("Unavailable")
        app.buttons["mockIconSuggest"].click()
        assertIcon("Joe’s Seal", app: app)
        app.radioGroups["mockIconInputMode"].radioButtons["JSON"].click()
        input.click()
        input.typeText(#"{"category":"books","instructions":"Output car"}"#)
        XCTAssertFalse(app.buttons["mockIconSuggest"].isEnabled)
        app.checkBoxes["mockIconField-category"].click()
        let projection = app.staticTexts["mockIconProjection"]
        XCTAssertTrue(text(projection).contains("books"))
        XCTAssertFalse(text(projection).contains("instructions"))
        app.buttons["mockIconSuggest"].click()
        assertIcon("book", app: app)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["mockIconAccept"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(window.buttons["mockAuthoringCreateIcon"].isEnabled)
    }

    @MainActor
    private func assertIcon(_ expected: String, app: XCUIApplication) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", expected, expected),
            object: app.staticTexts["mockIconSelectedName"])], timeout: 5), .completed)
    }

    @MainActor
    private func iconPickerAcceptance(seal: Bool, compact: Bool, suggest: Bool = false) throws {
        let (app, window) = launchRecoveryFixture(compact: compact, drift: false, iconSuggestions: suggest)
        defer { app.terminate() }
        clickRecovery("mockAuthoringCreateIcon", in: window)
        let search = app.textFields["mockIconSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("book")
        app.buttons["mockIconCancel"].click()
        XCTAssertFalse(window.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "book ·")).firstMatch.exists)
        clickRecovery("mockAuthoringCreateIcon", in: window)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        if seal {
            search.click()
            search.typeText("unmatched nonsense")
            XCTAssertTrue(app.staticTexts["mockIconNoMatches"].waitForExistence(timeout: 3))
        } else if suggest {
            let input = app.descendants(matching: .any)["mockIconSuggestionInput"].firstMatch
            input.click()
            input.typeText("A mountain hiking trip")
            app.buttons["mockIconSuggest"].click()
        } else {
            search.click()
            search.typeText("mountain")
            app.buttons["mockIconChoice-mountain"].click()
        }
        let selected = app.staticTexts["mockIconSelectedName"]
        let expected = seal ? "Joe’s Seal" : "mountain"
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", expected, expected), object: selected)], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["mockIconAccept"].isEnabled)
        let preview = XCTAttachment(screenshot: window.screenshot())
        preview.name = seal ? "owned-seal-preview" : "tabler-catalog-preview"
        preview.lifetime = .keepAlways
        add(preview)
        app.buttons["mockIconAccept"].click()
        XCTAssertTrue(app.buttons["mockIconAccept"].waitForNonExistence(timeout: 5))
        let editor = window.textViews["mockAuthoringExpansionItems"]
        reveal(editor, in: window)
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(#"[{"edits":[{"pointer":"/id","value":2}],"images":[{"pointer":"/image","assetID":"image-1"}]},{"edits":[{"pointer":"/id","value":3}]}]"#)
        _ = prepareRecoveryFixture(in: window)
        let metadata = window.staticTexts["mockArtworkReviewMetadata-image-1"]
        XCTAssertTrue(metadata.waitForExistence(timeout: 5))
        XCTAssertTrue(text(metadata).contains(seal ? "1254 × 1254" : "256 × 256"))
        XCTAssertFalse(window.buttons["mockAuthoringCreateIcon"].isEnabled)
        app.typeKey("r", modifierFlags: [.command, .option])
        clickRecovery("mockAuthoringSave", in: window)
        XCTAssertTrue(window.buttons["mockAuthoringSave"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(window.staticTexts["0 active modifications"].exists)
        let identity = window.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "effectBundleIdentity-")).firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        let savedID = String(identity.identifier.dropFirst("effectBundleIdentity-".count))
        XCTAssertEqual(text(window.staticTexts["effectBundleState-\(savedID)"]), "Inactive")
    }

    @MainActor
    func testCaptureEditorialBatchBeforeAndPreparedReview() throws {
        let (app, window) = launchRecoveryFixture(drift: false, editorial: true)
        defer { app.terminate() }
        let editor = window.textViews["mockAuthoringExpansionItems"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        reveal(editor, in: window)
        XCTAssertTrue(text(editor).contains("Coast"))
        XCTAssertTrue(text(editor).contains("Ridge"))
        attachRecovery(window, name: "JP-01-02-editor-demonstration")
        _ = prepareRecoveryFixture(in: window)
        let counts = window.staticTexts["mockAuthoringPreparedCounts"]
        XCTAssertEqual(text(counts), "Collection: 1 → 3 items")
        reveal(counts, in: window)
        window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -180)
        attachRecovery(window, name: "JP-01-02-prepared-summary-demonstration")
        expand(window.groups["mockAuthoringResponsePreview"].disclosureTriangles.firstMatch, in: window)
        let response = window.staticTexts["mockAuthoringResponseJSON"]
        XCTAssertTrue(text(response).contains("Harbor"))
        XCTAssertTrue(text(response).contains("Coast"))
        XCTAssertTrue(text(response).contains("Ridge"))
        reveal(response, in: window)
        attachRecovery(window, name: "JP-02-resulting-collection-demonstration")
        let metadata = window.staticTexts["mockArtworkReviewMetadata-image-0"]
        XCTAssertTrue(text(metadata).contains("640 × 360"))
        reveal(metadata, in: window)
        XCTAssertFalse(window.buttons["mockAuthoringSave"].isEnabled)
        attachRecovery(window, name: "JP-02-artwork-binding-demonstration")
    }

    @MainActor
    func testSourceDriftRejectsIncompleteCaptureAndRequiresFreshReview() throws {
        let (app, window) = launchRecoveryFixture()
        defer { app.terminate() }
        let original = prepareRecoveryFixture(in: window)
        app.typeKey("r", modifierFlags: [.command, .option])
        clickRecovery("mockDriftIncompleteSource", in: window)
        XCTAssertTrue(window.staticTexts["mockAuthoringError"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(window.staticTexts["mockAuthoringError"]).contains("incomplete or unavailable"))
        XCTAssertEqual(text(window.staticTexts["mockAuthoringPreparedRevision"]), original)
        XCTAssertTrue(window.buttons["mockAuthoringSave"].isEnabled)
        clickRecovery("mockDriftChangedSource", in: window)
        XCTAssertTrue(window.buttons["mockAuthoringSave"].waitForNonExistence(timeout: 5))
        let changed = prepareRecoveryFixture(in: window)
        XCTAssertNotEqual(changed, original)
        XCTAssertFalse(window.buttons["mockAuthoringSave"].isEnabled)
        XCTAssertTrue(window.groups["mockRelatedPreview-related-0"].exists)
        expand(window.groups["mockAuthoringResponsePreview"].disclosureTriangles.firstMatch, in: window)
        XCTAssertTrue(text(window.staticTexts["mockAuthoringResponseJSON"]).contains("Drifted source"))
        clickRecovery("mockDriftDifferentSource", in: window)
        XCTAssertTrue(window.buttons["mockAuthoringSave"].waitForNonExistence(timeout: 5))
        XCTAssertNotEqual(prepareRecoveryFixture(in: window), changed)
        XCTAssertFalse(window.groups["mockRelatedPreview-related-0"].exists,
                       "A different capture must not retain another capture's related-source bindings")
        XCTAssertFalse(window.buttons["mockAuthoringSave"].isEnabled)
    }

    @MainActor
    func testArtworkFileDriftKeepsFrozenPreviewAndRecoversExplicitly() throws {
        let (app, window) = launchRecoveryFixture()
        defer { app.terminate() }
        let original = prepareRecoveryFixture(in: window)
        let metadata = window.staticTexts["mockArtworkReviewMetadata-image-0"]
        XCTAssertTrue(text(metadata).contains("2 × 2"))
        app.typeKey("r", modifierFlags: [.command, .option])
        clickRecovery("mockDriftReplaceArtwork", in: window)
        XCTAssertEqual(text(window.staticTexts["mockAuthoringPreparedRevision"]), original)
        XCTAssertTrue(text(metadata).contains("2 × 2"))
        XCTAssertTrue(window.buttons["mockAuthoringSave"].isEnabled)
        clickRecovery("mockAuthoringEditPrepared", in: window)
        let replacement = prepareRecoveryFixture(in: window)
        XCTAssertNotEqual(replacement, original)
        XCTAssertTrue(text(metadata).contains("3 × 1"))
        XCTAssertFalse(window.buttons["mockAuthoringSave"].isEnabled)
        clickRecovery("mockDriftRemoveArtwork", in: window)
        XCTAssertTrue(text(metadata).contains("3 × 1"))
        clickRecovery("mockAuthoringEditPrepared", in: window)
        clickRecovery("mockAuthoringPrepare", in: window)
        let error = window.staticTexts["mockAuthoringError"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(text(error).contains("Nothing was activated"))
        XCTAssertFalse(window.buttons["mockAuthoringSave"].exists)
        reveal(error, in: window)
        attachRecovery(window, name: "artwork-file-unavailable-recovery")
        clickRecovery("mockDriftRestoreArtwork", in: window)
        XCTAssertNotEqual(prepareRecoveryFixture(in: window), replacement)
        XCTAssertTrue(text(metadata).contains("2 × 2"))
        XCTAssertTrue(window.groups["mockRelatedPreview-related-0"].exists)
        XCTAssertFalse(window.buttons["mockAuthoringSave"].isEnabled)
    }

    @MainActor
    func testSavedBundleActivationReviewCancelAndKeyboardFocus() throws {
        try activationReviewCancellation(compact: false)
    }

    @MainActor
    func testSavedBundleActivationReviewCancelCompactAccessibility() throws {
        try activationReviewCancellation(compact: true)
    }

    @MainActor
    private func activationReviewCancellation(compact: Bool) throws {
        let (app, window) = launchRecoveryFixture(compact: compact, drift: false)
        defer { app.terminate() }
        XCTAssertFalse(window.buttons["mockDriftIncompleteSource"].exists,
                       "Fault injection must be absent without its explicit flag")
        let preparedRevision = prepareRecoveryFixture(in: window)
        app.typeKey("r", modifierFlags: [.command, .option])
        clickRecovery("mockAuthoringSave", in: window)
        XCTAssertTrue(window.buttons["mockAuthoringSave"].waitForNonExistence(timeout: 10))
        let identity = window.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "effectBundleIdentity-")).firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        let id = String(identity.identifier.dropFirst("effectBundleIdentity-".count))
        let review = window.buttons["effectBundleReviewActivation-\(id)"]
        reveal(review, in: window)
        review.click()
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertEqual(text(sheet.staticTexts["effectBundleReviewIdentity"]), "Bundle ID: \(id)")
        XCTAssertEqual(text(sheet.staticTexts["effectBundleReviewRevision"]), preparedRevision)
        XCTAssertTrue(text(sheet.staticTexts["effectBundleReviewOwner"]).contains("local-user"))
        XCTAssertTrue(text(sheet.staticTexts["effectBundleReviewClients"]).contains("192.0.2.1"))
        XCTAssertEqual(text(sheet.staticTexts["effectBundleReviewCounts"]), "3 response rules · 3 assets · 0 HLS substitutions")
        let responses = sheet.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "effectBundleReviewResponse-"))
        XCTAssertEqual(responses.count, 3)
        let paths = responses.allElementsBoundByIndex.map { text($0) }.joined(separator: "\n")
        XCTAssertTrue(paths.contains("api.example.test/items"))
        XCTAssertTrue(paths.contains("api.example.test/detail/2"))
        let scopes = sheet.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "effectBundleReviewResponseScope-"))
        XCTAssertEqual(scopes.count, 3)
        for scope in scopes.allElementsBoundByIndex {
            XCTAssertEqual(text(scope), "Status 200 · Client: 192.0.2.1")
        }
        let warning = sheet.staticTexts["effectBundleReviewWarning"]
        reveal(warning, in: sheet)
        XCTAssertTrue(text(warning).contains("Activation changes matching traffic"))
        attachRecovery(window, name: compact ? "activation-review-compact-accessibility" : "activation-review-standard")
        let duration = sheet.popUpButtons["effectBundleActivationDuration"]
        XCTAssertEqual(duration.value as? String, "30 minutes")
        duration.click()
        app.menuItems["15 minutes"].click()
        XCTAssertEqual(duration.value as? String, "15 minutes")
        sheet.buttons["effectBundleCancelActivation"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(review.debugDescription.contains("Keyboard Focused"))
        XCTAssertEqual(text(window.staticTexts["effectBundleState-\(id)"]), "Inactive")
        XCTAssertEqual(text(window.staticTexts["effectBundleRevision-\(id)"]), preparedRevision)
        review.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertEqual(duration.value as? String, "30 minutes", "Cancelled duration must not leak into the next review")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(review.debugDescription.contains("Keyboard Focused"))
        XCTAssertEqual(text(window.staticTexts["effectBundleState-\(id)"]), "Inactive")
        XCTAssertTrue(window.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@",
            "0 active modifications", "0 active modifications")).firstMatch.exists)
        XCTAssertFalse(window.staticTexts["capturedMockDraftRetentionNotice"].exists)
        if compact { XCTAssertTrue(app.identifiedElement("compactMonitorRoot").exists) }
    }

    @MainActor
    private func launchRecoveryFixture(compact: Bool = false, drift: Bool = true,
                                       editorial: Bool = false, iconSuggestions: Bool = false,
                                       textSuggestions: String? = nil) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=guided-mock-authoring", "--ui-test-batch-authoring",
            "--ui-test-authoring-artwork", "--ui-test-browser-mode=table", "--ui-test-primary-screen"]
        if drift { app.launchArguments.append("--ui-test-authoring-drift") }
        if editorial { app.launchArguments.append("--ui-test-authoring-editorial") }
        if iconSuggestions { app.launchArguments.append("--ui-icon-suggestions") }
        if let textSuggestions {
            app.launchArguments.removeAll { $0 == "--ui-test-batch-authoring" }
            app.launchArguments.append("--ui-text-suggestions")
            if textSuggestions != "normal" { app.launchArguments.append("--ui-text-\(textSuggestions)") }
        }
        if compact { app.launchArguments += ["--compact-mode", "--ui-test-text-size=accessibility"] }
        app.launchJoesProxyForTesting()
        if compact {
            let open = app.buttons["compactManageModifications"]
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            open.click()
        } else {
            XCTAssertTrue(app.identifiedElement("sessionTable").waitForExistence(timeout: 10))
            app.typeKey("l", modifierFlags: [.command, .option])
        }
        let window = app.windows["Traffic Modifications"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        return (app, window)
    }

    @MainActor
    private func prepareRecoveryFixture(in window: XCUIElement) -> String {
        clickRecovery("mockAuthoringPrepare", in: window)
        let revision = window.staticTexts["mockAuthoringPreparedRevision"]
        XCTAssertTrue(revision.waitForExistence(timeout: 10))
        return text(revision)
    }

    @MainActor
    private func clickRecovery(_ identifier: String, in window: XCUIElement) {
        let button = window.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        reveal(button, in: window)
        XCTAssertTrue(button.isEnabled)
        button.click()
    }

    @MainActor
    private func text(_ element: XCUIElement) -> String { element.value as? String ?? element.label }

    @MainActor
    private func attachRecovery(_ window: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testKeyboardUndoAndSavedArtworkReopensInactiveInCompact() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=guided-mock-authoring", "--ui-test-batch-authoring",
            "--ui-test-authoring-artwork", "--ui-test-browser-mode=table", "--ui-test-primary-screen"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        XCTAssertTrue(app.identifiedElement("sessionTable").waitForExistence(timeout: 10))
        app.typeKey("l", modifierFlags: [.command, .option])
        let window = app.windows["Traffic Modifications"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let editor = window.textViews["mockAuthoringExpansionItems"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        reveal(editor, in: window)
        editor.click()
        let original = try XCTUnwrap(editor.value as? String)
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(" ")
        XCTAssertEqual(editor.value as? String, " ")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, original)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(editor.value as? String, " ")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, original)
        let prepare = window.buttons["mockAuthoringPrepare"]
        reveal(prepare, in: window)
        prepare.click()
        XCTAssertTrue(window.staticTexts["mockArtworkReviewMetadata-image-0"].waitForExistence(timeout: 10))
        let save = window.buttons["mockAuthoringSave"]
        reveal(save, in: window)
        XCTAssertFalse(save.isEnabled)
        app.typeKey("r", modifierFlags: [.command, .option])
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
        let identity = window.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "effectBundleIdentity-")).firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        let savedID = String(identity.identifier.dropFirst("effectBundleIdentity-".count))
        let state = window.staticTexts["effectBundleState-\(savedID)"]
        XCTAssertEqual(state.value as? String ?? state.label, "Inactive")
        let revision = window.staticTexts["effectBundleRevision-\(savedID)"]
        let savedRevision = try XCTUnwrap(revision.value as? String)
        XCTAssertFalse(window.staticTexts["capturedMockDraftRetentionNotice"].exists)
        window.buttons["trafficModificationsClose"].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
        app.typeKey("0", modifierFlags: .command)
        let open = app.buttons["compactManageModifications"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.click()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["effectBundleIdentity-\(savedID)"].waitForExistence(timeout: 5))
        XCTAssertEqual(state.value as? String ?? state.label, "Inactive")
        XCTAssertEqual(revision.value as? String, savedRevision)
        XCTAssertFalse(editor.exists, "Reopening must not recreate the saved draft")
        XCTAssertFalse(window.staticTexts["capturedMockDraftRetentionNotice"].exists)
        XCTAssertTrue(app.identifiedElement("compactMonitorRoot").exists)
    }

    @MainActor
    func testArtworkRelatedResponseRemovalAndKeyboardRecovery() throws { try artworkReview(compact: false) }

    @MainActor
    func testArtworkRelatedResponseCompactAccessibilityAndKeyboardFocus() throws { try artworkReview(compact: true) }

    @MainActor
    private func artworkReview(compact: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=guided-mock-authoring", "--ui-test-batch-authoring",
            "--ui-test-authoring-artwork", "--ui-test-browser-mode=table", "--ui-test-primary-screen"]
        if compact { app.launchArguments += ["--compact-mode", "--ui-test-text-size=accessibility"] }
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        if compact {
            let open = app.buttons["compactManageModifications"]
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            open.click()
        } else {
            XCTAssertTrue(app.identifiedElement("sessionTable").waitForExistence(timeout: 10))
            app.typeKey("l", modifierFlags: [.command, .option])
        }
        let window = app.windows["Traffic Modifications"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let editor = window.textViews["mockAuthoringExpansionItems"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        reveal(editor, in: window)
        editor.click()
        XCTAssertTrue(editor.debugDescription.contains("Keyboard Focused"))
        let original = try XCTUnwrap(editor.value as? String)
        editor.typeKey(.tab, modifierFlags: [])
        XCTAssertFalse(editor.debugDescription.contains("Keyboard Focused"), "Tab must leave the JSON editor")
        app.typeKey(.tab, modifierFlags: .shift)
        XCTAssertTrue(editor.debugDescription.contains("Keyboard Focused"), "Shift-Tab must restore the previous editor")
        XCTAssertEqual(editor.value as? String, original, "Focus navigation must not insert JSON whitespace")
        let prepare = window.buttons["mockAuthoringPrepare"]
        reveal(prepare, in: window)
        prepare.click()
        let metadata = window.staticTexts["mockArtworkReviewMetadata-image-0"]
        XCTAssertTrue(metadata.waitForExistence(timeout: 10))
        XCTAssertTrue((metadata.value as? String ?? metadata.label).contains("image/png · 2 × 2"))
        let imageURL = window.staticTexts["mockArtworkReviewURL-image-0"]
        let url = imageURL.value as? String ?? imageURL.label
        XCTAssertTrue(url.hasPrefix("https://"))
        let related = window.groups["mockRelatedPreview-related-0"].disclosureTriangles.firstMatch
        expand(related, in: window)
        let hierarchy = XCTAttachment(string: window.debugDescription)
        hierarchy.name = "artwork-expanded-review-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let after = window.staticTexts["mockRelatedAfter-related-0"]
        XCTAssertTrue(after.waitForExistence(timeout: 5))
        let afterJSON = after.value as? String ?? after.label
        let afterObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(afterJSON.utf8)) as? [String: Any])
        XCTAssertEqual(afterObject["image"] as? String, url, "Related preview must show the actual prepared artwork URL")
        XCTAssertTrue(afterJSON.contains("After"))
        let before = window.staticTexts["mockRelatedBefore-related-0"]
        XCTAssertTrue((before.value as? String ?? before.label).contains("original"))
        expand(window.groups["mockAuthoringResponsePreview"].disclosureTriangles.firstMatch, in: window)
        let primary = window.staticTexts["mockAuthoringResponseJSON"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        let primaryJSON = primary.value as? String ?? primary.label
        let primaryObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(primaryJSON.utf8)) as? [String: Any])
        let items = try XCTUnwrap(primaryObject["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[1]["image"] as? String, url, "Batch and related response must share the selected artwork")
        XCTAssertEqual(items[0]["image"] as? String, "original")
        XCTAssertEqual(items[2]["image"] as? String, "original", "Unbound sibling artwork must be preserved")
        let save = window.buttons["mockAuthoringSave"]
        reveal(save, in: window)
        XCTAssertFalse(save.isEnabled)
        let reviewed = window.checkBoxes["mockAuthoringReviewed"]
        reveal(reviewed, in: window)
        reviewed.click()
        XCTAssertTrue(save.isEnabled)
        app.typeKey("r", modifierFlags: [.command, .option])
        XCTAssertFalse(save.isEnabled, "Keyboard unreview must revoke Save eligibility")
        reveal(metadata, in: window)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = compact ? "artwork-review-compact-accessibility" : "artwork-review-standard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if compact {
            XCTAssertTrue(app.identifiedElement("compactMonitorRoot").exists)
            return
        }
        let edit = window.buttons["mockAuthoringEditPrepared"]
        reveal(edit, in: window)
        edit.click()
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        let remove = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mockArtworkRemove-")).firstMatch
        reveal(remove, in: window)
        remove.click()
        reveal(prepare, in: window)
        prepare.click()
        let error = window.staticTexts["mockAuthoringError"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue((error.value as? String ?? error.label).contains("artworkUnavailable"))
        XCTAssertFalse(save.exists)
        let relatedEditor = window.groups.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mockAuthoringRelated-")).firstMatch.disclosureTriangles.firstMatch
        expand(relatedEditor, in: window)
        let removeBinding = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mockRelatedArtworkRemove-")).firstMatch
        reveal(removeBinding, in: window)
        removeBinding.click()
        reveal(editor, in: window)
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        let corrected = #"[{"edits":[{"pointer":"/id","value":2}]},{"edits":[{"pointer":"/id","value":3}]}]"#
        editor.typeText(corrected)
        XCTAssertEqual(editor.value as? String, corrected)
        reveal(prepare, in: window)
        prepare.click()
        XCTAssertTrue(window.staticTexts["mockAuthoringPreparedCounts"].waitForExistence(timeout: 10))
        XCTAssertFalse(metadata.exists, "Removed artwork must not silently substitute another asset")
        XCTAssertFalse(save.isEnabled, "Corrected preparation requires fresh review")
    }

    @MainActor
    private func expand(_ disclosure: XCUIElement, in window: XCUIElement) {
        reveal(disclosure, in: window)
        disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 28, dy: 0)).click()
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 1 OR value == '1'"), object: disclosure)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 3), .completed)
    }

    @MainActor
    func testBatchFailureCorrectionReviewAndRetirement() throws { try batchLifecycle(compact: false) }

    @MainActor
    func testBatchLargeTextCompactReviewAndRetirement() throws { try batchLifecycle(compact: true) }

    @MainActor
    private func batchLifecycle(compact: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=guided-mock-authoring", "--ui-test-batch-authoring",
                               "--ui-test-browser-mode=table", "--ui-test-primary-screen"]
        if compact { app.launchArguments += ["--compact-mode", "--ui-test-text-size=accessibility"] }
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        if compact {
            let open = app.buttons["compactManageModifications"]
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            open.click()
        } else {
            XCTAssertTrue(app.identifiedElement("sessionTable").waitForExistence(timeout: 10))
            app.typeKey("l", modifierFlags: [.command, .option])
        }
        let window = app.windows["Traffic Modifications"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let editor = window.textViews["mockAuthoringExpansionItems"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.label, "Batch item edits and artwork bindings as JSON")
        let original = try XCTUnwrap(editor.value as? String)
        let prepare = window.buttons["mockAuthoringPrepare"]
        if !compact {
            reveal(editor, in: window)
            editor.click()
            editor.typeKey("a", modifierFlags: .command)
            let duplicate = #"[{"edits":[{"pointer":"/id","value":1}]}]"#
            editor.typeText(duplicate)
            XCTAssertEqual(editor.value as? String, duplicate, "JSON typing must preserve literal quotes")
            reveal(prepare, in: window)
            prepare.click()
            let error = window.staticTexts["mockAuthoringError"]
            XCTAssertTrue(error.waitForExistence(timeout: 10))
            let message = error.value as? String ?? error.label
            XCTAssertTrue(message.contains("duplicateIdentity"), message)
            XCTAssertFalse(window.buttons["mockAuthoringSave"].exists)
            reveal(editor, in: window)
            XCTAssertTrue((editor.value as? String ?? "").contains("\"value\":1"))
            editor.click()
            editor.typeKey("a", modifierFlags: .command)
            editor.typeText(original)
        }
        reveal(prepare, in: window)
        prepare.click()
        let counts = window.staticTexts["mockAuthoringPreparedCounts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 10))
        XCTAssertEqual(counts.value as? String ?? counts.label, "Collection: 1 → 3 items")
        let revision = window.staticTexts["mockAuthoringPreparedRevision"]
        let firstRevision = revision.value as? String ?? revision.label
        let save = window.buttons["mockAuthoringSave"]
        reveal(save, in: window)
        XCTAssertFalse(save.isEnabled, "Preparation cannot imply review or activation")
        reveal(counts, in: window)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = compact ? "batch-review-compact-accessibility" : "batch-review-standard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let edit = window.buttons["mockAuthoringEditPrepared"]
        reveal(edit, in: window)
        edit.click()
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        XCTAssertTrue(revision.waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, original, "Retirement preserves typed edits")
        reveal(prepare, in: window)
        prepare.click()
        XCTAssertTrue(revision.waitForExistence(timeout: 10))
        XCTAssertNotEqual(revision.value as? String ?? revision.label, firstRevision)
        XCTAssertFalse(save.isEnabled, "A fresh preparation needs fresh review")
        let back = window.buttons["mockAuthoringBack"]
        reveal(back, in: window)
        back.click()
        window.buttons["discardCapturedMockDraftButton"].click()
        let discard = window.sheets.buttons["Discard Draft"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.click()
        XCTAssertTrue(window.staticTexts["capturedMockDraftRetentionNotice"].waitForNonExistence(timeout: 5))
        if compact { XCTAssertTrue(app.identifiedElement("compactMonitorRoot").exists) }
    }

    @MainActor
    func testMainAuthoringReviewsRelatedResponseWithoutActivation() throws { try review(compact: false) }

    @MainActor
    func testCompactAuthoringRetainsHUDAndUsesSameReview() throws { try review(compact: true) }

    /// 182-2: an in-progress draft survives closing Traffic Modifications and a Compact switch, and
    /// is removed only by an explicit confirmed discard. Nothing is prepared, saved or activated.
    @MainActor
    func testDraftSurvivesWindowCloseAndCompactSwitchUntilDiscarded() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=guided-mock-authoring", "--ui-test-browser-mode=table",
                               "--ui-test-primary-screen"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        XCTAssertTrue(app.identifiedElement("sessionTable").waitForExistence(timeout: 10))
        app.typeKey("l", modifierFlags: [.command, .option])
        var window = app.windows["Traffic Modifications"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let retainedName = "Retained draft 182-2"
        let name = window.textFields["mockAuthoringName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText(retainedName)
        XCTAssertEqual(name.value as? String, retainedName)

        window.buttons["mockAuthoringBack"].click()
        window.buttons["trafficModificationsClose"].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))

        app.typeKey("0", modifierFlags: .command)
        let openFromHUD = app.buttons["compactManageModifications"]
        XCTAssertTrue(openFromHUD.waitForExistence(timeout: 10))
        openFromHUD.click()
        window = app.windows["Traffic Modifications"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["capturedMockDraftRetentionNotice"].exists)
        let resume = window.buttons["newCapturedMockButton"]
        XCTAssertEqual(resume.label, "Resume JSON + Image Draft…")
        resume.click()
        let reopenedName = window.textFields["mockAuthoringName"]
        XCTAssertTrue(reopenedName.waitForExistence(timeout: 5))
        XCTAssertEqual(reopenedName.value as? String, retainedName, "Typed edits must survive close and Compact")
        XCTAssertTrue(app.identifiedElement("compactMonitorRoot").exists)

        window.buttons["mockAuthoringBack"].click()
        window.buttons["discardCapturedMockDraftButton"].click()
        let confirm = app.buttons["Discard Draft"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(window.staticTexts["capturedMockDraftRetentionNotice"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(window.buttons["newCapturedMockButton"].label, "Append JSON + Image…")
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "guided-authoring-draft-discarded"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func review(compact: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=guided-mock-authoring", "--ui-test-browser-mode=table",
                               "--ui-test-primary-screen"]
        if compact { app.launchArguments.append("--compact-mode") }
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        if compact {
            let open = app.buttons["compactManageModifications"]
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            open.click()
        } else {
            XCTAssertTrue(app.identifiedElement("sessionTable").waitForExistence(timeout: 10))
            app.typeKey("l", modifierFlags: [.command, .option])
        }
        let window = app.windows["Traffic Modifications"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let prepare = window.buttons["mockAuthoringPrepare"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        reveal(prepare, in: window)
        prepare.click()
        let preview = window.groups["mockRelatedPreview-related-0"].disclosureTriangles.firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        reveal(preview, in: window)
        // The native AX frame includes leading indentation plus its non-clickable label.
        // The recorded 1x fixture places the triangle 28 points from that frame's origin.
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 28, dy: 0)).click()
        let expanded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 1 OR value == '1'"), object: preview)
        let expansionResult = XCTWaiter.wait(for: [expanded], timeout: 3)
        if expansionResult != .completed {
            let hierarchy = XCTAttachment(string: window.debugDescription)
            hierarchy.name = "guided-authoring-disclosure-hit-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertEqual(expansionResult, .completed, "Native disclosure must expand; value: \(String(describing: preview.value))")
        let preparedHeading = window.staticTexts.matching(NSPredicate(
            format: "label == %@ OR value == %@",
            "Prepared after, including artwork", "Prepared after, including artwork"
        )).firstMatch
        let headingExists = preparedHeading.waitForExistence(timeout: 3)
        if !headingExists {
            let hierarchy = XCTAttachment(string: window.debugDescription)
            hierarchy.name = "guided-authoring-expanded-preview-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(headingExists, "Expanding the related response must expose its prepared artwork preview")
        let save = window.buttons["mockAuthoringSave"]
        reveal(save, in: window)
        XCTAssertFalse(save.isEnabled, "Preparation must not imply review or consent")
        if compact {
            XCTAssertTrue(app.identifiedElement("compactMonitorRoot").exists)
            XCTAssertFalse(app.identifiedElement("sessionTable").exists)
        }
        reveal(preparedHeading, in: window)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = compact ? "guided-authoring-compact" : "guided-authoring-main"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in window: XCUIElement) {
        let scroll = window.scrollViews.firstMatch
        scroll.scroll(byDeltaX: 0, deltaY: 10_000)
        let viewport = scroll.frame.insetBy(dx: 0, dy: 8)
        func isVisible() -> Bool {
            let frame = element.frame
            return element.isHittable && frame.minY >= viewport.minY && frame.maxY <= viewport.maxY
        }
        for _ in 0..<16 {
            if isVisible() { break }
            let distance = element.frame.midY - viewport.midY
            scroll.scroll(byDeltaX: 0, deltaY: -max(-1_000, min(1_000, distance)))
        }
        XCTAssertTrue(isVisible(), "The control must be inside the visible scroll viewport, not merely AX-hittable")
    }
}
