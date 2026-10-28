# RevTether · Harmony Reverse Tether

通过 USB 让 HarmonyOS 设备使用所连接电脑的互联网连接。

本项目提供 HarmonyOS VPN 客户端和电脑端的 Rust 转发服务，使用 HDC 传输数据，无需在设备或电脑上取得 root 权限。用途与 [gnirehtet](https://github.com/Genymobile/gnirehtet) 类似，面向 HarmonyOS 设备。

当前客户端版本为 0.2.1，relay 版本为 0.2.0，支持 **IPv4 / IPv6 TCP、UDP 和 DNS**。手机端 IPv6 默认关闭，可在设置中开启；电脑端可强制开启或关闭，优先于手机设置。IPv6 仍要求电脑有可用的 IPv6 网络。不支持 ICMP/ping 或 IP 分片重组，详细边界见[传输协议](docs/PROTOCOL.md)。电脑端服务提供 Windows amd64、Linux amd64 和 Linux arm64 版本；Linux 二进制需要 glibc 2.34 或更新版本。

## 组成

- **App**：主页提供 VPN 连接控制、状态、流量与手动 HTTPS 检查；设置页提供 IPv6 和应用白名单/黑名单；关于页提供离线指南和完整隐私政策。
- **harmony-relay**：在电脑上转发 TCP/UDP 流量，默认只监听本机回环地址。
- **harmony-tether.py**：通过 HDC 安装 App、建立 USB 转发、启动和停止连接。

```text
设备应用 → VPN → HDC USB → 电脑端 relay → 互联网
```

## 使用条件

- 支持 `VpnExtensionAbility` 的 HarmonyOS 设备；App 最低兼容 API 12。
- 已开启并授权 USB 调试，`hdc list targets` 能列出设备。
- 电脑安装 HDC，并可正常联网；使用配套 Python 工具时还需 Python 3。
- 设备上安装与其兼容、签名有效的 HAP。首次启动需阅读隐私政策并作出选择，首次连接还需确认系统 VPN 授权。

服务程序和客户端源码均包含在本仓库中。构建与签名步骤见 [BUILD_AND_SIGN.md](docs/BUILD_AND_SIGN.md)。

## 快速开始（Linux）

下载与电脑架构对应的发布压缩包，解压后可直接运行 `harmony-relay`。Windows 使用下面的[手动运行](#手动运行)步骤；`harmony-tether.py` 的进程管理目前面向 Linux。

在项目目录中构建电脑端服务：

```bash
./scripts/build-relay.sh
```

脚本默认构建当前电脑的架构，输出 `build/harmony-relay`。预编译的服务程序也可以放在 `bin/harmony-relay`，或使用 `--relay` 指定。

查看已连接设备，选择它的 USB 序列号：

```bash
hdc list targets
export SERIAL="YOUR_DEVICE_SERIAL"
```

安装已签名的 App，然后启动连接：

```bash
python3 scripts/harmony-tether.py install --serial "$SERIAL" \
  --hap /path/to/harmony-reverse-tether-signed.hap
python3 scripts/harmony-tether.py run --serial "$SERIAL"
```

首次使用先在设备上打开 RevTether，阅读并同意隐私政策。电脑发来的启动请求同样受隐私检查约束；同意政策后，请在主页点击“连接”或从电脑重新启动，再允许系统 VPN 请求。选择“暂不同意”仍可阅读内置指南和关于内容。

`run` 会保持运行；USB 连接恢复后先修复转发，保留已经运行的 VPN。只有初次明确启动时可以打开 App 完成授权，后续自动恢复不拉前台。按 `Ctrl+C` 清理该实例创建的精确转发，并尝试通过已配对的后台接口停止由该实例启动的 VPN；接管的既有 VPN 不主动停止。

检查设备连接信息或单独请求 App 断开：

```bash
python3 scripts/harmony-tether.py doctor --serial "$SERIAL"
python3 scripts/harmony-tether.py status --serial "$SERIAL"
python3 scripts/harmony-tether.py stop --serial "$SERIAL"
```

App 的“已连接”表示 VPN 和转发服务已连接。可点击“检查互联网连接”确认当前网络能否访问互联网。

## 配置

HDC 默认从 `PATH` 查找。可以用 `HDC` 环境变量或 `--hdc` 指定其他可执行文件：

```bash
HDC=/path/to/hdc python3 scripts/harmony-tether.py run --serial "$SERIAL"
```

| 参数 / 环境变量 | 用途 |
| --- | --- |
| `--hdc-server` | 显式指定已有 HDC server，并使用 `-p` 避免自动启动另一个 server；省略时沿用 HDC 自身的配置 |
| `--relay` / `HARMONY_RELAY` | 转发服务的可执行文件路径 |
| `--relay-port` | 电脑端服务端口，默认 `31417` |
| `--device-port` | 手机端回环端口，默认 `41417`；自定义端口需要 App 0.1.3 或更新版本 |
| `--dns` | 指定电脑可访问的 IPv4/IPv6 DNS，可带端口；Linux 默认读取 `/etc/resolv.conf`，Windows relay 默认读取系统 DNS |
| `--ipv6 inherit\|off\|on` | 默认 `inherit`，沿用手机开关；`off` / `on` 强制覆盖手机设置 |
| `--token-file` | 本机私有控制凭据，文件须仅限所有者读取；用于后台诊断、配置和停止 |
| `--bundle` / `HARMONY_BUNDLE_NAME` | App 包名，默认 `com.linloir.hrevtether` |
| `--state-dir` | 本地运行状态与进程锁目录 |

使用自定义签名包名时，构建 App 和运行控制工具必须使用相同的 `HARMONY_BUNDLE_NAME`。App 从系统上下文读取自身包名，不依赖固定的应用身份。

连接多个设备时，可分别启动一个 `run` 实例，并为每个实例指定不同的 `--relay-port`。

设置页默认“全局”。“白名单”只让名单中的应用经过 VPN，“黑名单”让名单中的应用绕过 VPN。应用按条目管理，可逐个添加包名，也可在“添加应用 → 从 USB 应用列表添加”中主动读取和多选。当前普通签名无法直接枚举手机全部应用，USB 读取由用户明确发起。绕过的应用使用手机本身的网络；RevTether 自身始终经过 VPN，保证后台网络诊断的路径可验证。保存运行中的配置会重建 VPN 以应用系统规则。

既有 VPN 无需为接管而停止。首次启用后台诊断时，可显式配对一次：

```bash
python3 scripts/harmony-tether.py pair --serial "$SERIAL" --token-file /private/revtether.token
python3 scripts/network-probe.py --serial "$SERIAL" --token-file /private/revtether.token \
  --stun stun.cloudflare.com:3478
```

`pair` 会打开 RevTether 保存控制凭据，保留 VPN；之后的后台探测不会打开页面。自动恢复不会代替用户进行这个前台配对步骤。控制凭据不是 VPN 授权凭据，不可放入日志或发布包。

## 可选 USB 添加应用

不使用 USB 读取时，逐个输入包名即可设置黑白名单；不申请应用列表受限权限。USB 读取需要 USB 调试授权、新版宿主机工具和已建立的 RevTether 供网连接。手机端选择“添加应用 → 从 USB 应用列表添加”，阅读连接说明后点击“读取应用列表”。新版 `harmony-tether.py run` 或 Pi-register 会处理这一条明确请求；不会在启动、普通设置浏览或手动添加时读取整机列表。也可以在手机开始读取后手动执行：

```bash
python3 scripts/harmony-tether.py sync-apps --serial <USB序列号>
```

使用自定义配对文件或 HDC 服务时，沿用 `--token-file`、`--hdc-server`、`--forward-host` 参数。请求在 45 秒后过期，退出选择页立即取消。失败、旧响应及取消不会改变名单或 VPN；完成选择后仍需保存设置。名称和包名仅在设备与授权电脑之间处理，列表保存在手机，不上传云端。当前 HDC 列表不含真实应用图标，界面使用统一应用标识。

[手机原生接口验证与权限说明](docs/APPLICATION_CATALOG_RESEARCH.md)记录了真机结果、官方文档和权限限制。

## 手动运行

也可分别管理服务和客户端：

```bash
./build/harmony-relay --port 31417
```

Windows 在 PowerShell 中进入解压目录，执行 `./harmony-relay.exe --port 31417`。保持服务运行，在另一个终端执行以下 HDC 命令，将 `SERIAL` 替换成 `hdc list targets` 显示的设备连接标识：

```text
hdc -t SERIAL rport tcp:41417 tcp:31417
hdc -t SERIAL shell aa start -b com.linloir.hrevtether -a EntryAbility
```

在 App 中点击“连接”并允许系统 VPN 请求。结束时在 App 中断开，执行 `hdc -t SERIAL fport rm tcp:41417 tcp:31417`，然后关闭服务终端。HDC 与已签名 App 需另行准备，服务压缩包不包含 HDC。

App 0.1.3 起，手机端默认端口为 `41417`，电脑端仍为 `31417`。旧版 App 的手机端端口为 `31417`。某些系统版本无法监听部分端口；需要更换手机端端口时，使用 `--device-port`，或在启动 `EntryAbility` 时传入 `--ps port PORT`，并建立对应的反向转发。App 会记住最近使用的手机端端口，供界面重新连接时使用。

VPN 内部 IPv4 地址为 `10.0.0.2/32`，MTU 为 1500。启用 IPv6 后增加 `fd00:7265:7674::2/128`；虚拟 DNS 分别为 `10.0.0.3` 和 `fd00:7265:7674::3`，由 relay 转发到电脑配置的 DNS。更换电脑的 DNS 后，重新启动 relay 以读取配置。

## 开发与验证

[0.2.1 更新说明](docs/releases/v0.2.1.md)汇总本次变化和验证范围。[测试说明](docs/TESTING.md)包含单元测试、USB 通道检查、实际应用联网和连接恢复的验证方法。[发布说明](docs/BUILD_AND_SIGN.md#发布源码)介绍源码打包和应用身份配置。

[网络质量探测接口](docs/NETWORK_PROBE.md)默认通过已经建立的 VPN 在后台测量 STUN RTT 和丢包率，并验证 VPN 会话与流量。VPN 未连接、未配对或版本过旧时明确失败，不自动打开页面。旧版独立探测保留为显式 `--foreground` 模式。

后台策略调研和系统边界见[后台运行说明](docs/BACKGROUND_RESEARCH.md)。USB 通道中断与 VPN 被系统回收是两种不同故障，恢复应根据实际状态处理；后台能力不能承诺绕过系统强制停止或资源管理。

0.1.4 起，VPN、手动联网检查和外部网络探测都要求设备使用者已同意当前版本隐私政策；旧版本没有同意记录，升级后也需先在手机上完成选择。未同意时不会启动这些网络功能。内置政策与政策网页均从 `docs/PRIVACY.md` 生成，修改后运行 `python3 scripts/build-site.py`，并用 `--check` 验证同步。

[隐私政策](https://linloir.github.io/HarmonyOS-Reverse-Tether/privacy/)说明网络转发、日志及诊断请求的数据处理方式；也可阅读[仓库中的政策文本](docs/PRIVACY.md)。

## 许可与来源

作者：linloir。

采用 [Apache License 2.0](LICENSE)。转发核心基于 [Genymobile gnirehtet](https://github.com/Genymobile/gnirehtet)，相关署名和修改说明见 [NOTICE](NOTICE)。
