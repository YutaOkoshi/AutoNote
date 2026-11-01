import Foundation

/// Why meetings cannot be combined (`MeetingCombiner.plan`) or why combining them failed (`execute`).
public enum CombineError: Error, Equatable, Sendable {
    case tooFew
    case duplicate(MeetingID)
    case recording(MeetingID)
    case processing(MeetingID)
    case notLive(MeetingID)
    case notEnded(MeetingID)
    case alreadyMerged(MeetingID, into: MeetingID)
    case overlapping(MeetingID, MeetingID)
    case languageMismatch
    case destinationExists(MeetingID)
    case missingFile(MeetingID, String)

    /// The wording the CLI and the window show.
    public var message: String {
        switch self {
        case .tooFew: "統合するには会議を 2 つ以上指定してください"
        case .duplicate(let id): "同じ会議が 2 回指定されています: \(id.rawValue)"
        case .recording(let id): "録音中の会議は統合できません: \(id.rawValue)"
        case .processing(let id): "処理中の会議は統合できません。処理が終わってから統合してください: \(id.rawValue)"
        case .notLive(let id): "取り込んだ音声の会議は統合できません（話者を区別できないため）: \(id.rawValue)"
        case .notEnded(let id): "終了時刻のない会議は統合できません: \(id.rawValue)"
        case .alreadyMerged(let id, let into): "\(id.rawValue) はすでに \(into.rawValue) に統合されています"
        case .overlapping(let a, let b): "録音の時間が重なっています: \(a.rawValue) と \(b.rawValue)"
        case .languageMismatch: "言語の違う会議は統合できません"
        case .destinationExists(let id): "統合先の会議がすでにあります: \(id.rawValue)"
        case .missingFile(let id, let path): "録音ファイルがありません: \(id.rawValue)/\(path)"
        }
    }
}

/// What `MeetingCombiner.execute` does: the combined manifest, and which source file goes where.
public struct CombinePlan: Equatable, Sendable {
    public struct Copy: Equatable, Sendable {
        public var source: MeetingID
        /// Relative to the source meeting directory.
        public var from: String
        /// Relative to the new meeting directory.
        public var to: String

        public init(source: MeetingID, from: String, to: String) {
            self.source = source; self.from = from; self.to = to
        }
    }

    public var manifest: Manifest
    /// The sources, oldest first.
    public var sources: [Manifest]
    public var copies: [Copy]
    /// Where each source starts on the combined timeline, in seconds.
    public var offsets: [MeetingID: Double]
    /// The total time between the recordings, in seconds.
    public var gapSeconds: Double
}

/// Combines recordings of one meeting that ended up split (a crash, an accidental stop) into a new meeting whose
/// timeline runs from the first start to the last stop. The time between recordings becomes a pause, so
/// `SegmentMerger` keeps each recording in its own file and the transcript times run through (SPEC §2).
public enum MeetingCombiner {
    /// Statuses whose meeting is still in the post-processing queue.
    static let processingStatuses: Set<MeetingStatus> = [.recorded, .transcribing, .transcribed, .generating]

