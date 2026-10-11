import RepoPromptUI
import SwiftUI
#if os(macOS)
    import AppKit
#endif

struct BenchmarkSettingsView: View {
    @StateObject var viewModel: BenchmarkSettingsViewModel
    @State private var showClearHistoryConfirmation = false
    private let canonicalTaskTotal = 30

    init(promptViewModel: PromptViewModel, apiSettingsViewModel: APISettingsViewModel) {
        _viewModel = StateObject(wrappedValue: BenchmarkSettingsViewModel(
            promptViewModel: promptViewModel,
            apiSettingsViewModel: apiSettingsViewModel
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            tabSelector
            Divider()
            groupedContent
        }
        .padding(20)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Repo Bench")
                .font(.title2).bold()
            Text("Run the benchmark against different models, track history, and compare local rankings.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text("Benchmark runs make ~30 API calls and may incur significant costs.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            .padding(.top, 4)
        }
    }

    private var tabSelector: some View {
        HStack(spacing: 12) {
            ForEach(BenchmarkSettingsViewModel.Tab.allCases) { tab in
                let isSelected = viewModel.activeTab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.activeTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.headline)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        .foregroundColor(isSelected ? .accentColor : .primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var groupedContent: some View {
        Group {
            switch viewModel.activeTab {
            case .run:
                runContent
            case .history:
                historyContent
            case .leaderboard:
                leaderboardContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var runContent: some View {
        ScrollView {
            ViewThatFits(in: .horizontal) {
                wideRunLayout
                compactRunLayout
            }
            .padding(.vertical, 12)
            .animation(.easeInOut(duration: 0.2), value: viewModel.isRunning)
        }
    }

    private var wideRunLayout: some View {
        Group {
            if viewModel.isRunning {
                runStatusColumn(inlineStart: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    runControlsStack(maxWidth: 420)
                    runStatusColumn(inlineStart: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private var compactRunLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.isRunning {
                runStatusColumn(inlineStart: true)
            } else {
                runControlsStack()
                runStatusColumn(inlineStart: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private func runControlsStack(maxWidth: CGFloat? = nil) -> some View {
        if !viewModel.isRunning {
            VStack(alignment: .leading, spacing: 20) {
                configurationSection
                #if DEBUG
                    if let logURL = viewModel.latestLogURL {
                        debugLogCard(url: logURL)
                    }
                #endif
            }
            .frame(maxWidth: maxWidth ?? .infinity, alignment: .leading)
            .transition(.move(edge: maxWidth == nil ? .top : .leading).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func runStatusColumn(inlineStart: Bool) -> some View {
        let showProgress = inlineStart || viewModel.isRunning || shouldShowProgressSection
        let showSummary = !viewModel.isRunning && viewModel.latestSummary != nil
        let showRunLog = shouldShowRunLogSection
        if showProgress || showSummary || showRunLog {
            VStack(alignment: .leading, spacing: 20) {
                if showSummary, let summary = viewModel.latestSummary {
                    resultsCard(summary: summary)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if showProgress {
                    progressSection(forceVisible: inlineStart, inlineStart: inlineStart)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if showRunLog {
                    runLogSection
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var configurationSection: some View {
        BenchmarkCard(
            title: "Run Controls",
            subtitle: "Select a model and manage the canonical benchmark run.",
            systemImage: "slider.horizontal.3",
            spacing: 16
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom, spacing: 16) {
                    modelSelector
                        .frame(maxWidth: 360)
                    Spacer(minLength: 16)
                    runControlButton
                }
                if let error = viewModel.runError {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
                #if DEBUG
                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $viewModel.debugLoggingEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Write debug log to Downloads")
                                    .font(.subheadline)
                                Text("Captures prompts, responses, and verifier results after each run.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .disabled(viewModel.isRunning)

                        DisclosureGroup("Debug individual tests") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Run any test individually and write a debug log. Uses current seed and subseed count.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.bottom, 4)

                                ForEach(viewModel.debugAvailableTests.indices, id: \.self) { idx in
                                    let group = viewModel.debugAvailableTests[idx]
                                    DisclosureGroup("Task Group \(idx + 1) – Seed \(group.seed)") {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ForEach(group.tasks) { ref in
                                                HStack(spacing: 12) {
                                                    Text("\(ref.taskIndex + 1). \(friendlyName(for: ref.spec.type))")
                                                        .font(.callout)
                                                    Spacer()
                                                    if viewModel.runningTestIDs.contains(ref.id) {
                                                        ProgressView().controlSize(.small)
                                                    }
                                                    Button("Run") {
                                                        Task { await viewModel.runSingleTestDebug(ref) }
                                                    }
                                                    .buttonStyle(.borderedProminent)
                                                    .disabled(viewModel.isRunning || viewModel.runningTestIDs.contains(ref.id))
                                                }
                                            }
                                        }
                                        .padding(.leading, 6)
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                #endif
                if !viewModel.lastAudit.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Preflight Audit")
                            .font(.subheadline)
                        ForEach(Array(viewModel.lastAudit.enumerated()), id: \.element.spec.id) { index, audit in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Task Group \(index + 1)")
                                    .font(.callout)
                                Text(audit.solvable ? "Ready" : "Issues detected")
                                    .font(.caption)
                                    .foregroundColor(audit.solvable ? .secondary : .orange)
                                if audit.issues.isEmpty {
                                    Text("No issues detected.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    ForEach(audit.issues.indices, id: \.self) { issueIndex in
                                        let issue = audit.issues[issueIndex]
                                        Label("[\(issue.severity.rawValue.uppercased())] \(issue.code)", systemImage: "exclamationmark.triangle.fill")
                                            .labelStyle(.titleAndIcon)
                                            .font(.caption)
                                            .foregroundColor(severityColor(issue.severity))
                                        Text(issue.message)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    private var shouldShowProgressSection: Bool {
        viewModel.isRunning
    }

    private var shouldShowRunLogSection: Bool {
        viewModel.isRunning
    }

    @ViewBuilder
    private func progressSection(forceVisible: Bool = false, inlineStart: Bool = false) -> some View {
        let show = forceVisible || viewModel.isRunning || shouldShowProgressSection
        if show {
            let completed = min(viewModel.progressSummary.completedTasks, canonicalTaskTotal)
            let percentage = canonicalTaskTotal == 0 ? 0 : Int((Double(completed) / Double(canonicalTaskTotal)) * 100)
            let runningModelName = viewModel.isRunning ? (AIModel.fromModelName(viewModel.selectedModelRaw)?.displayName ?? viewModel.selectedModelRaw) : nil
            BenchmarkCard(
                title: viewModel.isRunning ? "Benchmark running" : "Progress",
                subtitle: viewModel.isRunning ? "Live updates in progress…" : "Most recent canonical run snapshot.",
                systemImage: viewModel.isRunning ? "bolt.fill" : "checkmark.seal.fill",
                trailingTitle: runningModelName
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    ProgressView(value: Double(completed), total: Double(canonicalTaskTotal))
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                    HStack {
                        Text("\(completed) of \(canonicalTaskTotal) tasks complete")
                            .font(.subheadline)
                            .monospacedDigit()
                        Spacer()
                        Text("\(percentage)%")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    if viewModel.progressSummary.totalTasks > canonicalTaskTotal {
                        Text("Processed \(viewModel.progressSummary.totalTasks) tasks in total during the run.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if inlineStart {
                        Divider()
                            .transition(.opacity)
                        Button {
                            if viewModel.isRunning {
                                viewModel.stopRun()
                            } else {
                                viewModel.runBenchmark()
                            }
                        } label: {
                            Label(viewModel.isRunning ? "Stop Run" : "Run Benchmark", systemImage: viewModel.isRunning ? "stop.fill" : "play.circle.fill")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!viewModel.isRunning && viewModel.availableModels.isEmpty)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var runLogSection: some View {
        let steps = viewModel.progressSteps
        return BenchmarkCard(
            title: "Run log",
            subtitle: viewModel.isRunning ? "Live task group updates" : "Latest canonical run",
            systemImage: "list.bullet.rectangle"
        ) {
            if steps.isEmpty, viewModel.latestReport == nil {
                Text("Run the benchmark to see detailed task progress and pass/fail results.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(steps) { step in
                        let state: RunLogRow.State = if step.isComplete {
                            .complete
                        } else if step.isActive, viewModel.isRunning {
                            .active
                        } else {
                            .pending
                        }
                        RunLogRow(
                            title: step.description,
                            detail: step.detailText,
                            additionalInfo: step.additionalInfo,
                            state: state
                        )
                    }
                    if let report = viewModel.latestReport {
                        if !steps.isEmpty {
                            Divider()
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(report.perSeed.indices, id: \.self) { index in
                                let seedReport = report.perSeed[index]
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("Task Group \(index + 1)")
                                            .font(.callout)
                                        Text("Pts \(String(format: "%.1f/%.0f", seedReport.pointsEarned, seedReport.maxPoints)) (\(Int(seedReport.pointsRate * 100))%) • Pass \(Int(seedReport.passRate * 100))%")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    ForEach(seedReport.tasks, id: \.id) { task in
                                        TaskResultRow(
                                            title: friendlyName(for: task.type),
                                            passed: task.pass,
                                            score: task.score,
                                            summary: taskSummary(for: task),
                                            awardedPoints: task.awardedPoints,
                                            maxPoints: task.maxPoints,
                                            normalizedScore: task.normalizedScore
                                        )
                                    }
                                }
                                .padding(14)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        }
                    }
                }
            }
        }
    }

    private func resultsCard(summary: BenchmarkRunSummary) -> some View {
        BenchmarkCard(
            title: "Latest run",
            subtitle: summary.timestamp.formatted(date: .abbreviated, time: .shortened),
            systemImage: "chart.bar.fill"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Label(summary.modelDisplayShort, systemImage: "cpu")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if let hadErrors = summary.hadErrors, hadErrors {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                            .hoverTooltip("This run encountered API errors and is excluded from local rankings")
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        resultMetrics(summary: summary)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        resultMetrics(summary: summary)
                    }
                }
                if !summary.seedSummaries.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(summary.seedSummaries.indices, id: \.self) { index in
                            let seed = summary.seedSummaries[index]
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Task Group \(index + 1)")
                                        .font(.callout)
                                    Text("Pts \(String(format: "%.1f/%.0f", seed.pointsEarned, seed.maxPoints)) • Pass \(Int(seed.passRate * 100))%")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                ForEach(seed.tasks, id: \.id) { task in
                                    TaskResultRow(
                                        title: friendlyName(for: task.type),
                                        passed: task.pass,
                                        score: task.score,
                                        summary: taskSummary(for: task),
                                        awardedPoints: task.awardedPoints,
                                        maxPoints: task.maxPoints,
                                        normalizedScore: task.normalizedScore
                                    )
                                }
                            }
                            .padding(14)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resultMetrics(summary: BenchmarkRunSummary) -> some View {
        BenchmarkMetric(title: "Points rate", value: "\(Int(summary.pointsRate * 100))%")
        BenchmarkMetric(title: "Points earned", value: String(format: "%.1f / %.0f", summary.totalPointsEarned, summary.totalMaxPoints))
        BenchmarkMetric(title: "Pass rate", value: "\(Int(summary.passRate * 100))%")
        BenchmarkMetric(title: "Passed", value: "\(summary.passedTasks)")
        BenchmarkMetric(title: "Failed", value: "\(summary.totalTasks - summary.passedTasks)")
    }

    private func debugLogCard(url: URL) -> some View {
        BenchmarkCard(
            title: "Debug log saved",
            subtitle: "Files are written to Downloads when logging is enabled.",
            systemImage: "doc.richtext"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 12) {
                    Button("Reveal in Finder") {
                        revealLog(at: url)
                    }
                    .buttonStyle(.bordered)
                    Button("Copy Path") {
                        copyLogPath(url)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var runControlButton: some View {
        HStack(spacing: 10) {
            Button {
                if viewModel.isRunning {
                    viewModel.stopRun()
                } else {
                    viewModel.runBenchmark()
                }
            } label: {
                Label(viewModel.isRunning ? "Stop Run" : "Run Benchmark", systemImage: viewModel.isRunning ? "stop.fill" : "play.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.isRunning && viewModel.availableModels.isEmpty)
            if viewModel.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var modelSelector: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model")
                .font(.subheadline)
            OptimizedModelPicker(
                selection: $viewModel.selectedModelRaw,
                availableModels: viewModel.availableModels,
                font: .body,
                widthStyle: .flexible(minWidth: 220, maxWidth: 360, alignment: .leading)
            )
            .accessibilityLabel("Benchmark model")
        }
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Run history")
                    .font(.headline)
                Spacer()
                Button("Export CSV") {
                    if let url = viewModel.exportHistoryToCSV() {
                        revealLog(at: url)
                    }
                }
                .disabled(viewModel.history.isEmpty)
                Button("Clear history") {
                    showClearHistoryConfirmation = true
                }
                .disabled(viewModel.history.isEmpty)
                .confirmationDialog(
                    "Clear all benchmark history?",
                    isPresented: $showClearHistoryConfirmation
                ) {
                    Button("Clear All History", role: .destructive) {
                        viewModel.clearHistory()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently delete all benchmark run history and leaderboard data. This action cannot be undone.")
                }
            }
            if viewModel.history.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("No runs yet")
                        .font(.headline)
                    Text("Run the benchmark to populate history.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(viewModel.history) { run in
                            runHistoryRow(run, onDelete: {
                                if let index = viewModel.history.firstIndex(where: { $0.id == run.id }) {
                                    viewModel.deleteRun(at: IndexSet(integer: index))
                                }
                            })
                        }
                    }
                }
            }
        }
        .padding(.trailing, 4)
    }

    private func runHistoryRow(_ run: BenchmarkRunSummary, onDelete: @escaping () -> Void) -> some View {
        BenchmarkCard(title: nil, subtitle: nil, systemImage: nil) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(run.seedSummaries.indices, id: \.self) { index in
                        let seed = run.seedSummaries[index]
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Task Group \(index + 1)")
                                .font(.subheadline)
                            Text("Pts \(String(format: "%.1f/%.0f", seed.pointsEarned, seed.maxPoints)) (\(Int(seed.pointsRate * 100))%) • Pass \(Int(seed.passRate * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if !seed.tasks.isEmpty {
                                ForEach(seed.tasks, id: \.id) { task in
                                    TaskResultRow(
                                        title: friendlyName(for: task.type),
                                        passed: task.pass,
                                        score: task.score,
                                        summary: taskSummary(for: task),
                                        awardedPoints: task.awardedPoints,
                                        maxPoints: task.maxPoints,
                                        normalizedScore: task.normalizedScore
                                    )
                                }
                            }
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(.top, 6)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        HStack(spacing: 6) {
                            Text(run.modelDisplayShort)
                                .font(.headline)
                            if let hadErrors = run.hadErrors, hadErrors {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                                    .hoverTooltip("This run encountered API errors and is excluded from local rankings")
                            }
                        }
                        Spacer()
                        Button {
                            onDelete()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        Text(run.timestamp, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("Pts \(String(format: "%.1f/%.0f", run.totalPointsEarned, run.totalMaxPoints)) (\(Int(run.pointsRate * 100))%) • Pass \(Int(run.passRate * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var leaderboardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Local rankings")
                    .font(.headline)
            }
            if viewModel.leaderboard.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("No data yet")
                        .font(.headline)
                    Text("Run benchmarks to populate model rankings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.leaderboard.indices, id: \.self) { index in
                            leaderboardRow(rank: index + 1, entry: viewModel.leaderboard[index])
                        }
                    }
                }
            }
        }
        .padding(.trailing, 4)
    }

    private func severityColor(_ severity: BenchmarkAuditIssue.Severity) -> Color {
        switch severity {
        case .error:
            .red
        case .warning:
            .orange
        case .info:
            .secondary
        }
    }

    private func leaderboardRow(rank: Int, entry: BenchmarkLeaderboardEntry) -> some View {
        BenchmarkCard(title: nil, subtitle: nil, systemImage: nil) {
            HStack(spacing: 16) {
                Text("#\(rank)")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .frame(width: 40, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.modelDisplayName)
                        .font(.headline)
                    Text("Pts \(Int(entry.pointsRate * 100))% • Pass \(Int(entry.passRate * 100))% • Tasks \(entry.passedTasks)/\(entry.totalTasks)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(entry.lastRun, style: .date)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func friendlyName(for type: BenchmarkCaseType) -> String {
        let tokens = type.rawValue.split(separator: "_")
        let words = tokens.map { token -> String in
            switch token.lowercased() {
            case "ts":
                return "TypeScript"
            case "go":
                return "Go"
            default:
                return token.capitalized
            }
        }
        return words.joined(separator: " ")
    }

    private func friendlyName(for rawType: String) -> String {
        if let type = BenchmarkCaseType(rawValue: rawType) {
            return friendlyName(for: type)
        }
        let tokens = rawType.split(separator: "_")
        let words = tokens.map { token -> String in
            switch token.lowercased() {
            case "ts":
                return "TypeScript"
            case "go":
                return "Go"
            default:
                return token.capitalized
            }
        }
        return words.joined(separator: " ")
    }

    private func taskSummary(for task: BenchmarkTaskReport) -> String {
        let reason = task.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty {
            return BenchmarkVerifier.humanReadableReason(reason)
        }
        return task.pass ? "Passed" : "Needs review"
    }

    private func taskSummary(for task: BenchmarkTaskSummary) -> String {
        let reason = task.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty {
            return BenchmarkVerifier.humanReadableReason(reason)
        }
        return task.pass ? "Passed" : "Needs review"
    }

    private func revealLog(at url: URL) {
        #if os(macOS)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    private func copyLogPath(_ url: URL) {
        #if os(macOS)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.path, forType: .string)
        #endif
    }
}

private struct BenchmarkCard<Content: View>: View {
    let title: String?
    let subtitle: String?
    let systemImage: String?
    var spacing: CGFloat = 16
    let trailingTitle: String?
    @ViewBuilder var content: Content

    init(title: String?, subtitle: String?, systemImage: String?, spacing: CGFloat = 16, trailingTitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.spacing = spacing
        self.trailingTitle = trailingTitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.headline)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if let trailingTitle {
                        Text(trailingTitle)
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            content
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05))
        )
    }
}

private struct BenchmarkMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
        }
    }
}

private struct RunLogRow: View {
    enum State {
        case pending
        case active
        case complete
    }

    let title: String
    let detail: String
    let additionalInfo: String?
    let state: State

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            stateIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .fontWeight(state == .complete ? .regular : .medium)
                    .foregroundColor(state == .pending ? .secondary : .primary)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let additionalInfo, !additionalInfo.isEmpty {
                    Text(additionalInfo)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch state {
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .active:
            ProgressView()
                .controlSize(.small)
        case .pending:
            Image(systemName: "circle.dashed")
                .foregroundColor(.secondary)
        }
    }
}

private struct TaskResultRow: View {
    let title: String
    let passed: Bool
    let score: Double
    let summary: String
    let awardedPoints: Double?
    let maxPoints: Double?
    let normalizedScore: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                .foregroundColor(passed ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.callout)
                    Spacer()
                    if let awarded = awardedPoints {
                        // Apply 2x multiplier for perfectly completed tasks
                        let normalizedScore = normalizedScore ?? score
                        let multiplier = (passed && normalizedScore >= 1.0) ? 2.0 : 1.0
                        let finalPoints = awarded * multiplier
                        Text(String(format: "%.2f", finalPoints))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text(String(format: "%.2f", score))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
