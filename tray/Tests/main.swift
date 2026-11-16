import Foundation

// Tiny test harness: `build/reducer-tests <fixtures-dir>`; exit 1 on any failure.
var testCount = 0
var failureCount = 0

func expect(_ condition: @autoclosure () -> Bool, _ name: String, file: String = #file, line: Int = #line) {
    testCount += 1
    if condition() {
        print("PASS \(name)")
    } else {
        failureCount += 1
        print("FAIL \(name) (\((file as NSString).lastPathComponent):\(line))")
    }
}

guard CommandLine.arguments.count >= 2 else {
    print("usage: reducer-tests <fixtures-dir>")
    exit(2)
}
fixturesDirectory = CommandLine.arguments[1]

runTimelineReducerTests()
runTimelineClientTests()
runChatMarkdownTests()
runBotRecentsTests()
runHotKeySpecTests()
runEditMenuSpecTests()
runDispatcherStoreTests()

if failureCount == 0 {
    print("ALL \(testCount) TESTS PASSED")
    exit(0)
}
print("\(failureCount) of \(testCount) CHECKS FAILED")
exit(1)
