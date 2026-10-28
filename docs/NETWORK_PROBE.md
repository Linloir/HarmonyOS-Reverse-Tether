# 网络质量探测与后台控制

0.2.0 默认在已经运行的 `VpnExtensionAbility` 内探测，通过现有 VPN 测量 UDP 往返时间与丢包率。不会启动 Ability、切换前台、启停 VPN 或在失败时改用手机自身网络。未连接、未配对或客户端版本过旧时返回明确错误。

## 配对与调用

首次需在手机同意当前隐私政策、授权并启动 VPN。控制令牌由电脑生成并保存在仅所有者可读的文件中；显式启动命令可以一并传入令牌。对于已有 VPN，可以显式配对一次，保持 VPN 连接：

```bash
python3 scripts/harmony-tether.py pair --serial YOUR_DEVICE_SERIAL \
  --token-file /private/revtether.token
python3 scripts/network-probe.py --serial YOUR_DEVICE_SERIAL \
  --token-file /private/revtether.token \
  --stun stun.cloudflare.com:3478 --stun '[2001:db8::1]:3478'
```

示例 IPv6 为文档地址，实际使用须换成可达的 STUN 服务。支持 1–4 个 IPv4、IPv6 或域名目标；IPv6 带端口时使用方括号。没有内置服务器、定时探测或自动前台配对。每个目标发送 5 个 STUN Binding 请求，调用方应串行请求同一设备。

`--hdc`、`--hdc-server` 和 `--bundle` 指定 HDC 程序、已有 server 和 App 包名。显式 server 使用 `-p`，不自行创建 HDC server；`--forward-host` 指定 HDC 本地转发绑定的地址。脚本只清理自己创建且仍匹配的精确转发，不强停 App。

## 后台协议

VPN 扩展在 `127.0.0.1:41420` 提供 HTTP 服务。经 `hdc fport tcp:LOCAL_PORT tcp:41420` 访问。`GET /v1/status` 返回不含令牌及应用列表的最小状态；所有其他请求需要 `Authorization: Bearer TOKEN`。服务只接受有界请求，不提供浏览器跨域授权，也不发重定向。令牌不应写入日志、共享目录或发布包。

| 方法与路径 | 行为 |
| --- | --- |
| `GET /v1/status` | 当前状态、协议版本、会话、实际 IPv6 策略和流量计数 |
| `POST /v1/probe` | 接受 UUID 和服务器列表；202 表示已接受，相同 UUID 在60秒结果缓存内幂等 |
| `GET /v1/probe/UUID` | 202 处理中，200 已完成，404 未找到或已过期 |
| `POST /v1/configure` | 接受 UUID 以及可选 `port` / `dns`，返回202后串行应用；不支持远程改应用名单 |
| `POST /v1/stop` | 接受 UUID，返回202后停止当前 VPN 扩展 |

400 表示参数无效，401 表示未配对或令牌不匹配，409 表示忙碌或 VPN 不可用，503 表示请求处理失败。configure / stop 返回202只证明请求已接受，后续执行结果必须通过状态核验；不能将202视为配置完成或已停止。自动恢复不通过前台界面规避这些失败。

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

后台域名解析使用与本应用 TUN 接口及地址匹配的 VPN `NetHandle`，找不到时返回 `vpn_dns_unavailable`，不使用默认网络解析。测试设备 的底层 Wi-Fi 只有 IPv4 时，系统默认解析接口可能不查询 AAAA；本应用的显式 VPN 解析已在 IPv6 DNS 服务和 IPv6-only 域名上验证，但这不改变其他应用使用系统默认解析器的行为。

请求间隔100ms，最后一包发送后最多等待800ms，不重传同一个事务；RTT使用单调时钟。回复匹配源地址、源端口、消息类型、magic cookie、事务ID和长度，重复回复不重复计数。结果只反映本次到指定服务器的可达性，不代表带宽、所有网站的延迟或长期丢包率。

## 显式兼容模式

```bash
python3 scripts/network-probe.py --serial YOUR_DEVICE_SERIAL --foreground \
  --stun stun.cloudflare.com:3478
```

只有显式 `--foreground` 才调用旧 `ProbeAbility`。该模式不要求已有 VPN，也不能证明流量经过 VPN，系统可能显示启动窗口；不得用于承诺“不改变前台”的自动诊断。结果服务在手机回环端口41418，旧0.1.2为31418，由脚本按版本选择。仍要求同意隐私政策，完成后只结束探测组件，不停止整个 App。

数据处理见[隐私政策](PRIVACY.md)，恢复与 IPv6 的传输细节见[协议说明](PROTOCOL.md)。
