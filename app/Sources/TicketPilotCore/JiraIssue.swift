import Foundation

public struct JiraIssue: Equatable, Sendable, Identifiable {
    public enum StatusCategory: String, Sendable {
        case toDo = "new"
        case inProgress = "indeterminate"
        case done
    }

    public var key: String
    public var summary: String
    public var statusName: String
    public var statusCategory: StatusCategory
    public var labels: [String]
    public var components: [String]

    public var id: String { key }

    public init(
        key: String,
        summary: String,
        statusName: String,
        statusCategory: StatusCategory,
        labels: [String] = [],
        components: [String] = []
    ) {
        self.key = key
        self.summary = summary
        self.statusName = statusName
        self.statusCategory = statusCategory
        self.labels = labels
        self.components = components
    }
}
