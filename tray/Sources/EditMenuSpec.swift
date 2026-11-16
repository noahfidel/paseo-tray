import Foundation

/// One Edit-menu entry (all Command-modified; `shift` adds Shift). Foundation-only so test.sh can build it.
struct EditMenuItemSpec: Equatable {
    let title: String
    let action: String
    let key: String
    let shift: Bool
}

enum EditMenuSpec {
    /// nil = separator.
    static let items: [EditMenuItemSpec?] = [
        EditMenuItemSpec(title: L("Undo", "撤销"), action: "undo:", key: "z", shift: false),
        EditMenuItemSpec(title: L("Redo", "重做"), action: "redo:", key: "z", shift: true),
        nil,
        EditMenuItemSpec(title: L("Cut", "剪切"), action: "cut:", key: "x", shift: false),
        EditMenuItemSpec(title: L("Copy", "拷贝"), action: "copy:", key: "c", shift: false),
        EditMenuItemSpec(title: L("Paste", "粘贴"), action: "paste:", key: "v", shift: false),
        EditMenuItemSpec(title: L("Select All", "全选"), action: "selectAll:", key: "a", shift: false),
    ]
}
