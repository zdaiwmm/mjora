# 第四批接口与持久化契约（提案，尚不存在）

日期：2026-11-15。配合 [详细设计](01-detailed-design.md) 使用。以下 endpoint、类型、表、feature 均是**待实施的新契约**，不能当成当前服务器能力。URL 以现有 API base 为前缀。

本版纳入 [图片/交互/动效增补](07-loading-and-interaction-spec.md)：稳定显示身份、编辑会话状态、项目构图与固定集合写接口见下文新增条款。

## 1. 与前三批的接口隔离

- 保留 `PUT/GET/DELETE /assets/{id}/edits` 与前三批 `photo.parameters.version=1`，不改变 action 顺序、数值、颜色/几何公式或未知字段 round-trip。
- Live/Video 使用独立 `media-edit` 文档，不向旧 `/edits` 塞入新 action，不假定 `/trim` 在此服务器树中存在。
- 第四批原始输入若已有可解码照片编辑，将完整已批准参数作为基线的一部分记录，不能只搬颜色再漏掉裁剪。不理解的外部调整固定为 `foreignCurrent` 基线，不能 flatten 后假称可恢复原链。
- 旧接口对普通静态图继续工作。对已采用新文档的 Live/Video，旧 `/trim`、旧 `/adjust`、旧 `/edits` 写入必须统一检查 `media_edit_state`：返回 **409 MEDIA_EDIT_DOCUMENT_ACTIVE**，含安全提示；不得另写旧成品覆盖当前展示。若旧路由在目标服务器不存在，维持不存在，不为兼容增加一套影子路由。
- 所有影响源文件、live 配对、可见性的写入都递增相应 source/access epoch，使 CAS 与 render publish 检查可捕获变化。只改收藏不改变像素源修订。
- 回滚第四批 feature 时，已有新文档的资产保留旧客户端只读保护，播放最后有效成品或明确原版；不能解除旧写入口保护而允许不知情覆盖。

## 2. 能力协商

`GET /server/features` 增量增加可选字段：

| 字段 | 开启的最低含义 |
|---|---|
| `mediaEditDocumentsV1: true` | 文档 GET/PUT、强 ETag、幂等 receipt、durable render outbox 全部成立 |
| `liveEditsV1: true` | LiveEditV1 的普通/修剪/封面/静音可存取并生成 Imora poster/motion |
| `liveEffectsV1: ["loop","bounce"]` | 列表内效果经过对应 renderer 验收；空/缺失不支持 |
| `videoEditsV1: true` | 普通 SDR 视频 trim/crop/mirror/rotation/color/mute 管线可用 |
| `mediaFactsV1: true` | 云端可靠分类含 provenance、覆盖范围与一致分页 |
| `derivedCollectionsV1: true` | 日期/地点/旅程建议及覆盖层协议可用 |
| `memoryMovieProjectsV1: true` | 云端影片 manifest 存储与 CAS 可用，不代表服务器可导出 |
| `memoryMovieExportV1: true` | 服务端可渲染影片；初始 **false/不发布**，首版本机导出 |
| `mediaEditSyncV1: true` | 新文档变化可通过 delta 或 revision 对账，兼容未知状态恢复 |
| `mediaEditProfilesV1: ["sdr709-1080-v1"]` | 只开放明确通过验证的输出 profile；不借此声称 HDR |

前三批 `photoEditsV1` 原样保留。字段缺失或 GET 失败视为未知/不可写，不从产品版本推断。支持文档但缺 live/video 子能力时可以读取，不能提交对应类型。权限与 profile 仍需逐资产判断。

客户端新增 `ServerFeaturesFingerprint` 可选字段与 `ServerCapabilities` 对应判断；稳定 serverIdentity/账号隔离缓存，socket 提示版本变化或收到不支持错误即重新探测。旧客户端必须可忽略新增字段。

## 3. 文档模型

类型采用 Swift/TypeScript 都能表达的 JSON，不含任意 URL/磁盘路径/SQL/FFmpeg 表达式。完整意图限制 **256KiB**，JSON 深度最多 **16**，未知版本拒绝写入且可完整只读保存。所有数值必须有限。

