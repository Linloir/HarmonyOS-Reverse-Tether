import { PROJECT_URL, RELEASES_URL, DEVELOPER_URL, GNIREHTET_URL, CONTACT_EMAIL } from './Links';

export interface HelpSection {
  title: string;
  body: string;
}

export interface HelpLink {
  title: string;
  url: string;
}

export interface HelpTopic {
  id: string;
  title: string;
  introduction: string;
  sections: HelpSection[];
  links: HelpLink[];
}

export const HELP_TOPICS: HelpTopic[] = [
  {
    id: 'guide', title: '连接指南', introduction: '手机、数据线、能联网的电脑。先完成电脑端准备，再开始第一次连接。',
    sections: [
      { title: '01  准备电脑', body: '确认电脑可以访问所需网络。下载与你的电脑匹配的配套转发服务，按项目说明安装 HDC；Windows x64、Linux x64 和 Linux ARM64 均有电脑端服务。下载压缩包不包含 HDC。' },
      { title: '02  连接并授权 USB', body: '使用支持数据传输的 USB 线连接手机。在手机系统设置中开启开发者选项与 USB 调试，并授权这台电脑。仅支持充电的数据线无法建立连接。' },
      { title: '03  启动配套服务', body: '在电脑上按使用说明启动转发服务，并通过 HDC 建立反向转发。让电脑端服务保持运行。Linux 可以使用配套控制脚本，Windows 可按说明手动运行。' },
      { title: '04  在手机上连接', body: '阅读隐私政策并同意后，回到主页点击“连接”，再确认系统 VPN 请求。首次由电脑启动也需要在手机上完成隐私选择；同意政策本身不会自动开始供网，请点击连接或在电脑上重新发起启动。' },
      { title: '05  验证与结束', body: '显示“已连接”后，查看流量变化并打开目标网页或应用。验证 USB 供网时，可临时关闭手机 WLAN 和移动数据以排除其他网络，验证后恢复自己的设置。使用结束点击“断开”，并按电脑端说明停止服务、清理转发。' }
    ],
    links: [{ title: '打开完整电脑端使用说明', url: PROJECT_URL }]
  },
  {
    id: 'troubleshooting', title: '连接排查', introduction: '按顺序检查，通常可以定位到数据线、电脑服务或系统授权。',
    sections: [
      { title: '电脑没有识别手机', body: '检查数据线是否支持传输、接口是否接触良好，确认 USB 调试已开启，手机上已授权当前电脑。在电脑上运行 hdc list targets 应能列出设备；若不能，先解决 USB 连接问题。' },
      { title: '一直连接中或正在重连', body: '确认电脑端转发服务仍在运行、HDC 反向转发已建立，且手机端端口与电脑工具设置一致。重新插线后需等待电脑工具恢复转发；手动运行时需按说明重新建立。' },
      { title: '系统拒绝 VPN 请求', body: '先断开其他 VPN，再回到主页重试并阅读系统授权提示。设备管理策略也可能限制 VPN 或 USB 调试；受管理的设备请联系管理员。' },
      { title: '已连接，但网页打不开', body: '“已连接”只表示手机与转发服务已接通。请确认电脑自身能访问目标网络，且 DNS、代理、防火墙或网络登录页面没有阻断请求；电脑浏览器能上网也不代表它的浏览器专用代理可供转发服务使用。' },
      { title: '检查成功是否就代表 USB 供网成功', body: '互联网检查使用系统当前选择的网络；WLAN 或移动数据开启时，单次检查不能独立证明流量走了 USB。请结合关闭其他网络后的真实应用访问与主页流量变化判断。' },
      { title: '部分应用不兼容', body: '目前支持 IPv4 TCP、UDP 和 DNS，不支持 IPv6、ICMP/ping 或 IPv4 分片重组。部分应用还可能依赖特定系统联网判断、协议或网络策略。你可以随时断开，并恢复系统的其他网络连接。' }
    ],
    links: [{ title: '在 GitHub 查看或反馈问题', url: PROJECT_URL + '/issues' }]
  },
  {
    id: 'principle', title: '反向供网如何工作', introduction: '把电脑已有的网络连接，通过一根 USB 数据线带到手机。',
    sections: [
      { title: '为什么叫“反向”', body: '常见的 USB 网络共享是手机给电脑供网。反向供网交换了两者的角色：电脑提供网络出口，手机使用它访问互联网或电脑可达的网络。' },
      { title: '系统 VPN 在这里做什么', body: 'RevTether 借助 HarmonyOS 的 VPN 接口接收手机流量，再通过本地 USB 通道交给电脑上的转发服务。这里的 VPN 是系统网络接口，不代表连接了开发者运营的远程 VPN 服务器。' },
      { title: '手机与电脑如何配合', body: 'HDC 是连接手机与电脑的调试工具，它为应用建立 USB 数据通道。电脑上的转发服务负责向目标网络发送请求，并沿同一路径把响应送回手机。只安装手机 App 还不足以完成供网。' },
      { title: '这条连接的边界', body: '网络是否可达取决于电脑的连接、目标服务和系统路由。RevTether 不提供匿名上网，不会解密 HTTPS，也不会为原本未加密的流量额外加密。请只使用并授权可信的电脑。' }
    ], links: []
  },
  {
    id: 'purpose', title: '为什么专注反向供网', introduction: '手机需要网络，而手边已有一台能联网的电脑。我们希望把这一步连接做得清楚、可控。',
    sections: [
      { title: '有网线，暂时没有可用 WLAN', body: '在只有电脑接入有线网络的工作台，或不方便开启热点的环境里，可以用 USB 为手机增加一种网络接入方式。能否使用仍取决于所在网络与设备的管理策略。' },
      { title: '无 SIM 卡的备用机与测试机', body: '备用手机、开发测试机或展示设备可能没有 SIM 卡。复用电脑的网络，可以在不为每台设备准备移动数据连接的情况下完成应用访问与验证。' },
      { title: '开发、调试与设备验证', body: '手机已经通过 USB 接到电脑时，供网可以与调试工作一起进行。关闭无线网络后，还能观察应用在这条网络路径下的行为；这对定位环境差异有实际帮助。' },
      { title: '无线网络暂时不可用时', body: '遇到手机 WLAN 无法连接或信号较弱，而电脑仍有可用网络的情况，USB 可以提供另一条接入路径。它需要电脑持续运行，速度和稳定性也取决于数据线、电脑与网络条件。' },
      { title: '把一个明确需求做好', body: '反向供网的价值在于补足一种具体的连接方式。RevTether 围绕它提供连接控制、状态与流量、手动联网检查、准备指南和故障排查，让用户知道如何连接、如何验证以及如何停止。应用保持无需账户、无广告的使用方式。' }
    ], links: []
  },
  {
    id: 'platforms', title: '其他平台的类似工具', introduction: '反向供网在其他平台也有对应的开源实践。',
    sections: [
      { title: 'Android · gnirehtet', body: 'Genymobile 的 gnirehtet 通过 ADB 让 Android 设备使用所连接电脑的网络，无需手机或电脑 root 权限。它支持以 GNU/Linux、Windows 和 macOS 作为电脑端，处理 IPv4 TCP 与 UDP。' },
      { title: '与 RevTether 的关系', body: 'RevTether 面向 HarmonyOS，使用系统 VPN 接口与 HDC 建立通道；电脑端转发核心基于 gnirehtet 的开源实现并做了适配。两个项目的手机端、调试工具与安装包不能直接混用。' },
      { title: '查看项目的适用范围', body: 'gnirehtet 上游目前注明不再积极维护，仅修复重大阻塞问题。此处用于介绍同类技术实践，不表示双方存在商业合作，也不代表该项目可直接用于 HarmonyOS。平台兼容性与安装步骤请以各项目说明为准。' }
    ], links: [{ title: '查看 gnirehtet 原项目', url: GNIREHTET_URL }]
  },
  {
    id: 'downloads', title: '下载电脑端工具', introduction: '前往项目的 GitHub Releases 页面，按电脑系统与处理器选择发布包。',
    sections: [
      { title: 'Windows x64', body: '选择 Windows amd64 发布包，解压后按说明运行 harmony-relay.exe。配套 Python 脚本的进程管理目前面向 Linux，Windows 请参考手动运行步骤。' },
      { title: 'Linux x64', body: '常见 Intel / AMD 电脑选择 Linux amd64 发布包。预编译服务需要 glibc 2.34 或更新版本。' },
      { title: 'Linux ARM64', body: '使用 64 位 ARM Linux 的电脑或树莓派选择 Linux arm64 发布包。同样需要 glibc 2.34 或更新版本。' },
      { title: '下载后还需要准备什么', body: '按发布说明安装 HDC、建立 USB 反向转发，并运行电脑端服务。电脑端服务无需每次随 App 一起更新，请查看对应版本的兼容说明。当前项目不提供 macOS 预编译电脑端服务。' }
    ], links: [
      { title: '前往 GitHub Releases 下载', url: RELEASES_URL },
      { title: '打开安装与使用说明', url: PROJECT_URL }
    ]
  },
  {
    id: 'developer', title: '开发者与开源项目', introduction: 'RevTether 由 linloir 开发。客户端与电脑端服务均提供开源代码。',
    sections: [
      { title: '联系开发者', body: '邮箱：' + CONTACT_EMAIL + '\n可通过邮件提出使用问题与隐私请求，也可在 GitHub Issues 反馈问题。此处不会自动发送邮件。' },
      { title: '反馈时可以提供什么', body: '描述操作步骤、预期和实际现象，以及手机系统版本、电脑系统和 App 版本，有助于复现问题。分享日志前，请移除密码、私钥、设备标识和与问题无关的网络活动信息。' },
      { title: '开源许可与致谢', body: '本项目采用 Apache License 2.0。电脑端转发核心基于 Genymobile gnirehtet；版权、许可与修改说明见源码仓库中的 LICENSE 和 NOTICE。感谢原项目贡献者。' }
    ], links: [
      { title: '查看开发者 GitHub 主页', url: DEVELOPER_URL },
      { title: '查看 RevTether 源代码', url: PROJECT_URL },
      { title: '在 GitHub 反馈问题', url: PROJECT_URL + '/issues' }
    ]
  }
];

export function helpTopic(id: string): HelpTopic {
  return HELP_TOPICS.find((topic: HelpTopic) => topic.id === id) ?? HELP_TOPICS[0];
}
