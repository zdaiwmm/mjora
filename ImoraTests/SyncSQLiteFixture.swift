import Foundation
import SQLite3

/// Synthetic corruption injection verifies recovery using the real SQLite storage boundary.
func corruptSyncFixtureDatabase(_ file: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(file.path, &database) == SQLITE_OK, let database else { throw CocoaError(.fileWriteUnknown) }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
}
