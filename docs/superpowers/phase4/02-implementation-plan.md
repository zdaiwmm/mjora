# Imora Phase 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **执行授权：用户于2026-11-15明确确认更新方案并要求开始实施，先4P再推进其他第四批功能。** 历史“仅规划/未实施”文字记录编写时状态，不再限制本次在独立工作区内编码、测试和专用模拟器安装；不授权影响前三批、用户真实媒体写操作、合并/推送/部署。

**Goal:** 在保留原件与备份证据的前提下，交付实况/视频编辑、可靠精选集、回忆影片与可恢复的离线编辑同步。

**Architecture:** 本机持久草稿与 GPU 预览，增强服务器保存版本化意图并异步生成派生资源。PhotoKit 与云端分别记录结果，以强版本检查和幂等 receipt 处理未知结果；不伪造跨系统原子事务。

**Tech Stack:** Swift 6.0、iOS 26.0+、SwiftUI/UIKit、PhotoKit、AVFoundation、Core Image/Metal、SQLite；现有 NestJS/Kysely/PostgreSQL、BullMQ/媒体任务与 FFmpeg 管线。

**Spec:** [详细设计](01-detailed-design.md)、[接口契约](04-contracts.md)、[验收矩阵](03-acceptance-matrix.md)、[图片与交互动效补充规范](07-loading-and-interaction-spec.md)。本版18任务；新增17–18保留历史编号，**实际先执行4P/Task17–18，再按阶段依赖推进1–16，编号不表示执行顺序。**

## Global Constraints

- iOS 最低版本为 **26.0**，Swift **6.0**。
- **原件、当前渲染版、编辑意图、成品与备份证明是不同对象。**
- 文件名、时间、GPS、视觉相似都不能建立备份配对。
- 每次保存先持久化意图；网络未知结果先对账。
- 默认只保存入口来源；跨来源同步和 PhotoKit 写回必须有明确用户动作。
- 保留前三批 `photo.parameters.version=1`、现有 action 顺序、颜色/几何语义和未知字段 round-trip。
- 正常完整缓存复访，首个可交互图库内容帧显示全部可见真实缩略图，无逐格填充/淡入；不能以长启动遮罩或全库预加载代替。
- 自动保存workingDraft与committedDisplay分离，取消/退出不发布或入队，完成才提交；所有图片入口共同满足G5。
- 不增加第三方编辑 SDK，不使用 Apple Photos 私有 API/数据库。
- 本次允许独立工作区实现、测试、提交和专用模拟器验证；禁止修改前三批工作树、操作其设备/服务、真实图库写入、合并/推送或部署。
- 独立实施工作区已固定已提交native87bc12bb与server209aa4f7，不等待或修改仍在最终UI验证中的phase123；后续上游修复只经只读对齐再决定。

## Review Focus

1. 异步图像/播放晚到或仅metadata/字节已缓存：不能误认为已呈现，不能在松手/换账号后显示播放；归任务1/17–18。
2. 验证过的是当前渲染版，系统未调整原件尚无证明：不得取得本机清理资格；归任务 3。
3. PUT 已被服务器接收但响应丢失、App 重启/账号切换：同一 operation 不重复应用、不串账号；归任务 5/15。
4. 裁剪旋转、VFR/HDR/外部视频调整和实况配对同时存在：正确显示坐标和源修订，未知 profile 不静默降质；归任务 7/8/9。
5. 素材播放后被隐藏/删除/撤权，或音乐只可试听：导出必须重新核权、列出缺失并保留项目；归任务 14。

---

## 1. 实施前置与分期

实施者先阅读 [对齐清单](05-evidence-and-alignment.md)，将最终前三批提交、接口实况和测试目的地写入实施记录。下文 `N:` 为未来独立 native 仓库根，`S:` 为未来独立 server 仓库根；它们**不是**当前 `execution/photos-phase123/`。

| 交付 | 任务 | 可独立交付的用户结果 | 依赖与发布门槛 |
|---|---|---|---|
| **4P（新增，先做）** | **17–18** | 正常复访首屏图片齐备、跨页面位图复用、滚动/打开/返回连续 | G5；基于前三批最终版本独立实施，不等新编辑协议 |
| 4A | 1–2 | 实况按住/松手、可靠本机分类 | 与4P/G5一同放行；截图复用前三批 |
| 4B0 | 3–5 | 原件隔离、可恢复草稿、服务端版本化文档基础 | G0、G1；高级编辑的共同前置 |
| 4B1 | 6–7 | Imora 实况封面/修剪/静音/循环/来回、明确副本导出 | 依赖 4B0；系统完整实况写回由 G2 单独决定 |
| 4C | 8–9 | 普通 SDR 视频裁剪旋转调色、可选系统照片写回 | 依赖 4B0；HDR 保真由 G3 单独决定 |
| 4D | 10–11 | 云端可靠分类、最近的日子、旅程建议 | 4A facts 模型；不等 4B1/4C 渲染器即可开发 |
| 4E | 12–14 | 影片播放/节奏、音乐、1080p SDR 导出 | 4B0 项目存储；4D 可增加素材入口但非阻塞依赖 |
| 4F | 15–16 | 完整待同步、跨设备/PhotoKit 冲突处理、端到端验收 | 所有写入模块；G4 |

逻辑关键路径：`4P → 4A/4B0 → (4B1 或 4C 或 4E) → 4F`。4P可独立交付，4A在G5通过后先发布。4D 可先做本机日子/手动旅程，再开启云端聚合。4E 无音乐播放器可先发布；曲库授权/资源不应阻塞。每项 feature 单独开关，不能用一个 Phase4 Bool 让未验收能力全部上线。

### 门槛定义

