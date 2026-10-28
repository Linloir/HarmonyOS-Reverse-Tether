# 开发与测试

## 本地测试

转发服务单元测试：

```bash
cargo test --locked --manifest-path relay/Cargo.toml
```

原生转发线程测试使用 ASan/UBSan，覆盖数据边界、拆包、异常输入、会话重启和停止：

```bash
./scripts/test-native.sh
```

控制工具和构建配置测试：

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
```

STUN 数据包及测量结果的边界验证，使用 HarmonyOS SDK 自带的 ArkTS 编译器：

```bash
HARMONY_CLT_HOME=/path/to/command-line-tools node scripts/test-probe.cjs
HARMONY_CLT_HOME=/path/to/command-line-tools node scripts/test-privacy.cjs
HARMONY_CLT_HOME=/path/to/command-line-tools node scripts/test-client.cjs
HARMONY_CLT_HOME=/path/to/command-line-tools node scripts/test-application-catalog.cjs
python3 scripts/build-site.py --check
```

默认后台探测应在真机验证配对/未配对、VPN开启/关闭、无回复目标、DNS错误、会话中断以及精确转发清理。关闭 VPN 时必须明确失败且不拉起任何 Ability；开启时验证 TUN 收发、同一会话和前台窗口不变。显式 `--foreground` 兼容模式另行测试，不得替代后台验收。不要将 HDC 请求成功等同于互联网请求成功。

## 隐私与界面

在没有当前政策同意记录的设备上，确认首次启动弹窗能打开离线全文，返回后仍能作出选择。“暂不同意”后应可浏览全部关于内容，但连接、手动 HTTPS 检查、HDC 启动命令及独立探测都不得开始网络处理。同意本身不启动网络；重启后应保留当前政策选择，清除应用数据后则重新提示。

检查主页和关于之间的导航、各详情页返回、底部内容滚动以及外部链接打开失败时的反馈。底部页签、标题栏和详情页返回应使用系统原生样式并避让安全区；首页仅保留连接状态、流量和操作，说明内容从关于进入。系统大字体或较窄窗口下，隐私选择按钮和导航仍需可操作。

## 应用名单

- 手动添加、移除、重复包名、无效包名、数量上限和自身应用排除。
- 添加方式和 USB 列表分别以原生底部卡片打开；完成按钮固定在下方、提示文字在其上，键盘出现时仍可操作，关闭后返回上一层。
- 打开设置或 USB 说明页不产生读取请求。只有点击读取才调用宿主机；退出取消，迟到回复被拒绝，45 秒超时结束等待。
- 分别检查未连接、超时、读取失败和不支持的提示，以及名称/包名搜索、仅看已选、多选、刷新与取消。读取应用列表不得重建 VPN。

## 转发与 USB 通道

无外网依赖的真实 socket 双栈集成测试：

```bash
python3 relay/tests/dual_stack_integration.py --binary ./build/harmony-relay
```

它使用回环 TCP、UDP、STUN、HTTP 和 DNS fixture，检查双向校验和、MSS/MTU、服务器 IPv6 开关以及不同上下游地址族的 A/AAAA 查询。独立的 `relay/tests/network_fixtures.py --serve-fixtures` 可用于真机受控端点验证；测试所需的临时地址由操作者单独配置和清理。

`tests/packet_probe.cpp` 和 `tests/relay_integration.py` 可以检查握手、异常客户端隔离、DNS 和 HTTP。先编译探测程序并运行 relay：

```bash
mkdir -p build
g++ -std=c++17 -pthread -I app/entry/src/main/cpp \
  tests/packet_probe.cpp app/entry/src/main/cpp/tunnel.cpp -o build/packet-probe
./build/harmony-relay
```

在另一个终端执行：

```bash
python3 tests/relay_integration.py --probe ./build/packet-probe
```

可以使用 `--host`、`--port` 将探测程序连接到单独准备的 HDC 测试通道。该测试需要能访问 `example.com` 的 DNS 和 HTTP，不能代替手机应用通过 VPN 联网的验证。

`tests/browser_usb_server.py` 是单独的浏览器通道检查工具。页面请求到达服务端后，由服务端发起 HTTPS 请求；它只证明该通道可达。

## 设备应用联网

1. 安装与设备和包名匹配的签名 HAP，在设备上阅读并同意隐私政策，启动 `harmony-tether.py run` 并完成系统 VPN 授权。
2. 保存设备的 Wi-Fi/蜂窝状态。关闭其他联网通道，确认设备确实只能通过 USB 使用网络。
3. 在 App 中执行 HTTPS 检查，并用独立的浏览器打开新的 HTTPS 页面。确认 VPN、转发映射和电脑端 relay 的连接及流量同时变化。
4. 停止 VPN 后重新发起联网请求，应失败；重新连接后，新请求应恢复。
5. 完成测试后恢复原有网络设置。

## 双向数据完整性

电脑上运行临时测试服务，选择设备经 VPN 能访问的监听地址：

```bash
python3 tests/browser_transfer_server.py --bind "$TEST_BIND_ADDRESS"
```

用手机浏览器打开工具输出的随机路径。页面下载 8 MiB，逐字节校验后上传 1 MiB，再由服务端逐字节校验。页面和服务端均应报告成功。默认监听回环地址；测试结束后停止该服务。

## 连接恢复

- 移除本应用的精确 reverse 映射，确认运行中的控制工具重新建立映射，App 重连后新请求成功。
- 断开并重新连接 USB，确认设备重新授权/可用后恢复供网。
- 终止测试实例拥有的 relay，确认控制工具报告退出；重新运行后验证实际联网。
- 检查停止时不残留该实例创建的转发，其他设备和映射仍可使用。
- 分别验证首次授权、取消授权、重复启停和锁屏场景。
- relay 重启和精确 reverse 丢失时，记录 VPN 进程、TUN 接口及会话变化：传输会话可更新，健康 OS VPN/TUN 应保留。server IPv6 策略改变要求重建 TUN 时单独记录。
- Pi-register 重启应接管已有 VPN，不先发送 stop；错误路径使用退避，未配对不偷偷打开前台。
- 验证手机 IPv6 默认关闭，inherit 跟随手机开关，server on/off 覆盖手机开关；没有 IPv6 外网时只声明已验证的受控端点路径。
- 对全局、白名单、黑名单分别用一个纳入和一个绕过的真实应用验证路由；RevTether 后台诊断始终走 VPN。保存后核查实际状态及设置持久化。

保持测试记录最小化：描述版本、测试条件和结果即可。原始设备标识、网络拓扑、签名资料和未处理截图应保存在开发者自己的测试目录中。
