# 构建与签名

## 工具链

App 使用 HarmonyOS Command Line Tools、商业 HarmonyOS SDK API 18 Release 构建，最低兼容 API 12。已验证的工具链版本是 [Command Line Tools 5.1.0.840 Linux x64](https://repo.huaweicloud.com/harmonyos/ohpm/5.1.0/commandline-tools-linux-x64-5.1.0.840.zip)，配套 SDK 为 `5.1.0.125`。下载后可对照[官方 SHA-256](https://repo.huaweicloud.com/harmonyos/ohpm/5.1.0/commandline-tools-linux-x64-5.1.0.840.zip.sha256)校验。

电脑端 relay 使用 Rust stable 和 Cargo。App 构建脚本还需要 Python 3。

## 构建 App

```bash
export HARMONY_CLT_HOME=/path/to/command-line-tools
./scripts/build-app.sh
```

默认输出为 `build/harmony-reverse-tether-unsigned.hap`。构建在临时目录中完成，不改写源码中的应用身份，也不复用其他包名的构建状态。

默认包名是 `com.linloir.hrevtether`，构建派生应用时应使用开发者注册并获签名 Profile 授权的包名：

```bash
export HARMONY_BUNDLE_NAME=org.example.usbtether
./scripts/build-app.sh --output build/custom-unsigned.hap
```

也可使用 `--bundle-name` 显式指定。相同的包名应传给电脑端控制工具的 `--bundle`，或通过上述环境变量共享。App 内部的 VPN 启停使用运行时包名。

## 构建电脑端服务

默认构建当前电脑的架构：

```bash
./scripts/build-relay.sh
```

输出为 `build/harmony-relay`，并保留 `build/<target>/harmony-relay`。脚本会映射编译路径，避免将源码目录和 Cargo 缓存的本地绝对路径带入程序。交叉编译 Linux ARM64 时，需要安装对应的 Rust target 和 C 链接器：

```bash
rustup target add aarch64-unknown-linux-gnu
./scripts/build-relay.sh aarch64-unknown-linux-gnu
```

交叉编译产物只写入对应的 target 目录。可通过 `CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER` 指定链接器。

## 应用签名

安装到商业 HarmonyOS 设备时，HAP 必须使用设备信任的应用证书和有效 Profile。包名、证书及 Profile 必须匹配；调试 Profile 还需包含设备 UDID。USB connect key 与 UDID 是不同标识。参见[华为应用签名文档](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing)。

准备自己的 PKCS12 私钥、应用证书链和 Profile。CSR 是证书申请文件，不能替代已签发的证书。PKCS#7 格式的证书链可转换为 PEM：

```bash
openssl pkcs7 -in /path/to/app-certificate.cer -print_certs \
  -out /path/to/app-certificate-chain.pem
```

如果输入是 DER 格式，增加 `-inform DER`。签名工具需要完整应用证书链，单独的叶证书可能不足以签名。

创建仅保存在本地的 `signing.local.json`：

```json
{
  "keystore": "/path/to/app.p12",
  "alias": "application",
  "passwordFile": "/path/to/private/password",
  "certificate": "/path/to/app-certificate-chain.pem",
  "profile": "/path/to/app-profile.p7b"
}
```

将密码存放在权限为 `0600` 的文件中，并将该目录权限设为 `0700`。密钥、证书、Profile 和本地签名配置均不应进入源码包。

```bash
python3 scripts/sign-hap.py \
  --config /path/to/signing.local.json \
  --tool "$HARMONY_CLT_HOME/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar" \
  --input build/harmony-reverse-tether-unsigned.hap \
  --output build/harmony-reverse-tether-signed.hap
```

脚本执行 `sign-app`、`verify-app` 和 native codesign 验证，成功后原子替换输出 HAP，并打印 SHA-256。本地验签通过后，仍需在目标设备上验证安装和运行。

如需生成新的密钥和 CSR：

```bash
python3 scripts/prepare-signing.py /path/to/private/signing \
  --bundle org.example.usbtether \
  --subject 'CN=USB Tether Developer'
```

该工具拒绝覆盖已有密钥。根据申请到的证书、Profile 和实际 alias 更新本地签名配置。调试 Profile 用于获授权的开发设备；商店发布应使用相应的发布身份和 Profile。

## 发布源码

从已经提交、检查过的版本导出源码：

```bash
mkdir -p build
git archive --format=tar --prefix=harmony-reverse-tether/ HEAD \
  | gzip -n > build/harmony-reverse-tether-source.tar.gz
```

归档只包含当前提交的文件，不包含 Git 历史、未跟踪的文件或被忽略的构建与签名资料。解压后可直接构建；如需建立新的公开仓库，可以在解压目录中初始化 Git。

## 实现参考

- [HarmonyOS VPN API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-net-vpnextension)
- [OpenHarmony VPN 开发指南](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/network/net-vpnExtension.md)
- [HDC 文档](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hdc)