```text
MediaTime = { value: Int64-as-decimal-string, timescale: Int32 }
  timescale > 0 且 <= 1_000_000_000，value >= 0；有理数比较使用防溢出算法。

SourceComponent = {
  role: originalPhoto | originalVideo | originalMotion | foreignCurrent,
  remoteAssetID?: UUID,
  digest: { algorithm: "sha256", hex: lowercase64 },
  byteCount: decimal-string,
  contentRevision: opaque-string,
  displayWidth:positive-int, displayHeight:positive-int,
  displayTransform:validated-matrix,
  cleanAperture:validated-rect,
  colorProfile:known-profile | unknown
}
  既有 SHA-1 proof 保持既有表示；此 SHA-256 不是对旧 proof 的转换。

SourceManifest = {
  sourceRevision: opaque-string,
  baselineKind: unadjusted | imoraKnown | foreignCurrent,
  components: SourceComponent[],
  displayWidth: positive-int, displayHeight: positive-int,
  colorProfile: sdrSRGB | sdr709 | displayP3 | hdrHLG | hdrPQ | log | unknown,
  orientationRevision: opaque-string,
  duration?: MediaTime,
  frameIndexRevision?: opaque-string
}

GeometryV1 = {
  crop: null | {x:int, y:int, width:positive-int, height:positive-int},
  mirrorHorizontal: Bool, mirrorVertical: Bool,
  quarterTurnsClockwise: 0 | 1 | 2 | 3,
  straighten: finite-number(-45...45),
  horizontalPerspective: finite-number(-1...1),
  verticalPerspective: finite-number(-1...1)
}
  坐标为原始方向校正后的显示像素；顺序完全遵循前三批。
  未验证的视频/Live warp profile 强制后三项为 0，非 0 返回 422。
  新Live/Video crop还要求x,y>=0、width/height>=2，右/下界不超过参考显示矩形；
  源crop不强行取偶，yuv420p输出尺寸独立按合法偶数重采样。旧静态图schema不变。

PhotoColorV1 = 前三批 photo.parameters 的 version + 全部颜色成员，
  不在新文档中重复存储该 action 的几何成员。
  所有颜色项 -100...100，invert 为 Bool；缺省中性。

LiveEditV1 = {
  in: MediaTime, out: MediaTime,
  cover: { kind:"originalPhoto" } | { kind:"videoFrame", pts:MediaTime },
  normalMuted: Bool,
  effect: "normal" | "loop" | "bounce"
}

VideoEditV1 = { in:MediaTime, out:MediaTime, muted:Bool }

MediaEditIntentV1 = {
  schemaVersion:1,
  kind:"live" | "video",
  source:SourceManifest,
  geometry:GeometryV1,
  color:PhotoColorV1,
  live?:LiveEditV1, video?:VideoEditV1,
  renderProfile:"sdr709-1080-v1"
}
  live/video 恰有一个，且与 kind 一致。

MediaEditStateV1 = {
  assetID:UUID, editRevision:decimal-string,
  intent:MediaEditIntentV1,
  status:"neutral"|"accepted"|"queued"|"rendering"|"ready"|
         "blockedSource"|"blockedPermission"|"failed"|"superseded",
  lastReadyRevision?:decimal-string,
  operationID?:UUID,
  rendererVersion?:opaque-string,
  failure?:{code:string,retryable:Bool}
}
```

云端 intent 的组件只引用服务器资产，并由服务器校验自身文件元数据，不能相信上传的 byteCount/duration。系统的“server original”可能是此前上传的当前渲染资源；只有可证明角色才写 original*，否则使用 foreignCurrent。无可验证摘要/角色时先建 manifest 的服务端提取任务，不接受客户端自己声明为未调整原件。

本机持久文档可有 localIdentifier/installationID，**序列化到云端前必须映射到经验证的 remoteAssetID 并去掉本机标识**。配对未完成时为 blockedSource，不偷偷上传。

