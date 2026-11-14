# Immich 3.4.1 隔离集成验证

日期：2026-11-14（Asia/Shanghai）。本报告只描述官方服务端接口回归，不代表 iOS 客户端、PhotoKit 或真机验收已经通过。

## 实际结果

最终记录：[机器可读结果](2026-11-14-immich-341-fixture-results.json)。UTC 开始时间 `2026-11-13T20:32:11Z`，运行 ID `3ff9010343724508abd41803a035bd4e`。16 个检查全部通过。目的地址固定为 `http://127.0.0.1:32283/api`；没有使用生产地址、生产凭据、生产照片或生产数据卷。

| 检查 | 实测结果 |
| --- | --- |
| 合成 JPEG/MOV 的 Apple content ID | 镜像内 ExifTool 从两个文件读出相同 UUID |
| 新 JPEG 上传 | `created` |
| 重传及 bulk-upload-check 查重 | 返回原 asset ID、`duplicate`，非回收站 |
| 官方校验头 | `x-immich-checksum` 即使请求体不是上传表单也立即返回 duplicate；同样输入改用 `x-imora-checksum` 返回 400 |
| 已有静态图后补 motion，再重传静态图带关联参数 | 返回 duplicate，静态图关联仍为空；重传不能作为修复 |
| 显式 PUT 及 GET 回读 | `still.livePhotoVideoId` 精确等于刚上传的视频 ID；owner、IMAGE/VIDEO、非回收站、非 offline 均一致，motion 为 hidden |
| JPEG 原件读回 | `/original?edited=false`，HTTP 200；302 字节，SHA1 `9dce2fb180984e45ea4fe7043b3114001ac8fb6d` |
| MOV 原件读回 | 同一原件接口，HTTP 200；1974 字节，SHA1 `32a7683ac1493600de2052e97f3b3df546351cd7` |
| 异步自动配对 | 匹配 Apple content ID 的静态图与视频在 0.532 秒观察等待后精确关联，motion 被正常隐藏 |
| 缺少 asset.update | 只有 asset.read/asset.download 的专用 API key 能读取，但 PUT 返回 403 |
| 视频属于另一个 fixture 账号 | 关联被拒绝；原有正确关联保持不变 |
| 回收站副本 | 详情与查重均明确 isTrashed=true，不能当作当前安全备份 |
| 恢复 | fixture restore 后 isTrashed=false |
| 永久删除 | fixture 详情不再可读，查重返回 accept，表示需要重新上传 |
| 数据库校验和正常但原件损坏 | 人为把本轮新建合成 JPEG 改成 26 字节；详情 checksum 和 isOffline=false 不变，原件读回 SHA1 不匹配 |
| 数据库 online 但原件文件缺失 | 仅移除该合成文件时原件接口返回 404；finally 恢复保存的字节，并再次核对 SHA1 |

原件流式读回同时比较 SHA1 与实际字节数，未把数据库校验和当成磁盘完整性证据。所有可变资产均由本轮脚本创建；损坏测试在修改前校验其 owner、原始 checksum 和专用 upload 路径。没有直接修改数据库。

## 镜像和来源

- Immich API 返回 `3.4.1`，featureLevel=2。
- 服务器 OCI source revision：`22b95194c80a2f2e6201093916b6c8c3d6d271dd`，与已审查 3.4.1 源码一致。
- 官方服务器镜像 index digest：`sha256:7c489add298fc2f92cda4c777de6462aa206877e04087b815f62c7664af0b53b`；compose 已固定该摘要及 `linux/amd64`。
- 实际容器 ImageManifestDescriptor 为 amd64 manifest `sha256:4351dd621899ecc8ed317ae87cdcaeb968ec8ba4f9d8053d913a73eb6f6dd7c2`；按 `--platform linux/amd64` 检查 image.Architecture=amd64，容器 `uname -m` 为 x86_64。宿主 Docker VM 为 aarch64。没有依据默认 tag inspect 的原生平台结果误报实际架构。
- PostgreSQL：`ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23`。
- Redis 兼容服务：`docker.io/valkey/valkey:9@sha256:418652cfb58ef879d4978c33553735d7147016032d5aefaa14c828e611eb9dfd`。
- 服务配置关闭 ML、地图、反向地理编码及版本检查。该配置通过 docker cp 放入专用容器，没有宿主目录绑定；这不等于网络防火墙。

