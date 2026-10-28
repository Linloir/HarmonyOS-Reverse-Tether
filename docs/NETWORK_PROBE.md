# 网络质量探测与后台控制

本文对应客户端 0.2.1 和当前配套脚本。自客户端 0.2.0 起，默认在已经运行的 `VpnExtensionAbility` 内探测，通过现有 VPN 测量 UDP 往返时间与丢包率。不会启动 Ability、切换前台、启停 VPN 或在失败时改用手机自身网络。未连接、未配对或客户端版本过旧时返回明确错误。

## 配对与调用

首次需在手机同意当前隐私政策、授权并启动 VPN。控制令牌由电脑生成并保存在私有文件中，POSIX 系统要求文件权限仅限所有者；显式启动命令可以一并传入令牌。对于已有 VPN，可以显式配对一次，保持 VPN 连接：

```bash
python3 scripts/harmony-tether.py pair --serial YOUR_DEVICE_SERIAL \
  --token-file /private/revtether.token
python3 scripts/network-probe.py --serial YOUR_DEVICE_SERIAL \
  --token-file /private/revtether.token \
  --stun stun.cloudflare.com:3478
```

`pair` 会打开 App 保存令牌；后续后台探测不会打开页面。`network-probe.py` 的后台模式必须显式提供 `--token-file`，不会自动寻找默认文件。若 `run` / `pair` 未指定文件，应传入其默认的 `~/.local/state/harmony-reverse-tether/<包名>-<USB序列号>.token`；使用自定义 `--state-dir` 时路径相应变化。所有控制工具须使用同一配对文件。

支持 1–4 个 IPv4、IPv6 或域名目标；IPv6 带端口时使用方括号，例如 `--stun '[2001:db8::1]:3478'`（文档地址，须替换为可达的 STUN 服务）。没有内置服务器、定时探测或自动前台配对。每个目标发送 5 个 STUN Binding 请求，调用方应串行请求同一设备；脚本总调用预算为 25 秒。

`--hdc`、`--hdc-server` 和 `--bundle` 指定 HDC 程序、已有 server 和 App 包名。显式 server 使用 `-p`，不自行创建 HDC server；`--forward-host` 指定访问 HDC 转发的地址，不改变其监听配置。脚本只清理自己创建且仍匹配的精确转发，不强停 App。

## 后台协议

VPN 扩展在 `127.0.0.1:41420` 提供 HTTP 服务。经 `hdc -t SERIAL fport tcp:LOCAL_PORT tcp:41420` 访问。`GET /v1/status` 返回不含令牌及应用列表的最小状态；所有其他请求需要 `Authorization: Bearer TOKEN`，令牌为 32–128 位十六进制字符。扩展未运行时接口不可用；读状态或探测不会启动扩展。服务不提供浏览器跨域授权，也不发重定向。令牌不应写入日志、共享目录或发布包。

请求采用 HTTP/1.1；POST 需 `Content-Type: application/json` 和准确的 `Content-Length`，不支持 chunked 编码。非 ASCII 字符需以 JSON Unicode 转义传输。最多 4 个并发连接，接收请求时限 3 秒，头部小于 8 KiB，普通请求体最多 4 KiB；只有应用列表提交允许 128 KiB。

| 方法与路径 | 行为 |
| --- | --- |
| `GET /v1/status` | 当前状态、`protocol_version=2`、`vpnSession`、`effectiveIpv6` / `ipv6Policy`、`txBytes` / `rxBytes` 等；无需令牌 |
| `POST /v1/probe` | 接受 UUID 和服务器列表；202 表示已接受，相同 UUID 在60秒结果缓存内幂等 |
| `GET /v1/probe/UUID` | 202 处理中，200 已完成，404 未找到或已过期 |
| `POST /v1/configure` | 接受 UUID 以及 `port` / `dns` / `reloadSettings`，返回202后串行应用；不接受远程应用名单 |
| `POST /v1/stop` | 接受 UUID，返回202后停止当前 VPN 扩展 |
| `GET /v1/applications/request` | 0.2.1 起提供；返回手机主动创建且仍有效的请求标识，无请求时为 `0` |
| `POST /v1/applications` | 0.2.1 起提供；提交对应请求的名称/包名列表或错误，200 表示已保存读取结果，不表示已应用分流规则 |

400 表示参数无效，401 表示未配对或令牌不匹配，409 表示忙碌或 VPN 不可用，503 表示请求处理失败。configure / stop 返回202只证明请求已接受，后续执行结果必须通过状态核验；不能将202视为配置完成或已停止。自动恢复不通过前台界面规避这些失败。

