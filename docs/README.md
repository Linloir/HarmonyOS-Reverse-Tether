# RevTether 文档

当前文档对应客户端 **0.2.1（versionCode 7）**、relay **0.2.0** 和同一源码提交中的 Python 工具。最后核对日期：2026-10-28。

## 使用与接口

| 文档 | 内容 |
| --- | --- |
| [项目 README](../README.md) | 安装、连接、IPv6 策略、应用名单、可选 USB 导入、配对与停止 |
| [网络质量探测与后台控制](NETWORK_PROBE.md) | 后台 STUN、鉴权、配置、应用列表接口与显式前台兼容模式 |
| [传输协议](PROTOCOL.md) | IPv6 协商、DNS、数据包边界及应用列表传输约定 |
| [构建与签名](BUILD_AND_SIGN.md) | SDK、三平台 relay、开发与 release 签名、产物与源码归档 |
| [测试说明](TESTING.md) | 本地测试、真机分流、后台诊断、USB 列表与恢复验收 |
| [隐私政策](PRIVACY.md) | 实际数据处理与用户选择；生成应用内政策和政策网页的唯一源文件 |

应用“关于”中的离线指南位于 `app/entry/src/main/ets/common/HelpContent.ets`，项目网页位于 `site/index.html`。修改功能说明时需同时核对这两个入口；修改隐私政策后运行 `python3 scripts/build-site.py` 并以 `--check` 检查生成内容。

## 版本与验证边界

- IPv6 和后台控制从客户端 0.2.0 起提供；后台控制状态中的 `protocol_version` 为 `2`，它与隧道握手协议是不同标识。
- 可选 USB 应用选择从客户端 0.2.1 起提供。电脑端须使用对应版本脚本，或已集成该接口的 Pi-register。Pi-register 是独立项目，其部署版本需单独确认。
- 当前 Python `run` 需要支持 `--ipv6` 的 relay 0.2.0。新客户端连接旧 relay 时只使用 IPv4；旧二进制应按手动方式启动。
- SDK 构建配置的最低兼容版本不代表完整的设备测试范围。当前真机测试为 HUAWEI ADY-AL10 / HarmonyOS 6.0.1.115；公网 IPv6、Windows 运行和更早手机系统的完整功能尚未验收。
- 仓库文档描述当前源码。正式包、源代码提交、开发签名真机测试、release 验签和应用市场审核分别记录；版本号相同也不能代替构建来源与 SHA-256 比对。

## 更新与调研记录

- [0.2.1 更新说明](releases/v0.2.1.md)：当前功能与验证范围，包含 0.2.0 的网络和恢复更新。
- [手机原生应用列表验证](APPLICATION_CATALOG_RESEARCH.md)：当前签名的接口实测、权限边界与选用 USB 导入的原因。
- [后台运行调研](BACKGROUND_RESEARCH.md)：注明日期和源码快照的调查，以及当前恢复策略；不承诺绕过系统强制回收。
- [0.1.3](releases/v0.1.3.md)、[0.1.2](releases/v0.1.2.md)：历史发布记录，保留当时的端口、功能与命令，不作为当前使用指南。