帧索引来自实际源 sample/PTS，保存修订。实际改变区间时的修剪验证：Live ≥3 帧且 ≥0.3s；Video ≥2 帧且 ≥0.1s；out ≤原 duration，cover 在 `[in,out)`。完整原范围（in=0且out精确等于原duration）豁免最短范围，可保存短源的静音/旋转/调色；但短Live的loop/bounce仍必须满足3帧且0.3s。至少有1个可解码帧、正duration才可作为有效源。source 内的 duration 是原时间域，不是此前 trim 后时长。原始 cover 允许不对应 motion 中同分辨率的画面。

Live的顶层displayWidth/height固定为原照显示空间，也是geometry参考空间；每个组件另存自己的实际显示尺寸/transform。motion应用crop时按原照归一化比例映射：左/上取floor、右/下取ceil并夹在motion显示边界内；原照完整矩形映射为motion完整矩形。稳定处理/视场差异不伪称已对齐，poster与motion各自预览真实结果。用户选择的视频封面同样使用此固定参考空间，不因更换cover改变crop定义。方向/显示矩形未知时关闭几何写入。

初始无编辑状态 GET 返回中性 state revision **"0"**；其 intent 从服务端验证的基线构建，不是客户端合成来源。若摘要/时间基尚未准备好，GET source/media-edit 返回202 `{status:"preparingSource", retryAfterSeconds}`，不伪造可提交的manifest或ETag；客户端保留元数据草稿、允许取消并轮询，准备好后才启用完整提交。

## 4. 提交、对账和事件

| 请求 | 前置条件 | 成功/失败 |
|---|---|---|
| `GET /assets/{id}/media-edit` | AssetRead；不泄露无权 motion | 200 state + 强 `ETag: "medit:{id}:{revision}"`；不存在/不可读 404 |
| `PUT /assets/{id}/media-edit` | 逐资产 edit 权限；`If-Match`；`Idempotency-Key: UUID`；完整意图 | 新提交 202 receipt+state+新 ETag；重放 200 相同 receipt；缺 If-Match 428 |
| `GET /media-edit-operations/{operationID}` | 当前账号自己操作或有明确管理权限；重新核对资产可见性 | 200 receipt；确实未接受 404；结果 tombstone 410；不能用 404 证明刚发送的请求没在处理中 |
| `POST /media-edit-operations/{operationID}/retry-render` | 当前文档仍是此 revision，且 edit/read 权限有效 | 202 同修订新 attempt；已 superseded 为 409；不会再创建文档 revision |
| `GET /assets/{id}/media-edit/source` | 原始资源读取权限 | 元数据 manifest + 受控资源引用/帧索引摘要；不返回服务器磁盘路径 |
| `GET /assets/{id}/media-edit/revisions/{revision}` | 当前read/download权限和旧修订仍保留 | 不可变旧intent与资源snapshot引用；已过期410，不回退为当前head |

客户端必须先持久化**将发送的确切 UTF-8 body bytes**，`requestHash = SHA256(bodyBytes)`。重试同 ID 时发送相同 bytes；不依赖 Swift/JS 浮点 JSON 编码恰好一致。服务器以同一 bytes hash 判别键是否重用，文档语义校验另做。相同意图的冲突比较使用解码后规格化值，不拿 wire hash 当语义相等。

处理顺序：认证/授权 → 在事务锁内查该账号 operationID（重放先于 If-Match）→ 同键异 payload 拒绝 → 校验源与 base revision → 写文档新 revision、immutable receipt 和 durable render outbox → 提交事务 → 返回 accepted → dispatcher 可靠投递媒体任务。队列暂时不可用不能丢任务或返回“未保存”。同资产写入必须锁定 head，初始 revision 0 的并发创建也受唯一约束保护。

错误码：

- 409 `IDEMPOTENCY_KEY_REUSED` / `MEDIA_EDIT_DOCUMENT_ACTIVE` / `RENDER_SUPERSEDED`。
- 412 `EDIT_REVISION_CHANGED`，返回有权查看的当前 revision/ETag，客户端再 GET 完整状态。
- 422 `SOURCE_CHANGED` / `INVALID_TIME_RANGE` / `COVER_OUTSIDE_RANGE` / `UNSUPPORTED_PROFILE` / `UNSUPPORTED_SCHEMA`。
- 403 权限失效；404 资源不可见；413 payload 过大；429 配额，附 Retry-After。
- 5xx/传输中断：结果未知。不能直接标操作失败并撤回已被接受的本机成果。

