import XCTest

final class LoggerProtocolTests: XCTestCase {
    func testClockCommand() {
        let d = LoggerProtocol.setClock(Date(timeIntervalSince1970: 0x0102_0304))
        XCTAssertEqual([UInt8](d), [0x01, 0x04, 0x03, 0x02, 0x01])
    }

    func testStatus() {
        let s = LoggerProtocol.parseStatus(Data([1, 87, 0x10, 0x27, 1, 0xC4]))
        XCTAssertEqual(s, .init(bandConnected: true, batteryPercent: 87, storedReadings: 10000, clockSet: true, bandRSSI: -60))
    }

    func testReadingsPacket() {
        let bytes: [UInt8] = [0xD1, 2, 0x10, 0, 0, 0, 150, 0x11, 0, 0, 0, 152]
        XCTAssertEqual(LoggerProtocol.parsePacket(Data(bytes)), .readings([
            .init(time: Date(timeIntervalSince1970: 16), bpm: 150),
            .init(time: Date(timeIntervalSince1970: 17), bpm: 152)
        ]))
        XCTAssertEqual(LoggerProtocol.parsePacket(Data([0xD2, 0x2C, 0x01])), .end(total: 300))
        XCTAssertNil(LoggerProtocol.parsePacket(Data([0xD1, 3, 1, 2])), "a short packet is ignored")
    }

    func testGapFillersOnlyFillTheGap() {
        let start = Date(timeIntervalSince1970: 1000)
        // The phone has 1000-1010 and 1041-1050; the logger has everything.
        let existing = (1...10).map { start.addingTimeInterval(Double($0)) } + (41...50).map { start.addingTimeInterval(Double($0)) }
        let logger = (1...50).map { LoggerProtocol.Reading(time: start.addingTimeInterval(Double($0)), bpm: 140) }
        let fill = LoggerProtocol.gapFillers(logger, existing: existing, from: start, to: start.addingTimeInterval(50))
        XCTAssertEqual(fill.first?.time, start.addingTimeInterval(12))
        XCTAssertEqual(fill.last?.time, start.addingTimeInterval(39))
        XCTAssertEqual(fill.count, 28)
    }

    func testReadingsOutsideTheSessionAreIgnored() {
        let start = Date(timeIntervalSince1970: 1000)
        let logger = [LoggerProtocol.Reading(time: Date(timeIntervalSince1970: 900), bpm: 80),
                      LoggerProtocol.Reading(time: Date(timeIntervalSince1970: 2000), bpm: 80)]
        XCTAssertTrue(LoggerProtocol.gapFillers(logger, existing: [], from: start, to: Date(timeIntervalSince1970: 1500)).isEmpty)
    }
}
