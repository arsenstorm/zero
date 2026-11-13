import Foundation
import Testing

@testable import ZeroCore

/// Runs `security` with these arguments, its output dropped.
private func security(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

private func searchList() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["list-keychains", "-d", "user"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// A value goes to `security` on its input, never its command line, quoted whatever it holds; one too long for a line
/// of `security -i` isn't kept (the one before stays). Run in a keychain of the test's own, never the user's: nothing
/// in it asks anyone anything.
@Test func valuesAreKeptThroughSecuritysInputAsTheyAre() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zero-keychain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let keychain = folder.appendingPathComponent("test.keychain-db").path
    let before = searchList()
    #expect(security(["create-keychain", "-p", "throwaway", keychain]) == 0)
    defer {
        _ = security(["delete-keychain", keychain])
        try? FileManager.default.removeItem(at: folder)
        #expect(searchList() == before, "the user's search list as it was")
    }

    let (service, account) = ("zero-test", "a")
    let odd = #"tok"en\with 'quotes' and spaces"#
    Keychain.saveString(odd, service: service, account: account, in: keychain)
    #expect(Keychain.loadString(service: service, account: account, in: keychain) == odd)
    Keychain.saveString("second", service: service, account: account, in: keychain)
    #expect(Keychain.loadString(service: service, account: account, in: keychain) == "second")
    Keychain.saveString(String(repeating: "z", count: 5000), service: service, account: account, in: keychain)
    #expect(Keychain.loadString(service: service, account: account, in: keychain) == "second", "too long for a line: not kept")
    Keychain.saveString(nil, service: service, account: account, in: keychain)
    #expect(Keychain.loadString(service: service, account: account, in: keychain) == nil)
}
