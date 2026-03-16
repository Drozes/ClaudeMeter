import Foundation

struct UsageMeter: Equatable {
    let label: String
    let percentage: Int
    let detail: String
}

struct UsageSection: Equatable {
    let title: String
    let meters: [UsageMeter]
}