| 门槛 | 证据与通过条件 | 未通过时的处理 |
|---|---|---|
| G0 原件保护 | 每类资源的选择、摘要、只读回验和清理资格夹具；新编辑不会让 unknown/current proof 变成 original proof | 阻止相关本机清理资格；保留草稿/播放；不动原件 |
| G1 保存协议 | 并发 CAS、receipt、事务 outbox、未知结果、旧写入口保护的集成测试 | 高级云端编辑不开写；允许本机草稿 |
| G2 系统实况写回 | 公开 SDK 能力调查＋专用测试库完成关键帧/修剪/音频/方向/配对/重开/跨设备后仍识别实况 | 如不能支持完整语义，首版保持 Imora 效果与照片/视频导出；系统实况按钮不出现 |
| G3 HDR/特殊视频保真 | 真机 profile 夹具、色彩/metadata/方向/音画/重新导入验证 | 普通 SDR 继续交付；特殊源仅观看、草稿或明确 SDR 副本 |
| G4 整体验收 | 现有备份/清理/前三批回归＋第四批矩阵、隔离账号、断线/崩溃/迁移证据 | 仅开放已通过子能力，不宣称整个第四批完成 |
| G5 图片与交互呈现 | 补充规范第11节的真机首帧/总启动可操作时长/视口覆盖/滚动/打开返回/作用域/内存门槛及I/U用例 | 普通复访仍逐张补图/黑帧即失败；不以占位图、长启动等待或减少统计样本蒙混 |

## 2. 文件边界

新增路径均为建议实施落点，不表示现在已有这些文件。可以因前三批实际结构调整目录，但不得改变模型/契约语义而不更新文档。

| 路径 | 职责 |
|---|---|
| `N:Imora/Core/Editing/MediaEditModels.swift` | 公共文档、source、时间、颜色/几何、结果类型 |
| `N:Imora/Core/Editing/EditDraftStore.swift` | 独立 SQLite 迁移、draft/outbox/target receipts |
| `N:Imora/Core/Editing/EditSourceManifest.swift` | 原始与当前基线、资源租约、PhotoKit 修订 |
| `N:Imora/Core/Editing/OriginalEvidenceEligibility.swift` | 第四批编辑相关资产的原件证据附加门禁 |
| `N:Imora/Core/Editing/EditOutboxCoordinator.swift` | 串行发送、对账、暂停、重试和凭证 scope |
| `N:Imora/Core/Editing/EditConflictResolver.swift` | 三方比较与建议合并，纯函数 |
| `N:Imora/Core/Editing/MediaEditRenderer.swift`、`MediaEditKernel.metal` | 预览、帧输出和统一参数语义 |
| `N:Imora/Core/Editing/PhotoKitEditWriter.swift` | 显式系统照片写回及结果回读 |
| `N:Imora/Core/Images/MediaDisplayIdentity.swift`、`LaunchPreviewStore.swift`、`MediaPresentationCoordinator.swift` | 稳定显示键/授权generation、首屏预览包、prepared视口和实际呈现记录 |
| `N:Imora/Features/Viewer/LiveHoldController.swift` | 手势 reducer 与播放命令 |
| `N:Imora/Features/Viewer/LivePhotoEditScreen.swift`、`VideoEditScreen.swift` | 各编辑 UI，复用已有控制组件 |
| `N:Imora/Core/Collections/DeviceMediaFacts.swift`、`DerivedCollectionBuilder.swift` | 分类 facts、元数据聚合纯算法 |
| `N:Imora/Features/Collections/DerivedCollectionScreen.swift` | 日子/旅程详情、用户覆盖与转相册 |
| `N:Imora/Core/Memories/MovieModels.swift`、`MoviePlanner.swift`、`MovieExportCoordinator.swift` | 影片 manifest、编排、受控导出 |
| `N:Imora/Core/Memories/MovieSnapshotStore.swift` | 本机项目固定成品、下载状态、持久租约与离线完成事务 |
| `N:Imora/Features/Memories/MemoryMovieScreen.swift` | 播放、节奏、音乐、全部素材入口 |
| `N:Imora/Features/Editing/EditDraftsScreen.swift`、`EditConflictScreen.swift` | 草稿/待同步和明确冲突操作 |
| `S:server/src/dtos/media-edit.dto.ts`、`controllers/media-edit.controller.ts` | 新协议验证与路由 |
| `S:server/src/services/media-edit.service.ts`、`repositories/media-edit.repository.ts` | CAS/receipt/事务 outbox 与 head |
| `S:server/src/services/media-render.service.ts` | 固定修订渲染与原子发布 |
| `S:server/src/services/media-facts.service.ts`、`derived-collection.service.ts` | 云端 facts 和元数据聚合 |
| `S:server/src/services/memory-movie.service.ts` | 影片项目权限与修订存储 |
| `S:server/src/schema/tables/media-*.table.ts` 等 | 契约第 8 节定义的独立数据职责 |
| `S:server/src/schema/migrations/<生成时间戳>-Phase4*.ts` | 实施时生成真实时间戳，保留旧数据；不预占迁移编号 |
| `N:ImoraTests/Phase4*.swift`、`S:server/src/services/*.spec.ts` | 下文具名行为与故障夹具 |

只在接入时修改已有 `LivePhotoPage.swift`、`VideoPlayerPage.swift`、`AssetViewerScreen.swift`、`LocalImageLoader.swift`、`MemoryLane.swift`、精选集布局、`ServerCompatibility.swift`、`ImoraClient.swift`、`SessionStore.swift`。不在 `AssetEditScreen.swift` 再塞整套视频引擎，不为新分类扩张备份 `DeviceAsset`。

