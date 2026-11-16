import Foundation

func runEditMenuSpecTests() {
    let items = EditMenuSpec.items
    expect(items.count == 7, "testEditMenuItemCount")
    expect(items.map { $0?.action } == ["undo:", "redo:", nil, "cut:", "copy:", "paste:", "selectAll:"], "testEditMenuActionOrder")
    expect(items.map { $0?.key } == ["z", "z", nil, "x", "c", "v", "a"], "testEditMenuKeys")
    expect(items.compactMap { $0 }.filter { $0.shift }.map { $0.action } == ["redo:"], "testEditMenuShiftOnlyOnRedo")
    expect(items.filter { $0 == nil }.count == 1 && items[2] == nil, "testEditMenuSingleSeparatorBetweenRedoAndCut")
}
