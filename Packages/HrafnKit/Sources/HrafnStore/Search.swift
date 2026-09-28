import Foundation
import GRDB

extension HrafnDatabase {

    /// Messages whose text matches every word of `query`, each as a prefix
    /// ("jul" finds "Juliet"), newest first, across `accountIDs` (all when
    /// `nil`). Retracted messages and shared files (whose body is a URL) are
    /// left out.
    ///
    /// Words are what SQLite's unicode61 tokenizer makes them: runs of
    /// letters and digits. Scripts written without spaces (Chinese, Japanese,
    /// Thai) index a whole run as one word, so only its beginning is found.
    public func searchMessages(_ query: String, accountIDs: [String]? = nil,
                               limit: Int = 100) throws -> [StoredMessage] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try writer.read { db in
            var sql = """
                SELECT message.* FROM message
                JOIN messageSearch ON messageSearch.rowid = message.id
                WHERE messageSearch MATCH ?
                  AND NOT message.isRetracted AND message.attachment IS NULL
                """
            var arguments: StatementArguments = [pattern]
            if let accountIDs {
                sql += " AND message.accountID IN (\(databaseQuestionMarks(count: accountIDs.count)))"
                arguments += StatementArguments(accountIDs)
            }
            sql += " ORDER BY message.timestamp DESC, message.id DESC LIMIT ?"
            arguments += [limit]
            return try StoredMessage.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    /// How many of a conversation's messages are newer than `messageID`: the
    /// window a chat view must load to show it.
    public func messagesNewer(than messageID: Int64, accountID: String, peer: String) throws -> Int {
        try writer.read { db in
            guard let target = try StoredMessage.fetchOne(db, key: messageID) else { return 0 }
            return try StoredMessage
                .filter(Column("accountID") == accountID && Column("peer") == peer)
                .filter(Column("timestamp") > target.timestamp
                        || (Column("timestamp") == target.timestamp && Column("id") > messageID))
                .fetchCount(db)
        }
    }
}
