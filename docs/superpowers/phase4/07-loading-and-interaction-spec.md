# 图片即时呈现与交互、动效补充规范

2026-11-15复审增补，**仅规划、未实施或测量**。本文件落实用户新增要求：“进入App后，所有图片的加载速度要足够快，不要进入App后还看到加载、渲染。”与原设计冲突时，以本增补的具体规则为准；原件、权限和前三批边界仍生效。

## 1. 体验目标与边界

这是全App的横向要求，覆盖普通照片、实况/视频封面、精选集/人物/相册/日子/旅程封面、头像/音乐封面、搜索结果、查看器胶片带、编辑缩略帧和回忆播放器。第四批计划增加优先阶段 **4P** 和放行门槛 **G5**；本轮不在前三批工作树实施。无自定义头像时的首字母是产品默认图形，不是假照片加载占位。

**正常复访：首个可交互图库内容帧应已有全部可见真实缩略图，不能出现空格、灰块、菊花、逐张填充或逐格淡入。** 打开照片由当前缩略图连续进入；高清准备时保留同一照片的清晰预览，不黑屏、不退回占位。GPU仍会渲染，但用户不应感知从空白到逐张出现的过程。

“所有图片快”指所有图片入口遵守同一呈现规则，**不是启动时下载/解码整个图库**。首次登录、主动清缓存、从未浏览的远程区域、系统回收文件、iCloud只在云端、真实原件缺失或拒绝权限，不可能凭空获得图像。这些场景有单独状态、指标和恢复动作，不算普通缓存复访，也不得混入正常命中率美化结果。

不通过延长启动屏、全屏遮罩、不可操作的空壳、虚假进度或等全库下载来隐藏加载。首屏只依赖正确账号、权限、当前视口元数据和适配尺寸的预览；服务器feature探测、原片哈希、全库扫描、备份对账、facts/旅程计算、回忆编排和同步重放不得阻塞它。

## 2. 显示就绪不是一个Bool

| 层级 | 含义 | 是否满足图片已呈现 |
|---|---|---|
| metadataReady | 已知ID、顺序、尺寸、日期与位置 | 否 |
| encodedReady | 压缩图片字节在磁盘，无需网络 | 否 |
| decodedReady | 已按目标尺寸解码为可显示位图 | 仅代表CPU准备好 |
| presentationReady | 方向/色彩/裁剪正确，显示surface可提交 | 仍须记录实际显示帧 |
| presented | 该视口内真实图像已在实际内容帧出现 | 是 |

thumbhash、模糊色块、骨架、纯色、原片下载完成但尚未显示，均不能计作真实图片已呈现。较小的同资产照片预览可作为打开转场的真实画面；“首屏缩略图已齐”则要求位图至少满足该网格显示像素需求，不能拿32px占位放大冒充清晰就绪。高清放大另记fullResolutionReady，不阻塞浏览。

