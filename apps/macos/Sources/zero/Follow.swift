import Foundation
import ZeroCore

@MainActor func followCommand() async {
    guard !positional.isEmpty, let session = targetSession() else { usage() }
    let about = (flags["about"] ?? []).flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard let link = try? ZerodLink() else { fail("zero: Zero's daemon isn't running (open Zero)") }
    defer { link.close() }
    var failed = false
    for topic in positional {
        do {
            printFollowed(try await link.follow(session: session, topic: topic, mine: flag("mine") != nil, about: about))
        } catch {
            FileHandle.standardError.write(Data("✗ \(topic): \(error.localizedDescription)\n".utf8))
            failed = true
        }
    }
    print("\nYou'll be told what changes between your turns; end your turn rather than poll.")
    exit(failed ? 1 : 0)
}

private func printFollowed(_ followed: ZerodLink.Followed) {
    print("✓ \(followed.new ? "following" : "already following") \(followed.topic)")
    for line in [followed.summary, followed.detail] where !line.isEmpty { print("    \(line)") }
}

@MainActor func unfollowCommand() async {
    guard let session = targetSession(), !positional.isEmpty || flag("all") != nil else { usage() }
    let removed = await zerod { try await $0.unfollow(session: session, topics: flag("all") != nil ? nil : positional) }
    print("zero: \(removed) follow\(removed == 1 ? "" : "s") taken back")
}

@MainActor func followingCommand() async {
    let session = targetSession()
    let followed = await zerod { try await $0.following(session: session) }
    if followed.isEmpty { print(session == nil ? "zero: nothing is followed" : "zero: this session follows nothing; zero follow <url> to hear of a pull request, issue or thread") }
    for f in followed {
        let filter = (f.mine ? ["--mine"] : []) + (f.about.isEmpty ? [] : ["--about " + f.about.joined(separator: ",")])
        print("\(f.topic)" + (filter.isEmpty ? "" : "  " + filter.joined(separator: " ")) + (session == nil ? "  (\(f.session))" : ""))
        if !f.summary.isEmpty { print("    \(f.summary)") }
        if let error = f.error { print("    ✗ polling fails: \(error)") }
    }
}
