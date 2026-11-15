# 源码依据、边界与实施前对齐清单

日期：2026-11-15。仅只读调查；没有运行产品构建/测试、操作模拟器、安装App、改产品代码、提交或部署。

## 1. 约束来源

| 来源 | 已采用的事实/边界 |
|---|---|
| `/Users/achilles/mjora/execution/photos-phase123/phase4-new-chat-brief.txt` | 当前会话只规划，保存到本目录；禁止修改phase123 native/server或干扰测试 |
| `/Users/achilles/mjora/execution/photos-audit-20261115-report.html` | F10、F12–F15是第四批主要缺口；报告明确实况/断网/真机HDR等并非已测结论 |
| `/Users/achilles/mjora/execution/photos-phase123/native/docs/superpowers/specs/2026-11-15-photos-phase123-design.md` | 前三批批准范围、photo v1精确参数/公式、原件与备份proof独立；明确排除本批高级功能 |
| `/Users/achilles/mjora/execution/photos-phase123/native/PRODUCT.md`、`DESIGN.md` | 照片优先的原生产品，系统样式、来源明确、Reduced Motion、保留备份安全语义 |

## 2. 源码阅读记录

以下 `N` 固定表示 `/Users/achilles/mjora/execution/photos-phase123/native`，`S` 固定表示 `/Users/achilles/mjora/execution/photos-phase123/server`，只用于记录本次阅读来源。**它们不是未来实施工作区。**

| 文件 | 观察和影响 |
|---|---|
| `N/project.yml` | iOS26.0、Swift6.0、多个Apple平台构建目标；新文件需考虑平台编译门禁 |
| `N/Imora/Features/Viewer/LivePhotoPage.swift` | 0.35秒长按后toggle、无松手逻辑；本机优先/远端fallback、180ms本地准备；需要按token取消 |
| `N/Imora/Features/Viewer/VideoPlayerPage.swift` | VideoPlayback单owner、异步claim、默认静音、release与reclaim；新hold不能破坏普通视频/短暂翻页恢复 |
| `N/Imora/Core/Images/LocalImageLoader.swift` | motionFile按localIdentifier缓存，24项LRU，优先fullSizePairedVideo；需源修订键及草稿源租约 |
| `N/Imora/Features/Viewer/VideoTrimEditor.swift` | 2秒原片/1秒保留；源视频与trim时间分开，30秒事件等待；新协议不可假定继承可用 |
| `N/Imora/Core/API/ImoraClient.swift` | videoTrim/setVideoTrim/removeVideoTrim客户端路由及兼容分支；不证明当前server树实现了它们 |
| `N/Imora/Features/Timeline/MemoryLane.swift` | Memory点击走ViewerPresentation普通查看器，既有保存/移除保留 |
| `N/Imora/Core/Models/Models.swift` | Asset有本机/云端/Live标记、duration毫秒；AssetEdit保留other action；新协议不可破坏未知round-trip |
| `N/Imora/Core/API/ServerCompatibility.swift` | 产品识别、可选feature、supportsTrim/Adjust等；第四批显式子能力加入此模式 |
| `N/Imora/Core/Backup/PhotoLibraryService.swift` | DeviceAsset已有isScreenshot；primaryResource/motionResource优先当前fullSize资源；不能把其proof直接叫未调整原件proof |
| `N/Imora/Core/Backup/BackupVerification.swift` | BackupProof绑定localRevision、owner/type/checksum及Live双方；不能由派生成品补造 |
| `N/Imora/Core/Backup/CleanupVerification.swift` | 清理另有fresh evidence、全库授权和原字节回读；本批要保护而不是绕过 |
| `N/Imora/Core/Sync/RemoteSyncClient.swift` | SyncScope稳定serverIdentity/accountID；已支持的记录类型白名单；新增type必须协商 |
| `N/Imora/Core/Sync/SyncStateStore.swift` | SQLite WAL/FULL、账号namespace和安全重建，属于同步索引，不是编辑草稿仓库 |
| `N/Imora/Core/Sync/LocalLibraryDeltaStore.swift` | 当前增量source要求全库授权；有限权限编辑/分类应建立自己的可见资产读取，不放宽备份完整性门禁 |
| `N/Imora/Core/Backup/BackupIntentStore.swift` | pause/explicit resume持久屏障；编辑outbox借鉴语义但不挪用日志 |
| `N/scripts/test-ios.sh` | 默认会生成工程并使用iPhone17模拟器，不能在此会话调用；未来须独立UDID/DerivedData/缓存 |
| `S/server/src/dtos/editing.dto.ts` | 读到的schema仍为crop/rotate/mirror；前三批扩展正在开发，不能当最终接口 |
| `S/server/src/controllers/asset.controller.ts` | /assets/{id}/edits GET/PUT/DELETE存在 |
| `S/server/src/services/asset.service.ts` | 当前editAsset明确只图像且拒Live；replaceAll后排缩略图任务，无新media-edit CAS |
| `S/server/src/repositories/asset-edit.repository.ts` | replaceAll事务替换；不等于跨设备If-Match或PhotoKit事务 |
| `S/server/src/controllers/memory.controller.ts`、`dtos/memory.dto.ts` | memories CRUD/成员/日期型模型，不是影片manifest；避免误改旧MemoryType |
| `S/server/src/schema/tables/asset-edit.table.ts`、`asset.table.ts` | 原始/配对/编辑数据有既有schema职责；新成品不能覆盖originalPath/checksum |
| `S/server/package.json` | NestJS、Kysely、BullMQ/现有媒体依赖与Vitest脚本；不在规划期安装任何依赖 |

