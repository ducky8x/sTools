import Testing
@testable import NBBOverlay

/// Ninjabrain Bot 1.5.2's main window as Accessibility lists it (recorded from a real copy, empty labels and the
/// blind/divine panels trimmed where they don't matter).
private let recordedWindow: [NBBWindowParser.Item] = {
    let t = NBBWindowParser.Item.text
    var items: [NBBWindowParser.Item] = [t("Ninjabrain Bot"), t("v1.5.2"), t("Waiting for F3+C..."), t(""),
        t("Location"), t("%"), t("Dist."), t("Nether"), t("Angle"),
        t("(-1340, 84)"), t("100.0%"), t("1"), t("(-168, 10)"), t("118.30"), t(" (<- 113.7)"),
        t("(20, 308)"), t("0.0%"), t("1376"), t("(2, 38)"), t("-80.67"), t(" (-> 47.4)"),
        t("(116, 324)"), t("0.4%"), t("1474"), t("(14, 40)"), t("-80.66"), t(" (-> 47.4)"),
        t("s1"), t("s2"), t("s3"), t("Safe: "), t(""), t("Highroll: "), t(""),
        t("Location"), t("Nether"), t("Angle"), t(""), t("(-1340, 84)"), t("(-168, 10)"), t("118.3"), .button, t(""), .button,
        t("You might not be able to nether travel into the stronghold due to portal linking."),
        t("Ender eye throws"), Item(role: "AXButton", text: "Undo"), Item(role: "AXButton", text: "Redo"), Item(role: "AXButton", text: "Reset"),
        t("x"), t("z"), t("Angle"), t("Error"), .button, t(""), .button,
        t("-1374.70"), t("81.61"), t("-80.64"), t("+6"), t("-0.0022"), .button, t(""), t(""), t(""), .button]
    return items
}()

private typealias Item = NBBWindowParser.Item

@Suite("Reading Ninjabrain Bot's window")
struct NBBWindowParserTests {
    @Test func readsThePredictionsAsChunks() throws {
        let snapshot = try #require(NBBWindowParser.parse(recordedWindow))
        #expect(snapshot.stronghold.resultType == .triangulation)
        let first = try #require(snapshot.stronghold.predictions.first)
        #expect(first.chunkX == -84 && first.chunkZ == 5, "(-1340, 84) is in chunk (-84, 5)")
        #expect(first.certainty == 1.0 && first.overworldDistance == 1)
        #expect(snapshot.stronghold.predictions.count == 3, "the table's rows only, not the divine panel's location")
    }

    @Test func readsTheAngleAndItsTurnFromTheWindow() throws {
        let predictions = try #require(NBBWindowParser.parse(recordedWindow)).stronghold.predictions
        #expect(predictions[0].shownAngle == 118.30 && predictions[0].shownAngleChange == -113.7)
        #expect(predictions[1].shownAngle == -80.67 && predictions[1].shownAngleChange == 47.4)
        #expect(NBBWindowParser.turn(" (-> 47.4)") == 47.4 && NBBWindowParser.turn("(<- 2.0)") == -2 && NBBWindowParser.turn("1") == nil)
    }

    @Test func readsTheEyeThrows() throws {
        let throwsRead = try #require(NBBWindowParser.parse(recordedWindow)).stronghold.eyeThrows
        #expect(throwsRead.count == 1)
        #expect(throwsRead.first?.xInOverworld == -1374.70)
        #expect(throwsRead.first?.angle == -80.64)
        #expect(throwsRead.first?.error == -0.0022)
        #expect(throwsRead.first?.correction == 6)
    }

    @Test func readsTheNotesButNotTheLabels() throws {
        #expect(try #require(NBBWindowParser.parse(recordedWindow)).messages
            == ["You might not be able to nether travel into the stronghold due to portal linking."])
    }

    @Test func anEmptyWindowIsNoResult() throws {
        let t = Item.text
        let empty = [t("Waiting for F3+C..."), t("Location"), t("%"), t("Dist."), t("Nether"), t("Angle"), t(""), t(""), t("s1"),
                     t("Ender eye throws"), t("x"), t("z"), t("Angle"), t("Error"), .button, t(""), .button]
        let snapshot = try #require(NBBWindowParser.parse(empty))
        #expect(snapshot.stronghold.resultType == .none && snapshot.messages.isEmpty)
    }

    @Test func aWindowWithoutThePredictionsTableIsntRead() {
        #expect(NBBWindowParser.parse([Item.text("Options"), Item.text("Advanced")]) == nil)
    }

    @Test func throwsWithoutAPredictionReadAsFailed() throws {
        let t = Item.text
        let failed = [t("Location"), t("%"), t("Dist."), t("Nether"), t("Angle"), t("s1"),
                      t("Ender eye throws"), t("x"), t("z"), t("Angle"), t("Error"), .button, t("10.0"), t("20.0"), t("30.0"), t("0.01")]
        #expect(try #require(NBBWindowParser.parse(failed)).stronghold.resultType == .failed)
    }
}