## 3. 通用验证方式（均未运行）

未来进入独立 native 根后，使用新建且专用于第四批的模拟器 UDID、独立 DerivedData/包缓存，**不可复用默认 iPhone 17 或当前会话设备**。可采用以下形式（变量在实施记录中填真实值）：

```bash
IMORA_TEST_DESTINATION="platform=iOS Simulator,id=${PHASE4_SIM_UDID}" \
IMORA_DERIVED_DATA="${PHASE4_DERIVED_DATA}" \
IMORA_PACKAGE_CACHE="${PHASE4_PACKAGE_CACHE}" \
bash scripts/test-ios.sh -only-testing:ImoraTests/Phase4LiveHoldTests
```

后文 `NativeTest(Class)` 指仅替换上述 `-only-testing` 的类名；RED 必须出现指定业务断言失败，GREEN 必须该测试类 0 failures。依赖/编译失败不能冒充有效 RED。UI 测试类前缀改成 `ImoraUITests/`。系统实况写回、HDR/性能验收另用用户后续授权的专用真机，模拟器不能证明保真或帧率。

未来进入独立 server 根后：

```bash
pnpm --dir server exec vitest --config test/vitest.config.mjs run src/services/media-edit.service.spec.ts
pnpm --dir server exec vitest --config test/vitest.config.medium.mjs run test/medium/specs/services/media-edit.service.spec.ts
pnpm --dir server run check
```

`ServerTest(file)` 指第一条中替换文件路径；`ServerMedium(file)` 指第二条。medium 使用独立数据库/Redis/测试端口，不能重置当前会话服务。新测试夹具使用合成媒体/合成 EXIF 和专用账号，不接用户真实图库执行编辑/删除。

以下每个任务步骤 5 都是未来实施后的可独立审查变更与证据记录；本规划会话不产生提交。

## 4. 逐任务计划

### Task 1 / 4A：实况按住播放与取消

**Files:** 新建 `N:Imora/Features/Viewer/LiveHoldController.swift`、`N:ImoraTests/Phase4LiveHoldTests.swift`；修改现有 `LivePhotoPage.swift`、`VideoPlayerPage.swift` 和必要的 gesture hub。

**Interfaces:** 使用契约 `LiveHoldController.handle(event:context:) -> [PlaybackCommand]`；context 包含 assetID、pageGeneration、isActive、zoomScale、holdToken；输出 start/pause/showPoster/cancelLoad 命令，只允许当前 token 操作共享 owner。

- [ ] Step 1：加入 `testReleaseBeforeLoadDoesNotPlay`（hold→加载→release→lateReady 输出不含 start）、`testMoveBeyond10ptYieldsPaging`、`testSecondFingerCancelsHold`、`testVoiceOverPlaybackOwnsSinglePlayer`；锁定 0.35s 阈值与 end 后回封面。
- [ ] Step 2：`NativeTest(Phase4LiveHoldTests)`，确认上述行为在旧逻辑下失败。
- [ ] Step 3：实现 reducer 并接入按下/识别/抬手/取消生命周期；保留无障碍播放按钮，逐帧仅在编辑页呈现；普通视频播放不改变。
- [ ] Step 4：同测试类 GREEN；新增 UI 场景 `Phase4ViewerFlowTests.testHoldReleaseThenSwipe`，录制本机与云端加载取消，检查后台和音频中断。
- [ ] Step 5：独立评审 diff，附 A01–A08 证据；4A 可以先于高级编辑交付。

### Task 2 / 4A：本机可靠分类

**Files:** 新建 `DeviceMediaFacts.swift`、`N:ImoraTests/Phase4MediaFactsTests.swift`；接入前三批筛选与精选集实际落点，不重复实现截图。

**Interfaces:** `DeviceMediaFacts.extract(snapshot:AccessiblePhotoSnapshot) -> MediaFactsSnapshot`；输出独立 `yes/no/unknown + provenance + revision`，不改 `DeviceAsset` proof 语义。

- [ ] Step 1：测试 `testSelfPortraitUsesSmartAlbumMembership`、`testHighFPSIsNotAutomaticallySlowMotion`、`testLimitedAccessCountsOnlyVisibleAssets`、`testMotionHalfNotCountedAsStandaloneVideo`、`testFilenameDoesNotProveScreenshot`。
- [ ] Step 2：`NativeTest(Phase4MediaFactsTests)`，确认缺失事实/错误推断的断言为 RED。
- [ ] Step 3：读取可访问 PhotoKit subtype/智能相簿/资源类型；建立范围标记和修订；复用筛选计数与分页 snapshot。
- [ ] Step 4：测试 GREEN；UI 检查有限授权、unknown 和无预览模式文案；更改权限后旧封面立即失效。
- [ ] Step 5：交付 C01–C07 对应证据与独立 diff，不依赖新服务端。

### Task 3 / 4B0：固定输入、原件证据与资源租约（G0）

**Files:** 新建 `EditSourceManifest.swift`、`OriginalEvidenceEligibility.swift`、`N:ImoraTests/Phase4OriginalProtectionTests.swift`；只在必要接点修改 `PhotoLibraryService.swift`、`CleanupVerification.swift`、`ControlledMediaStore.swift`、`LocalImageLoader.swift`。

**Interfaces:** `EditSourceResolver.resolve(subject:EditSubject, scope:AccountScope) async throws -> SourceManifest`；`OriginalEvidenceEligibility.evaluate(manifest:SourceManifest, evidence:OriginalEvidenceSet) -> EligibilityDecision`。legacy/current/unknown 一律不能被此适配器提升为 unadjustedOriginal。

