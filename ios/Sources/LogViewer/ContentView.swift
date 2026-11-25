import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var parsedLog: ParsedLog?
    @State private var fileName: String = "尚未載入 Log"
    @State private var errorText: String?
    @State private var showingImporter = false
    @State private var vehicleMass: String = "150"

    var body: some View {
        TabView {
            overviewTab
                .tabItem { Label("總覽", systemImage: "gauge") }
            analysisTab
                .tabItem { Label("分析", systemImage: "chart.xyaxis.line") }
            accelerationTab
                .tabItem { Label("加速", systemImage: "speedometer") }
            tuningTab
                .tabItem { Label("調校", systemImage: "wrench.and.screwdriver") }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.plainText, .commaSeparatedText, .text],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
    }

    private var overviewTab: some View {
        NavigationStack {
            List {
                Section("Log") {
                    Button("匯入 .log / .csv / .txt") { showingImporter = true }
                    Text(fileName)
                    if let errorText { Text(errorText).foregroundStyle(.red) }
                }
                if let parsedLog {
                    Section("即時摘要") {
                        metricRow("資料筆數", "\(parsedLog.rows.count)")
                        metricRow("最高 RPM", formatted(LogAnalysis.max(parsedLog.rows, "RPM")))
                        metricRow("最高車速", formatted(LogAnalysis.max(parsedLog.rows, "Vehicle_Speed"), suffix: " km/h"))
                        metricRow("最低 AFR", formatted(LogAnalysis.min(parsedLog.rows, "AFR")))
                        metricRow("最高溫度", formatted(LogAnalysis.max(parsedLog.rows, "T_Eng"), suffix: " °C"))
                        metricRow("最大噴嘴率", formatted(LogAnalysis.max(parsedLog.rows, "Cyl1_Injector_Period_Rate"), suffix: "%"))
                    }
                }
            }
            .navigationTitle("總覽")
        }
    }

    private var analysisTab: some View {
        NavigationStack {
            List {
                if let parsedLog {
                    let wot = LogAnalysis.bestWOT(parsedLog.rows)
                    let knocks = LogAnalysis.knockRuns(parsedLog.rows)
                    Section("全油門") {
                        if wot.isEmpty { Text("無符合門檻的 WOT") }
                        ForEach(Array(wot.enumerated()), id: \.offset) { _, run in
                            VStack(alignment: .leading) {
                                Text("WOT \(Int(run.score))/100")
                                Text("\(formatTime(run.startTime))–\(formatTime(run.endTime)) · \(String(format: "%.1f", run.duration)) 秒")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("AFR") {
                        let groups: [(String, (LogSample) -> Bool)] = [
                            ("低負載", { ($0.number("TPS_Percent") ?? 0) < 30 }),
                            ("中負載", { ($0.number("TPS_Percent") ?? 0) >= 30 && ($0.number("TPS_Percent") ?? 0) < 70 }),
                            ("高負載", { ($0.number("TPS_Percent") ?? 0) >= 70 })
                        ]
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                            let samples = parsedLog.rows.filter(group.1)
                            Text("\(group.0)：平均 \(formatted(LogAnalysis.average(samples, "AFR"))) · 範圍 \(formatted(LogAnalysis.min(samples, "AFR")))–\(formatted(LogAnalysis.max(samples, "AFR"))) ")
                        }
                    }
                    Section("爆震") {
                        if knocks.isEmpty { Text("未偵測到爆震或退角欄位非零") }
                        ForEach(Array(knocks.enumerated()), id: \.offset) { _, knock in
                            Text("\(formatTime(knock.startTime))–\(formatTime(knock.endTime)) · 最大退角 \(String(format: "%.1f", knock.retard))°")
                        }
                    }
                } else {
                    Text("請先在總覽匯入 Log")
                }
            }
            .navigationTitle("分析")
        }
    }

    private var accelerationTab: some View {
        NavigationStack {
            List {
                Section("車輛參數") {
                    TextField("總重量（kg）", text: $vehicleMass)
                        .keyboardType(.decimalPad)
                }
                if let parsedLog {
                    let bands = [(0.0, 60.0), (0.0, 100.0), (40.0, 80.0), (60.0, 100.0), (80.0, 120.0), (100.0, 150.0)]
                    Section("加速區間") {
                        ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                            let runs = LogAnalysis.speedRuns(parsedLog.rows, low: band.0, high: band.1)
                            Text("\(Int(band.0))–\(Int(band.1)) km/h：\(runs.isEmpty ? "--" : String(format: "%.2f 秒", runs[0].duration))")
                        }
                    }
                    let mass = Double(vehicleMass) ?? 0
                    let power = LogAnalysis.roadPower(parsedLog.rows, mass: mass)
                    Section("道路估算馬力") {
                        if power.isEmpty {
                            Text("沒有足夠的連續加速資料")
                        } else {
                            let peakHP = power.max { $0.hp < $1.hp }
                            let peakTorque = power.max { $0.torque < $1.torque }
                            if let peakHP { metricRow("估算峰值馬力", String(format: "%.1f hp", peakHP.hp)) }
                            if let peakTorque { metricRow("估算峰值扭力", String(format: "%.1f N·m", peakTorque.torque)) }
                            Text("道路估值，不是馬力機實測").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("加速")
        }
    }

    private var tuningTab: some View {
        NavigationStack {
            List {
                if let parsedLog {
                    let score = LogAnalysis.performanceScore(parsedLog.rows)
                    Section("綜合評分") {
                        metricRow("總分", "\(score.total)")
                        metricRow("AFR", "\(score.afr)")
                        metricRow("爆震", "\(score.knock)")
                        metricRow("WOT", "\(score.wot)")
                        metricRow("供油餘裕", "\(score.power)")
                        metricRow("溫度", "\(score.temperature)")
                    }
                    Section("調校優先順序") {
                        let signals = LogAnalysis.tuningSignals(parsedLog.rows)
                        if signals.isEmpty {
                            Text("目前未偵測到主要異常條件")
                        }
                        ForEach(Array(signals.enumerated()), id: \.offset) { index, signal in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(index + 1). \(signal.key)").font(.headline)
                                Text(signal.detail)
                                Text(signal.level == "critical" ? "高優先" : "需留意")
                                    .foregroundStyle(signal.level == "critical" ? .red : .orange)
                            }
                        }
                    }
                } else {
                    Text("請先在總覽匯入 Log")
                }
            }
            .navigationTitle("調校")
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let contents = try String(contentsOf: url, encoding: .utf8)
                let parsed = try LogParser.parse(contents: contents, name: url.lastPathComponent)
                parsedLog = parsed
                fileName = url.lastPathComponent
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
        case .failure(let error):
            errorText = error.localizedDescription
        }
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func formatted(_ value: Double?, suffix: String = "") -> String {
        guard let value else { return "--" }
        return String(format: "%.1f%@", value, suffix)
    }

    private func formatTime(_ milliseconds: Double) -> String {
        let seconds = milliseconds / 1000
        let minutes = Int(seconds / 60)
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, remainder)
    }
}
