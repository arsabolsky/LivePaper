import XCTest
@testable import SakuraWallpaperCore

final class MediaTypeTests: XCTestCase {
    func testDetectVideoFormats() {
        XCTAssertEqual(MediaType.detect(URL(fileURLWithPath: "/tmp/a.mp4")), .video)
        XCTAssertEqual(MediaType.detect(URL(fileURLWithPath: "/tmp/a.mov")), .video)
    }

    func testDetectImageFormats() {
        XCTAssertEqual(MediaType.detect(URL(fileURLWithPath: "/tmp/a.jpg")), .image)
        XCTAssertEqual(MediaType.detect(URL(fileURLWithPath: "/tmp/a.heic")), .image)
        XCTAssertEqual(MediaType.detect(URL(fileURLWithPath: "/tmp/a.webp")), .image)
    }

    func testDetectGifFormats() {
        XCTAssertEqual(MediaType.detect(URL(fileURLWithPath: "/tmp/a.gif")), .gif)
    }

    func testDetectUnsupportedFormat() {
        XCTAssertEqual(MediaType.detect(URL(fileURLWithPath: "/tmp/a.txt")), .unsupported)
    }
}