- [ ] Step 1：夹具包含 `.photo/.fullSizePhoto`、`.pairedVideo/.fullSizePairedVideo` 同时存在且字节不同；测试 `testRenderedProofCannotAuthorizeOriginalCleanup`、`testBothOriginalLiveComponentsRequired`、`testDraftLeasePreventsEviction`、`testFavoriteOnlyChangePreservesContentIdentity`。
- [ ] Step 2：`NativeTest(Phase4OriginalProtectionTests)`，确认旧的“当前资源等于原件”假设不能通过。
- [ ] Step 3：记录明确资源角色、内容摘要和读取基线；草稿租约与派生文件隔离；本机运动缓存加入 revision；附加清理门禁仅消费可靠原件证明，未知则保留设备副本。
- [ ] Step 4：新测试 GREEN，并运行现有 `BackupVerificationTests`、`LivePhotoVerificationTests`、`BackupReceiptReplayTests` 和清理相关测试；保证旧 receipt 可读且不会被自动升级。
- [ ] Step 5：输出 G0 资源选择/证据表，单独审查；未通过不开放相关编辑后的清理资格。

### Task 4 / 4B0：编辑模型和持久草稿

**Files:** 新建 `MediaEditModels.swift`、`EditDraftStore.swift`、`N:ImoraTests/Phase4DraftStoreTests.swift`；未来新增本机独立 editing.sqlite，不修改现有索引 schema 作为捷径。

**Interfaces:** 契约的 `MediaTime`、`MediaEditIntentV1`、`EditDraftStore.saveDraft/enqueue/recordTargetResult/loadRecoverable`；`EditDraft` 包含 draftID/scope/subject/source/baseRevision/intent/targets/state/updatedAt，`DraftReceipt` 包含 draftID/persistedRevision/committedAt。

- [ ] Step 1：测试 `testRestartRestoresLastCommittedDraft`、`testDiskFullDoesNotReportSaved`、`testFutureSchemaIsReadOnly`、`testCorruptDatabaseIsPreserved`、`testAccountIsolationAndIndexReset`、`testUnknownActionsRoundTrip`；source lease 与草稿入队原子一致。补`testAutosaveThenCancelDoesNotPublish`、`testResumeDraftRequiresExplicitChoice`，覆盖U01–U03。
- [ ] Step 2：`NativeTest(Phase4DraftStoreTests)` 得到业务 RED。
- [ ] Step 3：实现 WAL/FULL 事务、版本迁移、300ms debounce＋完成前 flush、不可变 operation body、per-target receipts；未发送草稿与发送过的操作分别保存。按增补第6节区分entryBaseline/workingDraft/committedDisplay，cancel/退出保留草稿但不入队/发布，完成才提交。
- [ ] Step 4：测试 GREEN；模拟提交前/后强制退出检查边界，不声称 debounce 窗口未写入值可以恢复。
- [ ] Step 5：交付可恢复草稿基础 diff，记录迁移前后数据数量与摘要。

### Task 5 / 4B0：服务端 CAS、receipt 与原子渲染发布（G1）

**Files:** 新建契约所列 media-edit DTO/controller/service/repository/table/outbox/render service 和具名 tests；修改 `server.dto.ts` 实际 feature schema、server service、app module、schema/index、相关旧写入口和受控媒体读取。

**Interfaces:** 契约第 2–4、8 节所有 media-edit 路由/状态；repository `accept(input:AcceptMediaEdit) -> MediaEditReceipt` 必须在同事务写 head/receipt/outbox；renderer 发布检查 edit/source/access epoch。

- [ ] Step 1：`media-edit.service.spec.ts` 测试相同 revision 并发仅一个成功、同键重试/异 body、缺 If-Match=428、队列失败不丢已接受文档、旧写入口=409、回滚开关后仍只读保护；medium 测试真实事务与并发首次创建。
- [ ] Step 2：运行对应 `ServerTest`、`ServerMedium`，得到业务 RED。
- [ ] Step 3：实现 capability、revision 0、中性 PUT 还原、幂等 tombstone、durable outbox 和 renderer staging/publish；不接入未实现 renderer 子能力标志。新增原件 source manifest 提取接口，禁止客户端声明 source 即被信任。
- [ ] Step 4：测试 GREEN、`pnpm --dir server run check`；注入 DB commit 前/后进程退出、job 发布失败、旧任务晚到、权限撤销和源文件改动，断言 head/原件/配对未被不完整输出修改。
- [ ] Step 5：记录 G1、迁移 up/关闭 feature 保留数据验证，独立评审；客户端先仅能存草稿和前台提交/对账。

### Task 6 / 4B1：公开 API 的系统实况写回可行性验证（G2）

**Files:** 未来新建隔离验证 target/测试夹具与 `docs/validation/phase4-live-writeback.md`；不得把未通过验证的代码接进产品。

**Interfaces:** 输入为已固定的双组件源和 `LiveEditV1`，输出能力表 `normalMute/keyFrame/trim/pairRoundTrip/systemEffect`，每项是 proven/unsupported/unverified。

- [ ] Step 1：列出公开 SDK 的可写属性与合法输出路径，用专用测试库编写关键帧移动、修剪、音频、方向、重开、重新导入/跨设备用例；明确 photoTime 只读。
- [ ] Step 2：先运行未实现的能力用例并记录失败，不通过私有 metadata key 补成假 GREEN。
- [ ] Step 3：仅对公开 API 可证明的输出实现最小验证；产物和原件分别保存，不能用普通视频冒充 Live asset。
- [ ] Step 4：真机和跨设备重新读取验证 subtype、component identity、cover PTS、时长与可继续编辑；每个能力单列证据。
- [ ] Step 5：如果完整语义不成立，将 G2 标 unsupported，按已确认默认交付 Imora 效果和视频导出；如用户要求完整系统写回，回到产品范围确认，不能把此项默认为已完成。