## Docker 启动问题及可复现方式

初始阶段数据库和 Redis 正常，但 Immich 容器长期为 Created、PID 0、State.Error 为空；同镜像的 `/bin/true` 探针也挂起。原生 arm64、amd64、移除宿主 config 绑定、tmpfs `/data`、较旧 API 版本均未解决普通代理入口的启动阻塞。

进一步检查 Docker Desktop 4.65.0 本地日志发现：宿主 backend 已记录 `ContainerStartComposeLinux`，但 VM API 日志没有对应的 `POST /containers/.../start`，只有卷查询；因此证据指向 Docker Desktop 宿主代理的启动前路径，而非 Immich 进程错误。尚未确定该代理内部的最终根因。

直接通过同一 Docker Desktop 的本地 engine Unix socket 启动专用容器立即成功：

```sh
/usr/local/bin/docker -H unix://${HOME}/Library/Containers/com.docker.docker/Data/docker.raw.sock start imora-341-fixture-server-1
```

没有重启 Docker、修改全局设置或操作其他项目。专用服务随后完成迁移并返回 3.4.1。常规 socket 的失败不应被报告为“本机无法运行 3.4.1”。原始诊断日志来自只读路径 `${HOME}/Library/Containers/com.docker.docker/Data/log/host/com.docker.backend.log` 与 `log/vm/init.log`，本报告只保留相关结论，未复制包含其他项目状态的完整日志。

从仓库根目录复现：

```sh
IMORA_FIXTURE_RAW_SOCKET=1 python3 tests/integration/fixture.py start
IMORA_FIXTURE_RAW_SOCKET=1 python3 tests/integration/fixture.py run --report docs/validation/2026-11-14-immich-341-fixture-results.json
```

详细边界、依赖、停止专用服务的方法见 [fixture README](../../tests/integration/README.md)。当前最终测试使用已启动的专用容器，未因 compose 摘要固定这一等价配置修改而重新创建服务器。`start` 支持以后重新创建并复制配置。

## 为 iOS 测试准备的独立 fixture

另建了独立的 iOS 专用账号和未关联 JPEG/MOV，未复用上面 Python 回归的资产 ID。私有凭据清单在 `/private/tmp/imora-341-ios-fixture.json`，实测权限为 `0600`，未写入仓库、未打印密码或令牌。清单包含本地 API URL、账号及新生成的密码、owner/两个 asset ID、hex SHA1、字节数及源媒体绝对路径。可通过以下命令新建一组：

```sh
IMORA_FIXTURE_RAW_SOCKET=1 python3 tests/integration/fixture.py ios-fixture
```

iOS 客户端测试结果应由执行该测试的主实施记录另行报告。本子任务没有运行 Xcode，也没有修改 Swift 或产品文件。

## 保留限制

- Python 回归证明官方服务端契约；不证明 iOS 客户端真的调用了这些接口或执行了全部清理门禁。
- 自动配对的 0.532 秒是本轮观察时间，不能作为固定延迟或调度保证。
- 合成 MOV 包含配对 content identifier，但没有 Apple still-image-time 元数据轨；尚未验证 PhotoKit 对这些媒体的导入或导出。
- `GET-null → PUT → GET` 在 3.4.1 没有条件更新保证，不是原子事务；另一客户端仍可能在读写之间改变关联。
- 未用此 fixture 证明 iCloud、大视频、锁屏、系统终止、网络切换、系统 Photos 删除提示、分享扩展或后台上传的真机行为。
- 专用服务保持运行供主实施使用。历史失败或重复运行留下的账号/媒体均为合成 fixture，局限在专用卷内。