`configure` 至少包含 `port`、`dns` 或 `reloadSettings: true` 中的一项。`port` 为手机端回环端口（1024–65535）；`dns` 仅接受单个 IPv4/IPv6 字面地址，空字符串恢复虚拟 DNS，不接受域名或自定义端口。这与 **relay / harmony-tether.py 的 `--dns`** 不同，后者配置电脑端上游解析器，支持自定义端口。`reloadSettings: true` 重新读取手机已保存的设置，不允许调用方提交应用名单。端口、DNS 和设置 revision 均未变化时不重建 VPN；有变化时短暂重建以应用配置。

`vpnSession` 是传输会话标识，USB 重连时即使保留 OS VPN/TUN 也会更新。它不等于 OS VPN 被销毁重建的次数。探测回复使用 `vpn_session` 字段返回同一标识。

探测请求：

```json
{
  "request_id": "8d754f6d-bd11-4bcc-80d6-ef41a7ed90b8",
  "servers": [{"host": "stun.cloudflare.com", "port": 3478}]
}
```

成功结果示例：

```json
{
  "request_id": "8d754f6d-bd11-4bcc-80d6-ef41a7ed90b8",
  "path": "vpn",
  "vpn_session": 1793085000000,
  "tx_bytes_delta": 240,
  "rx_bytes_delta": 400,
  "value": {
    "protocol": "stun_binding_v1",
    "median_rtt_ms": 12.5,
    "packet_loss_percent": 0,
    "sent": 5,
    "received": 5,
    "rtts_ms": [12, 13, 12.5, 14, 11],
    "host": "stun.cloudflare.com",
    "port": 3478
  },
  "results": []
}
```

实际 `results` 包含各目标的独立测量或错误；顶层 `value` 选择第一个有回复的完整测量，不混合不同服务器样本。探测 socket 绑定 VPN 地址，RevTether 自身始终包含在 VPN 应用规则内。调用方验证请求 UUID、`path=vpn`、前后相同的有效 `vpn_session` 及 TUN 发送增量；VPN 会话变化或没有发送流量时拒绝结果。流量增量可能包含同期其他应用的数据，不能作为精确探测字节统计。

全部目标无回复且确实完成发送时，允许返回 `received=0`、`packet_loss_percent=100`、`median_rtt_ms=null`。域名解析、绑定、网络接口、控制鉴权和生命周期错误不能伪装成100%丢包；全部目标执行失败时返回 `error`，不提供 `value`。不自动转 HTTPS，也不回退到旧探测组件。

后台域名解析使用与本应用 TUN 接口及地址匹配的 VPN `NetHandle`，找不到时返回 `vpn_dns_unavailable`，不使用默认网络解析。测试设备的底层 Wi-Fi 只有 IPv4 时，系统默认解析接口可能不查询 AAAA；本应用的显式 VPN 解析已在 IPv6 DNS 服务和 IPv6-only 域名上验证，但这不改变其他应用使用系统默认解析器的行为。

请求间隔100ms，最后一包发送后最多等待800ms，不重传同一个事务；RTT使用单调时钟。回复匹配源地址、源端口、消息类型、magic cookie、事务ID和长度，重复回复不重复计数。结果只反映本次到指定服务器的可达性，不代表带宽、所有网站的延迟或长期丢包率。

## 可选应用列表同步

手机连接 VPN 并在“添加应用 → 从 USB 应用列表添加”中点击“读取应用列表”后，`GET /v1/applications/request` 才会返回非零请求。它是手机生成的毫秒时间戳，不是探测用的 UUID；宿主机与手机时间需同步。请求 45 秒后过期，退出选择页即取消。

当前 `harmony-tether.py run` 定期检查待处理请求，无请求时不枚举应用。也可使用同一配对令牌手动执行 `sync-apps`，具体命令见 [README](../README.md#可选-usb-添加应用)。主机通过 HDC 的 `bm dump -a -l` 获取名称与包名，再提交原请求标识；不返回真实图标。列表请求体格式、大小限制和错误值见[协议说明](PROTOCOL.md#optional-application-catalog-client-021)。过期、取消、已完成或被新请求替换的提交返回409；读取失败和列表导入不会重建 VPN。

## 显式兼容模式

```bash
python3 scripts/network-probe.py --serial YOUR_DEVICE_SERIAL --foreground \
  --stun stun.cloudflare.com:3478
```

只有显式 `--foreground` 才调用旧 `ProbeAbility`。该模式不要求已有 VPN，也不能证明流量经过 VPN，系统可能显示启动窗口；不得用于承诺“不改变前台”的自动诊断。结果服务在手机回环端口41418，旧0.1.2为31418，由脚本按版本选择。仍要求同意隐私政策，完成后只结束探测组件，不停止整个 App。

数据处理见[隐私政策](PRIVACY.md)，恢复与 IPv6 的传输细节见[协议说明](PROTOCOL.md)。
