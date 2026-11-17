import Foundation

func runQuickAskMenuTests() {
    typealias M = QuickAskMenu
    let a = M.Bot(id: "a", name: "Ada")
    let b = M.Bot(id: "b", name: "Bo")
    let c = M.Bot(id: "c", name: "Cy")
    let d1 = TrayDispatcher(agentId: "d1", groupId: "g", name: "Alpha", needsYou: false, status: "idle")
    let d2 = TrayDispatcher(agentId: "d2", groupId: "g", name: "Beta", needsYou: true, status: "idle")
    let header = M.Row.header(L("Dispatchers", "调度器"))
    func disp(_ d: TrayDispatcher) -> M.Row {
        .dispatcher(agentId: d.agentId, name: d.name, title: d.menuTitle, needsYou: d.needsYou)
    }

    expect(M.rows(connected: false, bots: .loaded([a]), recent: [], dispatchers: [d1]) == [],
           "quickAskMenu: disconnected hides the item")
    expect(M.rows(connected: true, bots: .hidden, recent: [], dispatchers: []) == [],
           "quickAskMenu: hidden bots and no dispatchers hides the item")
    expect(M.rows(connected: true, bots: .loaded([]), recent: [], dispatchers: []) == [],
           "quickAskMenu: loaded-empty bots and no dispatchers hides the item")

    expect(M.rows(connected: true, bots: .loaded([a, b]), recent: [], dispatchers: []) == [
        .quickAsk, .separator, .bot(id: "a", name: "Ada"), .bot(id: "b", name: "Bo"),
    ], "quickAskMenu: bots only, no header")

    expect(M.rows(connected: true, bots: .hidden, recent: [], dispatchers: [d1]) == [
        .quickAsk, .separator, header, disp(d1),
    ], "quickAskMenu: dispatchers only, header without extra separator")
    expect(M.rows(connected: true, bots: .loaded([]), recent: [], dispatchers: [d1]) == [
        .quickAsk, .separator, header, disp(d1),
    ], "quickAskMenu: loaded-empty bots with dispatchers shows dispatchers only")

    expect(M.rows(connected: true, bots: .loaded([a]), recent: [], dispatchers: [d1]) == [
        .quickAsk, .separator, .bot(id: "a", name: "Ada"), .separator, header, disp(d1),
    ], "quickAskMenu: both parts")

    expect(M.rows(connected: true, bots: .loading, recent: [], dispatchers: [d1]) == [
        .quickAsk, .separator, .loading, .separator, header, disp(d1),
    ], "quickAskMenu: loading bots with dispatchers")
    expect(M.rows(connected: true, bots: .loading, recent: [], dispatchers: []) == [
        .quickAsk, .separator, .loading,
    ], "quickAskMenu: loading bots alone")

    expect(M.rows(connected: true, bots: .loaded([a, b, c]), recent: ["c", "zzz", "a"], dispatchers: []) == [
        .quickAsk, .separator,
        .bot(id: "c", name: "Cy"), .bot(id: "a", name: "Ada"), .bot(id: "b", name: "Bo"),
    ], "quickAskMenu: recent first in recent order, rest in API order, unknown ids ignored")

    // Dispatchers share the recents list, keyed by group id.
    let e1 = TrayDispatcher(agentId: "e1", groupId: "g1", name: "Alpha", needsYou: false, status: "idle")
    let e2 = TrayDispatcher(agentId: "e2", groupId: "g2", name: "Zen", needsYou: false, status: "idle")
    expect(M.rows(connected: true, bots: .loaded([a, b, c]), recent: ["dispatcher:g2", "b", "gone"], dispatchers: [e1, e2]) == [
        .quickAsk, .separator, disp(e2), .bot(id: "b", name: "Bo"),
        .bot(id: "a", name: "Ada"), .bot(id: "c", name: "Cy"),
        .separator, header, disp(e1),
    ], "quickAskMenu: used mixed first, then unused bots, then unused dispatchers")
    expect(M.rows(connected: true, bots: .loaded([a]), recent: ["dispatcher:g1", "dispatcher:g2"], dispatchers: [e1, e2]) == [
        .quickAsk, .separator, disp(e1), disp(e2), .bot(id: "a", name: "Ada"),
    ], "quickAskMenu: all dispatchers used has no header")
    expect(M.rows(connected: true, bots: .loading, recent: ["dispatcher:g2", "b"], dispatchers: [e1, e2]) == [
        .quickAsk, .separator, disp(e2), .loading, .separator, header, disp(e1),
    ], "quickAskMenu: loading puts used dispatchers before the loading row")
    expect(M.rows(connected: true, bots: .hidden, recent: ["dispatcher:g2"], dispatchers: [e1, e2]) == [
        .quickAsk, .separator, disp(e2), .separator, header, disp(e1),
    ], "quickAskMenu: hidden bots still orders used dispatchers first")

    expect(M.rows(connected: true, bots: .hidden, recent: [], dispatchers: [d2, d1]) == [
        .quickAsk, .separator, header, disp(d2), disp(d1),
    ], "quickAskMenu: dispatcher order preserved")

    let marked = M.rows(connected: true, bots: .hidden, recent: [], dispatchers: [d2]).last
    expect(marked == .dispatcher(agentId: "d2", name: "Beta", title: d2.menuTitle, needsYou: true)
           && d2.menuTitle.hasPrefix("● "), "quickAskMenu: needs-you dispatcher row is marked")

    expect(M.title(dispatchers: [d1]) == L("Quick Ask", "快速提问"), "quickAskMenu: title has no marker when nobody needs you")
    expect(M.title(dispatchers: [d1, d2]) == "● " + L("Quick Ask", "快速提问"), "quickAskMenu: title marked when a dispatcher needs you")
    expect(M.title(dispatchers: []) == L("Quick Ask", "快速提问"), "quickAskMenu: title without dispatchers")
}
