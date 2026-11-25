import Foundation

struct LogSample {
    let values: [String: String]

    func number(_ key: String) -> Double? {
        guard let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let number = Double(value.replacingOccurrences(of: ",", with: "."))
        else { return nil }
        return number
    }
}

struct ParsedLog {
    let name: String
    let headers: [String]
    let rows: [LogSample]
    let metadata: [String: String]
}

enum LogParserError: LocalizedError {
    case missingTimeHeader
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .missingTimeHeader: return "找不到 Time 欄位"
        case .emptyFile: return "檔案沒有資料"
        }
    }
}

enum LogParser {
    static func parse(contents: String, name: String) throws -> ParsedLog {
        let cleaned = contents.replacingOccurrences(of: "\u{FEFF}", with: "")
        let lines = cleaned.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !lines.isEmpty else { throw LogParserError.emptyFile }

        guard let headerIndex = lines.firstIndex(where: { line in
            let fields = line.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" })
            return fields.first?.trimmingCharacters(in: .whitespaces) == "Time"
        }) else { throw LogParserError.missingTimeHeader }

        let headerLine = lines[headerIndex]
        let separator: Character = headerLine.contains(";") ? ";" : headerLine.contains("\t") ? "\t" : ","
        let headers = headerLine.split(separator: separator, omittingEmptySubsequences: false).map {
            String($0).split(separator: "/").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        }

        var rows: [LogSample] = []
        if headerIndex + 1 < lines.count {
            for line in lines[(headerIndex + 1)...] {
                let parts = line.split(separator: separator, omittingEmptySubsequences: false)
                guard Double(parts.count) >= Double(headers.count) * 0.8 else { continue }
                var values: [String: String] = [:]
                for (index, header) in headers.enumerated() where index < parts.count {
                    values[header] = String(parts[index]).trimmingCharacters(in: .whitespaces)
                }
                rows.append(LogSample(values: values))
            }
        }

        var metadata = ["name": name]
        if headerIndex > 0 {
            for line in lines[..<headerIndex] {
                if let colon = line.firstIndex(of: ":") {
                    let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { metadata[key] = value }
                }
            }
        }
        return ParsedLog(name: name, headers: headers, rows: rows, metadata: metadata)
    }
}

enum LogAnalysis {
    static func max(_ rows: [LogSample], _ key: String) -> Double? {
        let values = rows.compactMap { $0.number(key) }
        return values.max()
    }

    static func min(_ rows: [LogSample], _ key: String) -> Double? {
        let values = rows.compactMap { $0.number(key) }
        return values.min()
    }

