# 手机原生应用列表验证（2026-10-28）

目标是让普通个人开发者签名的 RevTether 在手机本地提供应用名称、包名和图标。USB 不能作为原生读取的证据。

## 真机与签名

在 测试设备 的 HUAWEI ADY-AL10 / HarmonyOS 6.0.1.115 上，以现有开发身份构建隔离探测包，声明普通 `ohos.permission.GET_BUNDLE_INFO`。开发与发布 Profile 均为 `normal` / `hos_normal_app`，ACL 为空。账号由用户确认为个人开发者账号。

| 调用 | 结果 |
| --- | --- |
| `bundle.queryAbilityByWant`，两种 HOME action，flags 0 / 4，当前用户 100 | 四组均为空数组 |
| 旧 `bundle.getAllBundleInfo(0)` | 空数组 |
| `bundleManager.getBundleInfoSync` 查询自身 | 成功 |
| 同接口查询已安装浏览器 | 错误码 201 |
| `launcherBundleManager.getLauncherAbilityInfoSync` 查询自身/浏览器 | 均为错误码 201（拒绝权限） |
| 旧 `getAbilityLabel` / `getAbilityIcon` 查询自身/浏览器 | 均拒绝，旧接口错误值为数字 1 |

这证明当前签名、SDK 与设备组合不能实现全量选择器；不能把空数组当成手机没有应用。探测完成后已移除探测包和临时权限声明。

API 18 / 20 的公开 `bundleManager` 未暴露全量枚举函数。API 18 的 `launcherBundleManager.getLauncherAbilityInfoSync` 要求 `GET_BUNDLE_INFO_PRIVILEGED`，且需要事先知道包名。SDK 权限定义中 `GET_BUNDLE_INFO_PRIVILEGED`、`GET_INSTALLED_BUNDLE_LIST` 为 system_basic，普通 `GET_BUNDLE_INFO` 为 normal。申请受限权限和获得系统 API 访问能力是不同前提，不能通过更换开发/发布签名或手机一次普通授权自动取得。

## 官方资料与适用边界

- [华为全量应用信息 FAQ](https://developer.huawei.com/consumer/en/doc/harmonyos-faqs-V14/faqs-ability-45-V14)：2025-03-11 版本明确查询其他应用的系统应用限制，并列出全量查询所需的 system_basic 权限。这是 API 14 FAQ，不能据此推导所有未来 API 或个人账号审批结果。
- [申请调试 Profile](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/agc-help-debug-profile-0000002248181278)：2026-10-13 文档明确先获得 ACL，再将已获权限加入 Profile；ACL 改动后需重新创建 Profile。
- [华为 2025-12 开发者月刊](https://developer.huawei.com/consumer/cn/monthly/202512)：说明 AGC 项目设置的 ACL 申请入口与部分试用能力；不证明上述两个权限向个人账号开放或属于可试用范围。

未查到足够权威的当前资料证明上述应用列表权限可以授予普通个人 VPN 应用。也没有登录该账号确认其实际可申请列表，因此不宣称“所有个人账号永远无法申请”。若将来继续原生方案，需由账号持有者在 AGC 确认具体权限及 VPN 分流场景是否开放；获批后提供更新的 Profile 即可继续验证，可复用现有证书和私钥，无需提供密码。当前按用户选择实施不依赖该审批的两种添加方式。

## 维护中的 VPN 应用参考

[ClashBox 的分享接收代码](https://github.com/xiaobaigroup/ClashBox/blob/master/entry/src/main/ets/entryability/EntryAbility.ets)调用 `systemShare.getSharedData`，从应用市场分享链接解析包名，并读取分享记录的 title / thumbnail。[访问控制页面](https://github.com/xiaobaigroup/ClashBox/blob/master/entry/src/main/ets/components/More/AccessControl/AccessControl.ets)维护本地记录并提供手动输入。其名称和缩略图不构成全量枚举权限可用的证据。

另一个开源 VPN 的 HOME Want 查询样例使用 flags 4；本次已在 测试设备 对这组参数实测，仍为空，未直接采用其静态测试所声称的可用性。

## 本轮实现

黑白名单逐项添加、移除；默认手动输入一个包名。可选 USB 入口提供连接说明，仅在明确开始读取后通过已授权 HDC 获取名称和包名。请求可取消并在 45 秒过期，不后台常驻枚举，不把旧缓存当作新读取结果，不因导入失败变更 VPN。当前 `bm dump -a -l` 不提供真实应用图标；界面使用明确的通用应用标识，状态页提供 USB / 提示图标。
