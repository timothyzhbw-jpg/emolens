# EmoLens 情绪透镜

**读懂对方那句「没事，你开心就好」。**

EmoLens 是一个开源的 macOS 桌面小工具：像共享屏幕一样实时「看着」你的微信聊天窗口，读出对方刚发来的消息，分析情绪和潜台词，在一个悬浮面板里告诉你：

- 对方现在是什么情绪、有多强烈，情绪冲着谁
- 字面意思和真实想法是否一致：**反话、撒娇、没说完**
- 关系信号：在生我的气、敷衍 / 不想争了、需要安慰、在试探我、冷淡疏远、冷战 / 分手信号、**情感操控**、**自伤风险**、**涉及钱或账号**
- 建议的回应方式，以及一句可以直接发的回复
- **记得每个人**：认出正在和谁聊，参考你们过去的情绪走势和你记下的事（「她在准备考研」「别说她想多了」），判断更贴合你们的情况

<p align="center">
  <img src="docs/screenshots/report.png" width="300" alt="读出反话和潜台词">
  <img src="docs/screenshots/manipulation-dark.png" width="300" alt="识别情感操控（暗色模式）">
</p>

> 默认情况下，截图、文字识别、分析全部在你的电脑上完成（本地 Ollama 模型），不上传任何聊天内容。你也可以在设置里换成 **OpenAI、Claude、DeepSeek、通义千问**等云端大模型：理解潜台词更准，但对方的消息和最近约 10 条上下文会发送给你选的服务商，面板底部会一直提示。
>
> EmoLens 不接入微信协议、不注入、不自动发消息，只读屏幕，因此不会导致封号。

```
微信窗口 ──ScreenCaptureKit 截图──▶ Vision 中文 OCR ──▶ 按气泡左右位置区分「对方 / 我」
      ──▶ 检测到对方的新消息 ──▶ 本地模型分析 ──▶ 悬浮面板
```

## 快速开始

