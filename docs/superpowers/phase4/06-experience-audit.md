# 功能、UI、交互、动效与图片加载二次审计

日期：2026-11-15。**结论：原稿仍有需要补齐的细节，尤其缺少全App图片呈现放行门槛。现已补入规划，不能据此宣称产品已达到速度或视觉目标。**

本轮只审阅设计/契约/计划和只读源码，未运行App、采集新UI截图、操作模拟器/设备、运行产品测试或修改前三批工作树。两项独立只读审查分别覆盖交互/动效和图片链路。以下优先级表示规划需要优先解决的程度，不表示已复现产品故障。

## 1. 审计结果与处置

| ID | 优先级 | 原稿缺口/源码风险 | 本次补入的确定规则 | 对应验收/任务 |
|---|---|---|---|---|
| R01 | P1 | 只有metadata缓存和编辑/影片性能，缺整个App的首屏图片目标 | 全图片入口4P、G5；正常缓存复访首个内容帧真图覆盖100%，无逐格填充/淡入，测完整启动到可操作 | I01–I03/I18；17–18 |
| R02 | P1 | URL带runtime UUID、浏览scope带token；跨进程内容身份未确认 | 稳定DisplayKey与runtime授权generation分离，安全迁移、不跨账号读；先核对Nuke缓存键/removeAll语义 | I04/I12/I15；17 |
| R03 | P1 | metadata/压缩字节/UIImage ready容易混作用户已看到 | 五级ready、首个实际呈现帧、首屏预览包与离主线程解码；placeholder不计作真图 | I02/I03/I10；17–18 |
| R04 | P1 | 网格scope与viewer部分本机预热/缓存查询scope不同，可能不能复用已热位图 | 共享已验证内容/表示规格，复用launch bridge；首个viewer/返回帧不得黑屏 | I07/I08；18 |
| R05 | P1 | Nuke高优先不代表自定义FIFO已给可见图优先 | P0/P1/P2统一调度、请求合并、按消费者取消、方向/速度窗口；后台sweep不得占首屏槽 | I05/I06/I16；18 |
| R06 | P1 | 自动存草稿、取消、完成与展示版本没有统一边界 | entryBaseline/workingDraft/committedDisplay分离；取消只留恢复草稿，不发布/入队；已发送操作另行对账 | U01–U03；4/7/9/15–16 |
| R07 | P1 | 回忆下一项未ready、stall时音乐/clock/过渡没有完整规则 | 过渡边界即冻结整条时钟和音轨、保持有效画面；3秒才显示恢复操作；generation拒绝旧结果 | U04/U05；13 |
| R08 | P1 | 手动旅程、合并/拆分已承诺，只有overrides接口 | 增加固定集合CRUD与批量幂等CAS谱系；不自动上传，不删原资产，重建不反复推荐被替代集合 | U06/U07；11 |
| R09 | P1 | 回忆fill/crop只有fit字段，没有持久构图 | item级framingV1、snapshot坐标、画幅切换映射、预览/导出同构图，不修改原asset crop | U08；12–14 |
| R10 | P2 | 双击/hold/移动接管与时间轴控件重叠未闭合 | 完整手势仲裁、连续位移接管、44pt目标与精细调整/逐帧按钮、非拖动方式 | U09/U10；1/7/9 |
| R11 | P2 | 裁剪顺序有了，边界、奇数编码尺寸、四转/双镜像仍可各自猜 | 合法矩形、保持中心/面积、坐标不累计取整、even编码尺寸不改原crop | U11；7–9 |
| R12 | P2 | iPad/RTL/动态字/VO只有覆盖名称，没有可判定布局结果 | safe-area关键动作固定可达、窄窗控制滚动、RTL时间正向、VO可调时间与焦点规则 | U12/U13；7/9/13/16 |
| R13 | P2 | 原子发布不保证图片surface连续，播放时新版本可能打断 | 双组件锁revision到静止边界；ready后交接，取消/页面generation可中断；无空白帧 | I08/U14；7/9/13/18 |
| R14 | P2 | 回忆观看静音与导出音轨、保存/删除对象容易混淆 | viewerMuted不改manifest；明确集合/项目/离线下载/成品操作，回全部照片后不自动开播 | U15/U16；13–16 |
| R15 | P2 | Reduced Motion会否改变overlap/总长未规定；触觉未定义 | 视觉简化不改变时间表/音乐/成片；第四批首版不新增自定义触觉 | U17；12–14/16 |
| R16 | P2 | 缓存清理、权限缩减、iCloud卸载与无缓存被笼统称“加载” | 正常复访/初次/资源缺失/授权变化分别定义，scope优先，首屏包和草稿/项目固定资源分开 | I09/I11–I14；3/17–18 |
| R17 | P2 | UI事件未区分图片ready和presented，缺启动/滚动/打开全路径量测 | G5包含首帧完整率、真实可操作总时长、调度/IO/解码/提交/显示、hitches，至少30次分场景 | I01–I18/U18；18/16 |

