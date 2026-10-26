import Foundation
import AutoNoteCore

public actor FakeUserNotifier: UserNotifier {
    public private(set) var posted: [UserNotice] = []
    public private(set) var withdrawn: [String] = []

    public init() {}

    public func post(_ notice: UserNotice) async { posted.append(notice) }
    public func withdraw(id: String) async { withdrawn.append(id) }
}
