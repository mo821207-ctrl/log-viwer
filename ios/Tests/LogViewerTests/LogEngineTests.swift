import XCTest
@testable import LogViewer

final class LogEngineTests: XCTestCase {
    func testParserSupportsCommaAndMetadata() throws {
        let text = "Vehicle: Test\nTime,RPM,TPS_Percent,AFR\n0,3000,20,12.8\n100,5000,95,13.2"
        let log = try LogParser.parse(contents: text, name: "test.csv")

        XCTAssertEqual(log.headers, ["Time", "RPM", "TPS_Percent", "AFR"])
        XCTAssertEqual(log.rows.count, 2)
        XCTAssertEqual(log.metadata["Vehicle"], "Test")
        XCTAssertEqual(log.rows[1].number("RPM"), 5000)
    }

    func testParserSupportsSemicolonAndBaseHeaders() throws {
        let text = "Time;RPM/Unit;AFR\n0;4000;12.5\n100;4500;13.0"
        let log = try LogParser.parse(contents: text, name: "test.log")

        XCTAssertEqual(log.headers, ["Time", "RPM", "AFR"])
        XCTAssertEqual(log.rows.count, 2)
    }

    func testWOTAndKnockAnalysis() {
        let rows = [
            sample(time: 0, rpm: 4200, tps: 95, afr: 12.8, knock: 0),
            sample(time: 700, rpm: 5000, tps: 95, afr: 13.0, knock: 1),
            sample(time: 900, rpm: 3000, tps: 20, afr: 14.0, knock: 0)
        ]

        let wot = LogAnalysis.wotRuns(rows)
        XCTAssertEqual(wot.count, 1)
        XCTAssertEqual(wot[0].duration, 0.7, accuracy: 0.01)
        XCTAssertEqual(LogAnalysis.knockRuns(rows).count, 1)
    }

    func testAccelerationRangeAndTuningSignals() {
        var rows: [LogSample] = []
        for index in 0...20 {
            rows.append(LogSample(values: [
                "Time": "\(index * 100)",
                "Vehicle_Speed": "\(index * 5)",
                "RPM": "\(3000 + index * 200)",
                "TPS_Percent": "95",
                "AFR": "13.8",
                "KnockOccur": "0",
                "Cyl1_Injector_Period_Rate": "85",
                "T_Eng": "105"
            ]))
        }

        let runs = LogAnalysis.speedRuns(rows, low: 60, high: 100)
        XCTAssertFalse(runs.isEmpty)
        let signals = LogAnalysis.tuningSignals(rows)
        XCTAssertTrue(signals.contains { $0.key == "afrLean" })
        XCTAssertTrue(signals.contains { $0.key == "highTemp" })

        let score = LogAnalysis.performanceScore(rows)
        XCTAssertGreaterThanOrEqual(score.total, 0)
        XCTAssertLessThanOrEqual(score.total, 100)
    }

    func testRoadPowerReturnsPeaksForAcceleratingData() {
        var rows: [LogSample] = []
        for index in 0...20 {
            rows.append(LogSample(values: [
                "Time": "\(index * 100)",
                "Vehicle_Speed": "\(20 + index * 2)",
                "RPM": "\(2000 + index * 300)"
            ]))
        }
        let points = LogAnalysis.roadPower(rows, mass: 150)
        XCTAssertFalse(points.isEmpty)
        XCTAssertTrue(points.allSatisfy { $0.hp >= 0 })
    }

    private func sample(time: Int, rpm: Int, tps: Int, afr: Double, knock: Int) -> LogSample {
        LogSample(values: [
            "Time": "\(time)",
            "RPM": "\(rpm)",
            "TPS_Percent": "\(tps)",
            "AFR": "\(afr)",
            "KnockOccur": "\(knock)"
        ])
    }
}