上述规则已在 [图片与交互补充规范](07-loading-and-interaction-spec.md) 展开，并已同步到设计、接口、18任务计划和122项验收矩阵。这里的“补齐”指文档决策闭合，所有产品速度、UI和媒体正确性仍未实测。

## 2. 图片链路的现有基础与风险依据

只读源码根 `N=/Users/achilles/mjora/execution/photos-phase123/native`。工作树仍在并行推进，下面行号仅定位读取时状态；未来实施须核对最终提交。

| 源码 | 读取事实与正确解读 |
|---|---|
| `N/Imora/Core/API/SessionStore.swift:72`、`:121` | 用缓存账号先显示UI，后台确认；不能推导图片已显示 |
| `N/Imora/Features/Timeline/TimelineModel.swift:549`、`:644` | 本机/metadata/网络重叠；先恢复最近6个月，部分等待本机合并最多500ms；不是图片就绪屏障 |
| `N/Imora/Core/API/TimelineCache.swift:14`、`:69` | 持久bucket与Asset metadata，未看到完整首屏图像包 |
| `N/Imora/Core/Images/ImageLoader.swift:23`、`:50`、`:70`、`:234` | 配置1GiB压缩磁盘、96MiB内存、网络4/解码2；configure调用cache.removeAll；完整URL进入请求键。实际Nuke缓存策略要核对依赖，不能断言磁盘已全删或必定命中 |
| `N/Shared/AccountRequestContext.swift:7`、`:36` | 每runtime context新UUID写入media URL fragment，安全机制不能为了速度直接删除 |
| `N/Imora/Core/API/SessionCache.swift:28`、`N/Imora/Core/API/ImoraClient.swift:1295` | offlineAccountKey实际是canonicalRoot＋token摘要，不是设计中的稳定server/accountID |
| `N/Imora/Core/Images/LocalImageLoader.swift:35`、`:245`、`:376` | 本机48MiB图像/12MiB preview、限并发/取消/权限generation；仍有同步immediateImage兜底，不能将此兜底放进首帧主线程关键路径 |
| `N/Imora/Core/Images/ThumbnailLoadLimiter.swift:9`、`:22` | 自定义FIFO；Nuke high优先级不自动改变它的出队顺序 |
| `N/Imora/Core/Images/ThumbnailPrefetcher.swift:98`、`:158`、`:187` | 已有窗口/预取；direction不代表当前已做方向速度分层；viewer本机warm传空scope，网格使用scope |
| `N/Imora/DesignSystem/RemoteImage.swift:47`、`:143`、`:392`、`:521` | 内存命中可首帧用图；慢路径可逐格150ms fade，grid本机scope与viewer部分调用不一致；这些是源码风险，不是本轮视觉复现 |
| `N/Imora/Features/Viewer/AssetViewerHostingController.swift:1010`、`AssetViewerScreen.swift:4360` | 本机开场查缓存/图像调用省略scope；需要统一真实位图复用，而不是再造转场 |
| `N/Imora/Features/Viewer/AssetViewerScreen.swift:1926`、`:4201` | 已有开场bridge保持图到ready再交接；yield/ready callback不能独自证明GPU实际呈现时间 |
| `N/Imora/Core/API/ControlledMediaStore.swift:33`、`:98` | 每client临时目录、完整视频下载后交播放器；不是跨进程持久首屏仓库 |

保留并扩展这些优化比重写图片管线更合适。将1GiB容量、缓存命中、decode完成当作“用户再也看不到加载”的证据均不充分。

## 3. 需要说明的能力边界

- 正常缓存复访应直接呈现真实图；不满足就判G5失败，不能以“系统就是会加载”结束优化。
- 首次无缓存且离线、无权限、原件/预览真实缺失不能承诺无等待；界面必须明确原因、保留已有内容、允许恢复。
- 网络速度有限时不能保证从未看过的全图库任意fling都已下载；使用可见优先和落点预取，另测停稳补齐时间，不把异常场景隐藏。
- 原方案G2系统实况写回、G3 HDR保真与音乐资产依赖仍待后续验证；新增快速图片目标不允许用错误账号/旧编辑/错误低清画面换速度。
- 本轮没有新截图，无法确认实际控件像素对齐、遮挡、色彩或动画平滑。这里定义了后续可判定规则与测量方法，没有给未经运行的UI打分，也没有宣称“所有细节完全无遗漏”。

## 4. 评审后的执行建议

先做4P的可观测性、稳定display identity和首屏缓存复用，再做可见优先调度与转场交接；与4A同时放行。图片体验是每阶段的共同验收，不能拖到4F最后才检查。UI状态缺口分别归既有编辑/旅程/影片任务，避免最后靠一个大UI补丁兜底。

当前只需评审这些规划变化；本会话不实施。`planning-validation.json`只记录文件/链接/任务/用例静态一致性，不是App性能报告。