### Task 7 / 4B1：实况高级编辑与 Imora 成品

**Files:** 新建 `LivePhotoEditScreen.swift`、`N:ImoraTests/Phase4LiveEditTests.swift`，扩展 renderer/现有编辑控件；新增 `S:server/src/services/live-render.service.ts` 和对应 spec，接入 media-render dispatcher。

**Interfaces:** `LiveEditV1`＋通用 geometry/color；`LiveRenderPlan.make(intent:MediaEditIntentV1, frames:FrameIndex) throws -> LiveRenderPlan`；输出 poster+motion 的同一 revision，原 pair ID 不变。

- [ ] Step 1：测试 3 帧/0.3 秒边界、短源完整原范围静音可保存但不能开loop/bounce、cover 被裁出后的最近帧、原照封面不降质、A/B/C/D→A/B/C/D/C/B、切回普通恢复 normalMuted、循环视频导出完整周期达到 3–30 秒、超30秒单周期提示缩短、双组件渲染一方失败、不同组件尺寸crop按契约映射。另测U09–U14：密集手柄精细调整、VO逐帧、crop边界/四转双镜像和surface revision交接。
- [ ] Step 2：`NativeTest(Phase4LiveEditTests)`、`ServerTest(src/services/live-render.service.spec.ts)` 得业务 RED。
- [ ] Step 3：实现缩略帧/设封面/区间/静音/效果、完整快照 undo/redo、受支持保存目标；loop/bounce 反向采用有界帧块处理，禁止全量无界内存；生成成品而非覆盖 motion original。实现增补规范的密集目标、精细调整/VO、合法crop和surface交接规则。
- [ ] Step 4：测试 GREEN；UI 覆盖未备份本机/配对/云端/旧服务器、松手恢复当前封面、重开编辑、失败保留草稿；G2 未通过不得展示完整系统实况写回。
- [ ] Step 5：以 L01–L12 的可读成品/摘要/操作日志独立评审，开启通过的 live 子能力。

### Task 8 / 4C：统一视频渲染与特殊 profile 门禁（G3）

**Files:** `MediaEditRenderer.swift`、`MediaEditKernel.metal`、`N:ImoraTests/Phase4VideoRenderTests.swift`；新增 `S:server/src/services/video-edit-render.service.ts` 及 spec，复用现有媒体 repository。

**Interfaces:** 契约 `MediaEditRenderer.preview/render`；`VideoRenderPlan` 消费固定 source/GeometryV1/PhotoColorV1/VideoEditV1，产物带 renderer/source/edit/profile revision。

- [ ] Step 1：夹具含竖向 transform、clean aperture、24/25fps、VFR、无音轨、0.08秒短片、HDR/Log unknown；测试 crop 映射、至少2帧/0.1秒修剪边界、短源完整原范围旋转调色可提交、A/V≤40ms、CPU/GPU/云端色块阈值与特殊 profile 拒绝静默 SDR。
- [ ] Step 2：`NativeTest(Phase4VideoRenderTests)` 与对应 `ServerTest` 得业务 RED。
- [ ] Step 3：实现固定管线顺序与 SDR profile；用实际 PTS 和显示尺寸，不以 nominal fps 构造源帧；HDR 仅明确转换副本或通过 G3 的独立 profile。
- [ ] Step 4：同测试 GREEN；真机运行 G3 夹具，测 4K 长片的有界内存、热限制和导出恢复；未通过 HDR 保真也不得阻塞普通 SDR 交付。
- [ ] Step 5：独立审查 renderer、色彩差异报告、输出 metadata 与输入原件摘要。

### Task 9 / 4C：视频编辑 UI 与系统照片显式写回

**Files:** `VideoEditScreen.swift`、`PhotoKitEditWriter.swift`、`N:ImoraTests/Phase4PhotoKitWriteTests.swift`、`N:ImoraUITests/Phase4VideoEditFlowTests.swift`；保留 legacy `VideoTrimEditor` 作为旧服务器入口。

**Interfaces:** `PhotoKitEditWriter.apply(intent:MediaEditIntentV1, expectedSource:SourceManifest) async throws -> PhotoKitApplyReceipt`；receipt 包含 adjustmentID、回读修订、verificationState，不只是 Bool。

- [ ] Step 1：测试全参数 undo/redo、同 PTS 原图比较、crop＋旋转重开不跳框、外部 adjustment 使用 current baseline、写入期间外部修改、permission 拒绝、成功本机但云端超时不撤回本机。
- [ ] Step 2：`NativeTest(Phase4PhotoKitWriteTests)` 与专用 UI 场景确认 RED。
- [ ] Step 3：实现视频/调整/裁剪三页、save target、PHContentEditingOutput+versioned adjustment、前后修订检查与失败草稿；不把 PhotoKit 当可 CAS 的数据库。
- [ ] Step 4：测试 GREEN；本机真实 PhotoKit 读取重开，验证源文件/回退边界；旧 `/trim` 保持2秒/1秒限制，视频新工具只在支持时显示。
- [ ] Step 5：附 V01–V11 证据独立评审，普通 SDR 的系统写回属于交付验收，不以 G2 结果代替。

### Task 10 / 4D：云端可靠分类与可重建索引

**Files:** 新建服务端 media-facts DTO/controller/service/repository/table/spec；客户端接入 `DeviceMediaFacts` 来源合并与服务器 capabilities。

**Interfaces:** 契约第 5 节 facts 请求、unknownCount/coverage/snapshot；`MediaFactsService.extract(assetID, sourceRevision)` 不读取未授权原件，不把文件名/fps当确证。