receipt 记录 operationID、actor/account、assetID、requestHash、acceptedRevision、acceptedAt、current render status；完整失败/响应详情至少保存 **90 天**。精简幂等 tombstone（键、hash、revision/已删除标志）保留到资产/账号生命周期结束；清理详情后同键请求只能返回 410 outcomeKnown，不再次接受，避免很久以前的离线操作重新执行。注销账号按既有账号删除政策清除。

事件建议 `MediaEditStateV1 {assetID,operationID,editRevision,renderRevision,status}`。事件仅提示刷新，客户端不凭未鉴权 socket payload 换文件。无 delta 子协议时以 GET/前台对账工作；新增 delta 记录必须先在 capabilities 声明，不能把现有 `RemoteSyncRecord` 的未知 type 硬塞入其解析器。

render worker 只读取固定 sourceRevision；输出先进入 staging，校验解码、时长、尺寸、音轨与摘要，再事务比较当前 head/source/access epoch 并原子发布 poster+motion/video。已经 superseded 的任务只保留其 receipt/可回收成品，不得覆盖当前指针。原文件与原始 `livePhotoVideoId` 不变。

## 5. 分类与聚合

`MediaFactV1 {category, value:yes|no|unknown, provenance:photoKit|fileMetadata|manual, extractorVersion, sourceRevision}`。

| 新接口 | 行为 |
|---|---|
| `GET /assets/media-facts?category=&cursor=&snapshot=` | 返回该权限范围内的 IDs、knownYesCount、unknownCount、coverage、snapshot、nextCursor；count 与结果同一个 snapshot；过期 snapshot 返回 409 要求重新开始 |
| `PUT /assets/{id}/media-facts/import` | owner/受控 metadata edit 权限；仅白名单枚举事实、源摘要与 extractor 版本；禁止任意 EXIF 和 localIdentifier；可以按来源删除导入事实 |
| `GET /derived-collections?kind=recentDay|tripSuggestion|placePeriod&cursor=&snapshot=` | 列表封面、完整成员数、算法版本、输入水位、来源覆盖、nextCursor；受权限和可见性过滤 |
| `GET /derived-collections/{id}/assets?cursor=&snapshot=` | 与列表相同 snapshot 的成员；已失去权限的素材即时剔除，count 可返回 invalidated，触发刷新而非泄露旧 ID |
| `PUT /derived-collections/{id}/overrides` | If-Match，用户标题/封面/排除/固定成员；仅该用户覆盖，不能改他人资产 |

分类尚未处理的不是 no。导入的截图事实只能说明可信 PhotoKit 来源，不表示文件本身带有该标记。facts/source revision 变化使可重建索引失效，不触发备份 proof 升级。

云端常驻地区设置为独立的 opt-in 用户偏好：`homeRegion {latitude/longitude rounded to 0.1 degree, radiusKm:50}`。实际判断仍按明示粗粒度近似，不用于定位用户。用户不设/不允许上传则只生成日期地点集合，不返回“旅程”假结果。删除设置停止新推断，既有固定项目保留成员而移除敏感推断说明。

派生集合 ID 是账号内持久对象，生成结果有 `generationRevision`。同算法的相邻重算采用成员交集最大匹配（Jaccard ≥0.5；多候选按交集数、旧 ID 字典序），否则建新对象；用户已固定的集合不再自动变成员，保存为独立固定集合。隐藏记录绑定对象与成员指纹，算法更新不得立即把完全相同成员换 ID 重新推荐。

手动旅程/固定集合补充：`FixedCollectionV1 {id,ownerID,revision,kind:manualTrip|fixedCollection,title,orderedAssetIDs,parentIDs,replacedByIDs}`。至少1项、logicalID去重；云端仅接受可读remote refs，本机/混合集合不隐式上传。

