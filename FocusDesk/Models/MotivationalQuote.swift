import Foundation

struct MotivationalQuote: Identifiable, Equatable {
    let id: String
    let text: String

    // Original encouragements. Keep IDs stable so cached selections survive app updates.
    static let all: [MotivationalQuote] = [
        .init(id: "small-step", text: "天行健，君子以自强不息。"),
        .init(id: "one-thing", text: "路漫漫其修远兮，吾将上下而求索。"),
        .init(id: "daily-growth", text: "一个知道自己为何而活的人，几乎可以忍受任何一种生活。"),
        .init(id: "gentle-start", text: "一点浩然气，千里快哉风。"),
        .init(id: "own-pace", text: "未经省察的人生不值得过。"),
        .init(id: "steady-progress", text: "攀向高峰的奋斗本身，足以充实一个人的心。"),
        .init(id: "return-focus", text: "对你心中一切尚未解决的问题保持耐心。"),
        .init(id: "rest-matters", text: "愤世嫉俗者知道一切事物的价格，却不知道任何事物的价值。"),
        .init(id: "begin-small", text: "人生对我们任何人都不容易，但那又怎样？我们必须有毅力。"),
        .init(id: "quiet-work", text: "此心安处是吾乡。"),
        .init(id: "today-enough", text: "男儿到死心如铁。看试手，补天裂。"),
        .init(id: "try-again", text: "你或许正因为寻求太多，反而无法发现。"),
        .init(id: "patient-growth", text: "只要善加安排，生命足够我们完成伟大的事业。"),
        .init(id: "make-room", text: "不积跬步，无以至千里。"),
        .init(id: "next-step", text: "谁道人生无再少？门前流水尚能西！"),
        .init(id: "small-wins", text: "流光容易把人抛，红了樱桃，绿了芭蕉。"),
        .init(id: "fresh-start", text: "不知道自己驶向哪个港口，任何风都不是顺风。"),
        .init(id: "careful-work", text: "立志欲坚不欲锐，成功在久不在速。"),
        .init(id: "keep-curious", text: "九万里风鹏正举。风休住，蓬舟吹取三山去！"),
        .init(id: "trust-steps", text: "知是行之始，行是知之成。")
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
