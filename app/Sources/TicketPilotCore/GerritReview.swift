import Foundation

/// The Gerrit server a repo's `origin` points to, over SSH (`ssh://[user@]host:29418/project`): asked
/// which patch sets a change has, so that a branch whose commits are all up for review can be deleted.
struct GerritServer: Equatable {
    var destination: String
    var port: Int?

    init(destination: String, port: Int?) {
        self.destination = destination
        self.port = port
    }

    /// Only an `ssh://` remote that `RepoDetector` sees as Gerrit: an HTTP one would need credentials.
    init?(remote: String) {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RepoDetector.review(ofRemote: trimmed) == "gerrit",
              let url = URL(string: trimmed), url.scheme?.lowercased() == "ssh",
              let host = url.host, !host.isEmpty
        else { return nil }
        destination = url.user.map { "\($0)@\(host)" } ?? host
        port = url.port
    }

    /// The commits of every patch set of the change, empty when Gerrit can't be asked (no key loaded,
    /// offline, unknown change): the branch is then kept.
    func revisions(ofChange changeID: String, runner: ProcessRunning) -> Set<String> {
        guard Self.isChangeID(changeID) else { return [] }
        var arguments = [
            // Never a prompt (password, host key), and no endless wait on a dead connection.
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
        ]
        if let port { arguments += ["-p", String(port)] }
        arguments += [destination, "gerrit", "query", "--format=JSON", "--patch-sets", "change:\(changeID)"]
        guard let result = try? runner.run("/usr/bin/ssh", arguments, currentDirectory: nil), result.status == 0
        else { return [] }
        return Self.revisions(inQueryOutput: result.output)
    }

    /// `gerrit query --format=JSON` prints one change per line, then a line of statistics.
    static func revisions(inQueryOutput output: String) -> Set<String> {
        var revisions: Set<String> = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let patchSets = object["patchSets"] as? [[String: Any]]
            else { continue }
            revisions.formUnion(patchSets.compactMap { $0["revision"] as? String })
        }
        return revisions
    }

    /// "I" and 40 hexadecimal digits: nothing else is ever sent to the server.
    static func isChangeID(_ value: String) -> Bool {
        value.count == 41 && value.first == "I" && value.dropFirst().allSatisfy(\.isHexDigit)
    }
}