    static func average(_ rows: [LogSample], _ key: String) -> Double? {
        let values = rows.compactMap { $0.number(key) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func standardDeviation(_ rows: [LogSample], _ key: String) -> Double? {
        let values = rows.compactMap { $0.number(key) }
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }

    static func wotRuns(_ rows: [LogSample], tpsThreshold: Double = 90, rpmThreshold: Double = 4000) -> [WOTRun] {
        var runs: [WOTRun] = []
        var start: Int?
        var last: Int?
        var gap: Int?

        func isWOT(_ row: LogSample) -> Bool {
            (row.number("TPS_Percent") ?? 0) >= tpsThreshold &&
            (row.number("RPM") ?? 0) >= rpmThreshold
        }

        for index in rows.indices {
            if isWOT(rows[index]) {
                if start == nil { start = index }
                last = index
                gap = nil
            } else if let currentStart = start, let time = rows[index].number("Time"),
                      let gapIndex = gap {
                if time - (rows[gapIndex].number("Time") ?? time) > 300 {
                    if let end = last { appendRun(currentStart, end) }
                    start = nil
                    last = nil
                    gap = nil
                }
            } else if let currentStart = start {
                gap = gap ?? index
                if let gapIndex = gap,
                   let gapTime = rows[gapIndex].number("Time"),
                   let currentTime = rows[index].number("Time"),
                   currentTime - gapTime > 300 {
                    if let end = last { appendRun(currentStart, end) }
                    start = nil
                    last = nil
                    gap = nil
                }
            }
        }
        if let start, let last { appendRun(start, last) }

        func appendRun(_ startIndex: Int, _ endIndex: Int) {
            let segment = Array(rows[startIndex...endIndex])
            guard let startTime = rows[startIndex].number("Time"),
                  let endTime = rows[endIndex].number("Time") else { return }
            let duration = (endTime - startTime) / 1000
            if duration >= 0.5 {
                runs.append(WOTRun(
                    startTime: startTime,
                    endTime: endTime,
                    duration: duration,
                    maxRPM: max(segment, "RPM"),
                    maxSpeed: max(segment, "Vehicle_Speed"),
                    averageAFR: average(segment, "AFR"),
                    minAFR: min(segment, "AFR"),
                    maxDuty: max(segment, "Cyl1_Injector_Period_Rate")
                ))
            }
        }
        return runs
    }

    static func knockRuns(_ rows: [LogSample]) -> [KnockRun] {
        var runs: [KnockRun] = []
        var start: Int?
        var last: Int?

        func isKnock(_ row: LogSample) -> Bool {
            (row.number("KnockOccur") ?? 0) > 0 ||
            (row.number("KnockSARetard") ?? 0) > 0 ||
            (row.number("Knock_SA_Retard") ?? 0) > 0
        }

        for index in rows.indices {
            if isKnock(rows[index]) {
                if start == nil { start = index }
                last = index
            } else if let currentStart = start, let end = last {
                appendRun(currentStart, end)
                start = nil
                last = nil
            }
        }
        if let start, let last { appendRun(start, last) }

        func appendRun(_ startIndex: Int, _ endIndex: Int) {
            let segment = Array(rows[startIndex...endIndex])
            guard let startTime = rows[startIndex].number("Time"),
                  let endTime = rows[endIndex].number("Time") else { return }
            let retardValues = segment.flatMap {
                [max(0, $0.number("KnockSARetard") ?? 0),
                 max(0, $0.number("Knock_SA_Retard") ?? 0)]
            }
            runs.append(KnockRun(
                startTime: startTime,
                endTime: endTime,
                duration: (endTime - startTime) / 1000,
                retard: retardValues.max() ?? 0,
                level: max(segment, "Knock_Level") ?? 0,
                maxRPM: max(segment, "RPM")
            ))
        }
        return runs
    }

    static func speedRuns(_ rows: [LogSample], low: Double, high: Double) -> [SpeedRun] {
        guard let actualKey = ["PH_GPS_Speed", "Vehicle_Speed", "GPS_Speed"].first(where: {
            rows.first?.values[$0] != nil
        }) else { return [] }
        var startIndex: Int?
        var startTime: Double?
        var runs: [SpeedRun] = []

        for index in 1..<rows.count {
            guard let previous = rows[index - 1].number(actualKey),
                  let current = rows[index].number(actualKey),
                  let previousTime = rows[index - 1].number("Time"),
                  let currentTime = rows[index].number("Time") else { continue }
            if startIndex == nil, previous < low, current >= low {
                let fraction = (low - previous) / max(0.001, current - previous)
                startIndex = index - 1
                startTime = previousTime + fraction * (currentTime - previousTime)
            }
            if let startIndex, let startTime,
               previous < high, current >= high,
               previousTime >= startTime {
                let fraction = (high - previous) / max(0.001, current - previous)
                let endTime = previousTime + fraction * (currentTime - previousTime)
                let duration = (endTime - startTime) / 1000
                if duration > 0, duration < 60 {
                    let segment = Array(rows[startIndex...min(index, rows.count - 1)])
                    runs.append(SpeedRun(
                        low: low, high: high, startTime: startTime, endTime: endTime,
                        duration: duration, key: actualKey,
                        averageAFR: average(segment, "AFR"),
                        maxTPS: max(segment, "TPS_Percent")
                    ))
                }
                startIndex = nil
                startTime = nil
            }
            if let startTime, currentTime - startTime > 60000 {
                startIndex = nil
                startTime = nil
            }
        }
        return runs.sorted { $0.duration < $1.duration }
    }

    static func performanceScore(_ rows: [LogSample]) -> PerformanceScore {
        let highLoad = rows.filter { ($0.number("TPS_Percent") ?? 0) >= 70 }
        let afrDeviation = standardDeviation(highLoad, "AFR")
        let afr = afrDeviation == nil ? 50 : max(0, 100 - afrDeviation! * 25)
        let knockCount = knockRuns(rows).count
        let knock = max(0, 100 - Double(knockCount) * 12)
        let wot = bestWOT(rows).first?.score ?? 40
        let duty = max(rows, "Cyl1_Injector_Period_Rate")
        let power = duty == nil ? 50 : max(0, 100 - abs(75 - min(100, duty!)) * 2)
        let temperature = max(rows, "T_Eng")
        let temp = temperature == nil ? 50 : max(0, 100 - max(0, temperature! - 90) * 4)
        let total = Int(round(afr * 0.25 + knock * 0.25 + wot * 0.20 + power * 0.15 + temp * 0.15))
        return PerformanceScore(total: total, afr: Int(round(afr)), knock: Int(round(knock)),
                                wot: Int(round(wot)), power: Int(round(power)), temperature: Int(round(temp)))
    }

    static func bestWOT(_ rows: [LogSample]) -> [WOTRun] {
        wotRuns(rows).map { run in
            let segment = rows.filter {
                ($0.number("Time") ?? 0) >= run.startTime &&
                ($0.number("Time") ?? 0) <= run.endTime
            }
            let afrSD = standardDeviation(segment, "AFR") ?? 9
            let tpsSD = standardDeviation(segment, "TPS_Percent") ?? 9
            let knockCount = knockRuns(segment).count
            let score = max(0, 100 - min(30, afrSD * 15) - min(20, tpsSD * 2) - min(40, Double(knockCount) * 10))
            var result = run
            result.score = Int(round(score))
            return result
        }.sorted { $0.score > $1.score }
    }

    static func tuningSignals(_ rows: [LogSample]) -> [TuningSignal] {
        let highLoad = rows.filter { ($0.number("TPS_Percent") ?? 0) >= 70 }
        let afr = average(highLoad, "AFR")
        let knockCount = knockRuns(rows).count
        let duty = max(rows, "Cyl1_Injector_Period_Rate")
        let temperature = max(rows, "T_Eng")
        let iat = max(rows, "T_Air_indx")
        let voltage = min(rows, "Volt_Batt_indx")
        var signals: [TuningSignal] = []
        if let afr, afr > 13.4 { signals.append(.init(key: "afrLean", level: "critical", priority: 100, detail: "高負載平均 AFR \(String(format: "%.1f", afr))")) }
        if let afr, afr < 11.5 { signals.append(.init(key: "afrRich", level: "warning", priority: 75, detail: "高負載平均 AFR \(String(format: "%.1f", afr))")) }
        if knockCount > 0 { signals.append(.init(key: "knock", level: "critical", priority: 95, detail: "偵測 \(knockCount) 次爆震事件")) }
        if let iat, iat > 50 { signals.append(.init(key: "highIat", level: "warning", priority: 55, detail: "最高進氣溫度 \(String(format: "%.1f", iat)) °C")) }
        if let temperature, temperature > 110 { signals.append(.init(key: "highTemp", level: "critical", priority: 90, detail: "最高引擎溫度 \(String(format: "%.1f", temperature)) °C")) }
        else if let temperature, temperature > 100 { signals.append(.init(key: "highTemp", level: "warning", priority: 60, detail: "最高引擎溫度 \(String(format: "%.1f", temperature)) °C")) }
        if let duty, duty > 90 { signals.append(.init(key: "injectorDuty", level: "critical", priority: 85, detail: "最大噴嘴使用率 \(String(format: "%.1f", duty))%")) }
        else if let duty, duty > 80 { signals.append(.init(key: "injectorDuty", level: "warning", priority: 50, detail: "最大噴嘴使用率 \(String(format: "%.1f", duty))%")) }
        if let voltage, voltage < 12 { signals.append(.init(key: "lowVoltage", level: "warning", priority: 65, detail: "最低電壓 \(String(format: "%.1f", voltage)) V")) }
        return signals.sorted { $0.priority > $1.priority }
    }

    static func roadPower(_ rows: [LogSample], mass: Double, crr: Double = 0.015, cda: Double = 0.68) -> [PowerPoint] {
        guard mass > 0, let key = ["PH_GPS_Speed", "Vehicle_Speed", "GPS_Speed"].first(where: {
            rows.first?.values[$0] != nil
        }) else { return [] }
        let smoothed = movingAverage(rows.compactMap { $0.number(key).map { $0 / 3.6 } }, window: 4)
        var points: [PowerPoint] = []
        let rho = 1.225
        let gravity = 9.80665
        guard rows.count > 4 else { return [] }
        for index in 2...(rows.count - 3) {
            guard smoothed[index - 2] != nil, smoothed[index + 2] != nil,
                  let rpm = rows[index].number("RPM"),
                  let time1 = rows[index - 2].number("Time"),
                  let time2 = rows[index + 2].number("Time"),
                  let speed = smoothed[index] else { continue }
            let dt = (time2 - time1) / 1000
            guard dt > 0 else { continue }
            let acceleration = ((smoothed[index + 2] ?? speed) - (smoothed[index - 2] ?? speed)) / dt
            guard speed >= 5 / 3.6, acceleration > 0 else { continue }
            let force = mass * acceleration + mass * gravity * crr + 0.5 * rho * cda * speed * speed
            let powerWatts = force * speed
            guard powerWatts >= 0, powerWatts <= 1_000_000, rpm >= 500 else { continue }
            let hp = powerWatts / 745.6998716
            let ps = powerWatts / 735.49875
            let torque = powerWatts / (rpm * 2 * Double.pi / 60)
            points.append(PowerPoint(time: rows[index].number("Time") ?? 0, rpm: rpm,
                                     speed: speed * 3.6, acceleration: acceleration,
                                     hp: hp, ps: ps, torque: torque, key: key))
        }
        return points
    }

    private static func movingAverage(_ values: [Double], window: Int) -> [Double?] {
        values.enumerated().map { index, _ in
            let lower = max(0, index - window)
            let upper = min(values.count - 1, index + window)
            let slice = Array(values[lower...upper])
            guard !slice.isEmpty else { return nil }
            return slice.reduce(0, +) / Double(slice.count)
        }
    }
}

struct WOTRun {
    let startTime: Double
    let endTime: Double
    let duration: Double
    let maxRPM: Double?
    let maxSpeed: Double?
    let averageAFR: Double?
    let minAFR: Double?
    let maxDuty: Double?
    var score: Int = 0
}

struct KnockRun {
    let startTime: Double
    let endTime: Double
    let duration: Double
    let retard: Double
    let level: Double
    let maxRPM: Double?
}

struct SpeedRun {
    let low: Double
    let high: Double
    let startTime: Double
    let endTime: Double
    let duration: Double
    let key: String
    let averageAFR: Double?
    let maxTPS: Double?
}

struct PerformanceScore {
    let total: Int
    let afr: Int
    let knock: Int
    let wot: Int
    let power: Int
    let temperature: Int
}

struct TuningSignal {
    let key: String
    let level: String
    let priority: Int
    let detail: String
}

struct PowerPoint {
    let time: Double
    let rpm: Double
    let speed: Double
    let acceleration: Double
    let hp: Double
    let ps: Double
    let torque: Double
    let key: String
}
