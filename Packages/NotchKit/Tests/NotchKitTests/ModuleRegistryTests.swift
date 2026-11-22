import SwiftUI
import Testing
@testable import NotchKit

@MainActor
private final class StubModule: NotchModule {
    let id: String
    let title: String
    let systemImage = "circle"
    let tabOrder: Int
    var attention: ModuleAttention
    var activations = 0
    var deactivations = 0

    init(_ id: String, order: Int = 100, attention: ModuleAttention = .none) {
        self.id = id
        self.title = id
        self.tabOrder = order
        self.attention = attention
    }

    func makeExpandedView() -> AnyView { AnyView(EmptyView()) }
    func activate() { activations += 1 }
    func deactivate() { deactivations += 1 }
}

@MainActor
struct ModuleRegistryTests {
    @Test func ordersByTabOrderThenRegistration() {
        let r = ModuleRegistry()
        r.register(StubModule("c", order: 20))
        r.register(StubModule("a", order: 10))
        r.register(StubModule("b", order: 10))
        #expect(r.visibleModules.map(\.id) == ["a", "b", "c"])
        #expect(r.selectedID == "a")
    }

    @Test func registerSameIdReplaces() {
        let r = ModuleRegistry()
        r.register(StubModule("a"))
        let replacement = StubModule("a")
        r.register(replacement)
        #expect(r.modules.count == 1)
        #expect(r.modules[0] === replacement)
    }

    @Test func selectActivatesOnlyWhileOpen() {
        let r = ModuleRegistry()
        let a = StubModule("a", order: 1), b = StubModule("b", order: 2)
        r.register(a); r.register(b)
        r.select(id: "b")
        #expect(b.activations == 0 && r.selectedID == "b")
        r.notchDidOpen()
        #expect(b.activations == 1)
        r.select(id: "a")
        #expect(b.deactivations == 1 && a.activations == 1)
        r.notchDidClose()
        #expect(a.deactivations == 1)
    }

    @Test func openCloseAreIdempotent() {
        let r = ModuleRegistry()
        let a = StubModule("a")
        r.register(a)
        r.notchDidOpen(); r.notchDidOpen()
        #expect(a.activations == 1)
        r.notchDidClose(); r.notchDidClose()
        #expect(a.deactivations == 1)
    }

    @Test func disablingSelectedFallsBackAndDeactivates() {
        let r = ModuleRegistry()
        let a = StubModule("a", order: 1), b = StubModule("b", order: 2)
        r.register(a); r.register(b)
        r.notchDidOpen()
        r.setEnabled(false, id: "a")
        #expect(a.deactivations == 1)
        #expect(r.selectedID == "b")
        r.select(id: "a") // disabled: ignored
        #expect(r.selectedID == "b")
    }

    @Test func topAttentionPicksHighest() {
        let r = ModuleRegistry()
        r.register(StubModule("music", attention: .active))
        r.register(StubModule("claude", attention: .needsInput))
        r.register(StubModule("idle"))
        #expect(r.topAttention?.module.id == "claude")
        #expect(r.topAttention?.level == .needsInput)
    }

    @Test func unregisterSelectedMovesSelection() {
        let r = ModuleRegistry()
        r.register(StubModule("a", order: 1)); r.register(StubModule("b", order: 2))
        r.unregister(id: "a")
        #expect(r.selectedID == "b")
        r.unregister(id: "b")
        #expect(r.selectedID == nil)
    }
}
