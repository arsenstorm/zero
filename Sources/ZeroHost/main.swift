import Foundation

if CommandLine.arguments.dropFirst().first == "--selftest" {
    let screen = Screen(columns: 40, rows: 10)
    var replies = Data()
    screen.reply = { replies.append($0) }
    screen.feed(Data("hello\r\n\u{1B}[31mred\u{1B}[0m world\r\n\u{1B}[2J\u{1B}[Hcleared and redrawn\r\n\u{1B}[6n".utf8))
    screen.feed(Data("\u{1B}]7501;state=blocked:kind=permission:msg=QXBwcm92ZT8=\u{1B}\\".utf8))
    print(screen.text())
    print("reply to cursor query:", replies.map { String(format: "%02x", $0) }.joined(separator: " "))
    print("status:", screen.status.map { "\($0.state) \($0.message)" } ?? "none")
    exit(0)
}
