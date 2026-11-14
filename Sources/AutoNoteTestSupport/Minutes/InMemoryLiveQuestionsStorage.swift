import AutoNoteCore
import Foundation
import Synchronization

/// `LiveQuestionsStorage` in memory.
public final class InMemoryLiveQuestionsStorage: LiveQuestionsStorage {
    private let lists = Mutex<[LiveQuestionScope: LiveQuestionList]>([:])

    public init(_ initial: [LiveQuestionScope: LiveQuestionList] = [:]) {
        lists.withLock { $0 = initial }
    }

    public func load(_ scope: LiveQuestionScope) throws -> LiveQuestionList? { lists.withLock { $0[scope] } }

    public func save(_ list: LiveQuestionList, _ scope: LiveQuestionScope) throws { lists.withLock { $0[scope] = list } }
}