- [ ] Step 1：测试 import 白名单/owner/摘要匹配、source 改变使 facts 过期、有限来源 unknown 不等于0、Live motion 去重、分页/计数同 snapshot、撤权后旧封面不可见。
- [ ] Step 2：运行对应 `ServerTest`、`ServerMedium` 和 `NativeTest(Phase4MediaFactsTests)` 新用例确认 RED。
- [ ] Step 3：实现按版本的元数据提取、可取消回填和来源解释；默认关闭本机事实上传，显式同意后只传白名单事实。
- [ ] Step 4：测试 GREEN；大图库索引分批处理、首页不等待全库回填；旧服务端继续本机分类。
- [ ] Step 5：交付 facts coverage 示例、权限与迁移证据，独立开启 mediaFactsV1。

### Task 11 / 4D：最近的日子、旅程建议与用户覆盖

**Files:** `DerivedCollectionBuilder.swift`、`DerivedCollectionScreen.swift`、`N:ImoraTests/Phase4DerivedCollectionTests.swift`；新建服务端 derived-collection DTO/controller/service/repository/table 与 spec。

**Interfaces:** 契约 `recentDays/tripSuggestions`、集合分页和 overrides；算法输入为固定 metadata snapshot，不引入新的原片扫描。

- [ ] Step 1：测试 UTC+8/负时区/午夜/DST、日期 unknown、30日边界、每日1项详情/3项卡片、48小时/24小时/6项/100km/50km/30天边界、无 home 不叫旅程、无定位素材需确认、覆盖层重建不丢、同素材换ID不重复推荐。补U06/U07：无GPS手动新建、重复创建、合并去重、互斥完整拆分、输入revision任一冲突不部分隐藏、重建保留谱系。
- [ ] Step 2：`NativeTest(Phase4DerivedCollectionTests)` 和服务端同一 JSON 夹具测试确认 RED。
- [ ] Step 3：实现确定性排序、粗粒度 home opt-in、可解释推荐和稳定 ID 匹配；源集合不自动变云端相册，转相册调用前三批明确上传工作流。新增FixedCollectionV1 CRUD与批量If-Match/幂等receipt、parent/replacedBy谱系和原子隐藏；不得隐式上传或改源素材。
- [ ] Step 4：测试 GREEN；本机与云端各自覆盖范围、大/小/无预览、无 GPS、撤权、晚同步素材、手动旅程全部可用。
- [ ] Step 5：附 D01–D11 证据独立评审，不依赖音乐或完整跨设备同步。

### Task 12 / 4E：影片 manifest 与确定性编排

**Files:** `MovieModels.swift`、`MoviePlanner.swift`、`MovieSnapshotStore.swift`、`N:ImoraTests/Phase4MoviePlannerTests.swift`；新建 memory-movie与media-snapshot DTO/controller/service/repository/table/spec，保留原 Memory DTO/枚举。

**Interfaces:** `MoviePlanner.makeManifest(input:preferences:seed:) -> MovieManifestV1`；项目接口独立 projectRevision/幂等，不重用 asset editRevision。

- [ ] Step 1：测试相同输入/seed输出完全一致、60/90/120 BPM、15/30/60秒目标、最多60项/180秒、标题/重叠总长、最后过渡none、短素材不重复凑长、固定顺序不因新缩略图改变；另测本机保存未下载完整不能offlineReady、云端项目引用阻止旧revision/源/成品30天GC、静态照片固定旧photo intent、撤权不因租约被绕过。另测U08的item构图、换项目画幅/undo/重开和导出一致。
- [ ] Step 2：`NativeTest(Phase4MoviePlannerTests)` 和服务端 manifest 校验测试确认 RED。
- [ ] Step 3：按设计等分时间桶选片与时间编排，固定snapshot/presentationRevision，新增media_edit_revision与snapshot一致读取/租约；旧memory转本机草稿但不改原集合，本机ref不能上传云端；离线保存时固定全部成品后才offlineReady，普通自动播放仍只预取当前/下一项。增加item级framingV1和保持焦点/面积的画幅映射，项目crop不修改源asset。
- [ ] Step 4：测试 GREEN；项目权限、CAS、删除不删素材、未知版本保留为只读通过。
- [ ] Step 5：交付 manifest 样例与算法夹具，独立审查。

### Task 13 / 4E：回忆播放器、节奏和音乐

**Files:** `MemoryMovieScreen.swift`、受控 music catalog 模型与资源目录、`N:ImoraTests/Phase4MoviePlaybackTests.swift`；修改 `MemoryLane.openMemory` 路由。

**Interfaces:** 播放器只消费 manifest；`MoviePlaybackClock` 提供 manifest time→当前素材/过渡/音量，单媒体时钟；曲目 `rightsProfile` 明确可试听/可导出。

- [ ] Step 1：测试暂停/拖进度后时钟不漂移、只准备当前下一项、3秒缺失停住而非自动删项、Reduced Motion、默认静音、原声duck0.2/150ms、音乐500ms循环淡化、无授权曲库music=null。补U04/U05/U15/U17：过渡前或中间stall冻结clock/音乐，generation拒旧seek，本次跳过不改导出，临时静音不改音轨，Reduced Motion不改片长。
- [ ] Step 2：`NativeTest(Phase4MoviePlaybackTests)` 得业务 RED。
- [ ] Step 3：实现播放器、全部照片、前后素材、音乐/节奏编辑与持久化；背景/撤权/换账号立即停止并清理当前授权文件引用。按增补第8节实现冻结/重试、temporarySkippedItemIDs/viewerMuted与manifest隔离，全部照片返回同位置且暂停。
- [ ] Step 4：测试 GREEN；UI 包含 VoiceOver操作、动态字体、横竖屏、低速网络与零曲库，不用截图声称真实无障碍或音频时序验证已完成。
- [ ] Step 5：先可交付无音乐播放；曲目资源与权利记录核验后才开启音乐选择，不影响其他模块。

