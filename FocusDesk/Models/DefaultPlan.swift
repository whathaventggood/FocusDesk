import Foundation

enum DefaultPlan {
    static let tasks: [PlanTask] = [
        PlanTask(startMinutes: 0, endMinutes: 480, title: "睡眠", details: "保证约 8 小时睡眠"),
        PlanTask(startMinutes: 480, endMinutes: 500, title: "起床洗漱", details: "洗脸、刷牙、整理床铺，禁止躺床上玩手机"),
        PlanTask(startMinutes: 500, endMinutes: 530, title: "早餐 + 散步", details: "吃早餐，出去走走，接触自然光"),
        PlanTask(startMinutes: 530, endMinutes: 540, title: "制定今日计划", details: "写下今天必须完成的 3 个学习目标"),
        PlanTask(startMinutes: 540, endMinutes: 590, title: "Agent 理论学习①", details: "学习新知识，例如 MCP、RAG、Agent 架构、Python 异步"),
        PlanTask(startMinutes: 590, endMinutes: 600, title: "休息 10 分钟", details: "离开座位，散步、喝水、看窗外"),
        PlanTask(startMinutes: 600, endMinutes: 650, title: "Agent 理论学习②", details: "阅读技术文档，运行示例代码，理解实现原理"),
        PlanTask(startMinutes: 650, endMinutes: 670, title: "休息 20 分钟", details: "出去散步，闭眼休息，禁止刷手机"),
        PlanTask(startMinutes: 670, endMinutes: 720, title: "Agent 实践学习", details: "自己编写代码，验证上午学习的技术"),
        PlanTask(startMinutes: 720, endMinutes: 760, title: "午饭", details: "正常吃饭，适当放松"),
        PlanTask(startMinutes: 760, endMinutes: 790, title: "午休", details: "午睡 15～20 分钟，其余时间放松"),
        PlanTask(startMinutes: 790, endMinutes: 810, title: "散步 + 准备", details: "活动身体，回到学习状态"),
        PlanTask(startMinutes: 810, endMinutes: 860, title: "Agent 项目开发①", details: "FinPilot / Coding Agent，实现一个具体功能"),
        PlanTask(startMinutes: 860, endMinutes: 870, title: "休息 10 分钟", details: "起身活动、喝水"),
        PlanTask(startMinutes: 870, endMinutes: 920, title: "Agent 项目开发②", details: "继续开发，完成核心逻辑"),
        PlanTask(startMinutes: 920, endMinutes: 930, title: "A 股复盘（可选）", details: "收盘后看持仓、交易计划，最多 10 分钟"),
        PlanTask(startMinutes: 930, endMinutes: 980, title: "Agent 项目开发③", details: "调试代码，处理异常，解决技术问题"),
        PlanTask(startMinutes: 980, endMinutes: 990, title: "休息 10 分钟", details: "散步、拉伸、闭眼"),
        PlanTask(startMinutes: 990, endMinutes: 1_040, title: "Agent 项目开发④", details: "编写测试、检查代码、Git 提交"),
        PlanTask(startMinutes: 1_040, endMinutes: 1_080, title: "运动", details: "跑步、引体向上、散步，按身体状态调整"),
        PlanTask(startMinutes: 1_080, endMinutes: 1_140, title: "晚饭 + 洗澡", details: "补充能量，充分放松"),
        PlanTask(startMinutes: 1_140, endMinutes: 1_190, title: "Agent 面试准备", details: "Agent 八股、Python 八股、项目设计原理"),
        PlanTask(startMinutes: 1_190, endMinutes: 1_200, title: "休息 10 分钟", details: "走动、喝水"),
        PlanTask(startMinutes: 1_200, endMinutes: 1_250, title: "Agent 知识巩固", details: "复盘当天代码、整理笔记、解释技术实现"),
        PlanTask(startMinutes: 1_250, endMinutes: 1_290, title: "自由休息", details: "散步、聊天、听音乐，尽量不碰手机"),
        PlanTask(startMinutes: 1_290, endMinutes: 1_350, title: "Codeforces", details: "独立思考一道题，卡住就学题解，总结关键性质"),
        PlanTask(startMinutes: 1_350, endMinutes: 1_380, title: "洗漱 + 放松", details: "洗漱、整理明天需要的东西"),
        PlanTask(startMinutes: 1_380, endMinutes: 1_440, title: "睡前休息", details: "不碰短视频、不打游戏，尽量在宿舍安静后入睡")
    ]
}