- 新增`POST /fixed-collections`（客户端UUID、Idempotency-Key）、`GET/PUT/DELETE /fixed-collections/{id}`（写入If-Match）；删除只删集合/引用。
- 新增`POST /fixed-collection-operations`，operationID＋Idempotency-Key；merge/split输入带各`{kind:derived|fixed,id,ifMatch}`和确定输出ID。事务检查全部revision/权限、写新固定对象与parent/replacedBy谱系、隐藏被替代建议；任一失败412，不能部分隐藏。输出顺序、去重和拆分覆盖约束按补充规范第9节。
- `GET /fixed-collection-operations/{operationID}`提供独立receipt/未知结果对账，同键同body只执行一次，同键异body409；不与媒体operation混用。
- 自动suggestion被替代的隐藏覆盖绑定原对象和成员指纹，算法重建仍保留。操作只改当前用户集合，不修改原资产日期/GPS/相册。

## 6. 回忆影片项目

```text
MovieManifestV1 = {
  version:1, projectID:UUID, projectRevision:decimal-string,
  sourceMemoryID?:UUID,
  seed:opaque-string,
  durationPresetSeconds:15|30|60,
  aspect:"portrait"|"landscape"|"square",
  pace:"calm"|"standard"|"fast",
  items:[{
    subject:remote-asset-ref or local-ref (云端只能 remote),
    snapshotID, sourceRevision, presentationRevision, editRevision?,
    in?:MediaTime, out?:MediaTime,
    duration:MediaTime, fit:"contain"|"fill",
    framingV1:{rect:{x,y,width,height}, focalPoint:{x,y}},
    transition:{kind:"none"|"crossfade", duration:MediaTime},
    useOriginalAudio:Bool
  }],
  music:null|{trackID,version,digest,bpm,beatOffset:MediaTime,rightsProfile},
  title:{text,maxDuration:MediaTime},
  outputProfile:"sdr709-1080-v1"
}
```

单项目最多 60 项、180 秒、manifest 最大 256KiB；durationPreset 是自动编排目标，不强制凑足。项目总长由各 item duration 减 crossfade overlap 再加标题确定，不能依赖 UI 字符串。最后项过渡必须为 none，其他 overlap ≤相邻项最短时长的 1/2，项目无零/负时长。

framingV1坐标在snapshot显示空间归一化，rect在0...1边界内且宽高>0，contain为完整画面；fill按输出画幅裁剪，使用补充规范的保持焦点/面积规则。历史无framing字段项目解码为contain完整/居中fill的既有语义，首次保存才写出明确框；不能因此改变旧项目画面。它不是源asset编辑。`viewerMuted`和`temporarySkippedItemIDs`只在播放session，不序列化到manifest；修改导出音轨或排除素材须创建显式项目修订。Reduced Motion仅改变播放器视觉过渡，不改变manifest时间表。

`snapshotID`固定所选画面/运动/音轨和必要intent/source版本。新media-edit使用其editRevision；前三批静态照片或外部编辑没有该revision时使用服务端生成的独立presentationRevision，editRevision缺省，不能用0假装存在。clip in/out是snapshot展示时间轴（trim后起点0）。

新增`POST /assets/{id}/media-snapshots`（受read/download及个人项目配额约束，Idempotency-Key），body只能选择当前展示或明确旧editRevision，不能上传任意recipe覆盖owner素材；返回snapshotID/presentationRevision/sourceRevision/status。建立快照时以一致事务读取源和完整旧photo intent，取得必要文件租约，再生成/固定成品；不修改asset。`GET /media-snapshots/{snapshotID}`及`GET /media-snapshots/{snapshotID}/content?role=poster|motion|video|image|audio`重新核查原资产权限，按固定版本返回；尚在准备为202，过期410，撤权404，不偷偷返回最新版。

云端project写入事务同时创建/更新snapshot refs和源/成品租约，删除项目同时释放refs；无活跃引用的旧snapshot默认30天保留。对本机/混合项目不登记云端project或云端永久租约：`MovieSnapshotStore.prepareLocal(projectID:)`逐项获取已选snapshot，全部固定文件持久落盘后事务设置offlineReady；失败保留preparing/needsAttention。自动播放草稿只准备当前/下一项，未固定项过期需用户选择；离线保存动作才下载全部所需内容。旧服务器不支持snapshot时先在本机固定可读取成品及摘要，任何无法确定版本的项必须提示刷新选择，不能发出已固定全部旧版本的承诺。

