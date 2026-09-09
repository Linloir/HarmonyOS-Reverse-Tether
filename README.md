# Harmony Reverse Tether

通过 USB 让 HarmonyOS 设备使用所连接电脑的互联网连接。

本项目提供 HarmonyOS VPN 客户端和电脑端的 Rust 转发服务，使用 HDC 传输数据，无需在设备或电脑上取得 root 权限。用途与 [gnirehtet](https://github.com/Genymobile/gnirehtet) 类似，面向 HarmonyOS 设备。

目前支持 **IPv4 TCP、UDP 和 DNS**。不支持 IPv6、ICMP/ping 或 IPv4 分片重组。电脑端服务提供 Windows amd64、Linux amd64 和 Linux arm64 版本；Linux 二进制需要 glibc 2.34 或更新版本。

## 组成

- **App**：通过系统 VPN 接口共享网络，显示连接状态和流量，并提供可手动触发的 HTTPS 检查。
- **harmony-relay**：在电脑上转发 TCP/UDP 流量，默认只监听本机回环地址。
- **harmony-tether.py**：通过 HDC 安装 App、建立 USB 转发、启动和停止连接。

```text
设备应用 → VPN → HDC USB → 电脑端 relay → 互联网
```

## 使用条件

- 支持 `VpnExtensionAbility` 的 HarmonyOS 设备；App 最低兼容 API 12。
- 已开启并授权 USB 调试，`hdc list targets` 能列出设备。
- 电脑安装 HDC，并可正常联网；使用配套 Python 工具时还需 Python 3。
- 设备上安装与其兼容、签名有效的 HAP。首次启动需要确认系统 VPN 授权。

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

在设备上允许 VPN 连接。`run` 会保持运行；按 `Ctrl+C` 停止连接并清理该实例创建的转发。USB 连接恢复后，工具会重新建立转发，App 会自动重试连接。

检查设备连接信息或单独请求 App 断开：

```bash
python3 scripts/harmony-tether.py doctor --serial "$SERIAL"
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
| `--hdc-server` | 显式指定 HDC server；省略时沿用 HDC 自身的配置 |
| `--relay` / `HARMONY_RELAY` | 转发服务的可执行文件路径 |
| `--relay-port` | 电脑端服务端口，默认 `31417` |
| `--device-port` | 手机端回环端口，默认 `41417`；自定义端口需要 App 0.1.3 或更新版本 |
| `--dns` | 指定电脑可访问的 IPv4 DNS；Linux 默认读取 `/etc/resolv.conf`，Windows relay 默认读取系统 DNS |
| `--bundle` / `HARMONY_BUNDLE_NAME` | App 包名，默认 `com.linloir.hrevtether` |
| `--state-dir` | 本地运行状态与进程锁目录 |

使用自定义签名包名时，构建 App 和运行控制工具必须使用相同的 `HARMONY_BUNDLE_NAME`。App 从系统上下文读取自身包名，不依赖固定的应用身份。

连接多个设备时，可分别启动一个 `run` 实例，并为每个实例指定不同的 `--relay-port`。

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

在另一个终端中建立转发并启动 App：

```bash
export BUNDLE="com.linloir.hrevtether"
hdc -t "$SERIAL" rport tcp:41417 tcp:31417
hdc -t "$SERIAL" shell aa start -b "$BUNDLE" -a EntryAbility
hdc -t "$SERIAL" shell aa start -b "$BUNDLE" -a EntryAbility --ps command start
```

停止 App 并移除该转发：

```bash
hdc -t "$SERIAL" shell aa start -b "$BUNDLE" -a EntryAbility --ps command stop
hdc -t "$SERIAL" fport rm tcp:41417 tcp:31417
```

VPN 内部地址为 `10.0.0.2/32`，MTU 为 1500。默认虚拟 DNS `10.0.0.3` 由 relay 转发到电脑配置的 DNS；这些是协议内部地址。更换电脑的 DNS 后，重新启动 relay 以读取配置。

## 开发与验证

[测试说明](docs/TESTING.md)包含单元测试、USB 通道检查、实际应用联网和连接恢复的验证方法。[发布说明](docs/BUILD_AND_SIGN.md#发布源码)介绍源码打包和应用身份配置。

独立的[网络质量探测接口](docs/NETWORK_PROBE.md)支持由调用方提供 STUN 服务器列表，返回设备当前网络的 RTT、丢包率及各目标结果。该功能不在主界面显示，调用时不需要启用 VPN。

[隐私政策](https://linloir.github.io/HarmonyOS-Reverse-Tether/privacy/)说明网络转发、日志及诊断请求的数据处理方式；也可阅读[仓库中的政策文本](docs/PRIVACY.md)。

## 许可与来源

作者：linloir。

采用 [Apache License 2.0](LICENSE)。转发核心基于 [Genymobile gnirehtet](https://github.com/Genymobile/gnirehtet)，相关署名和修改说明见 [NOTICE](NOTICE)。
