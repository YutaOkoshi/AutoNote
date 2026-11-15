import Testing
@testable import AutoNoteCore

@Suite struct StopScannerTests {
    private let stops = ["<|plamo:tag|>", "<|plamo:bos|>"]

    @Test func stopsAtStopStringInsideOnePiece() {
        var scanner = StopScanner(stops: stops)
        let first = scanner.append(Array("The meeting".utf8))
        let second = scanner.append(Array(" moved.<|plamo:tag|>output".utf8))
        #expect(!first && second)
        #expect(scanner.text == "The meeting moved.")
        #expect(scanner.stopped)
    }

    @Test func stopStringSplitAcrossPieces() {
        var scanner = StopScanner(stops: stops)
        for piece in ["Done", ".<|pla", "mo:", "bos|", ">tail"] {
            if scanner.append(Array(piece.utf8)) { break }
        }
        #expect(scanner.text == "Done.")
    }

    @Test func earliestStopWins() {
        var scanner = StopScanner(stops: ["B", "A"])
        let stopped = scanner.append(Array("xxAyyB".utf8))
        #expect(stopped)
        #expect(scanner.text == "xx")
    }

    @Test func appendAfterStopIsIgnored() {
        var scanner = StopScanner(stops: ["|"])
        scanner.append(Array("a|b".utf8))
        scanner.append(Array("cdef".utf8))
        #expect(scanner.text == "a")
    }

    @Test func noStopsKeepsEverything() {
        var scanner = StopScanner(stops: ["", ""])
        let stopped = scanner.append(Array("<|plamo:tag|>".utf8))
        #expect(!stopped)
        #expect(scanner.text == "<|plamo:tag|>")
    }

    @Test func multiByteCharacterSplitAcrossPieces() {
        var scanner = StopScanner(stops: stops)
        let bytes = Array("会議です".utf8)
        scanner.append(bytes[0..<4])   // 会 + first byte of 議
        #expect(scanner.text == "会")   // the cut-off character is left out
        scanner.append(bytes[4...])
        #expect(scanner.text == "会議です")
    }

    @Test func completeUTF8PrefixDropsOnlyATrailingPartialSequence() {
        #expect(StopScanner.completeUTF8Prefix([]) == 0)
        #expect(StopScanner.completeUTF8Prefix(Array("abc".utf8)) == 3)
        let emoji = Array("a😀".utf8)   // 1 + 4 bytes
        #expect(StopScanner.completeUTF8Prefix(emoji) == 5)
        #expect(StopScanner.completeUTF8Prefix(Array(emoji[0..<4])) == 1)
        #expect(StopScanner.completeUTF8Prefix(Array(emoji[0..<2])) == 1)
        #expect(StopScanner.completeUTF8Prefix([0x61, 0x80]) == 2)   // stray continuation byte: left to the decoder
    }
}
