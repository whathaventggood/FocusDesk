import Foundation

struct MotivationalQuote: Identifiable, Equatable {
    let id: String
    let text: String

    // Original encouragements. Keep IDs stable so cached selections survive app updates.
    static let all: [MotivationalQuote] = [
        .init(id: "small-step", text: "先把眼前这一小步走好。"),
        .init(id: "one-thing", text: "专注一件事，就是向前一步。"),
        .init(id: "daily-growth", text: "今天的积累，会成为明天的底气。"),
        .init(id: "gentle-start", text: "不必等到准备完美，现在就能开始。"),
        .init(id: "own-pace", text: "按自己的节奏，慢慢把事情做好。"),
        .init(id: "steady-progress", text: "一点点推进，也是在认真前行。"),
        .init(id: "return-focus", text: "走神没关系，轻轻把注意力带回来。"),
        .init(id: "rest-matters", text: "好好休息，也是在为下一步蓄力。"),
        .init(id: "begin-small", text: "把大目标拆小，先完成手边这一件。"),
        .init(id: "quiet-work", text: "安静做事的每一刻，都在积累力量。"),
        .init(id: "today-enough", text: "今天做好的这一点，值得被看见。"),
        .init(id: "try-again", text: "遇到难处，换个小步骤再试一次。"),
        .init(id: "patient-growth", text: "给成长一点耐心，给自己一点空间。"),
        .init(id: "make-room", text: "留一点余地，让专注走得更长久。"),
        .init(id: "next-step", text: "看清下一步，就已经有了方向。"),
        .init(id: "small-wins", text: "每完成一小件，都让目标近一点。"),
        .init(id: "fresh-start", text: "此刻重新开始，也一样有意义。"),
        .init(id: "careful-work", text: "用心完成的事，自有它的分量。"),
        .init(id: "keep-curious", text: "带着一点好奇，继续探索眼前的事。"),
        .init(id: "trust-steps", text: "不用急着抵达，脚下的每一步都算数。")
    ]
}

/// A persisted six-hour rotation. The caller supplies the clock and decides when to refresh.
final class QuoteRotation {
    static let refreshInterval: TimeInterval = 6 * 60 * 60
    static let cacheKey = "motivationalQuote.v1"

    private let defaults: UserDefaults
    private let chooseIndex: (Int) -> Int

    init(
        defaults: UserDefaults = .standard,
        chooseIndex: @escaping (Int) -> Int = { Int.random(in: 0..<$0) }
    ) {
        self.defaults = defaults
        self.chooseIndex = chooseIndex
    }

    func quote(at date: Date) -> MotivationalQuote {
        let cache = defaults.object(forKey: Self.cacheKey) as? [String: Any]
        let previous = (cache?["id"] as? String).flatMap { id in
            MotivationalQuote.all.first { $0.id == id }
        }

        if let previous,
           let selectedAt = cache?["selectedAt"] as? Date,
           selectedAt.timeIntervalSinceReferenceDate.isFinite {
            let elapsed = date.timeIntervalSince(selectedAt)
            if elapsed < 0 {
                // A clock correction must not freeze the rotation until the old future date.
                persist(previous, selectedAt: date)
                return previous
            }
            if elapsed < Self.refreshInterval {
                return previous
            }
        }

        // One fresh selection after a long sleep; no catch-up loop or consecutive repeats.
        let candidates = MotivationalQuote.all.filter { $0.id != previous?.id }
        let index = chooseIndex(candidates.count)
        let selected = candidates[candidates.indices.contains(index) ? index : 0]
        persist(selected, selectedAt: date)
        return selected
    }

    private func persist(_ quote: MotivationalQuote, selectedAt date: Date) {
        defaults.set(["id": quote.id, "selectedAt": date], forKey: Self.cacheKey)
    }
}
