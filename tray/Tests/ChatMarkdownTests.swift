import Foundation

func runChatMarkdownTests() {
    expect(ChatMarkdown.split("Hello **there**") == [.text("Hello **there**")], "testMarkdownPlainText")

    expect(ChatMarkdown.split("") == [], "testMarkdownEmpty")

    let mixed = "Run this:\n\n```bash\nls -la\necho hi\n```\n\nThen check."
    expect(ChatMarkdown.split(mixed) == [
        .text("Run this:"),
        .code(language: "bash", text: "ls -la\necho hi"),
        .text("Then check."),
    ], "testMarkdownFenceSplitsTextAndCode")

    expect(ChatMarkdown.split("```\nplain\n```") == [.code(language: nil, text: "plain")],
           "testMarkdownFenceWithoutLanguage")

    // Streaming: the closing fence hasn't arrived yet.
    expect(ChatMarkdown.split("Code:\n```swift\nlet x = 1") == [
        .text("Code:"),
        .code(language: "swift", text: "let x = 1"),
    ], "testMarkdownUnclosedFenceRunsToEnd")

    // A shorter or different marker inside a block doesn't close it.
    expect(ChatMarkdown.split("````md\n```\ninner\n```\n````") == [
        .code(language: "md", text: "```\ninner\n```"),
    ], "testMarkdownLongerFenceNestsShorter")

    expect(ChatMarkdown.split("~~~\na\n~~~\nb") == [.code(language: nil, text: "a"), .text("b")],
           "testMarkdownTildeFence")

    // Inline backticks are not fences.
    expect(ChatMarkdown.split("Use ``` inline ``` here") == [.text("Use ``` inline ``` here")],
           "testMarkdownInlineBackticksStayText")

    // Indented four spaces is not a fence.
    expect(ChatMarkdown.split("    ```\nx") == [.text("    ```\nx")], "testMarkdownIndentedFenceIgnored")

    expect(ChatMarkdown.split("a\n```\n\n```\nb") == [.text("a"), .code(language: nil, text: ""), .text("b")],
           "testMarkdownEmptyCodeBlock")
}
