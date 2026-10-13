import Foundation
import SQLite3

final class CodexThreadTitleResolver {
    private let databaseURL: URL
    private var database: OpaquePointer?

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite")
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func title(for threadID: String) -> String? {
        guard openDatabaseIfNeeded(), let database else { return nil }

        let sql = "SELECT title, preview FROM threads WHERE id = ?1 LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, threadID, -1, transientDestructor)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let title = text(at: 0, from: statement)
        let preview = text(at: 1, from: statement)
        return usableTitle(title) ?? usableTitle(preview)
    }

    private func openDatabaseIfNeeded() -> Bool {
        if database != nil { return true }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        return sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK
    }

    private func text(at column: Int32, from statement: OpaquePointer) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private func usableTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let compact = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !compact.isEmpty,
              compact.count <= 240,
              !compact.hasPrefix("The following is the Codex agent history") else {
            return nil
        }

        if compact.count <= 72 { return compact }
        return String(compact.prefix(72)) + "…"
    }

    private var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
