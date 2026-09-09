# 网络质量探测接口

这个接口用于从 HarmonyOS 应用进程中测量当前网络的 UDP 往返时间和丢包率。它不显示在主界面中，也不依赖 VPN：未启用 USB 网络时使用设备当前的系统网络；启用 USB 网络时使用系统路由选择的路径。调用不会启停 VPN。

## 调用

设备安装支持 `ProbeAbility` 的 App，并授权 HDC 后，可以使用配套脚本：

```bash
python3 scripts/network-probe.py --serial YOUR_DEVICE_SERIAL \
  --stun stun.cloudflare.com:3478 --stun stun.l.google.com:19302
```

服务器必须由调用方提供。支持 1–4 个 IPv4 地址或域名及端口，每个目标发送 5 个 STUN Binding 请求。没有内置服务器或定时探测任务。

脚本通过系统接口启动独立的 `ProbeAbility`，传入 JSON 请求；不启动 `EntryAbility` 或 VPN。该组件不加载应用页面，会请求短时后台执行并在完成后结束。冷启动时系统可能短暂显示应用启动窗口，具体取决于系统版本。即使 App 进程已退出、VPN 从未授权，也可以单独调用这个组件。

```json
{
  "request_id": "8d754f6d-bd11-4bcc-80d6-ef41a7ed90b8",
  "servers": [
    {"host": "stun.cloudflare.com", "port": 3478},
    {"host": "stun.l.google.com", "port": 19302}
  ]
}
```

底层调用为 `hdc -t SERIAL shell aa start -b com.linloir.hrevtether -a ProbeAbility --ps request 'JSON'`。JSON 应作为一个经过正确 shell 引号处理的参数发送；每次调用生成新的随机 UUID。

App 0.1.3 起，设备只在 `127.0.0.1:41418` 上提供结果。使用 `hdc fport tcp:LOCAL_PORT tcp:41418` 后，读取 `GET /v1/probe/REQUEST_ID`：处理中返回 HTTP 202，完成返回 HTTP 200；未知或过期 ID 返回 HTTP 404。0.1.2 使用 `31418`，配套脚本会根据已安装应用的 `versionCode` 自动选择。结果读取需要与启动时相同的请求 ID，不应将该 ID 发布或记录到共享日志。

HDC 的 `-e` 选项可能将电脑端转发绑定到指定网卡地址；此时脚本使用 `--forward-host ADDRESS` 指定该地址。`--hdc`、`--hdc-server` 和 `--bundle` 分别指定 HDC 可执行文件、已有 HDC server 和派生 App 包名。该脚本需要 Python 3，不依赖电脑端 relay。

## 结果与边界

```json
{
  "request_id": "8d754f6d-bd11-4bcc-80d6-ef41a7ed90b8",
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

以上为格式示例。实际 `results` 包含每个请求目标的独立 `value` 或 `error`；顶层 `value` 选择列表中第一个有回复的完整测量，不混合不同服务器的样本。如果完成的测量都没有回复，返回其中第一个完整测量：`received=0`、`packet_loss_percent=100`、`median_rtt_ms=null`。

域名解析失败、接口不可用、后台执行被系统拒绝、超时或本地套接字错误不会伪装成完整丢包样本。所有目标均发生执行错误时返回顶层 `error`，不提供 `value`。本接口不自动转为 HTTPS 测量。

请求间隔为 100 ms，最后一包发送后最多再等待 800 ms，不对同一个事务重传；RTT 使用系统单调时钟。回复必须匹配源地址、源端口、STUN 类型、magic cookie、事务 ID 和消息长度；重复回复不重复计数。结果仅反映测量期间到指定服务器的可达性，不能直接视为带宽、所有网站延迟或整条网络的长期丢包率。

调用方应串行请求同一设备。设备探测总时限为 16.5 秒，启动与结果保留的生命周期最多 20 秒；电脑端应设置略长的整体期限，并在结束时移除本次创建的精确转发。不要强制停止整个 App 进行清理，这会影响同时运行的 VPN。

数据处理说明见[隐私政策](PRIVACY.md)。