保留现有Nuke/ImageIO/PhotoKit管线、请求合并和缓存，不为4P另建第二套下载器。先用trace分清磁盘读取、解码、调度等待、UI绑定和首个实际显示帧，再在真实瓶颈处改造。UIKit的异步图像准备可用于把解码移出主线程，不能假定它消除了所有首次GPU成本。[Apple图像准备](https://developer.apple.com/documentation/uikit/uiimage/preparefordisplay(completionhandler:))。

## 3. 稳定缓存身份与运行时授权分离

```text
MediaDisplayKeyV1 = {
  serverIdentity, accountID,
  subject: remoteAssetID | {installationID, localIdentifier} |
           {kind:avatar|artwork, objectID, contentRevision},
  sourceRevision, presentationRevision,
  variant: grid | cover | avatar | artwork | viewerPreview | original | livePoster | motionFrame,
  pixelBucket, fitMode, orientationRevision, colorProfile
}

MediaAccessGeneration = runtime-session-generation + permission-generation
```

- MediaDisplayKey可跨进程复用；token、请求context UUID、URL fragment、LAN/WAN host不进入稳定内容身份。它不是授权凭证。
- 每次读缓存/绑定图像/返回异步结果仍核对当前MediaAccessGeneration、账号和本机可见范围。旧请求晚到丢弃。不能为了命中率简单删除现有session fragment检查。
- 尚无经过验证的serverIdentity/accountID时，只读现有credential scope内的旧缓存；不得猜测用户ID或跨token合并。取得稳定身份后才建立有证据的映射。
- 现有credential-scoped缓存逐项校验资产、账号、修订再导入，不全库复制，不因token更新一律清掉有效内容，也不把旧账号缓存借给新账号。
- 当前源码的`SessionCache.accountKey`是canonicalRoot＋token摘要，不能写成已具备稳定用户命名空间。`ImageLoader.configure`内cache.removeAll究竟影响哪些Nuke缓存层，未来先核对锁定依赖源码再修改；本复审不推断其实际磁盘删除范围。
- 本机网格、viewer warm、viewer图像和开场cache lookup必须使用同一个已验证scope、修订、尺寸/fit描述。只有经过证明的同内容尺寸变体可共享位图，不以“配对已备份”推断两端当前编辑结果相同。
- 服务器当前成品、Imora已完成本机版本、编辑会话草稿是不同presentationRevision；自动保存草稿不污染普通网格显示键。
- 已知删除/隐藏/撤权/锁定立即清除可见引用和对应预览缓存，取消请求，安全优先于无闪烁。离线时无法知道尚未收到的远端撤权，不承诺瞬时跨设备撤销；沿用已明确的离线读取政策。locked媒体不进入普通持久首屏包。

## 4. 首屏持久预览包与启动路径

### 4.1 LaunchPreviewPackV1

账号内保存小型、可重建的首屏包：来源/筛选/排序、最近视口锚点、布局尺寸和scale、可见逻辑ID与revision、当前封面、尺寸匹配的编码预览及摘要、complete generation。**不保存包含工具栏/敏感页面的整屏截图。** 源图片、编辑草稿、项目pinned文件不混入普通预览包。

只保留当前主浏览上下文的可见视口W0＋前后邻接内容和当前精选集封面；建议每账号**32MiB**压缩预览包预算，从既有磁盘预览缓存预算中划出保护区，不再无界叠加一个全库缓存。内存解码缓存复用既有预算；内存压力时先去远端预取/全尺寸非可见对象，保住W0和转场当前图；不得无限保留所有已浏览图片。

已浏览图像到达后在后台落适配尺寸预览，滚动/布局稳定**250ms**后提交包。metadata、文件存在/摘要和scope核对全部成功才原子替换complete generation。中途退出保留上一个完整包；独立保存的最新浏览锚点不随之回滚。若最新锚点缺包，优先在同一锚点从普通磁盘/PhotoKit预览补齐，明确记一次checkpoint miss，不悄悄跳到别的日期伪装命中。无法补齐时进入受预算限制的缺缓存路径。

不能因为包损坏清空草稿或全部媒体缓存；隔离坏包并重建。系统回收/低空间/清缓存导致无包时如实统计；清缓存后不再声称下一次是有完整持久包的复访。

### 4.2 不同启动情形

| 情形 | 显示策略 |
|---|---|
| 进程仍在、普通前后台恢复 | 保留已呈现surface，轻量核对账号/权限；不因refresh重置所有image state |
| 进程重启，有合法complete包 | 并行读取小metadata和W0编码预览，限并发离主线程解码；整体提交W0，后台再做服务器/图库变化对账 |
| 有元数据但包缺项 | 同锚点使用普通磁盘或可访问PhotoKit预览，先准备W0；不启动全库补图任务占槽；记录缺项原因 |
| 首次账号、首次空缓存且在线 | 先取第一页面向当前视口的小缩略图，允许渐进呈现但不逐格动画；一处安静的同步状态，操作可达；不装成完整本地缓存 |
| 首次空缓存且离线 | 明确“此设备尚未缓存这些照片”，显示重试/切来源；不无穷菊花、不虚构空图库 |
| iCloud卸载原片但有本机预览 | 先显示真实本机预览；只有打开高清/编辑/主动实况播放时才依政策请求原资源 |
| 权限缩减、账号不确定或保护数据不可用 | 不显示先前无权图像；等待本地解锁/重新授权的明确状态，禁止网络/主线程忙等 |

初始布局先固定图片区域和封面比例，异步metadata不推动整屏跳动。后台新素材到达时在用户停止滚动且无转场时一次合并，保留anchor；不能让首屏先空→填充→重排两次。metadata尚未知不显示“0项”。

不人为hold启动screen。Apple的启动首帧指标也不能替代用户真正看到内容并可操作的时间；两者都测。[Apple启动性能](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)。

## 5. 滚动预取、优先级和全App复用

### 5.1 调度

统一调度器复用现有loader，维护三类需求：

1. **P0 当前可见/当前打开图/进行中的转场**，立即提升已经排队的同键请求；拖动期间的当前帧也属P0。
2. **P1 下一个视口、viewer相邻页、下一张回忆**，按方向和速度预备。
3. **P2 远处磁盘预取、离线sweep、聚合封面回填**，仅在P0/P1无压力时工作。

沿用当前总网络4、解码2的起始上限，经真机证据才调整。自定义ThumbnailLoadLimiter也要体现优先级和需求合并；不能只给Nuke请求设high，却让它排在自定义FIFO后。P0可抢下一次执行机会，不强行中断已进入不可取消解码的工作。预取等待只取消本消费者，引用计数为0才取消共享任务，避免取消预取连带取消可见图。

普通滚动：当前视口两侧各1屏解码预热；移动方向再提前1屏只落压缩字节。快速fling时减少过路区域解码，将资源留给可预测落点；反向立即调整窗口。窗口是视口相对值，适应iPad、网格列数/缩放，不固定“前20张”。当前图预览不主动下载原件或所有Live motion。

PhotoKit预热和实际request使用相同manager、targetSize、contentMode、delivery/resize/network选项。尺寸不同不能当作同次预热命中；公开API对此有明确约束。[Apple PhotoKit预热](https://developer.apple.com/documentation/photos/phcachingimagemanager/startcachingimages(for:targetsize:contentmode:options:))。

### 5.2 页面行为

| 页面 | 规则 |
|---|---|
| 网格/搜索/分类/相册 | 已有图保持原surface；cell复用先验subject/key，绝不闪前一张；高分图可安静升级，不逐格fade |
| 精选集/人物/日子/旅程 | 当前屏封面P0，下一屏P1；更换大/小/无预览遵守同key尺寸规则，无预览时不取图 |
| 图片打开 | 复用现有launch bridge/registry实际位图，第一帧与网格同照片/同构图，不能先黑屏再请求；预览接替thumbnail时保留surface |
| viewer左右翻页 | 当前preview＋前后各1项的匹配预览；手势途中不为上一页补高清；快速翻页generation丢弃晚结果 |
| 返回网格 | 保持原可见位图和anchor；先显示已完成编辑的prepared preview，再等正式render，不能闪原图或旧revision |
| 视频/实况 | poster先就绪；实际播放保留poster直到第一视频帧可呈现，同一原子切换；音频不能先于首帧出声 |
| 编辑器 | 缩略帧先用有限低分辨率序列，焦点帧升级为P0；相同意图复用kernel/context，不每滑一次初始化GPU；预览准备不阻塞完成/取消 |
| 回忆 | 当前和下一item含所需过渡surface都ready才过渡，见第8节；离线保存才准备完整项目 |

每个入口可追踪到同一DisplayKey/ReadyState。某一个网格很快不能代替所有图片入口验收。

## 6. 编辑取消、草稿与展示版本

明确三份状态：`entryBaseline`（打开时已完成版本）、`workingDraft`（本会话自动落盘恢复）、`committedDisplay`（用户点完成后可展示的版本）。

| 动作 | 本机数据/显示 | 外部写入 |
|---|---|---|
| 滑块、拖动、自动保存、后台/强杀 | 仅持久workingDraft，300ms规则不变；普通图库仍用committedDisplay | 不入outbox、不写PhotoKit、不发布server intent |
| 完成（有变化） | flush成功后事务形成用户提交版本与selected targets；以prepared新预览承接返回 | 才创建immutable operation；离线为待同步，不假称cloud ready |
| 完成（无变化） | 返回已有版本，不重新编码/新建无意义operation | 无新写入 |
| 取消/返回/下拉关闭（未发送） | 退出并保留恢复草稿，普通图库仍旧committedDisplay；轻量提示“已保留草稿” | 无新写入 |
| 再次编辑有草稿 | 先显示“继续草稿/从已保存版本开始”的轻量内联选择；不自动恢复后发布 | 选择本身不发送 |
| 明确放弃草稿 | 删除对应未提交草稿并释放其独占租约，保留已完成版本 | 不撤销已接受操作；永久丢弃需明确对象 |
| 操作已发送/accepted后关闭编辑器 | 保留各目标receipt；界面显示实际状态 | “停止后续同步”只能阻止未发目标，未知结果仍对账；撤销已保存修改须创建新CAS意图 |

退出手势全部经过同一close方法；写入磁盘失败留在编辑器并保留内存意图，可重试/明确放弃。不能为了禁止侧滑就永久锁住页面。恢复草稿的预览cache按editorSession隔离，不可被普通首屏包误收。

预览准备不禁用完成/取消，也不让退出等待网络或全片渲染。完成先落盘、建立可校验的选定目标操作：有合法新prepared preview则连续返回；暂时没有时立即返回并保留同资产的上次合法surface，明确“新编辑已保存，待生成；当前显示上次完成版本”，不能先显示新图再闪回旧图。没有合法图像则显示明确不可用原因，不伪造图片。源manifest不足以提交时只保存blockedSource草稿，不发送虚构操作。取消始终无需等预览，直接回entryBaseline/committedDisplay。

## 7. 手势、裁剪、布局与无障碍

### 7.1 仲裁表

| 上下文 | 优先顺序和收尾 |
|---|---|
| viewer图片区 | 系统边缘导航/可访问性操作→明确按钮→双指pinch或已缩放pan→有方向移动的翻页/关闭→hold→单击；继承前三批已验证recognizer结构 |
| 单击/双击 | 双击缩放消费事件，不能先单击闪一次工具栏；单击等待系统双击识别失败，设置不超过系统识别窗口的既有原生延迟 |
| hold后拖动 | 10pt从本次touch起点累计；hold失效后pager沿同一touch当前位置接管，转移累计位移不能跳图，不等第二次触摸才可翻页 |
| 编辑图片比较 | 仅图片非交互工具区域按住看基线，抬手回草稿；不触发Live播放；拖控件/第二指加入立即结束比较 |
| 时间轴 | 起止手柄/封面点/播放头优先于父级关闭/分页，触点命中区域至少44×44pt；不在同一拖动中转为另一对象 |
| 密集重叠目标 | 先选开始/结束/封面具体目标，再拖或用前后帧按钮；提供精细时间调整popover，不能只靠3个重叠细杆猜中；一次拖动只形成一次undo节点 |

横向拖播放头/时间轴不触发侧滑退出。时间显示按实际PTS，帧步进不假设30fps；无障碍增减可逐个有效帧移动，报“开始/结束/封面、时间、总长”，最短边界有文字/AX反馈，触觉不是唯一提示。

### 7.2 裁剪交互

原始方向校正后的像素坐标及原有管线顺序保持不变。新Live/Video几何的crop要求`x,y>=0`、右/下边界不超过参考显示矩形、宽高至少2显示像素；无可编码尺寸时解释不支持，不偷偷扩大到不同内容。

- 切比例：保持当前裁剪中心与尽可能接近的面积。令当前面积A、新显示比例r，候选w=sqrt(A*r)、h=sqrt(A/r)，等比缩小至源显示矩形内，再将中心夹到合法范围；最终映射回固定原坐标，不从上次取整结果反复计算。
- 90°旋转/镜像：裁剪原坐标不变，显示变换改变；固定比例按输出方向显示，90°时交换显示宽高/比例，不自动丢选区。连续四转/两次同轴镜像回到完全相同存储矩形。
- 用户单独更换16:9/9:16时才按新比例重算；原图比较与撤销保存完整几何。
- 源裁剪矩形不为编码器强行取偶数。H.264 yuv420p输出尺寸按比例选不大于目标/原有效尺寸的偶数像素，差异通过统一resampling生成，不改源crop；UI与服务端使用同一输出尺寸计算。输出任一边<2时拒绝成品导出并保留草稿。

### 7.3 页面布局

本批沿用SF字体、系统色、已批准编辑工具样式，不创建新视觉品牌。明确cancel/done、播放/静音、当前工具名称与值、时间轴为关键操作；可选细调可滚动，不能遮住关键动作。

- iPhone紧凑/横屏：图片区可缩小，控制区可滚动；完成/取消放在safe-area内固定可达；进度/错误不覆盖时间手柄。
- iPad窄分屏/Stage Manager窗口：按实际可用宽度布局，不按设备名固定列数；宽屏可用侧栏，收窄后复用底部工具，不开两个互相独立的同资产编辑会话。
- 最大辅助字体/长中文、德语：按钮和数值允许换行/独立行，重要文案不只截断；可访问性标签给完整意义。
- RTL：布局与方向图标依系统语义镜像；视频/实况/回忆时间轴**始终时间从左到右递增**，数字用本地格式，开始/结束按时间语义命名；不把倒放效果与RTL混为一谈。
- VO焦点在某控制时不自动隐藏工具栏；退出弹层回原触发控件，关闭编辑回到同资产；切音乐/效果只做必要状态播报，不每帧朗读。触点/键盘/指针具有同等可达的命名操作。
- 增加对比度/减少透明度使用系统不透明材质；加载/失败/选中不只靠颜色；首版第四批不新增自定义触觉，保留系统组件现有反馈，不承诺模拟器证明触觉。

## 8. 回忆播放、构图与操作对象

### 8.1 播放时间线

使用单一`PlaybackSession`与`playbackGeneration`。进入下一项过渡前检查下一surface与对应音轨准备；不足时**从边界起立即冻结media clock、进度、音乐和原声，保持最后有效画面**。3秒只是显示“重试/本次跳过/全部照片”的阈值，不是允许音乐先走3秒。中途视频stall同样冻结整条时钟。

若过渡已开始才发生资源错误，固定最近有效的合成画面，不能淡到黑。重试成功后从冻结时间继续，保持音乐/画面同步；连续seek、前后切换、改节奏和离开页面均递增generation，晚结果不得恢复旧播放或旧音频。

“本次跳过”只更新内存播放路径`temporarySkippedItemIDs`，项目manifest不变。进入导出前明确提示“本次跳过未修改回忆；导出仍包含这些素材”，用户可以明确进入项目编辑排除后再导出，不能静默忽略。片段暂时跳过后当前会话时钟用临时路径重算，保存项目/重开仍以原manifest为准。

点“全部照片”暂停并保存session时间/临时跳过/静音，返回时恢复同位置且保持暂停，只有用户再点播放才继续。播放过程中单击显隐不改变项目参数。

### 8.2 项目构图

首版继续提供contain与显式fill/crop。每个item增加`framingV1`，归一化矩形定义在固定snapshot显示坐标内，不修改源asset crop：

```text
framingV1 = { rect:{x,y,width,height}, focalPoint:{x,y} }
  各值有限、0...1，rect严格位于图像内；contain使用完整矩形。
```

用户在“调整画面”页选择填充、拖动/缩放构图、原画面比较和撤销；fill默认居中但必须预览被裁部分。项目画幅改变时按第7.2节保持焦点/面积后夹取，所有item重新预览并在确认后一次提交项目修订。视频与Live motion使用对应snapshot显示尺寸，预览和导出读取同一framing。

### 8.3 音量和删除对象

播放器speaker是本次观看静音；不改manifest的音乐选择/原声轨道，也不决定导出有无声音。导出确认页显示“音乐/原声/最终有声或无声”；要导出静音必须显式选择输出音轨。耳机断开/音频中断暂停，不自动外放。

操作命名分开：“收藏/移除此回忆集合”（旧Memory）、“保存影片项目到云端”（纯remote项目）、“离线保留影片”（本机固定文件）、“导出视频”（新成品）、“删除影片项目”（项目与引用）、“移除离线下载”（本机文件）。任何一个都不等于删除原照片。移除项目文件导致不再offlineReady时立即更新状态，不仍显示“可离线”。

## 9. 旅程手动创建、合并、拆分

首版保留原设计承诺，补完整操作，不缩减为只能固定自动建议。

- 手动创建：选择至少1个可访问逻辑素材，确认来源/标题/成员；不要求GPS。本机或混合成员只建本机固定集合；云端固定集合仅可包含当前账号有权引用的remote成员，不自动上传。
- 新建使用client-generated objectID＋幂等键；用户成员顺序可保存。普通自动旅程建议仍遵循6项/24小时等阈值，手动集合不假称算法证明旅行。
- 合并：保留用户指定集合顺序，各集合内稳定顺序去重logicalID，生成新固定对象；事务标记旧集合由新对象替代并隐藏原建议，不删原资产；失败不出现只隐藏一半的情况。
- 拆分：用户明确选择互斥且并集等于原成员的分组，每组非空，生成新固定对象并记录parent；用户想排除素材应先做成员编辑，不能让拆分暗中丢项。更新原对象的replacedBy lineage，默认隐藏旧建议。
- 本机与服务端使用同样谱系语义。云端合并/拆分要求每个输入ETag，原子检查全部版本、成员权限和目标来源；失败412保留选择，重新拉取再确认；重试不重复创建。
- 算法重建不重新推荐已被同成员替代的原建议；允许用户在管理页恢复原集合的显示，不产生源素材写操作。

## 10. 动效规格与图片交接

复用前三批interruptible viewer/period转场，只定义本批扩展的图片交接和工具状态；不另造第二个打开引擎。动效需要UI、loader与surface共同满足，不是只调整duration。

| 场景 | 默认规则 | 中断/Reduced Motion |
|---|---|---|
| 正常首屏/缓存命中/滚回 | 无逐格动画，无stagger，无shimmer；图像一次绑定到正确布局 | Reduce Motion相同；不能因禁动画才隐藏慢加载 |
| thumbnail→preview→高清 | 同照片原位置替换，无尺寸/裁剪跳变；静止时可用≤80ms整体过渡，滚动/缩放/转场时不额外fade | 就绪之前保留旧真实surface；新revision时按语义检查；Reduced Motion直接换 |
| 打开/关闭照片 | 复用现有共享图片几何，图片资源锁定到本次presentation；不等网络才响应 | 保持可逆/可中断；Reduced Motion≤100ms淡变或直接切换 |
| 按住播放/松手 | poster持续到首视频帧ready；松手立即暂停，回poster交接≤80ms；相同容器不闪底色 | 第二指/翻页取消token，回调只可收尾当前generation |
| 播放时新render到达 | 锁住本次poster+motion revision；普通更新到静止/下一次播放边界一起换 | 权限/源删除立即停止；不能以“等静止”延后安全失效 |
| 工具切换/undo/redo | 控制状态150–200ms ease-out；数值与预览属于同一intentRevision | 可快速连续操作，最新意图赢；Reduced Motion直接更新，撤销不播大缩放 |
| 完成返回viewer | 有新prepared preview就连续交接；没有则不等待网络/全片渲染，保持上次合法surface并明确新编辑待生成，正式render晚到不闪回 | 取消始终返回旧committedDisplay；源不全只存blockedSource草稿；无合法图像明确不可用，不展示他人/旧资产 |
| 回忆切换 | 200ms crossfade只在双方ready时运行，时间由manifest决定 | stall冻结合成画面/整条时钟；Reduced Motion直接切换，**用同样时长表保持总长与音乐一致** |
| 云端进度/异常 | 内联状态可150ms显隐；不让整图随进度重布局 | VO焦点所在控件不消失；终态一次呈现，旧completion不可覆盖新状态 |

Reduce Motion只改视觉效果，不改变片长、拍点、导出内容或用户已选素材。普通观看音量、编辑mute、音乐manifest和render状态分别管理。

## 11. G5：建议验收指标（不是实测结果）

参考硬件沿用验收矩阵建议iPhone16/A18、iOS26系列，再补当前系统设备。每种情况单独至少30次，报告p50/p95、最大值、失败率、图像区域逐帧检查；OS首启/首次解锁另列，不能把进程重启称作完全冷系统启动。

| 指标 | 目标与测试前提 |
|---|---|
| 进程仍在的前台恢复 | scene active至可交互完整W0，p95≤150ms；首个图库内容帧W0真图覆盖100% |
| 进程重启、完整持久包可读 | 进程启动至可交互完整W0，p95≤800ms；首个图库内容帧覆盖100%，其后2秒无逐格补图/占位/重新洗牌 |
| 用户点图标到可操作 | 另用系统launch指标＋UI交互测量，参考p95≤1.5秒；不得仅报告app自定起点后的800ms |
| 首次空缓存在线 | 单独在50Mbps/RTT30ms参考网络，首个真实缩略图p95≤700ms、W0完整p95≤1.5秒（从首批授权请求可开始计，另报登录至内容总耗时）；坏网络独立记录，不能承诺同值 |
| 已预取内容普通滚动 | 10秒、每秒1屏往返，W0中可访问且已有合格预览的项目每个实际显示帧真实图片覆盖100%；无占位入屏，接触图像目标尺寸满足网格 |
| 未缓存远程fling | 无网络无法保证全屏真图；停稳后在参考网络W0齐图p95≤500ms；无浪费全尺寸下载、无旧图串位，无逐格淡入 |
| 打开/返回已显示照片 | 首个viewer/网格帧是真实对应图，**0空白过渡帧**；触摸至转场响应p95≤100ms；高清升级不清空surface |
| 可见请求排队 | 本地prepared预览P0的调度等待p95≤16ms；正在不可取消worker工作不超过一项既有执行周期后应获下一执行机会；记录实际等待，不用Nuke priority名称代替结果 |
| UI流畅度 | 在参考60Hz真机上，滚动/打开/工具切换每个采样区间持续卡顿>100ms为0；使用Animation Hitches记录总hitch time ratio目标<1%；不能以录屏FPS宣称120Hz |
| 资源上限 | 网络4/解码2为起始预算；普通32MiB首屏包从现有磁盘预算内划分；4K编辑与影片仍满足原P03/P05目标，不能靠无限内存换命中 |

100%覆盖只适用于“已验证scope且持有合格可用预览”的定义场景，必须同时报告缓存缺失率、checkpoint miss、真实首帧时间和异常场景，不能故意剔除常见失败使指标变好。首次无缓存、失权限、缺资源单独放行恢复行为；普通复访常出现占位则G5失败，不能借异常定义逃避。

## 12. 本机接口与落点（提案）

```text
LaunchPreviewStore (actor)
  checkpoint(snapshot: LaunchViewportSnapshot, images: [PreparedImageRecord]) async throws -> LaunchPackReceipt
  restore(scope: StableMediaScope, context: LaunchContext) async throws -> LaunchPackReadResult

MediaPresentationCoordinator
  prepareViewport(request: ViewportRequest) async throws -> PreparedViewport
  presentation(for key: MediaDisplayKeyV1, access: MediaAccessGeneration) -> PreparedImage?

ThumbnailDemandScheduler
  acquire(key: MediaDisplayKeyV1, priority: DemandPriority, consumerID: UUID) async throws -> PreparedImage
  release(key: MediaDisplayKeyV1, consumerID: UUID) async

EditorSessionState
  close(action: cancel | complete | discardDraft | stopFutureSync) async throws -> EditorCloseResult

MoviePlaybackSession
  handle(event: MoviePlaybackEvent) -> [MoviePlaybackCommand]
  state包含clockTime、generation、viewerMuted、temporarySkippedItemIDs、readiness与frozenComposite
```

`StableMediaScope`为已验证server/account（本机另带installation），`LaunchViewportSnapshot`为明确source/filter/sort/anchor/layout/W0及revision集合；`PreparedImageRecord`带DisplayKey、编码文件摘要及真实像素；`LaunchPackReadResult=complete|partial(missingKeys)|invalid(reason)|notAvailable`；`PreparedViewport`带同generation的可显示图像，不把metadata当图；`DemandPriority=P0|P1|P2`。`LaunchPackReceipt`只证明预览包落盘，不是备份proof。

建议新增`N:Imora/Core/Images/LaunchPreviewStore.swift`、`MediaDisplayIdentity.swift`、`MediaPresentationCoordinator.swift`，扩展现有`ThumbnailLoadLimiter.swift`为优先调度，不重写网络层。按实际最终代码接入RootScene/TimelineModel、RemoteImage/LocalPhotoImage、ThumbnailPrefetcher、viewer bridge/registry和精选集各入口。所有迁移/开关都在后续独立工作区，当前仅写本规划目录。
