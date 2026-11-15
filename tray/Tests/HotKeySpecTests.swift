import Foundation

func runHotKeySpecTests() {
    let space = HotKeySpec.parse("option+space")
    expect(space == HotKeySpec(keyCode: 49, modifiers: 2048), "testHotKeyDefault")
    expect(HotKeySpec.parse("option+shift+space") == HotKeySpec(keyCode: 49, modifiers: 2048 | 512), "testHotKeyOptionShiftSpace")
    expect(HotKeySpec.parse(HotKeySpec.defaultString) == space, "testHotKeyDefaultStringParses")
    expect(HotKeySpec.parse("Cmd+K") == HotKeySpec(keyCode: 40, modifiers: 256), "testHotKeyCmdK")
    expect(HotKeySpec.parse(" Command + Ctrl + 1 ") == HotKeySpec(keyCode: 18, modifiers: 256 | 4096), "testHotKeyAliasesAndSpaces")
    expect(HotKeySpec.parse("alt+opt+a") == HotKeySpec(keyCode: 0, modifiers: 2048), "testHotKeyOptionAliasesMerge")
    expect(HotKeySpec.parse("space") == nil, "testHotKeyNeedsModifier")
    expect(HotKeySpec.parse("ctrl+shift+f13") == nil, "testHotKeyUnknownKey")
    expect(HotKeySpec.parse("cmd+shift") == nil, "testHotKeyNeedsKey")
    expect(HotKeySpec.parse("cmd+a+b") == nil, "testHotKeyTwoKeys")
    expect(HotKeySpec.parse("") == nil, "testHotKeyEmpty")
    expect(HotKeySpec.parse("cmd+") == nil, "testHotKeyTrailingPlus")
    expect(space?.keyEquivalent == " " && HotKeySpec.parse("cmd+k")?.keyEquivalent == "k", "testHotKeyMenuKeyEquivalent")
}
