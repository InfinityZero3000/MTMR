import XCTest

class ParseConfig: XCTestCase {
    func testButtonNoAction() {
        let buttonNoActionFixture = """
            [  { "type": "staticButton",  "title": "Pew" } ]
        """.data(using: .utf8)!
        let result = try? JSONDecoder().decode([BarItemDefinition].self, from: buttonNoActionFixture)
        guard case .staticButton("Pew")? = result?.first?.type else {
            XCTFail()
            return
        }
        guard result?.first?.actions.count == 0 else {
            XCTFail()
            return
        }
    }

    func testButtonKeyCodeAction() {
        let buttonKeycodeFixture = """
            [  { "type": "staticButton",  "title": "Pew", "actions": [ { "trigger": "singleTap", "action": "hidKey", "keycode": 123 } ] } ]
        """.data(using: .utf8)!
        let result = try? JSONDecoder().decode([BarItemDefinition].self, from: buttonKeycodeFixture)
        guard case .staticButton("Pew")? = result?.first?.type else {
            XCTFail()
            return
        }
        guard case .hidKey(keycode: 123)? = result?.first?.actions.filter({ $0.trigger == .singleTap }).first?.value else {
            XCTFail()
            return
        }
    }
    
    func testButtonKeyCodeLegacyAction() {
        let buttonKeycodeFixture = """
            [  { "type": "staticButton",  "title": "Pew", "action": "hidKey", "keycode": 123 } ]
        """.data(using: .utf8)!
        let result = try? JSONDecoder().decode([BarItemDefinition].self, from: buttonKeycodeFixture)
        guard case .staticButton("Pew")? = result?.first?.type else {
            XCTFail()
            return
        }
        guard case .hidKey(keycode: 123)? = result?.first?.legacyAction else {
            XCTFail()
            return
        }
    }

    func testPredefinedItem() {
        let buttonKeycodeFixture = """
            [  { "type": "escape" } ]
        """.data(using: .utf8)!
        let result = try? JSONDecoder().decode([BarItemDefinition].self, from: buttonKeycodeFixture)
        guard case .staticButton("esc")? = result?.first?.type else {
            XCTFail()
            return
        }
        guard case .keyPress(keycode: 53)? = result?.first?.actions.filter({ $0.trigger == .singleTap }).first?.value else {
            XCTFail()
            return
        }
    }

    func testCodexItemsAndKeyCombo() {
        let fixture = """
            [
              {
                "type": "staticButton",
                "title": "",
                "image": { "systemName": "bubble.left.and.bubble.right" },
                "action": "keyCombo",
                "keycode": 45,
                "modifiers": ["command", "option"]
              },
              { "type": "codexToday", "refreshInterval": 20 },
              { "type": "codexQuota", "refreshInterval": 30 }
            ]
        """.data(using: .utf8)!

        let result = try? JSONDecoder().decode([BarItemDefinition].self, from: fixture)
        XCTAssertEqual(result?.count, 3)

        guard case let .keyCombo(keycode, modifiers)? = result?.first?.legacyAction else {
            return XCTFail("Expected keyCombo action")
        }
        XCTAssertEqual(keycode, 45)
        XCTAssertEqual(modifiers, ["command", "option"])
        guard case let .image(source)? = result?.first?.additionalParameters[.image] else {
            return XCTFail("Expected SF Symbol image source")
        }
        XCTAssertNotNil(source.image)

        guard case .codexToday(refreshInterval: 20)? = result?[1].type else {
            return XCTFail("Expected codexToday item")
        }
        guard case .codexQuota(refreshInterval: 30)? = result?[2].type else {
            return XCTFail("Expected codexQuota item")
        }
    }

    func testCodexItemsDefaultToTenSecondRefresh() throws {
        let fixture = """
            [
              { "type": "codexToday" },
              { "type": "codexQuota" }
            ]
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode([BarItemDefinition].self, from: fixture)
        guard case .codexToday(refreshInterval: 10) = result[0].type else {
            return XCTFail("Expected a 10-second codexToday default")
        }
        guard case .codexQuota(refreshInterval: 10) = result[1].type else {
            return XCTFail("Expected a 10-second codexQuota default")
        }
    }

    func testExtendedWidthForPredefinedItem() {
        let buttonKeycodeFixture = """
            [  { "type": "escape", "width": 110}, ]
        """.data(using: .utf8)!
        let result = try? JSONDecoder().decode([BarItemDefinition].self, from: buttonKeycodeFixture)
        guard case .staticButton("esc")? = result?.first?.type else {
            XCTFail()
            return
        }
        guard case .keyPress(keycode: 53)? = result?.first?.actions.filter({ $0.trigger == .singleTap }).first?.value else {
            XCTFail()
            return
        }
        guard case .width(110)? = result?.first?.additionalParameters[.width] else {
            XCTFail()
            return
        }
    }

    func testSpotifyItemAndLRC() {
        let fixture = #"[ { "type": "spotify", "mode": "lyrics" }, { "type": "spotify" } ]"#.data(using: .utf8)!
        let result = try? JSONDecoder().decode([BarItemDefinition].self, from: fixture)
        guard case let .spotify(mode, _, _, _)? = result?.first?.type, case let .spotify(defaultMode, reactive, offset, style)? = result?.last?.type else {
            return XCTFail("Expected spotify items")
        }
        XCTAssertEqual(mode, "lyrics")
        XCTAssertEqual(defaultMode, "both")
        XCTAssertTrue(reactive)
        XCTAssertEqual(offset, 0)
        XCTAssertEqual(style, SpotifyStyle())

        let lines = LRCParser.parse("[ar:x]\n[00:01.50] one\n[00:05.00][00:09.25]two\n[00:12.00]")
        XCTAssertEqual(lines.map { $0.text }, ["one", "two", "two", ""])
        XCTAssertNil(LRCParser.index(in: lines, at: 0.5))
        XCTAssertEqual(LRCParser.index(in: lines, at: 6), 1)
        XCTAssertEqual(LRCParser.index(in: lines, at: 100), 3)

        // [offset:+500] makes every line appear 0.5 s sooner.
        XCTAssertEqual(LRCParser.parse("[offset:+500]\n[00:10.00]a").first?.time ?? 0, 9.5, accuracy: 0.001)

        // The version whose length matches the track wins; a far-off version is rejected.
        let results: [[String: Any]] = [["duration": 250.0, "syncedLyrics": "[00:01.00]radio edit"], ["duration": 301.0, "syncedLyrics": "[00:01.00]album"]]
        XCTAssertEqual(LyricsProvider.bestLyrics(results, duration: 300, tolerance: 3), "[00:01.00]album")
        XCTAssertNil(LyricsProvider.bestLyrics(results, duration: 400, tolerance: 6))
    }
}
