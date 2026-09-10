import { common } from '@kit.AbilityKit';
import { PRIVACY_BLOCKS, PrivacyBlock } from '../common/PrivacyContent';
import { openWebsite, PRIVACY_URL } from '../common/Links';

@Component
export struct Privacy {
  @State message: string = '';

  private async openOnline(): Promise<void> {
    try {
      await openWebsite(this.getUIContext().getHostContext() as common.UIAbilityContext, PRIVACY_URL);
    } catch (_) {
      this.message = '暂时无法打开浏览器，可继续阅读此处的完整离线政策。';
    }
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 16 }) {
          Text('完整政策 · 离线可读').fontSize(13).fontColor($r('sys.color.font_emphasize')).width('100%')
          ForEach(PRIVACY_BLOCKS, (block: PrivacyBlock) => {
            Text(block.text).width('100%')
              .fontSize(block.heading ? 20 : 15)
              .fontWeight(block.heading ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(block.heading ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .lineHeight(block.heading ? 30 : 25).copyOption(CopyOptions.LocalDevice)
              .margin({ top: block.heading ? 12 : 0 })
          })
          Button('在浏览器中查看政策网页')
            .width('100%').constraintSize({ minHeight: 48 }).fontColor($r('sys.color.font_emphasize')).backgroundColor($r('sys.color.comp_background_secondary'))
            .onClick(() => this.openOnline())
          Text('仅在点击上方按钮时访问 GitHub Pages；网站可能处理访问日志。阅读此页无需联网。')
            .fontSize(12).fontColor($r('sys.color.font_secondary')).lineHeight(20).width('100%')
          if (this.message.length > 0) {
            Text(this.message).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
          }

        }.padding({ left: 16, right: 16, bottom: 24 }).width('100%').constraintSize({ maxWidth: 680 })
      }.width('100%').height('100%')
    }.title('隐私政策').backgroundColor($r('sys.color.background_primary'))
  }
}