音乐节拍数据只允许来自受控目录，不执行用户自带滤镜代码。无内置曲库时 music=null 完整合法。云端项目保存时再次检查所有引用素材的 read/download 权限，导出时再次检查；原件不存在则列出问题，不能后台上传本机替代物。

新增 `GET/POST /memory-movie-projects`、`GET/PUT/DELETE /memory-movie-projects/{id}`，PUT/DELETE使用独立project ETag与同样If-Match/幂等语义，POST使用Idempotency-Key。项目操作对账用 `GET /memory-movie-operations/{operationID}`，有独立receipt/tombstone，不误查媒体操作endpoint。原 memories CRUD 保留不变。项目删除只移除项目，不删素材；项目 conflict 不复用媒体 editRevision。

首版本机导出由 `MovieExportCoordinator` 消费持久 manifest，无服务器 export endpoint。以后如开放服务端 export，另增 job endpoint 和 capability，不能让 `memoryMovieProjectsV1` 自动暗示有服务端转码服务。

## 7. 本机类型接口（未来文件中的约定）

```text
EditDraftStore (actor, 独立 editing.sqlite)
  saveDraft(draft: EditDraft) async throws -> DraftReceipt
  enqueue(draftID: UUID, targets: Set<EditTarget>) async throws -> [EditOperation]
  recordTargetResult(operationID: UUID, result: TargetResult) async throws
  loadRecoverable(scope: AccountScope) async throws -> [EditDraft]

EditOutboxCoordinator (actor)
  reconcile(scope: AccountScope, trigger: SyncTrigger) async -> ReconcileSummary
  pause(scope: AccountScope) async throws
  resume(scope: AccountScope) async throws

EditConflictResolver (纯函数，无网络/PhotoKit 写入)
  compare(base: MediaEditIntentV1, local: MediaEditIntentV1,
          remote: MediaEditIntentV1) -> ConflictAnalysis
  proposeMerge(analysis: ConflictAnalysis) -> MergeProposal?

LiveHoldController (@MainActor)
  handle(event: LiveHoldEvent, context: LiveHoldContext) -> [PlaybackCommand]
  LiveHoldEvent = began | recognized | moved(distancePt) | ended | cancelled |
                  pageChanged | zoomBegan | sceneInactive | loadReady(token)

MediaEditRenderer
  preview(intent: MediaEditIntentV1, at: MediaTime, targetPixels: Int) async throws -> PreviewFrame
  render(intent: MediaEditIntentV1, destination: ProtectedRenderDestination) async throws -> RenderResult

DerivedCollectionBuilder (纯元数据算法)
  recentDays(input: CollectionInputSnapshot, policy: RecentDayPolicy) -> [DerivedCollection]
  tripSuggestions(input: CollectionInputSnapshot, home: HomeRegion?, policy: TripPolicy) -> [DerivedCollection]

MoviePlanner (纯函数)
  makeManifest(input: MovieInputSnapshot, preferences: MoviePreferences, seed: String) throws -> MovieManifestV1

MovieExportCoordinator (actor)
  export(projectID: UUID, profile: ExportProfile) async throws -> ExportReceipt
```

上述参数/返回类型均归属同名模型文件，不能临时用 Bool/字典穿透模块。`PreviewFrame` 和 `RenderResult` 带 source/edit/profile revision；`TargetResult` 分别表达 accepted/unknown/ready/permission/conflict，不把异构目标结果压成一个成功状态。

共同类型最少字段约定：`EditTarget=appLocal|cloud|photoKit`；`EditDraft` 含draftID/scope/subject/source/baseRevision/intent/targets/state/updatedAt；`EditOperation` 含operationID/draftID/scope/subject/target/baseRevision/bodyBytes/requestHash/attempt/state；`DraftReceipt` 含draftID/persistedRevision/committedAt；`PhotoKitApplyReceipt` 含adjustmentID/readbackRevision/verificationState。`OriginalEvidenceSet` 只能包含逐资源角色/摘要/owner/字节回读证据，不以可用的render receipt构造；`EligibilityDecision=eligible|retain(reason)`。`FrameIndex` 包含sourceRevision、各实际PTS和sampleDuration；`TargetResult` 的状态之外记录对应revision/receipt或明确错误码。`CollectionInputSnapshot` 包含来源scope/snapshot、逻辑素材的captureInstant?、captureWallDate?、位置/精度?、visibility、facts与稳定ID；`MovieInputSnapshot` 是同样鉴权后的固定素材和可用展示区间。问号为真实unknown，不得以当前时间/零坐标填补。