早期读取时 HEAD：native `0421e1b9b75c85ff0b1818b91b710686c9ab5e69`，server `2151507ccc301cdb5d563118d3b4141b797a7420`。生成参考清单时native已前进到 `45b0cd853add02df6a4169eabf393a610dd0eba0`，server HEAD未变，说明原会话确实仍在推进。**HEAD不代表并行开发中的未提交内容。** 本目录的 `source-manifest.json` 记录生成清单时各文件字节摘要/时间，仅帮助定位参考状态；它不是完整工作树快照、测试证据或冻结承诺。方案对旧逻辑的观察来自前期阅读，实施前须重新核对最新代码，不能把清单时间的摘要当成此前读到的全部字节。

未读写 `server/web`，其AGENTS.md只约束该子树；本会话无适用的额外仓库AGENTS.md。未创建或修改任何phase123文件。

## 3. 官方技术资料（2026-11-15核对）

| 一手资料 | 支撑的事实 | 不据此推导的结论 |
|---|---|---|
| [Apple PHLivePhotoEditingContext](https://developer.apple.com/documentation/photos/phlivephotoeditingcontext) | 通过帧处理和audioVolume生成PhotoKit Live输出，可存adjustment data | 不表示可任意改key frame/trim或保存系统loop/bounce效果 |
| [Apple photoTime](https://developer.apple.com/documentation/photos/phlivephotoeditingcontext/phototime) | 关键照片时刻只读 | 不臆造setPhotoTime或trim API |
| [Apple Editing Asset Content](https://developer.apple.com/documentation/photokit/editing-asset-content) | 内容输入/输出、adjustment处理与库变更；视频对不可读adjustment的版本处理有约束 | 不保证跨App CAS或任意外部编辑链可还原 |
| [Apple PHAssetMediaSubtype](https://developer.apple.com/documentation/photos/phassetmediasubtype) | 公开媒体标记，多标签；高帧率与延时等有明确类型 | fps高不等于慢动作；没有列出自拍subtype不靠猜造一个 |
| [Apple smartAlbumSelfPortraits](https://developer.apple.com/documentation/photos/phassetcollectionsubtype/smartalbumselfportraits) | 自拍采用智能相簿类别 | 不读取系统Photos私有精选集数据库 |
| [Apple HDR editing sample](https://developer.apple.com/documentation/avfoundation/editing-and-playing-hdr-video) | AVFoundation支持HDR编辑/播放路径 | 当前Imora滤镜/FFmpeg配置已经HDR保真 |
| [Apple addResource](https://developer.apple.com/documentation/photos/phassetcreationrequest/addresource(with:data:options:)) | 可为新资产提供资源 | 任意重编码照片视频都能稳定重新配为Live |

平台资料只支撑上述事实。0.35s/10pt、聚合阈值、BPM、SDR默认、重试时间和性能预算都是本方案的产品/工程建议，不是Apple承诺。未做同机系统Photos高级页面的视觉逐项对照，不宣称1:1复刻。

## 4. 实施前必须对齐（不阻塞本轮规划）

| ID | 要对齐的问题 | 推荐处理与放行条件 | 对应任务 |
|---|---|---|---|
| P123-01 | 前三批最终代码/测试/交付状态 | 原会话交付后读取最终提交，独立工作区；不从正在变化的文件直接开工 | 全部 |
| P123-02 | photoEditsV1实际字段、action完整保存、未知结果对账 | 以批准spec和最终测试为准；本批单独media-edit协议，不修改公式 | 3–5、7–9 |
| P123-03 | PhotoKit照片编辑如何处理Live/外部adjustment | 明确是否限定普通静态图；Live不能被无告知flatten；统一恢复原始文案 | 3、6–9 |
| P123-04 | 原件resource选择与proof真实范围 | G0逐角色回验；legacy/current/unknown不升级；缺原件证据的编辑资产保留设备副本 | 3 |
| P123-05 | 收藏last-intent durable retry | 保持原有账号隔离与成功本机结果；不合并进media-edit造成行为回退 | 15 |
| P123-06 | 截图、Edited/Not in Album、source search、collection display落点 | 本机facts/派生集合接入真实最终代码，复用snapshot/偏好，避免双实现 | 2、10–11 |
| P123-07 | 日期formatter和asset capture时间依据 | date分组/AX/旅程统一；绝对时刻unknown明确降级 | 11 |
| P123-08 | trim/adjust路由在目标产品是否真的实现 | capability明确、GET成功读取旧状态；新文档开启后旧写入口保护 | 5、8–9 |
| P123-09 | 现有媒体队列/受控下载/事件协议 | 新任务durable outbox，旧client不会被未知sync type打断；先GET对账可独立运行 | 5、15 |
| P123-10 | 实施资源隔离 | 新sim UDID、DerivedData、包缓存、数据库、Redis namespace/端口；不得复用原会话设备/服务 | 全部验证 |

## 5. 用户待确认、工程探针与内容依赖分开

**产品待确认：** Imora内实况效果与系统写回边界；默认不同步覆盖；旅程建议/home opt-in；音乐来源和1080p SDR默认；分期顺序。默认建议已写在设计，不把未回复当批准。

**工程门槛：** G0原件资源证据、G1 CAS与outbox、G2公开API的系统实况写回、G3 HDR/特殊profile、G4整体验收。这些需要未来验证，不允许在规划阶段编造已通过。

**外部内容依赖：** 可随视频导出的音乐资产、beat metadata和权利记录。无音乐路线完整可交付。无需为此安装插件、连接音乐账号或主动联系任何人。

## 6. 本轮检查范围

允许且实际安排：读取brief/审查/已批准spec/源码/技能；核对官方API资料；写本目录Markdown和参考摘要；静态检查内部链接、范围/接口/测试覆盖一致性；一次只读文档builder check。

未执行：xcodegen、xcodebuild、simctl、设备安装、App启动、单元/UI/后端测试、pnpm安装、数据库迁移、服务器写请求、产品源码变更、git stage/commit/merge/push、部署或对外消息。计划中的代码路径和命令只用于后续执行者理解，不能读作本轮已完成实现。

## 7. 用户追加图片要求后的二次审计

新增需求是全App图片呈现速度；授权仍仅规划。执行了两个独立的只读审查：功能/UI/交互/动效，及启动/缓存/预取/查看器图片链路。发现17项文档缺口/源码路径风险，处置见 [审计报告](06-experience-audit.md)，具体新规则见 [增补规范](07-loading-and-interaction-spec.md)。未新增App截图或实测数据。

特别更正术语：现有`SyncScope.accountKey`的稳定server/user设计，**不等于**浏览图像已经用同一命名空间。当前`SessionCache.accountKey`为canonicalRoot＋token摘要，媒体URL另带context UUID；Nuke数据key与`cache.removeAll`的具体影响留给实施核对锁定依赖，不能在审计中武断宣称跨进程必命中或全部磁盘缓存必删除。

新增实施前对齐项：

| ID | 要对齐的问题 | 放行规则 |
|---|---|---|
| P123-11 | 图片/预取/viewer代码在前三批最终版本的变化 | 复用最终管线与launch bridge，4P只在未来独立工作区实施；避免覆盖原会话的交互/编辑/缓存修复 |
| P123-12 | 稳定server/user身份、credential scope和媒体请求context | 有证据迁移、不删除runtime授权检查，缺稳定身份时保留安全旧scope；新token/跨host不得猜测同账号 |
| P123-13 | Nuke锁定版本的request/data cache key及removeAll语义 | 先读具体依赖源码并加缓存生命周期测试，再决定最小修改；不得仅关闭淡入称为加载加快 |
| P123-14 | 本机预热与网格/viewer表示规格、priority FIFO、首屏恢复 | 以当前调用点核对scope/修订/尺寸/manager/options，P0跨全部队列生效；G5真机trace与实际图片帧放行 |

官方补充依据：[UIKit异步图像准备](https://developer.apple.com/documentation/uikit/uiimage/preparefordisplay(completionhandler:))、[PhotoKit预热的匹配条件](https://developer.apple.com/documentation/photos/phcachingimagemanager/startcachingimages(for:targetsize:contentmode:options:))、[启动性能与首帧之外的活动](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)。首屏800ms等为本方案建议，不是Apple承诺。

`source-manifest-recheck.json`只记录二次审计新关注文件的观察时摘要；原31文件清单保留。`planning-validation.json`更新为18任务/122案例与本版文档摘要；它仍只证明静态材料一致，不证明性能达标。
