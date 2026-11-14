# iOS 实施验证记录

最终本机验证于 2026-11-14 05:29:58（Asia/Shanghai）通过。工作位于既有 `codex/imora-backup-zh-hans` 分支，未部署、推送或访问生产服务器。测试只使用本机隔离 Immich 3.4.1、专用模拟器和合成媒体。

## 已取得的证据

- Xcode 27.2、iOS 27.2 arm64 模拟器，主应用及分享扩展均已编译。Nuke 固定为 `9e37a277bdb527bf3ae71156ded1423f495f5168`。
- 最终 `scripts/test-ios.sh -parallel-testing-enabled NO`：**83 项测试，82 项通过、1 项跳过、0 失败**，退出码 0、`TEST SUCCEEDED`。81 项为单元/集成测试，2 项为实际界面流程。跳过项是模拟器不提供的物理文件保护元数据检查。[机器可读 Xcode 汇总](2026-11-14-ios-results.json)。
- 实际 iOS → Immich 3.4.1：3/3，通过真实客户端完成新上传、官方校验头重复短路、实况照片精确关联/双原件回读，以及本地视频准备和 AVFoundation 帧解码。微型合成 MOV 准备约 0.31 秒，仅代表该样本，不能推算大视频首帧或磁盘成本。
- 官方服务端隔离回归：16/16。详见 [3.4.1 fixture 记录](2026-11-14-immich-341-fixture.md)，包括原件损坏/缺失而数据库状态仍正常的故障。
- 真实 PhotoKit：单项定向检查通过，只创建 16 像素合成 JPEG；零/部分/重复匹配均未提交删除，合成资产仍存在。未用此检查声称系统删除确认和成功提交已验收。
- 英文/简体中文资源单元检查已通过；共享资源目录 1,586 个键，加两目标 5 项权限说明，合计 1,591 项。覆盖编译器当前提取的 1,578 个应用/扩展键，占位符、换行和英文回退检查通过。两种语言的登录、照片、设置、隐私、备份页面实际流程及退出均通过，保留 10 张截图。初次退出按钮匹配失败已修复并重跑全套验证。

## 截图与来源

| 页面 | 简体中文 | English |
| --- | --- | --- |
| 登录 | [截图](screenshots/zh-Hans-login.png) | [Screenshot](screenshots/en-login.png) |
| 照片 | [截图](screenshots/zh-Hans-photos.png) | [Screenshot](screenshots/en-photos.png) |
| 设置 | [截图](screenshots/zh-Hans-settings.png) | [Screenshot](screenshots/en-settings.png) |
| 隐私 | [截图](screenshots/zh-Hans-privacy.png) | [Screenshot](screenshots/en-privacy.png) |
| 备份 | [截图](screenshots/zh-Hans-backup.png) | [Screenshot](screenshots/en-backup.png) |

截图只含本机合成账号和媒体；账号名称、邮件、服务器内容按原样显示。已目视检查中文排版及隐私页 Apple 地图/iCloud 两段说明。测试原始 xcresult 位于 `/private/tmp/imora-implementation/DerivedData/Logs/Test/Test-Imora-2026.11.14_05-28-11-+0800.xcresult`；控制台日志 `/private/tmp/imora-final-all.log`。

源码及实际未签名模拟器包的 SHA256 记录由 `scripts/write-validation-manifest.py` 生成，见 [构建来源清单](2026-11-14-build-manifest.json)。此清单不是签名真机或发布包证明。

全分支独立复查发现并修复了：旧请求缓存身份、取消与启动竞争、实时连接失效、清理证据失效、视频缓存生命周期、离线恢复、设备副本删除绕过、分享前台恢复与保留存储、误译 SF Symbol。最终源码复查没有剩余的 Critical/Important 问题；待真机门禁另列。

## 重要行为与边界

Apple 文档说明后台 `URLSession` 会自动跟随重定向且不调用重定向决策委托。因此敏感上传改为进程内受控传输；仅在 iOS 允许进程执行时继续。挂起、终止或强制退出可能暂停，受保护的队列/日志在重新打开后对账并恢复。旧后台会话只取消，不把未知旧任务重新绑定到当前凭据。[Apple 重定向委托文档](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:))。

分享队列不保存令牌，使用完整 API 根地址、凭据指纹和 generation 绑定；跨进程锁序列化撤销、取消与请求启动，单独长租约避免重复 worker。失败文件可保留以便恢复，需在存储界面明确显示和允许丢弃已知记录。

普通“已备份”只表示当次接口状态/校验和/owner/type/实况关联满足条件；不冒充磁盘逐字节完整性证明。保留服务器副本而移除设备副本的操作必须额外读完每个服务器原件，比较 SHA1 和实际长度，并在提交 Photos 前复核当前证据。实况照片必须两部分都通过。此过程增加服务器下载，未知本地资源还可能读取 iCloud，确认界面说明路线、预计大小和取消入口。

视频只以本地文件交给 AVFoundation。活跃消费者持有文件租约；空闲缓存有 1 GiB 预算，正在使用的文件可临时超过预算，释放后回收；启动时清理上次进程遗留目录。清缓存不会中断仍在使用的文件，待释放后删除。大视频需要足够可用磁盘，不能据小样本声称首帧性能已满足真机需求。

实况配对的 GET/PUT/GET 不具备服务端条件更新原子性；核验后到 Photos 系统确认之间也不能与服务器组成原子事务。已观察到的事件会使证据失效；未观察到的后续服务器损坏、恶意服务器和存储冗余属于另外的服务端保护范围。

## 仍需真机或签名环境验收

- App Group/共享钥匙串的真实分享扩展进程、挂起/终止/重开恢复、锁屏及首次解锁的文件保护行为。
- iCloud 原件、实况资源导出、长视频/低空间/蜂窝与 Wi-Fi 切换的成本和恢复。
- Photos 系统删除确认的用户取消、系统失败与实际成功结果；当前真实 PhotoKit 检查只证明不精确集合不会提交删除。
- Apple 地图开关实际网络流量捕获；现有渲染测试证明关闭时不构造地图内容，不能代替真机抓包。

这些项目没有伪记为通过。生产安装与发布应等待相应验收；本次不执行部署。