### Task 14 / 4E：回忆影片可靠导出

**Files:** `MovieExportCoordinator.swift`、导出状态页、`N:ImoraTests/Phase4MovieExportTests.swift`；受控导出目录与 source lease；首版不新增服务端影片导出路由。

**Interfaces:** `export(projectID:profile:) -> ExportReceipt`；receipt 为 manifestRevision、profile、fileDigest、duration、byteCount 和完成状态，不能作为 backup receipt。

- [ ] Step 1：测试播放同 manifest 导出总时长误差≤1输出帧、A/V≤40ms、撤权/缺失列清单、不可导出曲目阻止混入、低空间保留项目、杀进程staging隔离、重新生成不重复入系统相册、导出文件不授权清理。补U08/U15/U16：framing与预览一致、静音观看后导出仍遵循显式音轨、项目/离线文件/成品操作对象分开。
- [ ] Step 2：`NativeTest(Phase4MovieExportTests)` 业务 RED。
- [ ] Step 3：实现 preflight、1080p SDR/H.264/AAC、进度/取消/过期恢复、原子完成与校验；用户确认才请求照片添加权限或调用分享。构图与音轨只读manifest；临时观看静音/跳过不进入导出。
- [ ] Step 4：测试 GREEN；在专用设备完成180秒/60项、4K源降采样、混合音轨的资源压力与低空间验证；不保证后台永不暂停。
- [ ] Step 5：交付可播放MP4、ffprobe/解码摘要与 M01–M12 证据，原件哈希保持不变。

### Task 15 / 4F：完整 outbox、账号隔离与未知结果恢复

**Files:** `EditOutboxCoordinator.swift`、`EditDraftsScreen.swift`、`N:ImoraTests/Phase4OutboxTests.swift`；接入 SessionStore/后台任务/网络政策，扩展 4B0 前台对账为完整调度。

**Interfaces:** 契约 reconcile/pause/resume、immutable EditOperation、per-target TargetResult；`EditOperation` 固定 bodyBytes/requestHash/baseRevision/operationID/accountScope/target/attempt；凭证不入库。

- [ ] Step 1：测试接受后丢响应→重启→receipt对账不重复；2/5/15/60/300s+jitter、429/401/403分类；暂停屏障；LAN/WAN同身份；登录其他账号不读不发；旧操作未决时新草稿不篡改body；90天后tombstone不重新执行。
- [ ] Step 2：`NativeTest(Phase4OutboxTests)` 和 HTTP fixture 测试确认 RED。
- [ ] Step 3：实现前台/网络恢复/可用后台机会触发对账，同subject串行，不跨账号执行；现有收藏 last-intent retry 保持独立，不强制迁移成新编辑事务。
- [ ] Step 4：测试 GREEN；协议/网络故障注入和用户暂停/恢复/登出/能力撤销都有可见状态，已本机保存但远端失败不得被抹掉。
- [ ] Step 5：交付 O01–O10 证据，连接所有编辑保存入口，独立评审。

### Task 16 / 4F：冲突 UI、迁移与整体验收（G4）

**Files:** `EditConflictResolver.swift`、`EditConflictScreen.swift`、`N:ImoraTests/Phase4ConflictTests.swift`、`N:ImoraUITests/Phase4RecoveryFlowTests.swift`；必要时补服务端真实并发测试。

**Interfaces:** 契约 compare/proposeMerge；ConflictAnalysis 输出冲突组/源变化/相等与可合并建议；用户确认后才生成基于最新 revision 的新 operation。

- [ ] Step 1：测试裁剪作为整组、时间与封面/效果与静音联动、不同组只建议不自动写、相同意图可对齐状态、源/配对变化阻止重放、再次412保留两版、采用云端后30天草稿恢复、PhotoKit无CAS竞态、删除不自动复活。
- [ ] Step 2：`NativeTest(Phase4ConflictTests)` 与 UI/服务端并发用例确认 RED。
- [ ] Step 3：实现冲突预览和四个明确动作；做 DB/旧trim/旧photo/receipt/facts/movie迁移和只读降级，损坏文件不清空。
- [ ] Step 4：测试 GREEN；运行前三批最终完整 native unit/UI 与 backend相关回归、验收矩阵所有适用项；对真实不支持的能力记录 N/A 理由，不能把未测写成通过。新增Phase4InteractionFlowTests覆盖U01–U18；所有新图片入口执行I01–I18适用项，图片体验不等4F才量测。
- [ ] Step 5：G4审查，提交“能力开关→证据→已知限制”清单；仅在后续用户授权范围内准备集成，部署/真实图库操作不在本规划授权中。

### Task 17 / 4P：稳定显示身份、首屏持久包与首帧图片集合（优先执行）

**Files:** 新建`N:Imora/Core/Images/MediaDisplayIdentity.swift`、`LaunchPreviewStore.swift`、`MediaPresentationCoordinator.swift`、`N:ImoraTests/Phase4LaunchPreviewTests.swift`；按最终落点修改`ImageLoader.swift`、`LocalImageLoader.swift`、`SessionStore.swift`、`SessionCache.swift`、`TimelineCache.swift`、`TimelineModel.swift`和RootScene。只消费metadata/现有图片端点，不改原件/备份proof。

