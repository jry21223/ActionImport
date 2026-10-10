# 本地 AI 素材初筛与分类：产品和原生组件调查

调查日期：2026-10-10。只核查官方产品文档和公开源码，未安装软件、下载模型或分析用户视频。

## 结论

类似产品已经存在，且覆盖不同阶段：Basecut 接近“导入后的初筛和分类”；Jumper 偏视频内容搜索与候选镜头定位；Peakto 偏整个素材库的分类和管理。对 ActionImport，更合适的第一步是导入后生成可修改的标签和待复核提示，而非扩展成剪辑器。这是本次调查后的产品判断，尚未通过 Action 6 素材实测。

## 已有产品

### Basecut：最接近初筛和分类

官方展示把素材分为 hero、keeper、maybe、skip，并按 action、b-roll、interview、drone 等镜头类型标记；支持在 Mac 上用本地模型分析，也有可选云端路径。产品主要面向婚礼、活动拍摄和剪辑前准备，后续可交给 DaVinci Resolve。以上是厂商文档声明，不是我们运行后的效果结论。[分类和初筛说明](https://basecut.app/features/sort-and-tag) · [平台、导出及本地/云端说明](https://basecut.app/)

值得参考的是明确的筛选等级、可解释的分类结果和“分析完成后可直接开始挑素材”的体验。没有找到可据此复用实现的开源仓库；先作为产品参照。

### Jumper：本地视频语义搜索和镜头定位

官方提供 Mac 和 Windows 独立应用及剪辑器插件。画面、语音、人脸和摘要分析在本机运行；自然语言查询可定位场景、物体、动作和来源时间范围。它更接近素材检索和候选镜头定位，不能仅凭搜索能力推断它会准确判断“视频好不好”。[产品首页](https://getjumper.io/) · [分析能力和本地边界](https://getjumper.io/solutions/ai-video-analysis)

可参考“搜到片段后直接回到原视频”的交互；ActionImport 初版不必承担完整编辑器集成。

### Peakto：Mac 素材库管理和自动标签

官方明确面向 macOS，支持照片和视频，提供本地 AI 分析、自动标签、自然语言搜索、视频帧搜索和相似素材检索。它管理整个素材库及多个来源；另有团队远程访问功能，不能把“本地 AI”理解成产品没有任何网络功能。[官方功能页](https://cyme.io/en/products/peakto/) · [视频帧搜索](https://cyme.io/en/products/peakto/features/video-frame-search/)

可参考批量分类和标签浏览，初版保持“相机导入后的这一批素材”范围即可。

## 原生 Mac 开源参考

### Whittle：照片初筛，可借鉴原生信号与模型分工

这是 Swift 原生照片连拍筛选工具，**不是视频初筛成品**。源码先通过 CoreImage/Vision 测量清晰度、脸部质量、水平线、场景类型及美学分数，再把这些信号交给视觉模型解释和推荐。清晰度实现明确用于同一连拍组内的相对比较，不能直接拿阈值判断所有类型的视频是否可用。[项目](https://github.com/surendranb/whittle) · [NativeSignals 源码](https://github.com/surendranb/whittle/blob/main/Sources/Whittle/NativeSignals.swift)

实际 LICENSE 为 MIT。它可以连接 LM Studio 或 Ollama，也有用户主动选择的云端后端；README 明确称 Ollama 尚未用实际安装验证。读取 Apple Photos 的部分不适合直接接管 Action 6 文件夹，但原生评分、分组和结构化模型输出的思路有参考价值。[许可证](https://github.com/surendranb/whittle/blob/main/LICENSE) · [后端与隐私说明](https://github.com/surendranb/whittle#models--bring-your-own)

截至调查日 GitHub API 显示最近 push 为 2026-08-09，未归档。它仍需我们用视频抽帧、运动场景和真实性能验证，不能当作已经证明的视频算法。

### MLX Swift LM：可集成的本地视觉模型运行组件

这不是素材整理 App，而是 Swift 语言模型/视觉语言模型组件。公开产品包括 MLXVLM、MLXEmbedders 和受约束的结构化生成，适合作为将来原生应用中的本地推理候选。仓库为 MIT；模型权重与其他依赖的许可仍须分别核查。[项目说明](https://github.com/ml-explore/mlx-swift-lm) · [许可证](https://github.com/ml-explore/mlx-swift-lm/blob/main/LICENSE)

调查时 main 的配置要求 Swift 6.2、macOS 14 及以上。README 明确提示 3.x 有破坏性改动；其中 FoundationModels 桥接另外需要 macOS 27 SDK，不能把这个要求混同于核心 MLXVLM。实施时应选定版本及模块，并在作者现有工具链验证编译和推理，不能直接追随 main。[Package.swift](https://github.com/ml-explore/mlx-swift-lm/blob/main/Package.swift) · [README](https://github.com/ml-explore/mlx-swift-lm#mlx-swift-lm)

## 对 ActionImport 的建议

以下是基于调查的设计建议，不是已实现功能：

1. 导入与校验保持独立完成；AI 分析在已校验的电脑副本上排队运行，失败不影响素材导入。
2. 先做两类结果：内容标签（如人物、风景、运动、室内）和待复核提示（疑似失焦、曝光异常、近似片段、可能误拍）。标签允许多选、改正和不确定状态。
3. 技术质量先用快速的本地信号检测，语义分类再用视觉模型；不要让一个视觉模型包办文件完整性、清晰度、抖动和审美判断。
4. 对视频抽帧和多个时间段汇总。单张缩略图的分类不能代表整个片段，运动相机的大幅运动也不能简单等同于不可用素材。
5. 第一版保存标签、时间范围、理由和分析状态，供用户筛选。AI 不据此自动删除或覆盖原片，自动移动到分类文件夹也应晚于标签验证。

下一次验证应挑少量代表性视频，覆盖室内、夜景、运动、风景和误触录制，比较标签正确率、初筛误判、每分钟视频的处理时间、内存和模型下载体积。未获得这些数据前，不承诺“一导入就瞬间分类”或“准确选出最佳镜头”。

开源视频项目及其源码、许可证和平台边界另见 `ai-local-footage-github.md`。
