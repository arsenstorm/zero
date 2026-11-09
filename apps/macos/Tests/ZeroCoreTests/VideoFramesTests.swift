import Testing
@testable import ZeroCore

@Test func framesAreSpreadAndSteppedWithinTheVideo() {
    #expect(VideoFrames.spread(4, over: 8) == [1, 3, 5, 7])
    #expect(VideoFrames.spread(0, over: 8).isEmpty)
    #expect(VideoFrames.every(0.5, from: 2, to: 3.2, seconds: 10) == [2, 2.5, 3])
    #expect(VideoFrames.every(1, from: 8, to: 20, seconds: 9.5) == [8, 9])
    #expect(VideoFrames.stamp(65.25) == "1:05.250")
}
