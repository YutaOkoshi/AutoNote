import Foundation

public enum LiveLine: Equatable, Sendable { case utterance(Utterance), marker(Utterance) }

/// The live transcript as the window shows it. `LiveFeed` has already ordered, replaced and marked the whole
/// list; this only takes each snapshot as is and tells the markers apart.
public struct LiveTranscriptBuffer: Equatable, Sendable {
    public private(set) var lines: [LiveLine] = []

    public init() {}

    public mutating func update(_ snapshot: [Utterance]) {
        lines = snapshot.map { LiveFeed.isMarker($0) ? .marker($0) : .utterance($0) }
    }

    public mutating func reset() { lines = [] }
}
