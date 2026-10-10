# ActionImport：本地 AI 素材初筛与分类的 GitHub 研究

核查日期：2026-10-10（Asia/Shanghai）。目标是 Apple Silicon Mac 上，对导入的 Action 6 视频做质量提示、候选片段推荐及人物/风景/运动/室内等语义标签。

本次只读核查 GitHub 当前源码、实际许可证、提交与 Release 元数据；未克隆、安装或运行项目，未下载模型，未读取相机或用户素材。下面的性能、兼容性是源码/作者文档支持程度，不是真机验收。

## 结论与优先级

已经有相近项目，但不能把“本地 AI”四个字直接等同于“可商用的 Mac 原生素材初筛组件”。建议按目的分别看：

1. **先试现成功能：VideoHighlighter。** 已发布 Mac DMG，支持精彩片段、视觉查询、分类及模糊质量门；适合看用户到底需要什么。当前代码是 AGPL-3.0，若准备分发收费闭源 App，不能默认直接复制成自己的产品底座。Mac 上也不是全部模型都走 GPU。[0.13.1 Release](https://github.com/Aseiel/VideoHighlighter/releases/tag/0.13.1)、[实际 LICENSE](https://github.com/Aseiel/VideoHighlighter/blob/main/LICENSE)
2. **研究初筛产品流程：roughcut-stdio。** 功能最贴近“先筛可用片段，再理解内容”，有 MLX 本地 VLM、清晰度/亮度/运动信号、近似重复和片段评分。不过未发现明确许可证，且抽帧失败会生成非图像测量的占位信号；适合学流程，当前不应直接当商用代码底座。[分析流水线](https://github.com/Mallfurion/roughcut-stdio/blob/main/docs/analyzer-pipeline.md)、[预筛源码](https://github.com/Mallfurion/roughcut-stdio/blob/9828b71f061f9d96e48d83727e48eb7840fd72ae/services/analyzer/app/prefilter.py#L234-L253)
3. **可复用语义搜索原型：SentrySearch。** 四个项目中许可证最直接：MIT；源码明确有本地 Qwen3-VL 和 Apple MPS 路径。它主要解决“用一句话找到视频片段”，没有完整的坏片质量初筛。默认后端会向 Gemini 发送视频片段，必须显式锁定 local。[LICENSE](https://github.com/0xSojalSec/video-clip-search/blob/master/LICENSE)、[本地模型实现](https://github.com/0xSojalSec/video-clip-search/blob/d004b8aa3ec649fdffb1ac654273efa21ca1b955/sentrysearch/local_embedder.py#L124-L170)、[默认后端](https://github.com/0xSojalSec/video-clip-search/blob/d004b8aa3ec649fdffb1ac654273efa21ca1b955/sentrysearch/cli.py#L229-L261)

**对 ActionImport 的判断（研究推断）：** 第一版可以将轻量技术质量测量与语义分类分开：抽帧后测模糊/曝光/相似度，用一个小型本地视觉模型补充标签和候选片段说明。不要让大模型承担复制正确性，也不要直接根据模型判断删原片。现有项目中没有核实到一个同时覆盖 Action 6 自动导入、可靠复制校验、Mac 原生低资源运行和完整初筛分类的现成代码底座。

## 对比

| 项目 | 真实方向 | 初筛证据 | 语义能力 | Mac 本地边界 | 当前许可 |
|---|---|---|---|---|---|
| [roughcut-stdio](https://github.com/Mallfurion/roughcut-stdio) | 片段初筛、粗剪 | 清晰度/亮度/对比度/运动；候选评分；CLIP 近似重复 | VLM 的 subjects/actions/shot_type 等结构化结果 | MLX-VLM 路径显式要求 macOS arm64；CPU 确定性路径 | 未找到明确许可 |
| [VideoHighlighter](https://github.com/Aseiel/VideoHighlighter) | 亮点推荐、视觉搜索、剪辑导出 | 模糊质量门；信号曲线；候选窗口 | CLIP 查询和示例帧自定义分类；物体/动作/语音 | Mac DMG；部分 ONNX/Core ML 为实验路径；torch 主要 CPU | AGPL-3.0 |
| [SentrySearch / video-clip-search](https://github.com/0xSojalSec/video-clip-search) | 视频片段语义检索 | 静止片段跳过；没有核实完整质量筛选 | 本地 Qwen3-VL 视频 embedding，文字检索 | MPS float16；CPU float32 回退；模型下载较大 | MIT |
| [edit-mind](https://github.com/IliasHad/edit-mind) | 视频知识库与内容检索 | 内容元数据；没有核实完整坏片筛选 | 物体/人脸/语音/文本、多模态 embedding | 原生 Python 有 MPS 分支；Docker 路线不利用 Apple GPU | 自定义限制许可 |

表中能力的源码证据详见下面，不能将“语义相似”当作“文件重复”，也不能将“运动强”当作“值得保留”。

## roughcut-stdio：最接近初筛流程，但不能直接拿来商用

- **能做什么：** `prefilter.py` 从实际灰度帧计算亮度、对比度、梯度清晰度、帧间差异等；稳定度由 motion 值的波动估算，属于启发式，并非陀螺仪或可靠相机抖动分类器。[真实信号计算](https://github.com/Mallfurion/roughcut-stdio/blob/9828b71f061f9d96e48d83727e48eb7840fd72ae/services/analyzer/app/prefilter.py#L702-L754)、[片段指标](https://github.com/Mallfurion/roughcut-stdio/blob/9828b71f061f9d96e48d83727e48eb7840fd72ae/services/analyzer/app/prefilter.py#L377-L399)
- **筛选与分类：** 综合 technical/semantic/story 分量进行排序；VLM 输出包含 subjects、actions、shot_type、camera_motion、质量发现、风险和 keep/maybe/reject；CLIP embedding 用于相似片段去重。没有核实出可直接使用的人物/风景/运动/室内固定分类器，需要自行约束标签并评估。[评分](https://github.com/Mallfurion/roughcut-stdio/blob/main/services/analyzer/app/scoring.py)、[VLM 输出格式](https://github.com/Mallfurion/roughcut-stdio/blob/main/services/analyzer/app/ai_runtime/prompts.py)、[去重](https://github.com/Mallfurion/roughcut-stdio/blob/main/services/analyzer/app/clip_dedup.py)
- **本地/远程边界：** 默认 `mlx-vlm-local`，平台检查要求 Darwin + arm64；模型 bootstrap 使用 Hugging Face 下载，推理加载本地缓存。另有 LM Studio HTTP 接口，默认 `127.0.0.1`，但 base URL 可配置，所以这条路径并不强制只连接本机。[平台检查与配置](https://github.com/Mallfurion/roughcut-stdio/blob/main/services/analyzer/app/ai_runtime/config.py)、[模型运行及 HTTP 适配器](https://github.com/Mallfurion/roughcut-stdio/blob/main/services/analyzer/app/ai.py)、[配置文档](https://github.com/Mallfurion/roughcut-stdio/blob/main/docs/configuration.md)
- **关键源码风险：** 抽帧两次仍失败时调用 `deterministic_signal`；它根据 asset ID、文件名、路径和时间等生成清晰度/亮度/运动值，而不是测量画面。这可以支撑演示/fixture，但产品若把它当真实评分会误导。借鉴时应将这种状态显示为未测量或分析失败。[失败回退入口](https://github.com/Mallfurion/roughcut-stdio/blob/9828b71f061f9d96e48d83727e48eb7840fd72ae/services/analyzer/app/prefilter.py#L234-L253)、[占位信号](https://github.com/Mallfurion/roughcut-stdio/blob/9828b71f061f9d96e48d83727e48eb7840fd72ae/services/analyzer/app/prefilter.py#L535-L563)
- **接入成本：** Tauri 桌面 + Python 分析服务 + FFmpeg、PyTorch/OpenCLIP/MLX 等可选依赖；流程借鉴价值高，但并不是可直接塞进 Swift App 的轻量库。[依赖](https://github.com/Mallfurion/roughcut-stdio/blob/main/services/analyzer/pyproject.toml)、[桌面打包](https://github.com/Mallfurion/roughcut-stdio/blob/main/docs/desktop-distribution.md)
- **许可和成熟度：** README 仍是许可证占位文字；API `license=null`，递归文件树未见 LICENSE/COPYING 类文件，不能据此假定有复制/分发许可。最新提交 2026-03-31；v2.2.1 发布于 2026-03-28，发布 assets 为空，并未核实到可下载安装包。[README 许可节](https://github.com/Mallfurion/roughcut-stdio#license)、[仓库元数据](https://api.github.com/repos/Mallfurion/roughcut-stdio)、[文件树](https://api.github.com/repos/Mallfurion/roughcut-stdio/git/trees/main?recursive=1)、[最新提交](https://github.com/Mallfurion/roughcut-stdio/commit/9828b71f061f9d96e48d83727e48eb7840fd72ae)、[v2.2.1](https://github.com/Mallfurion/roughcut-stdio/releases/tag/v2.2.1)

## VideoHighlighter：现成功能最值得试，Mac 加速要分模块看

- **能做什么：** 从场景、运动、音频、物体、动作及语音分数选择候选窗口，并可导出高光视频。实际候选算法包含全局排序、固定窗口和时长预算，不能当作一个已验证的通用剪辑审美模型。[项目说明](https://github.com/Aseiel/VideoHighlighter#readme)、[候选选择算法](https://github.com/Aseiel/VideoHighlighter/blob/main/modules/segments/highlight_select.py)
- **技术质量筛选：** `clip_quality.py` 在候选片段采样三帧，用灰度 Laplacian 方差的中位数估计清晰度；读不到画面返回 `None`。流水线的 quality gate 默认关闭，开启后对低于阈值的片段把分数乘以 0.3。该证据支持模糊提示，不足以声称已经完整处理坏曝光、剧烈抖动等。[模糊测量](https://github.com/Aseiel/VideoHighlighter/blob/main/modules/segments/clip_quality.py)、[默认与惩罚逻辑](https://github.com/Aseiel/VideoHighlighter/blob/444a47060dffe38a43196ffe3a5b0bb6f2285400/pipeline.py#L2047-L2066)
- **语义分类：** CLIP 帧索引支持文本相关性；`clip_categories.py` 允许用户拿示例帧教一个自定义类别，平均 embedding 后再次匹配，不需重新训练。这比单纯让 VLM自由写标签更容易形成可重复的用户分类，但准确率仍须测试。[帧索引](https://github.com/Aseiel/VideoHighlighter/blob/main/llm/clip_index.py)、[示例分类](https://github.com/Aseiel/VideoHighlighter/blob/main/llm/clip_categories.py)
- **本地/远程边界：** Ollama 默认 localhost，允许用户设置远端 host；因此本地处理成立的条件包括模型服务地址确实是本机。首次模型下载不等于素材上传。[Ollama 地址解析](https://github.com/Aseiel/VideoHighlighter/blob/main/llm/ollama_host.py)、[远端配置说明](https://github.com/Aseiel/VideoHighlighter/blob/main/docs/OLLAMA-REMOTE.md)
- **Mac 加速的实际边界：** `device_utils.py` 的 Apple 分支支持部分模型走 ONNX Runtime/Core ML，并标为 experimental；代码明确说明 torch 消费者尚未接入 MPS，`pytorch_device="cpu"`，OpenVINO 也留在 CPU。不能因存在 Mac DMG 或检测到 Metal，就声称所有分析都能用 Apple GPU。[Apple 分支](https://github.com/Aseiel/VideoHighlighter/blob/444a47060dffe38a43196ffe3a5b0bb6f2285400/modules/system/device_utils.py#L219-L263)
- **接入成本、许可、成熟度：** 已有完整 UI 与 Python 流水线，适合先做对照试用；直接嵌入原生轻量 App 的依赖与打包成本高。LICENSE 为 AGPL-3.0，不能默认为闭源商用产品的宽松许可。2026-10-08 的 0.13.1 Release 有 `VideoHighlighter-0.13.1.dmg`；最新提交 2026-10-09。[LICENSE](https://github.com/Aseiel/VideoHighlighter/blob/main/LICENSE)、[requirements](https://github.com/Aseiel/VideoHighlighter/blob/main/requirements.txt)、[Release](https://github.com/Aseiel/VideoHighlighter/releases/tag/0.13.1)、[最新提交](https://github.com/Aseiel/VideoHighlighter/commit/444a47060dffe38a43196ffe3a5b0bb6f2285400)

## SentrySearch：MIT，适合作为本地语义搜索原型

- **真实用途：** 仓库名为 video-clip-search，README 产品名为 SentrySearch。按时间切重叠片段，对整段视频 embedding，存本地 ChromaDB；文字查询后可从原片裁出匹配片段。主要是内容检索，未核实完整清晰度/曝光/抖动评分。[README](https://github.com/0xSojalSec/video-clip-search#readme)、[检索入口](https://github.com/0xSojalSec/video-clip-search/blob/master/sentrysearch/search.py)
- **默认会发送素材到外部：** `index` 未指定参数时选 Gemini；Gemini 后端读取视频字节，以 `Part.from_bytes` 传给 Google 的 `embed_content`。local 要显式指定 `--backend local` 或指定 local model。做 ActionImport 集成时应固定本地后端，并让缺模型/运行失败直接报错，不转云端。[默认选择](https://github.com/0xSojalSec/video-clip-search/blob/d004b8aa3ec649fdffb1ac654273efa21ca1b955/sentrysearch/cli.py#L229-L261)、[视频 API 请求](https://github.com/0xSojalSec/video-clip-search/blob/d004b8aa3ec649fdffb1ac654273efa21ca1b955/sentrysearch/gemini_embedder.py#L115-L139)、[载入视频字节](https://github.com/0xSojalSec/video-clip-search/blob/d004b8aa3ec649fdffb1ac654273efa21ca1b955/sentrysearch/gemini_embedder.py#L183-L189)
- **Apple Silicon 证据：** 本地源码选择 MPS + float16；CPU 则 float32。按 Mac 内存自动选 2B/8B；作者给出 2B 约 4 GB 模型下载、运行约 6 GB 内存，8B 约 16 GB 下载，这些没有在本次实测。4-bit bitsandbytes 分支仅 CUDA，不能把其显存数字搬到 Mac。[设备与量化源码](https://github.com/0xSojalSec/video-clip-search/blob/d004b8aa3ec649fdffb1ac654273efa21ca1b955/sentrysearch/local_embedder.py#L124-L170)、[硬件说明](https://github.com/0xSojalSec/video-clip-search#local-backend-no-api-key-needed)
- **局限：** 静止片段跳过是 JPEG 文件大小比较的启发式；安静风景、固定机位可能恰好是用户想保留的镜头。它也不是坏片检测或审美评分，类别自动打标还要自行实现。[静止判定](https://github.com/0xSojalSec/video-clip-search/blob/master/sentrysearch/chunker.py)、[已知限制](https://github.com/0xSojalSec/video-clip-search#limitations--future-work)
- **接入与成熟度：** MIT 源码可按条件复用；Python CLI + ChromaDB + Transformers/PyTorch 等本地依赖，适合独立 sidecar 原型。原生发行仍需解决模型包、运行时、下载管理和资源限制。当前 pyproject 版本 0.1.0，latest commit 是 2026-03-30，本次 API 查询 Releases 为空。[LICENSE](https://github.com/0xSojalSec/video-clip-search/blob/master/LICENSE)、[依赖与版本](https://github.com/0xSojalSec/video-clip-search/blob/master/pyproject.toml)、[最新提交](https://github.com/0xSojalSec/video-clip-search/commit/d004b8aa3ec649fdffb1ac654273efa21ca1b955)、[Releases API](https://api.github.com/repos/0xSojalSec/video-clip-search/releases)

## edit-mind：知识库方向可参考，当前许可不适合此产品复用

- **功能边界：** 监听视频目录，提取人脸/物体/文字/语音与 embedding，支持自然语言查找。源码 `ShotTypePlugin` 根据人脸画面占比等判断景别，不能将“景别分类”误写成风景/运动/室内语义分类器。[功能说明](https://github.com/IliasHad/edit-mind#core-features)、[景别插件](https://github.com/IliasHad/edit-mind/blob/main/python/plugins/shot_type.py)
- **Mac 与部署：** Python AnalysisConfig 有 MPS 检测；转录设备仅 CUDA/CPU。官方 README 明确 Docker 路线无法利用 Apple GPU，另宣传商业桌面版/预订。当前 Compose 包含 web、background-jobs、ml、Postgres、Redis、Chroma，适合自托管素材库，作为一个小菜单栏工具成本偏高。[设备配置](https://github.com/IliasHad/edit-mind/blob/main/python/core/config.py)、[桌面版说明](https://github.com/IliasHad/edit-mind#desktop-app)、[Compose](https://github.com/IliasHad/edit-mind/blob/main/docker-compose.yml)
- **本地/远程边界：** 可选 Ollama，也可选 Gemini。Gemini 实际源码会把查询、聊天上下文或生成好的提示文本传 Google；这不是“必然上传全部原视频”的证据，但启用它就不能说完全离线。Ollama host 同样可配置成其他机器。[Gemini 服务](https://github.com/IliasHad/edit-mind/blob/main/packages/ai/src/services/gemini.ts)、[Ollama 服务](https://github.com/IliasHad/edit-mind/blob/main/packages/ai/src/services/ollama.ts)、[配置模板](https://github.com/IliasHad/edit-mind/blob/main/.env.example)
- **实际许可证：** 2026-02-21 之后版本采用 Edit Mind License。个人与小组织有使用资格，但明确禁止出售/重新许可自己的衍生品，且禁止以其全部或部分代码制作直接竞争产品。LICENSE 说以前版本仍为 MIT，但本次未审核历史 MIT 版本，不能把旧许可套到当前 main。[LICENSE.md](https://github.com/IliasHad/edit-mind/blob/547041957ee6161dcc3d015916edde072d953ad1/LICENSE.md)
- **成熟度：** README 自称尚未 production-ready；最新提交 2026-06-30，最近 v0.30.0 发布于 2026-06-28，本次看到的发布 asset 是 MCP JavaScript 文件，并不是 Mac App。[README](https://github.com/IliasHad/edit-mind#readme)、[最新提交](https://github.com/IliasHad/edit-mind/commit/547041957ee6161dcc3d015916edde072d953ad1)、[v0.30.0 Release](https://github.com/IliasHad/edit-mind/releases/tag/v0.30.0)

## 从这些项目可借鉴的产品决策

这些是基于代码审查的建议，尚未变更项目规格或承诺实现：

- 输出两个独立维度：技术问题提示与语义标签。模糊、亮度低、运动大是证据，不自动等于“没价值”。Action 用户的运动镜头可能故意抖动；D-Log/HLG/HDR 素材的曝光阈值尤其需要校准，本次未验证相关支持。
- 给候选片段保留原文件名、时间范围、理由和置信状态；评分失败应明确显示未分析。roughcut 的占位信号不能成为真实产品结果。
- 把“精确重复文件”和“画面相似”分开：前者交给导入校验/哈希，后者只做分组提示。近似重复不自动删除。
- 一段视频可以同时有人物、室外、运动等标签，保持多标签；先用少量真实 Action 素材建立人工标注集，再比较规则、小视觉模型与 VLM 的准确率、耗时、内存和误筛率。
- “完全本地”需要固定 localhost 或进程内推理，避免接受任意远端 endpoint；首次下载权重与发送素材是不同动作。AI 分析中断应不影响已验证的素材归档结果。

本次没有证明任何候选对 Action 6 特定编码、LRF、D-Log/HLG、高帧率和长片连续分析的兼容性，也没有实际速度、内存、功耗或分类精度数据。
