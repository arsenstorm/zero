import Foundation
import ZeroCore

/// `zero slack <method> [key=value…] [--workspace NAME] [--approval ID]`: Slack's Web API through Zero's connection
/// (zerod holds the token). Slack's JSON on stdout.
@MainActor func slackCommand() async {
    guard let method = positional.first else { usage() }
    var params: [String: String] = [:]
    for pair in positional.dropFirst() {
        guard let equals = pair.firstIndex(of: "=") else {
            fail("zero: Slack's arguments are key=value, such as channel=C0123 (got \(pair))")
        }
        params[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
    }
    let args: [String: Any?] = ["method": method, "params": params, "workspace": flag("workspace"), "approval": flag("approval")]
    printJSON(await zerod { try await $0.call("slack", ["session": targetSession(), "args": args.compactMapValues { $0 }]) })
}

/// `zero linear '<graphql>' [--variables JSON] [--approval ID]`: Linear's GraphQL API through Zero's connection; the
/// query from stdin when it's `-` or left out. Linear's JSON on stdout.
@MainActor func linearCommand() async {
    var query = positional.first ?? "-"
    if query == "-" { query = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
    var args: [String: Any] = ["query": query]
    if let text = flag("variables") {
        guard let variables = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            fail("zero: --variables is a JSON object, such as '{\"id\": \"ENG-123\"}'")
        }
        args["variables"] = variables
    }
    if let approval = flag("approval") { args["approval"] = approval }
    printJSON(await zerod { try await $0.call("linear", ["session": targetSession(), "args": args]) })
}

func printJSON(_ value: Any) {
    let data =
        (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed]))
        ?? Data()
    print(String(decoding: data, as: UTF8.self))
}
