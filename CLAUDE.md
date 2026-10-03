# EmoLens（情绪透镜）

macOS 悬浮窗：截取即时通讯软件的聊天窗口，用 OCR 加像素版面分析认出消息，再用大模型或决策模型分析对方最新一条的情绪、潜台词和关系信号。Swift Package，macOS 14+。

## 结构

- `Sources/EmoLensCore/`：纯逻辑（消息解析、版面检测、分析引擎、安全网），单元测试都针对它
- `Sources/EmoLens/`：Mac 应用（ScreenCaptureKit 截图、Vision OCR、SwiftUI 面板、设置）
- `Sources/EmoLensDemo/`：演示聊天窗口
- `presets/`：给模型的提示词和问题集，中英各一套（`*.zh.json` / `*.en.json`）
- `eval/en.jsonl`：英文评测集；`scripts/score_eval.py` 打分，`scripts/adaption_localize_eval.py` 用 Adaption Labs 把它本地化成别的英语地区
- `scripts/`：`build_app.sh` 打包 .app（版本号在这里），`make_dmg.sh` 打安装包

## 编译和测试

- **只能在 macOS 上编译。** 云端会话是 Ubuntu，`swift build` 跑不了：改完推上去，看 GitHub Actions 的 CI（macOS）结果，失败了按日志修。
- `swift build`、`swift test`
- 离线检查识别，不截屏、不弹窗口：`swift run EmoLens --inspect 截图.png [--analyze]`，`swift run EmoLens --replay 1.png 2.png …`
- 所有命令行工具都认 `--language en|zh`（或环境变量 `EMOLENS_LANGUAGE`）；CI 每次推送都会渲染中英文界面预览并上传为 artifact
- 评测（需要本机 Ollama 和 qwen3.5:4b）：`swift run EmoLens --eval 输入.jsonl 输出.jsonl`

## 规矩

- 对外的文字（README、发布说明、界面文字、仓库简介）统一说「即时通讯」「聊天软件」，不点名具体的聊天软件。
- 隐私：默认全部在本机处理；绝不自动改用云端模型或自动调用任何收费接口；日志里的聊天内容一律 `privacy: .private`；API Key 只进钥匙串。
- 改 `presets/emotion.llm.zh.json` 的 system 或示例，会改变纯文字消息的判断（实测「情感操控」曾因此漏判）。要改先跑评测，前后对比。
- 中英双语：界面文字一律写成 `L("中文", "English")`；情绪、信号、回应方式、关系在内部只存中文规范值，显示时用 `Vocabulary.display`，英文模型的输出经 `Vocabulary.canonical` 换回规范值。新增文字两种语言都要写。
- 改 `presets/emotion.llm.en.json` 同样要先跑英文评测（`--eval eval/en.jsonl … --language en`），前后对比。
- 英文安全网只收具体的说法，日常夸张（「I'm dead」「kill me now」）不能触发，改动要配正反两类测试。
- 注释用中文，风格和周围代码一致；提交信息用英文。
- 新功能配单元测试；识别相关的改动用 `--inspect` / `--replay` 在截图上验证。
- 发版（改 VERSION、打 DMG、签名）需要 macOS 和本机的签名证书，云端做不了，留给维护者在本机做。
