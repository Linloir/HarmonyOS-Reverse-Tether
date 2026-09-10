import { common } from '@kit.AbilityKit';
import { HelpTopic, HelpSection, HelpLink, helpTopic } from '../common/HelpContent';
import { openWebsite } from '../common/Links';

@Component
export struct Info {
  @Prop topicId: string = 'guide';
  @State topic: HelpTopic = helpTopic('guide');
  @State message: string = '';

  aboutToAppear(): void {
    this.topic = helpTopic(this.topicId);
  }

  private async open(url: string): Promise<void> {
    try {
      await openWebsite(this.getUIContext().getHostContext() as common.UIAbilityContext, url);
      this.message = '';
    } catch (_) {
      this.message = '暂时无法打开浏览器。可复制下方链接后访问：\n' + url;
    }
  }

  @Builder
  private node(title: string, subtitle: string) {
    Column({ space: 5 }) {
      Text(title).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_emphasize'))
      Text(subtitle).fontSize(13).fontColor($r('sys.color.font_secondary')).textAlign(TextAlign.Center).lineHeight(20)
    }.width('100%').padding(18).backgroundColor($r('sys.color.comp_emphasize_tertiary')).borderRadius(16)
  }

  @Builder
  private diagram() {
    Column({ space: 10 }) {
      Text('数据的往返路径').fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
      this.node('手机上的应用', 'RevTether · 系统 VPN 接口')
      SymbolGlyph($r('sys.symbol.arrow_up_and_down_square_portrait')).fontSize(20).fontColor([$r('sys.color.icon_emphasize')])
      Text('USB 数据线 / HDC').fontSize(14).fontColor($r('sys.color.font_emphasize'))
      this.node('你连接的电脑', '配套转发服务 · 使用电脑网络')
      SymbolGlyph($r('sys.symbol.arrow_up_and_down_square_portrait')).fontSize(20).fontColor([$r('sys.color.icon_emphasize')])
      Text('电脑的网络出口').fontSize(14).fontColor($r('sys.color.font_emphasize'))
      this.node('目标网络', '网站、应用服务与 DNS')
      Text('请求发出，响应沿通道返回。开发者不运营接收这些流量的远程 VPN 服务器。')
        .fontSize(13).fontColor($r('sys.color.font_secondary')).lineHeight(21).width('100%').margin({ top: 4 })
    }.padding(20).width('100%').backgroundColor($r('sys.color.comp_background_list_card')).borderRadius(20)
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 16 }) {
          Text(this.topic.introduction).fontSize(16).fontColor($r('sys.color.font_secondary')).lineHeight(26).width('100%')
            .margin({ bottom: 4 })
          if (this.topic.id === 'principle') {
            this.diagram()
          }
          ForEach(this.topic.sections, (section: HelpSection) => {
            Column({ space: 10 }) {
              Text(section.title).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
              Text(section.body).fontSize(15).fontColor($r('sys.color.font_secondary')).lineHeight(25).width('100%')
                .copyOption(CopyOptions.LocalDevice)
            }.padding(20).width('100%').backgroundColor($r('sys.color.comp_background_list_card')).borderRadius(20)
          })
          ForEach(this.topic.links, (link: HelpLink) => {
            Button(link.title).width('100%').constraintSize({ minHeight: 48 })
              .padding({ top: 12, bottom: 12, left: 16, right: 16 })
              .onClick(() => this.open(link.url))
          })
          if (this.topic.links.length > 0) {
            Text('以上链接将在浏览器中访问 GitHub，需要可用网络。第三方网站可能处理访问日志。')
              .fontSize(12).fontColor($r('sys.color.font_secondary')).lineHeight(20).width('100%')
          }
          if (this.message.length > 0) {
            Text(this.message).fontSize(14).fontColor($r('sys.color.font_secondary')).lineHeight(22).width('100%')
              .copyOption(CopyOptions.LocalDevice)
          }
        }.padding({ left: 16, right: 16, top: 8, bottom: 24 }).width('100%').constraintSize({ maxWidth: 680 })
      }.width('100%').height('100%')
    }.title(this.topic.title).backgroundColor($r('sys.color.background_secondary'))
  }
}
