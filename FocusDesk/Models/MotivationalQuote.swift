import Foundation

struct MotivationalQuote: Identifiable, Equatable {
    let id: String
    let text: String

    let explanation: String
    let source: String

    // Keep IDs stable so cached selections survive app updates.
    // Explanations are editorial paraphrases; translated excerpts are labeled in the source.
    static let all: [MotivationalQuote] = [
        .init(id: "small-step", text: "天行健，君子以自强不息。", explanation: "自然运行刚健不息，君子也应不断进取。把自我提升落实到今天的一次行动中。", source: "《周易·乾卦·象传》"),
        .init(id: "one-thing", text: "路漫漫其修远兮，吾将上下而求索。", explanation: "追寻理想的道路漫长而艰难，仍要不断探索。眼前暂时没有答案，也可以继续求索。", source: "屈原《离骚》"),
        .init(id: "daily-growth", text: "一个知道自己为何而活的人，几乎可以忍受任何一种生活。", explanation: "清楚自己为何而努力，往往能更有力量地面对困难。先找到行动的意义，再走好眼前这一步。", source: "尼采《偶像的黄昏》“格言与箭”第 12 则（中文意译）"),
        .init(id: "gentle-start", text: "一点浩然气，千里快哉风。", explanation: "胸中保有正直坦荡的气概，即使身处逆境，也能感受到开阔与自在。", source: "苏轼《水调歌头·黄州快哉亭赠张偓佺》"),
        .init(id: "own-pace", text: "未经省察的人生不值得过。", explanation: "留出时间审视自己的选择与生活，才能更清楚地知道什么值得投入。", source: "柏拉图《申辩篇》38a，苏格拉底在审判中的发言（中文译述）"),
        .init(id: "steady-progress", text: "攀向高峰的奋斗本身，足以充实一个人的心。", explanation: "即使结果尚未到来，清醒地投入奋斗，本身也能赋予生活充实感。", source: "阿尔贝·加缪《西西弗神话》末章（中文节译）"),
        .init(id: "return-focus", text: "对你心中一切尚未解决的问题保持耐心。", explanation: "不必催促所有困惑立刻得到答案。允许自己在经历和实践中，慢慢长出理解。", source: "里尔克《给青年诗人的信》第四封，1903 年 7 月 16 日（中文节译）"),
        .init(id: "rest-matters", text: "愤世嫉俗者知道一切事物的价格，却不知道任何事物的价值。", explanation: "价格可以衡量成本，却无法穷尽事物的意义。也为热爱、关系和成长保留位置。", source: "奥斯卡·王尔德《温德米尔夫人的扇子》第三幕，道林顿勋爵的台词（中文译述）"),
        .init(id: "begin-small", text: "人生对我们任何人都不容易，但那又怎样？我们必须有毅力。", explanation: "困难是生活的一部分。承认它的存在，同时保有毅力，继续做自己认定有价值的事。", source: "玛丽·居里；见艾芙·居里《居里夫人传》所引书信（中文节译）"),
        .init(id: "quiet-work", text: "此心安处是吾乡。", explanation: "能让内心安定的地方，就是精神上的归宿。身在变化之中，也可以培养自己的安稳与从容。", source: "苏轼《定风波·南海归赠王定国侍人寓娘》"),
        .init(id: "today-enough", text: "男儿到死心如铁。看试手，补天裂。", explanation: "即使遭遇挫折，仍不放弃坚定的志向。词中以“补天裂”表达挽救时局的抱负。", source: "辛弃疾《贺新郎·同父见和再用韵答之》"),
        .init(id: "try-again", text: "你或许正因为寻求太多，反而无法发现。", explanation: "过于执着于预设的答案，可能会忽略眼前的发现。试着放下急切，认真观察当下。", source: "赫尔曼·黑塞《悉达多》“乔文达”一章（中文译述）"),
        .init(id: "patient-growth", text: "只要善加安排，生命足够我们完成伟大的事业。", explanation: "生命的充裕不仅取决于长度，也取决于怎样使用时间。把精力分给真正重要的事情。", source: "塞涅卡《论生命之短暂》第一章（中文意译）"),
        .init(id: "make-room", text: "不积跬步，无以至千里。", explanation: "远大的目标来自细小行动的累积。先完成眼前能做的一步，让进展逐渐发生。", source: "荀子《劝学》；“跬步”指半步"),
        .init(id: "next-step", text: "谁道人生无再少？门前流水尚能西！", explanation: "流水尚能向西，人生也不必因年龄或境遇而自我设限。保持重新开始的心气。", source: "苏轼《浣溪沙·游蕲水清泉寺》"),
        .init(id: "small-wins", text: "流光容易把人抛，红了樱桃，绿了芭蕉。", explanation: "春去夏来，时光在景物变化间悄然流逝。这句原含惜春之情，也提醒人珍惜当下。", source: "蒋捷《一剪梅·舟过吴江》"),
        .init(id: "fresh-start", text: "不知道自己驶向哪个港口，任何风都不是顺风。", explanation: "先明确方向，机会和努力才有着力之处。开始忙碌之前，想清楚自己要抵达哪里。", source: "塞涅卡《致卢西利乌斯道德书简》第 71 封第 3 节（中文意译）"),
        .init(id: "careful-work", text: "立志欲坚不欲锐，成功在久不在速。", explanation: "立志贵在坚定持久，成事依靠长期积累。找到能持续下去的节奏，不必急于一时。", source: "张孝祥《论治体札子》"),
        .init(id: "keep-curious", text: "九万里风鹏正举。风休住，蓬舟吹取三山去！", explanation: "词人借大鹏展翅、乘风远行的想象，表达对自由境界和理想的追求。给自己的志向留一点辽阔。", source: "李清照《渔家傲·天接云涛连晓雾》"),
        .init(id: "trust-steps", text: "知是行之始，行是知之成。", explanation: "认识引导行动，行动又使认识得到完成。把学到的一点道理，放进实际生活中试一试。", source: "王守仁（王阳明）《传习录》卷上，徐爱录")
    ]
}

/// A persisted hourly random rotation. The caller supplies the clock and decides when to refresh.
final class QuoteRotation {
    static let refreshInterval: TimeInterval = 60 * 60
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
