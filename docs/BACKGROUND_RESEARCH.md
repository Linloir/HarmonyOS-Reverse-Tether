# HarmonyOS VPN 后台运行调研与本次取舍

调研快照日期：2026-10-27；RevTether 0.2.1 实现复核：2026-10-28。构建基线为 HarmonyOS API 18；公开 OpenHarmony 接口用于核对能力边界，不代替目标手机固件的实测。以下第三方维护数据描述调研当时，不作为其后续状态的保证。

## 主流实现与维护证据

ClashBox 是本轮找到的较成熟的 HarmonyOS 原生 Mihomo 客户端，GitHub 页面约 4.7k stars、289 forks，有独立发布和问题跟踪。维护规模不能证明某一种固件上的保活效果。[项目主页](https://github.com/xiaobaigroup/ClashBox)

其 README 明确承认后台核心可能被系统关闭，并提供与模拟画中画关联的核心恢复。检查 `master` 分支快照 `e036a6a3097192ff74987ce7306eea2a03d6a3ac`（提交日期 2026-08-15）可见：

- EntryAbility 每秒检查核心活动状态，异常时重新初始化核心并调用 VPN 重启。
- PipManager 使用视频播放类型的画中画模板。
- BackgroundDownService 申请 `dataTransfer`，每 10 秒更新流量通知，示例中的进度值固定为 99.9。

这是源码观察，并非对这些机制可靠性、当前发行版本或应用商店合规性的背书。本次没有复制这些 GPL 实现。[README](https://github.com/xiaobaigroup/ClashBox/blob/main/README.md)、[恢复逻辑](https://github.com/xiaobaigroup/ClashBox/blob/e036a6a3097192ff74987ce7306eea2a03d6a3ac/entry/src/main/ets/entryability/EntryAbility.ets)、[画中画](https://github.com/xiaobaigroup/ClashBox/blob/e036a6a3097192ff74987ce7306eea2a03d6a3ac/entry/src/main/ets/common/utils/PipManager.ets)、[长时任务](https://github.com/xiaobaigroup/ClashBox/blob/e036a6a3097192ff74987ce7306eea2a03d6a3ac/entry/src/main/ets/common/utils/BackgroundDownService.ets)

ClashOH 声称使用长时任务和实况窗，最低 API 21；查询时仅约 3 stars、12 commits，不足以称为广泛维护、验证充分的替代基线。没有将其“退后台锁屏不受影响”的 README 陈述当作平台保证。[项目与说明](https://github.com/tom-cat-mao/clash-OpenHarmony)

## 官方能力边界

Stage 模型长时任务由 UIAbility 申请，要求实际业务与申请类型一致。`dataTransfer` 面向实际上传下载，需要更新真实进度及实况窗；手机 `taskKeeping` 从 API 21 起还需要受限的 `KEEP_BACKGROUND_RUNNING_SYSTEM` ACL。不能仅为常驻而伪装音频、定位、下载进度或视频画中画。[官方长时任务文档](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/task-management/continuous-task.md)

公开 VPN API 提供 IPv6 地址/路由、`trustedApplications` 和 `blockedApplications`（二者互斥；当前 API 18 每份列表最多 64 个）。Always-on VPN 设置属于系统权限接口，不能作为普通开发签名应用的通用能力。`protect()` 让指定 socket 绕过 VPN，因此只能用于连接宿主机的隧道 socket，不能用于测量实际 VPN 网络的探测 socket。[VPN 接口定义](https://github.com/openharmony/interface_sdk-js/blob/master/api/%40ohos.net.vpnExtension.d.ts)

VpnExtensionAbility 公开生命周期仅包含 `onCreate` / `onDestroy`，没有可依赖的 `onRequest` 重配入口。API 18 TCPSocketServer 也没有公开 close 方法；控制监听器按 VPN 进程单实例复用，停止后拒绝请求，由进程退出释放端口。[生命周期接口](https://github.com/openharmony/interface_sdk-js/blob/master/api/%40ohos.app.ability.VpnExtensionAbility.d.ts)、[Socket API](https://github.com/openharmony/interface_sdk-js/blob/master/api/%40ohos.net.socket.d.ts)

## RevTether 当前实现（0.2.0 引入，0.2.1 延续）

本次采用专用 VpnExtensionAbility 承载隧道、状态与诊断。后台探测不再启动 ProbeAbility：HDC 转发到仅监听 loopback 的 41420 控制端口，持有配对令牌的控制端请求 STUN 测量。探测 socket 绑定 VPN 地址、不调用 protect；RevTether 自身始终包含在应用路由内。返回 VPN 连接 epoch 和探测期间 TUN 收发增量；会话变化或无发送增量时不声明测量成功。令牌在应用沙箱保存，每次请求重读，显式配对可更新它而不停止 VPN。

公开状态接口不返回令牌或应用包名名单。修改配置、停止、发起探测、读取探测结果及 0.2.1 的应用列表同步均需 Bearer token，且有请求大小、连接数、探测并发和时间限制。EntryAbility 原有宿主机命令入口仍可被能启动该导出 Ability 的调用者访问；此 token 不是对该入口另加的一层应用身份认证，不能声称它隔绝了所有本机其他应用。

恢复分层处理：宿主机优先修复 HDC 转发并接管现有服务；手机 relay socket 断开时保留仍有效的 OS VPN/TUN，仅替换传输 socket。配置变化、新服务器 IPv6 策略要求改变 TUN 或 TUN 失效时需要重建；显式停止则销毁 VPN。客户端连接和清理由单个异步队列串行执行，代际标记阻止旧 connect 回调创建晚到的 VPN；重试间隔从 1 秒倍增至最多 30 秒，连续短暂成功不重置退避，稳定 30 秒才重置。传输会话更新不代表 OS VPN/TUN 一定重建；后台探测要求一次测量内传输会话不变。

本次没有添加模拟音频、模拟画中画、模拟定位或虚假下载通知。专用 VPN 扩展和恢复改进降低可避免的断连，不承诺抵御系统强制回收、用户强停或权限撤销。若需要更强的平台保活，应以华为正式适用的 VPN 后台运行能力/受限权限审批为前提，再对目标固件做长时锁屏验证。

## IPv6 路由兼容性复核

测试设备首轮验证中，IPv4 访问成功而 IPv6 受控 ULA 目标没有进入隧道，因此继续核对实际路由配置，不能仅凭 `effectiveIpv6=true` 声明 IPv6 可用。Hey 项目记录了高度匹配的真机案例：`::/0` 的 gateway 写成 `::` 且 `isDefaultRoute=true` 时，系统没有正确安装 IPv6 路由；其修复使用空 gateway 和 `isDefaultRoute=false`。x4h 的原始配置也采用这一写法。本次只针对 IPv6 路由调整这两个字段，保留目标 `::/0`、family=2 和 IPv4 原配置，测试设备（ADY-AL10，OHOS 6.0.1.115，API 18 构建）已验证：宿主机强制 IPv6 开启、手机开关关闭时，同一既有 VPN 会话内 IPv4 与 IPv6 ULA STUN 各收到 5/5 个回复，后台探测保持浏览器前台不变；旧路由配置下相同 IPv6 请求失败。此次证据覆盖受控 ULA 双栈路径，尚未验证公网 IPv6。[Hey 的真机排查记录](https://github.com/popsiclelmlm/Hey/blob/main/docs/ipv6-leak-prevention.md)、[x4h 的配置源文件](https://github.com/arror/x4h/blob/master/entry/src/main/ets/manager/vpn/VpnConfigManager.ets)

官方 OpenHarmony 5.1 VPN NAPI 源码明确把 family=1/2 分别定义为 IPv4/IPv6，IPv6 前缀允许到128；没有将 socket 的 POSIX AF_INET6=10 填入 ArkTS VPN 配置。探测新增仅含阶段、地址族、系统错误码及已发送数的错误日志，以区分 bind/send/receive 失败，不记录凭据或目的地址。[VPN 配置解析源码](https://github.com/openharmony/communication_netmanager_ext/blob/OpenHarmony-5.1.0-Release/frameworks/js/napi/vpnext/src/context/setup_context_ext.cpp)

## IPv6 域名解析边界

测试设备追加测试使用受控 IPv6 DNS 服务器：IPv4 域名解析与 STUN 成功，IPv6 字面地址 STUN 也成功，但仅有 AAAA 记录的域名失败。DNS 查询日志显示，旧后台探测和浏览器均只发送 A 查询，即使这些 DNS 请求本身已通过 VPN 发往 IPv6 DNS 服务器。因此不能把 IPv6 DNS 服务器可达等同于系统会请求 AAAA。

公开 OpenHarmony 5.1 源码提供了与现象一致的解释：全局 `connection.getAddressesByName()` 使用 netId=0；musl 查询 `IsIpv6Enable(netId)`，该标志为假时不查询 AAAA，强制原生 `AF_INET6` 也不能绕过。netId=0 的 IPv6 能力判断取默认物理网络，而 DNS 服务器选择另行按 UID 匹配 VPN。显式指定 VPN netId 时，能力标志和 DNS 服务器才取同一个 VPN 网络；VPN 的 IPv6 路由成功安装会开启相应标志。这是基于公开源码对目标固件现象的解释，并非该商业固件源码的逐行验证。[全局解析实现](https://github.com/openharmony/communication_netmanager_base/blob/OpenHarmony-5.1.0-Release/frameworks/js/napi/connection/connection_exec/src/connection_exec.cpp)、[AAAA 查询条件](https://github.com/openharmony/third_party_musl/blob/OpenHarmony-5.1.0-Release/src/network/lookup_name.c)、[网络能力缓存](https://github.com/openharmony/communication_netmanager_base/blob/OpenHarmony-5.1.0-Release/services/netmanagernative/src/netsys/dnsresolv/dns_param_cache.cpp)、[DNS 请求的 netId 选择](https://github.com/openharmony/communication_netmanager_base/blob/OpenHarmony-5.1.0-Release/services/netmanagernative/src/netsys/dnsresolv/dns_resolv_listen.cpp)

后台探测现在通过公开 `getAllNets()` / `getConnectionProperties()` 查找接口名和本 TUN 地址均匹配的 VPN，再调用该 `NetHandle.getAddressesByName()`；每轮缓存句柄，发现过程设时限和并发上限，找不到 VPN 明确失败，不回退到物理网络。字面地址不做网络发现，旧前台探测保留默认解析。此次修复仅影响 RevTether 自身探测的解析选择；其他应用使用默认解析器时仍可能遇到系统的 AAAA 抑制，不能据此保证所有应用在 IPv4 物理网络下可解析仅有 AAAA 的域名。[公开网络接口](https://github.com/openharmony/communication_netmanager_base/blob/OpenHarmony-5.1.0-Release/interfaces/kits/js/%40ohos.net.connection.d.ts)

修复后，测试设备上的开发签名包已在同一既有 VPN 会话内完成 `revtether4.test` 和仅有 AAAA 的 `revtether6.test` 后台 STUN 测试，两者均收到 5/5 个回复；TUN 收发增量为 952/1252 字节。受控 DNS 服务器记录到通过 IPv6 UDP 传输的 AAAA 查询和响应，确认此次成功包含真实 IPv6 域名解析。此结论覆盖 RevTether 自身的后台探测；浏览器等其他应用的默认解析器限制仍保留，公网 IPv6 尚未验证。
