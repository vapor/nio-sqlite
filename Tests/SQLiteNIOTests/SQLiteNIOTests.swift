import XCTest
import SQLiteNIO

final class SQLiteNIOTests: XCTestCase {
    func testBasicConnection() throws {
        let conn = try SQLiteConnection.open(storage: .memory, threadPool: self.threadPool, on: self.eventLoop).wait()
        defer { try! conn.close().wait() }

        let rows = try conn.query("SELECT sqlite_version()").wait()
        print(rows)
    }

    func testZeroLengthBlob() throws {
        let conn = try SQLiteConnection.open(storage: .memory, threadPool: self.threadPool, on: self.eventLoop).wait()
        defer { try! conn.close().wait() }

        let rows = try conn.query("SELECT zeroblob(0) as zblob").wait()
        print(rows)
    }

    func testTimestampStorage() throws {
        let conn = try SQLiteConnection.open(storage: .memory, threadPool: self.threadPool, on: self.eventLoop).wait()
        defer { try! conn.close().wait() }

        let date = Date()
        let rows = try conn.query("SELECT ? as date", [date.sqliteData!]).wait()
        XCTAssertEqual(rows[0].column("date"), .float(date.timeIntervalSince1970))
        XCTAssertEqual(Date(sqliteData: rows[0].column("date")!)?.description, date.description)
    }

    func testTimestampStorageInDateColumnIntegralValue() throws {
        let conn = try SQLiteConnection.open(storage: .memory, threadPool: self.threadPool, on: self.eventLoop).wait()
        defer { try! conn.close().wait() }

        let date = Date(timeIntervalSince1970: 42)
        // This is how a column of type .date is crated when using Vapor’s
        // scheme table creation.
        _ = try conn.query(#"CREATE TABLE "test" ("date" DATE NOT NULL);"#).wait()
        _ = try conn.query(#"INSERT INTO test (date) VALUES (?);"#, [date.sqliteData!]).wait()
        let rows = try conn.query("SELECT * FROM test;").wait()
        XCTAssertTrue(rows[0].column("date") == .float(date.timeIntervalSince1970) || rows[0].column("date") == .integer(Int(date.timeIntervalSince1970)))
        XCTAssertEqual(Date(sqliteData: rows[0].column("date")!)?.description, date.description)
    }

    func testDuplicateColumnName() throws {
        let conn = try SQLiteConnection.open(storage: .memory, threadPool: self.threadPool, on: self.eventLoop).wait()
        defer { try! conn.close().wait() }

        let rows = try conn.query("SELECT 1 as foo, 2 as foo").wait()
        var i = 0
        for column in rows[0].columns {
            XCTAssertEqual(column.name, "foo")
            i += column.data.integer!
        }
        XCTAssertEqual(i, 3)
        XCTAssertEqual(rows[0].column("foo")?.integer, 1)
        XCTAssertEqual(rows[0].columns.filter { $0.name == "foo" }[1].data.integer, 2)
    }

	func testCustomAggregate() throws {
		let conn = try SQLiteConnection.open(storage: .memory, threadPool: self.threadPool, on: self.eventLoop).wait()
		defer { try! conn.close().wait() }

		_ = try conn.query(#"CREATE TABLE "test" ("score" INTEGER NOT NULL);"#).wait()
		_ = try conn.query(#"INSERT INTO test (score) VALUES (?), (?), (?);"#, [.integer(3), .integer(4), .integer(5)]).wait()

		struct MyAggregate: DatabaseAggregate {
			var sum: Int = 0
			mutating func step(_ dbValues: [SQLiteData]) throws {
				sum = sum + (dbValues.first?.integer ?? 0)
			}

			func finalize() throws -> SQLiteDataConvertible? {
				sum
			}
		}

		let function = DatabaseFunction("my_sum", aggregate: MyAggregate.self)
		try function.install(in: conn)

		let rows = try conn.query("SELECT my_sum() as my_sum FROM test").wait()
		XCTAssertEqual(rows.first?.column("my_sum")?.integer, 10)
	}

	func testDatabaseFunction() throws {
		let conn = try SQLiteConnection.open(storage: .memory, threadPool: self.threadPool, on: self.eventLoop).wait()
		defer { try! conn.close().wait() }

		let function = DatabaseFunction("my_custom_function") { args in
			print(args)
			let result = Int(args[0].integer! * 3)
			print(result)
			return SQLiteData.integer(result)
		}

		try function.install(in: conn)
		let rows = try conn.query("SELECT my_custom_function(2) as my_value").wait()
		print(rows)
		XCTAssertEqual(rows.first?.column("my_value")?.integer, 6)
	}

    var threadPool: NIOThreadPool!
    var eventLoopGroup: EventLoopGroup!
    var eventLoop: EventLoop {
        return self.eventLoopGroup.next()
    }

    override func setUp() {
        self.threadPool = .init(numberOfThreads: 8)
        self.threadPool.start()
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 8)
    }

    override func tearDown() {
        try! self.threadPool.syncShutdownGracefully()
        try! self.eventLoopGroup.syncShutdownGracefully()
    }
}