## 8. 表与资源生命周期

本机：`edit_draft`、`edit_operation`、`edit_target_result`、`edit_source_lease`、`movie_project`、`export_job`；source 和项目数据库文件受账号目录隔离、iOS 文件保护和现有 ControlledMediaStore 授权检查。DB 写 WAL/事务并做完整性检查。outbox 不持久化 token，每次发送通过当前 SessionStore 取得正确账号凭证。

服务端新增表职责：

- `media_edit_state`：asset 唯一 head、source epoch、edit revision、intent、last ready 指针。
- `media_edit_revision`：asset+revision唯一的不可变intent/source refs；head替换不能丢旧文档；被项目引用时保留必要源版本。
- `media_edit_operation`：actor+operationID 唯一，hash、accepted revision、tombstone。
- `media_render_outbox`：与 intent 同事务，任务投递/重试进度；jobKey=assetID+editRevision+profile+rendererVersion。
- `media_rendition`：源/编辑/profile/renderer 版本、文件角色与摘要、可见性状态；不会写入 asset originalPath/checksum。
- `media_fact`：asset+category+provenance+sourceRevision 的事实。
- `derived_collection`、`derived_collection_override`：生成结果和用户覆盖分离。
- `fixed_collection`、`fixed_collection_operation`：手动/固定成员、幂等receipt及merge/split谱系，原资产不变。
- `memory_movie_project`：不可变修订 manifest 与当前 head，owner 独立校验。
- `media_snapshot`、`media_snapshot_reference`：跨普通照片/Live/Video的固定展示版本，权限仍继承原资产；仅云端project登记长期引用。本机`movie_snapshot_file`只登记本机项目持久文件和摘要。

staging 失败只删 staging；已发布成品被 draft/project 引用时持租约。没有引用的旧派生成品默认 30 天后清理，receipt tombstone 和用户草稿保留规则独立。原件/备份证据不参与此垃圾回收。账号删除走既有资源清理机制，避免孤儿文件。

所有读取、预览、轮询、重试和下载都重新校验 scope/权限；禁止日志写 token、精确 GPS、localIdentifier 和原始图像。日志以 operationID、匿名化 subject、revision、错误码为主，足够定位未知结果与 stale render，而不产生新媒体泄露面。

## 9. 显示身份、首屏包和编辑会话补充

4P优先复用既有thumbnail/preview接口，不把快速显示强制绑定第四批新服务端。客户端`MediaDisplayKeyV1`、`MediaAccessGeneration`、`LaunchPreviewPackV1`、P0/P1/P2调度接口与ready层级以补充规范第2–5、12节为准。若服务器缺少版本/稳定身份，使用当前已验证credential作用域和可验证响应validator，不猜测跨token/host映射；旧资料可作为明确缓存版本展示，获知新revision/权限后立即按语义失效，不把未知revision冒称最新。

首屏pack是普通可重建预览缓存，32MiB预算在既有磁盘缓存内划分；不会成为edit草稿或backup proof。稳定key不含token/URL session UUID，但每次显示仍检查runtime授权，不能删除现有请求隔离。新`LaunchPreviewStore`不能替代`MovieSnapshotStore`用户显式离线保留的持久文件。

编辑会话模型新增`entryBaselineRevision/workingDraftRevision/committedDisplayRevision/editorSessionID`：自动保存只能写draft，完成事务才更新committedDisplay并enqueue选定target；cancel/close不enqueue。已发送操作只能停止未发目标，未知结果保留对账。各图像回调带displayKey/accessGeneration/presentationGeneration；UI不能把旧草稿或已取消回调发布到新页面。