    /// Pure: checks the preconditions (SPEC §2.2) and computes the combined manifest. `busy` holds the meetings
    /// with an active queue job. The sources may come in any order.
    public static func plan(_ manifests: [Manifest], newID: MeetingID, busy: Set<MeetingID> = [],
                            appVersion: String = AutoNoteVersion.current) throws(CombineError) -> CombinePlan {
        guard manifests.count >= 2 else { throw .tooFew }
        var seen = Set<MeetingID>()
        for m in manifests where !seen.insert(m.id).inserted { throw .duplicate(m.id) }

        let sources = manifests.sorted { ($0.startedAt, $0.id.rawValue) < ($1.startedAt, $1.id.rawValue) }
        var ends: [Date] = []
        for m in sources {
            if let into = m.mergedInto { throw .alreadyMerged(m.id, into: into) }
            if m.status == .recording { throw .recording(m.id) }
            if processingStatuses.contains(m.status) || busy.contains(m.id) { throw .processing(m.id) }
            guard m.source == .live else { throw .notLive(m.id) }
            guard let end = m.endedAt else { throw .notEnded(m.id) }
            ends.append(end)
        }
        guard Set(sources.map(\.language)).count == 1 else { throw .languageMismatch }
        for i in sources.indices.dropFirst() where ends[i - 1] > sources[i].startedAt {
            throw .overlapping(sources[i - 1].id, sources[i].id)
        }

        let base = sources[0].startedAt
        // Dates are stored at millisecond precision; keep the offsets exact to the millisecond too.
        func seconds(_ date: Date) -> Double { (date.timeIntervalSince(base) * 1000).rounded() / 1000 }

        var tracks: [TrackFile] = []
        var copies: [CombinePlan.Copy] = []
        var pauses: [PauseInterval] = []
        var bookmarks: [Bookmark] = []
        var offsets: [MeetingID: Double] = [:]
        var nextIndex: [Track: Int] = [:]
        var gap = 0.0
        for (i, m) in sources.enumerated() {
            let offset = seconds(m.startedAt)
            let end = seconds(ends[i])
            offsets[m.id] = offset
            if i > 0 {
                let previousEnd = seconds(ends[i - 1])
                if offset > previousEnd {
                    pauses.append(PauseInterval(start: .init(seconds: previousEnd), end: .init(seconds: offset)))
                    gap += offset - previousEnd
                }
            }
            for file in m.tracks {
                let n = nextIndex[file.track, default: 0]
                nextIndex[file.track] = n + 1
                let path = String(format: "tracks/%@-%03d.wav", file.track.rawValue, n)
                copies.append(.init(source: m.id, from: file.relativePath, to: path))
                tracks.append(TrackFile(track: file.track, relativePath: path,
                                        startOffset: .init(seconds: offset + file.startOffset.seconds),
                                        durationSeconds: file.durationSeconds))
            }
            // A pause still open at the stop lasted until the stop.
            pauses += m.pauses.map {
                PauseInterval(start: .init(seconds: offset + $0.start.seconds),
                              end: .init(seconds: $0.end.map { offset + $0.seconds } ?? end))
            }
            bookmarks += m.bookmarks.map { Bookmark(at: .init(seconds: offset + $0.at.seconds), note: $0.note) }
        }

        let first = sources[0]
        let manifest = Manifest(
            id: newID, title: nil, startedAt: base, endedAt: ends[ends.count - 1], source: .live,
            device: first.device, language: first.language, tracks: tracks,
            pauses: pauses.sorted { $0.start < $1.start }, bookmarks: bookmarks.sorted { $0.at < $1.at },
            status: .recorded, silenceWarning: sources.contains { $0.silenceWarning },
            autonoteVersion: appVersion, mergedFrom: sources.map(\.id))
        return CombinePlan(manifest: manifest, sources: sources, copies: copies, offsets: offsets, gapSeconds: gap)
    }

    /// Creates the new meeting: links (or copies) the WAV files, joins the sources' `live.json` on the combined
    /// timeline, and saves the manifest last. Any failure removes everything it created. The sources are not touched.
    @discardableResult
    public static func execute(_ plan: CombinePlan, paths: AppPaths, manifests: ManifestStore) async throws -> Manifest {
        let id = plan.manifest.id
        let fm = FileManager.default
        // Failure cleanup deletes the whole directory, so never write into one that exists.
        guard !fm.fileExists(atPath: paths.meetingDirectory(id).path),
              !fm.fileExists(atPath: paths.transcriptsDirectory(id).path) else { throw CombineError.destinationExists(id) }
        do {
            try fm.createDirectory(at: paths.tracksDirectory(id), withIntermediateDirectories: true)
            for copy in plan.copies {
                let from = paths.meetingDirectory(copy.source).appending(path: copy.from)
                guard fm.fileExists(atPath: from.path) else { throw CombineError.missingFile(copy.source, copy.from) }
                let to = paths.meetingDirectory(id).appending(path: copy.to)
                // The recordings directory is one volume, so a hard link is the usual case; copy where links fail.
                do { try fm.linkItem(at: from, to: to) } catch { try fm.copyItem(at: from, to: to) }
            }
            try writeLiveTranscript(plan, paths: paths)
            try Task.checkCancellation()
            try await manifests.save(plan.manifest)
            return plan.manifest
        } catch {
            try? await manifests.delete(id)
            throw error
        }
    }

    /// `transcripts/<new id>/live.json` from the sources' live transcripts, shifted onto the combined timeline.
    /// The final-transcription stage falls back to it. Sources without a readable one are skipped; nothing is
    /// written when none has one.
    private static func writeLiveTranscript(_ plan: CombinePlan, paths: AppPaths) throws {
        var utterances: [Utterance] = []
        var engine: String?
        for m in plan.sources {
            guard let data = try? Data(contentsOf: paths.transcriptFile(m.id, .live)),
                  let live = try? AutoNoteJSON.decoder().decode(Transcript.self, from: data) else { continue }
            let offset = TimelineTime(seconds: plan.offsets[m.id] ?? 0)
            engine = engine ?? live.engine
            utterances += live.utterances.map {
                var u = $0
                u.start = offset + u.start
                u.end = u.end.map { offset + $0 }
                return u
            }
        }
        guard let engine else { return }
        let url = paths.transcriptFile(plan.manifest.id, .live)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let transcript = Transcript(utterances: utterances, engine: engine, language: plan.manifest.language)
        try AutoNoteJSON.encoder().encode(transcript).write(to: url, options: .atomic)
    }
}
