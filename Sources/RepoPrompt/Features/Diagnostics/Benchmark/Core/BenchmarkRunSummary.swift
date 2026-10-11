import Foundation
import RepoPromptAgentCore

struct BenchmarkTaskSummary: Codable, Identifiable {
    let id: String
    let type: String
    let pass: Bool
    let score: Double
    let reason: String
    let difficulty: String
    let maxPoints: Double
    let awardedPoints: Double
    let normalizedScore: Double
}

struct BenchmarkSeedSummary: Codable, Identifiable {
    let seed: UInt32
    let passRate: Double
    let averageScore: Double
    let tasks: [BenchmarkTaskSummary]
    let pointsEarned: Double
    let maxPoints: Double
    let pointsRate: Double

    var id: UInt32 {
        seed
    }
}

struct BenchmarkTypeSummary: Codable, Identifiable {
    let type: String
    let passRate: Double
    let averageScore: Double
    let count: Int
    let pointsEarned: Double
    let maxPoints: Double
    let pointsRate: Double

    var id: String {
        type
    }
}

struct BenchmarkRunSummary: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let modelRawValue: String
    let modelDisplayName: String
    let coreSeed: UInt32
    let subSeeds: [UInt32]
    let totalTasks: Int
    let passedTasks: Int
    let averageScore: Double
    let passRate: Double
    let seedSummaries: [BenchmarkSeedSummary]
    let typeSummaries: [BenchmarkTypeSummary]
    let temperature: Double?
    let totalMaxPoints: Double
    let totalPointsEarned: Double
    let pointsRate: Double
    let hadErrors: Bool?

    var modelDisplayShort: String {
        modelDisplayName.isEmpty ? modelRawValue : modelDisplayName
    }

    var providerName: String {
        guard let model = AIModel.fromModelName(modelRawValue) else {
            return "Unknown"
        }
        return AIProviderType.displayName(for: model.providerType)
    }
}

extension BenchmarkRunSummary {
    static func make(
        report: BenchmarkFinalReport,
        model: AIModel,
        timestamp: Date = Date(),
        temperature: Double? = nil
    ) -> BenchmarkRunSummary {
        let seedSummaries = report.perSeed.map { seed -> BenchmarkSeedSummary in
            let tasks = seed.tasks.map { task in
                BenchmarkTaskSummary(
                    id: task.id,
                    type: task.type.rawValue,
                    pass: task.pass,
                    score: task.score,
                    reason: task.reason,
                    difficulty: task.difficulty.rawValue,
                    maxPoints: task.maxPoints,
                    awardedPoints: task.awardedPoints,
                    normalizedScore: task.normalizedScore
                )
            }
            let passedCount = tasks.filter(\.pass).count
            let passRate = seed.passRate == 0 ? (Double(passedCount) / Double(max(1, tasks.count))) : seed.passRate
            return BenchmarkSeedSummary(
                seed: seed.seed,
                passRate: passRate,
                averageScore: seed.averageScore,
                tasks: tasks,
                pointsEarned: seed.pointsEarned,
                maxPoints: seed.maxPoints,
                pointsRate: seed.pointsRate
            )
        }

        let totalTasks = report.totalTasks
        let passedTasks = seedSummaries.reduce(0) { result, summary in
            result + summary.tasks.filter(\.pass).count
        }
        let passRate = totalTasks == 0 ? 0.0 : Double(passedTasks) / Double(totalTasks)

        let typeSummaries = report.perType.map { key, value in
            BenchmarkTypeSummary(
                type: key.rawValue,
                passRate: value.passRate,
                averageScore: value.averageScore,
                count: value.count,
                pointsEarned: value.pointsEarned,
                maxPoints: value.maxPoints,
                pointsRate: value.pointsRate
            )
        }.sorted { $0.type < $1.type }

        // Check if any task had MODEL_EXECUTION_FAILED error (API error)
        let hadAPIErrors = report.perSeed.contains { seedReport in
            seedReport.tasks.contains { task in
                task.errors.contains { error in
                    error.code == "MODEL_EXECUTION_FAILED"
                }
            }
        }

        return BenchmarkRunSummary(
            id: UUID(),
            timestamp: timestamp,
            modelRawValue: model.rawValue,
            modelDisplayName: model.displayName,
            coreSeed: report.coreSeed,
            subSeeds: report.subSeeds,
            totalTasks: totalTasks,
            passedTasks: passedTasks,
            averageScore: report.averageScore,
            passRate: passRate,
            seedSummaries: seedSummaries,
            typeSummaries: typeSummaries,
            temperature: temperature,
            totalMaxPoints: report.totalMaxPoints,
            totalPointsEarned: report.totalPointsEarned,
            pointsRate: report.pointsRate,
            hadErrors: hadAPIErrors
        )
    }
}

struct BenchmarkLeaderboardEntry: Identifiable {
    let modelRawValue: String
    let modelDisplayName: String
    let runs: Int
    let totalTasks: Int
    let passedTasks: Int
    let averageScore: Double
    let passRate: Double
    let pointsRate: Double
    let lastRun: Date

    var id: String {
        modelRawValue
    }
}
