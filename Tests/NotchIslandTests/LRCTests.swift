import XCTest
@testable import NotchIsland

final class LRCTests: XCTestCase {
    func testParsesAndSortsTimestampedLines() {
        let lyrics = """
        [00:12.50] Segunda línea
        [00:01.25] Primera línea
        """

        XCTAssertEqual(LRC.parse(lyrics), [
            LyricLine(time: 1.25, text: "Primera línea"),
            LyricLine(time: 12.5, text: "Segunda línea")
        ])
    }

    func testMultipleTimestampsRepeatTheSameLine() {
        let lyrics = "[01:02.50][02:03.75] Estribillo"

        XCTAssertEqual(LRC.parse(lyrics), [
            LyricLine(time: 62.5, text: "Estribillo"),
            LyricLine(time: 123.75, text: "Estribillo")
        ])
    }

    func testIgnoresMetadataAndUntimedLines() {
        let lyrics = """
        [ar:Artista]
        Texto sin tiempo
        [00:05.00] Letra
        """

        XCTAssertEqual(LRC.parse(lyrics), [
            LyricLine(time: 5, text: "Letra")
        ])
    }

    func testKeepsInstrumentalGapsAsEmptyLines() {
        let lyrics = "[00:03.00]   \n[00:08.00] Vuelve la voz"

        XCTAssertEqual(LRC.parse(lyrics), [
            LyricLine(time: 3, text: ""),
            LyricLine(time: 8, text: "Vuelve la voz")
        ])
    }
}
