import Testing
@testable import Prologue

@Suite("Trial checklist")
struct ChecklistTests {
    private let items = [
        ChecklistItem(id: "on", title: "Switch it on"),
        ChecklistItem(id: "shape", title: "Try another shape"),
        ChecklistItem(id: "image", title: "Use your own image", isOptional: true),
        ChecklistItem(id: "rebind", title: "Make a rebind", unavailableReason: "Needs Karabiner-Elements"),
    ]

    @Test func itemsStartPending() {
        let list = Checklist(items: items)
        #expect(list.state(of: "on") == .pending)
        #expect(list.state(of: "rebind") == .unavailable)
        #expect(!list.isComplete)
        #expect(list.doneCount == 0)
    }

    @Test func itemsTickThemselvesAndStayTicked() {
        var list = Checklist(items: items)
        let result1 = list.markDone(["on"])
        #expect(result1 == ["on"])
        #expect(list.state(of: "on") == .done)
        // The tool switched off again: the tick stays.
        let result2 = list.markDone([])
        #expect(result2.isEmpty)
        #expect(list.state(of: "on") == .done)
        let result3 = list.markDone(["on"])
        #expect(result3.isEmpty)
    }

    @Test func unavailableAndUnknownItemsNeverTick() {
        var list = Checklist(items: items)
        let result4 = list.markDone(["rebind", "nonsense"])
        #expect(result4.isEmpty)
        #expect(list.state(of: "rebind") == .unavailable)
    }

    @Test func anyItemCanBeSkipped() {
        var list = Checklist(items: items)
        list.skip("shape")
        #expect(list.state(of: "shape") == .skipped)
        list.skip("image")
        #expect(list.state(of: "image") == .skipped)
    }

    @Test func doingASkippedItemStillTicksIt() {
        var list = Checklist(items: items)
        list.skip("shape")
        let result5 = list.markDone(["shape"])
        #expect(result5 == ["shape"])
        #expect(list.state(of: "shape") == .done)
    }

    @Test func aDoneItemCannotBeSkipped() {
        var list = Checklist(items: items)
        list.markDone(["on"])
        list.skip("on")
        #expect(list.state(of: "on") == .done)
    }

    @Test func completeOnceEveryRequiredItemIsDoneOrSkipped() {
        var list = Checklist(items: items)
        list.markDone(["on"])
        #expect(!list.isComplete)
        list.skip("shape")
        #expect(list.isComplete)
        #expect(list.doneCount == 1)
    }

    @Test func newItemListsKeepTicks() {
        var list = Checklist(items: items)
        list.markDone(["on"])
        list.skip("shape")
        var available = items
        available[3].unavailableReason = nil
        list.update(items: available)
        #expect(list.state(of: "on") == .done)
        #expect(list.state(of: "shape") == .skipped)
        #expect(list.state(of: "rebind") == .pending)
        let result6 = list.markDone(["rebind"])
        #expect(result6 == ["rebind"])
    }
}
