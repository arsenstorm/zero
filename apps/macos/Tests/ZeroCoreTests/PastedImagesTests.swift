import Testing
@testable import ZeroCore

/// A reply box's words come back as typed with its images' paths after them, and only Zero's own paths are images.
@Test func pastedImagesSplitFromTheWords() {
    let folder = "/Users/u/.zero/attachments"
    let a = folder + "/a.png", b = folder + "/b.png"
    for words in ["", "broken:", "broken: ", " ", "two\nlines"] {
        #expect(PastedImages.split(PastedImages.join(words, [a, b]), folder: folder) == (words, [a, b]))
    }
    #expect(PastedImages.split("see \(a) here", folder: folder) == ("see here", [a]))
    #expect(PastedImages.split("see /tmp/x.png", folder: folder) == ("see /tmp/x.png", []))
    #expect(PastedImages.split("see \(folder)x/c.png", folder: folder) == ("see \(folder)x/c.png", []))
}