**Interfaces:** 增补规范的MediaDisplayKeyV1/MediaAccessGeneration、LaunchPreviewStore.checkpoint/restore、prepareViewport；LaunchPackReadResult显式complete/partial/invalid/notAvailable。恢复出的scope必须与当前凭证已有验证绑定一致；稳定内容key不是授权凭证。

- [ ] Step 1：写`testCompleteLaunchPackRestoresRealW0`、`testMetadataOrThumbhashDoesNotCountAsPresented`、`testInterruptedCheckpointKeepsPreviousCompletePackAndLatestAnchor`、`testNewContextSameVerifiedUserReusesContentWithoutReusingAuthorization`、`testDifferentAccountSameAssetIDNeverHits`、`testUnknownIdentityStaysCredentialScoped`、`testDraftPreviewDoesNotPolluteCommittedPack`、`testProtectedOrLockedContentIsExcluded`；覆盖I01–I04/I09–I15。
- [ ] Step 2：`NativeTest(Phase4LaunchPreviewTests)`确认真实行为RED；同时只读核对项目锁定Nuke版本的key/removeAll语义并记录，不把依赖语义猜测当故障。
- [ ] Step 3：从既有缓存预算内划32MiB保护首屏预览，后台250ms稳定视口checkpoint与原子generation；重启只恢复W0需要的metadata和适配预览、限并发解码后提交，服务器probe/全库扫描/备份/facts计算不进入首屏关键路径。按证据迁移legacy credential cache，保留运行时context与权限取消检查。
- [ ] Step 4：同类测试GREEN，独立设备运行`Phase4ImagePresentationFlowTests`的恢复/重启/首屏案例；测W0真实图像而非只有ready布尔值。完整包重启p95≤800ms、全启动动作至可操作参考p95≤1.5秒，首次空缓存单列；不得以拉长启动遮罩获得漂亮内容首帧。
- [ ] Step 5：独立审查缓存身份迁移、IO/解码trace、正常与异常分布、原件与编辑资料未受缓存GC影响的证据。4P不等新服务端media-edit能力，先交付基础。

### Task 18 / 4P：可见优先调度、全图片入口与动效交接（G5）

**Files:** 扩展`N:Imora/Core/Images/ThumbnailLoadLimiter.swift`、`ThumbnailPrefetcher.swift`、`AssetThumbnailSource.swift`、`RemoteImage.swift`、viewer bridge/registry/hosting及各图库/搜索/精选集入口；新建`N:ImoraTests/Phase4ImageDemandTests.swift`、`N:ImoraUITests/Phase4ImagePresentationFlowTests.swift`与隔离性能采集配置。公共内容模型来自Task17，不创建第二下载管线。

**Interfaces:** 增补规范`ThumbnailDemandScheduler.acquire/release`、P0/P1/P2、MediaDisplayKey/AccessGeneration和presentation generation；全页面用同一表示规格，view ready与实际显示分阶段记录。

- [ ] Step 1：测试`testVisibleDemandOvertakesQueuedPrefetch`、`testCancelPrefetchKeepsVisibleSharedConsumer`、`testReverseScrollDropsOldWindow`、`testPhotoKitPreheatMatchesActualRequestOptions`、`testGridAndViewerReusePreparedLocalImage`、`testLateOldRevisionNeverReplacesCurrentSurface`、`testMemoryPressureKeepsW0BeforeOffscreenHighRes`、`testLaunchAndCacheHitHaveNoPerTileFade`。加入旧源缺失/iCloud策略/新token/有限权限/低空间夹具，对应I05–I18及U14/U18。
- [ ] Step 2：`NativeTest(Phase4ImageDemandTests)`得到业务RED；独立UI夹具先验证捕捉首帧/黑帧/错图的方法能检测故意注入的失败，不能只测状态变量。
- [ ] Step 3：统一自定义限流lane与Nuke/PhotoKit请求的优先级/引用计数取消，视口和速度自适应窗口；统一网格/viewer cache scope与尺寸；开场、翻页、松手和编辑返回复用已就绪surface，正常缓存路径无逐格fade/shimmer；首屏期间sweep/facts/render让出资源。片段/音频先ready再切换，保留generation检查。
- [ ] Step 4：单元与UI GREEN；按G5真机至少30次分场景测启动/完整W0/可操作、滚动/打开返回0空白帧、排队IO解码/呈现及hitches，报告p50/p95/最坏值/异常率。复用前三批interruptible viewer/period回归，证明性能优化未打断原交互；低空间/离线不拿占位算成功。
- [ ] Step 5：G5独立评审，4P与4A共同放行；后续4B1/4C/4D/4E新增图片页面须重跑其适用用例而非无理由重跑所有已有测试。未测真机不能宣称加载达标。

## 5. 交付与评审规则

每项交付至少提供：用户可见结果；精确 capability/profile；测试命令与结果；原件摘要和备份证明未被提升的断言；失败/恢复截图；迁移与关闭功能后的行为。只有文档被接受但成品未生成时，状态必须写 accepted/rendering/failed，不能写 ready。

新增图片与UI细节以二次审计R01–R17和增补规范为追踪来源；总计18任务、122项验收定义。G5必须随图片入口交付，不允许等4F才发现启动慢或图片逐格出现。

测试按变更风险运行，纯文案和可逆样式调整不另建照抄实现的单元测试；上述测试都针对数据、手势、并发、媒体时序或恢复风险。验证通过后不要无理由重复全套。没有独立设备/数据库条件时先完成纯模型和服务端隔离检查，将需设备项目保留为未验证，不能占用前三批设备补证据。

阶段性评审可以接受 4A 或其他独立项，不代表接受 G2/G3 保真声明。全批完成必须明确：哪些在 Imora 内生效、哪些能写回系统照片、哪些只导出副本、哪些仍因公开 API/设备 profile 受限。