需要：macOS 14+（推荐 Apple Silicon）、Xcode 或 Command Line Tools（Swift 5.10+）、[Ollama](https://ollama.com)。

```bash
ollama pull qwen3.5:4b          # 默认的本地分析模型，约 3.4 GB（只用云端模型可以跳过）
                                # 不用手动 ollama serve，EmoLens 会自己启动
git clone https://github.com/timothyzhbw-jpg/emolens.git && cd emolens
./scripts/build_app.sh          # 生成 build/EmoLens.app
open build/EmoLens.app
```

**建议先做一次（约 1 分钟）：创建本地签名证书。** 打开「钥匙串访问 → 证书助理 → 创建证书…」，名称填 `EmoLens Local`，身份类型「自签名根证书」，证书类型「代码签名」。`build_app.sh` 检测到它就会用它签名。没有它时只能用 ad-hoc 签名，**每次重新构建，macOS 都会把应用当成新的，要求重新授予屏幕录制权限**（系统设置里的开关可能仍显示为打开，但已经不生效，需要先用「−」删掉旧条目）。

打开后面板会浮在最上层，切换桌面空间、或别的应用全屏时都会跟着走；菜单栏也有一个眼睛图标，可以随时把面板叫回来或暂停监控。

用本地模型时不用先开终端：**EmoLens 会自己启动 Ollama**（只对本机地址生效，可在设置里关闭）。本地起不来时会如实报错并告诉你怎么办，**绝不会自动改用云端模型**——聊天内容要不要发出去只能由你决定。

第一次打开时：

1. 在「系统设置 → 隐私与安全性 → 录屏与系统录音」里允许 **EmoLens**，然后重新打开应用。
2. 点面板右上角的齿轮，在窗口截图上**拖一个框，只框住消息气泡那一栏**（不要框左侧会话列表和底部输入框）。
3. 在面板上选好你和对方的关系（恋人 / 家人 / 朋友 / 同事 / 同学）。同一句话在不同关系里意思不一样。

没有微信、或不想拿真实聊天测试？运行演示聊天窗口，每 15 秒会「收到」一条新消息：

```bash
swift run EmoLensDemo
```

然后在 EmoLens 设置里把「要看的窗口」选成「EmoLensDemo」。

## 联系人记忆

<p align="center"><img src="docs/screenshots/memory.png" width="300" alt="联系人记忆与「要记住吗」提示"></p>

EmoLens 会读聊天窗口顶部的名字，认出正在和谁聊（认错了可以在面板上改），并为每个人单独记住：

- **你记下的事**：在「记忆」里随手记，比如近况、喜好、雷区、重要日子。
- **AI 建议记住的事**：对方透露了具体的日子、计划、身体状况或喜好时（「下周三面试」「对虾过敏」），面板会问「要记住吗？」——**只有你点「记住」才会写进去**。
- **情绪走势**：自动累计最近的情绪和关系信号（原话只留前 40 字）。
- **每个人自己的关系**：小美是恋人、王经理是同事，切换聊天时自动切换。

分析时，EmoLens 把这个人的记忆摘要作为背景一起交给模型，并提醒模型「以这次的原话为准」。记忆只存在本机 `~/Library/Application Support/EmoLens/memory.json`（仅你自己可读），可以按人删除或一键清空，也可以在设置里关掉「参考记忆」或「自动记录」。用云端模型时，当前联系人的记忆摘要会随分析一起发送。

## 分析引擎

### 大模型从哪来

| 来源 | 说明 |
|---|---|
| **本地 Ollama**（默认） | `qwen3.5:4b`，数据不出本机，免费。4B 小模型对复杂语境（例如甜言蜜语里夹着控制）偶尔判错 |
| **OpenAI 兼容** | 一套设置支持 OpenAI（默认 `gpt-5.5`）、DeepSeek、通义千问、OpenRouter 和任何兼容 OpenAI 接口的服务；选预设自动填地址，模型名可改 |
| **Anthropic Claude** | 原生 Messages API，默认 `claude-opus-5`，也可选 `claude-sonnet-5`、`claude-haiku-4-5` |

- 云端模型用**结构化输出**（JSON Schema）严格约束返回格式；不支持 JSON Schema 的兼容服务自动改用 JSON 模式。
- `claude-opus-5` 默认开启 Anthropic 的服务端拒答兜底（`fallbacks: "default"`）：极少数情况下安全分类器误拦时，由服务端自动换模型重跑。
- API Key 只保存在 macOS 钥匙串里，不写进配置文件，也不会出现在日志里。
- 云端按量计费：每分析一条消息都是一次请求（系统提示 + 示例约几千 token，会自动缓存）。价格以各服务商官网为准。

### 三种引擎

| 引擎 | 强项 | 弱项 | 占用 |
|---|---|---|---|
| **大模型**（默认） | 能读中文潜台词（反话、敷衍、撒娇、报喜不报忧），会写回复建议 | 本地 4B 小模型不够稳定，严重信号偶尔漏判；换成云端大模型会好很多 | 本地约 5 GB 内存、每条 3–5 秒；云端几乎不占本机资源 |
| **双引擎**（大模型 + [Kev](https://github.com/jaredpalmer/kev) 复核） | 大模型负责潜台词和回复；Kev 并行复核「生我的气 / 冷战 / 操控 / 自伤」，两者取较高值 | 需要同时运行 Kev 服务 | 再多约 10 GB 内存 |
| **决策模型**（Kev，System One API） | 输出校准过的概率，严重信号稳定 | 读不懂中文潜台词（反话、敷衍几乎全漏），没有回复建议，Mac 上较慢 | 约 10 GB 内存 |

此外有两道**关键词安全网**，不依赖模型，任何引擎下都生效：

- **轻生信号**：手段、计划、道别、自伤行为、以死相逼（「把药都攒够了」「我又划了自己」「我就是个累赘」）。在一份 44 条的中文情感评测集上 5/5 命中，39 条反例和「尴尬得想去死」这类玩笑零误报。触发时面板会隐藏「情感操控」标签——给说「我是累赘」的人贴操控标签是有害的。
- **涉及钱或账号**：借钱、转账、卡号、验证码、支付密码。盗号后冒充熟人借钱是最常见的骗局，模型经常判不出（决策模型实测只有 0.31）。触发时建议改成「先打电话或当面核实身份」。亲密关系里要看手机密码不算在内，那属于边界问题。

「情感操控」会误判（「反正我也不重要」这种委屈也常被判成），所以提示语写成对误判无害的说法；如果联系人记忆显示最近 14 天反复出现，才会明确提醒。

任何兼容 [TypeSafe System One API](https://docs.typesafe.ai/api) 的服务都可以作为决策模型引擎。Kev 的启动方式见它的仓库；在 24 GB 内存的 Mac 上建议加 `KEV_MERGE=0`：

```bash
KEV_DTYPE=bf16 KEV_MERGE=0 uv run --extra serve python -m kev.serve --run jaredpalmer/kev-4b --port 8009
```

### 实测（开发时的小样本，仅供参考）

| 测试 | 结果 |
|---|---|
| 30 条微信消息分诊（类别 / 要回复 / 今天处理 / 诈骗 / 语气），另一个模型独立标注的一致率 149/150 | Kev 总体 83–85%，诈骗识别 97%；Laya 33% |
| 8 条未出现在提示词里的情感对话（反话、敷衍、试探、自伤、口头禅、操控、报喜不报忧、正常） | 大模型主要判断正确 7/8；操控漏判，双引擎下由 Kev 补上（0.93）；消极自伤念头由安全网兜底 |
| 44 条中文情感评测集（另一个项目标注，Grok 盲标一致率 95%），默认引擎 qwen3.5:4b | 自伤 5/5、操控 5/5，均零误报；冷淡 3/5；冷战 1/2（5 条误报）；**反话只有 2/5**；情绪类别 54%（全猜最多的一类 26%） |

样本很小，而且是人工构造的对话。请把结果当作提示，不要当作结论。

反话（「呵呵，这公司真是太『公平』了」「都听你的，你永远是对的」）是本地 4B 模型最弱的一项，换成云端大模型会明显好转。评测可以自己重跑：

```bash
swift run EmoLens --eval 你的测试集.jsonl 结果.jsonl   # 每行 {"text": "...", "relationship": "恋人"}
```

## 自定义

分析用的问题和提示词都在 `presets/` 里，改 JSON 就行，不用重新编译（修改后重新打包 .app，或设置环境变量 `EMOLENS_PRESETS` 指向你的目录）：

- `presets/emotion.llm.zh.json`：给生成式模型的 system prompt 和 few-shot 示例
- `presets/emotion.zh.json`：给决策模型的 System One 问题集
- `presets/emotion.schema.json`：云端模型结构化输出用的 JSON Schema

决策模型不直接问「是不是在说反话」——它只会回答两段式问题的后半句。改成问可观察的「TA 是不是说了没事 / 随便 / 你开心就好」，再按规则推出反话（说了 + 情绪不是开心或亲昵）。这个改法来自姊妹项目的实测：34% → 98%。

## 局限

- **只看得到屏幕上的内容**：文字识别依赖框选的区域。图片、表情包、语音不会被分析；群聊昵称的识别是启发式的。
- **只分析对方最新的一条**，上下文取最近约 10 条。切换聊天或往上翻页时会重新对齐。
- **联系人名字靠识别标题栏**：聊天区域要框在名字下方才能认出来；认错或没认出时，在面板上点铅笔手动改。
- **模型会犯错**：尤其是 4B 小模型，同一句话两次的结果可能不同。重要的判断请结合原话和你对对方的了解。
- 没有创建 `EmoLens Local` 签名证书时，`build_app.sh` 只能做 ad-hoc 签名，每次重新构建后都要重新授予屏幕录制权限（见「快速开始」）。
- 目前只针对 Mac 版微信的布局调过参数；其他聊天软件只要是「对方靠左、我靠右」的布局，通常也能用。

<p align="center"><img src="docs/screenshots/safety.png" width="300" alt="自伤风险提醒"></p>

## 负责任地使用

- **这不是心理诊断工具**，也不能代替真诚的沟通。
- 聊天里有对方的隐私。联系人记忆只存在本机，随时可以删；请不要用它监视别人。选用云端模型前，想清楚是否愿意把这些内容交给服务商处理。
- 看到「自伤风险」提醒时：先温和地问一句对方现在是否安全，陪着 TA；如果 TA 提到具体的打算、正在伤害自己或突然联系不上，请马上联系 TA 身边的人，或拨打 120 / 110。心理援助热线：**12356**（多数地区已开通），**希望24热线 400-161-9995**。
- 看到「情感操控」提醒时：你的感受是真实的。可以温和而坚定地守住边界，必要时向信任的人求助。

## 开发

```bash
swift build          # 编译
swift test           # 单元测试（聊天气泡解析、新消息检测、引擎解析与请求格式、安全网）
swift run EmoLens    # 直接运行（屏幕录制权限会记在终端名下）
```

```
Sources/EmoLensCore/   纯逻辑：OCR 行 → 聊天消息、新消息检测、分析引擎（本地 / OpenAI 兼容 / Claude）、安全网
Sources/EmoLens/       macOS 应用：截图、OCR、悬浮面板、设置
Sources/EmoLensDemo/   仿微信演示聊天窗口
presets/               问题集与提示词
```

调试时可以设置 `EMOLENS_LOG=/path/to/reports.jsonl`，把每次分析结果追加写入该文件；设置 `EMOLENS_MEMORY=/path/to/memory.json` 可以让记忆写到别的文件（测试时避免碰到真实记忆）。运行日志：`log stream --predicate 'subsystem == "io.github.emolens"'`（消息正文标为隐私，不会明文出现）。

界面预览：`swift run EmoLens --render-previews docs/screenshots` 会用虚构的示例数据把各种状态（亮色 / 暗色）渲染成 PNG，不截屏、不需要任何权限。

## 致谢

- [Kev](https://github.com/jaredpalmer/kev)：开放权重的 System One 决策模型
- [Ollama](https://ollama.com) 与 [Qwen](https://github.com/QwenLM)
- 本项目由 Claude 牵头完成，OpenAI Codex 实现了聊天气泡解析与新消息检测模块，Grok 审阅了情感维度和提示词。

## 许可证

[Apache License 2.0](LICENSE)

---

**English summary.** EmoLens is an open-source macOS floating-panel app that watches a chat window (WeChat by default) via ScreenCaptureKit, OCRs new messages locally with Apple Vision, and analyzes the other person's latest message with a local model (Ollama, optionally cross-checked by a System One decision model such as Kev): emotion, subtext (sarcasm / coy / unsaid), relationship signals including manipulation and self-harm risk, and a suggested reply. By default everything runs on-device; you can opt into cloud models (OpenAI-compatible services such as OpenAI, DeepSeek, Qwen, OpenRouter, or Anthropic Claude via the native Messages API with structured outputs), in which case the message, recent context and that contact's memory summary are sent to that provider. EmoLens also keeps a local per-contact memory (notes you confirm, emotion trends, per-contact relationship) that is fed back into the analysis. It never touches the WeChat protocol.
