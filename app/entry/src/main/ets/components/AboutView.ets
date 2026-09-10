import { bundleManager } from '@kit.AbilityKit';

@Component
export struct AboutView {
  @State version: string = '';
  onOpen: (topic: string) => void = () => {};
  onPrivacy: () => void = () => {};

  aboutToAppear(): void {
    try {
      this.version = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
    } catch (_) {}
  }

  @Builder
  private entry(title: string, subtitle: string, topic: string) {
    ListItem() {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(title).fontSize(16).fontColor($r('sys.color.font_primary'))
          Text(subtitle).fontSize(12).fontColor($r('sys.color.font_secondary')).lineHeight(18)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('sys.color.icon_tertiary')])
      }.padding({ left: 16, right: 16, top: 16, bottom: 16 }).width('100%')
    }.onClick(() => this.onOpen(topic)).accessibilityGroup(true).accessibilityText(title + '，' + subtitle)
  }

  @Builder
  private section(title: string) {
    ListItem() {
      Text(title).fontSize(14).fontColor($r('sys.color.font_secondary'))
        .padding({ left: 16, top: 12, bottom: 4 }).width('100%')
    }
  }

  build() {
    List({ space: 12 }) {
      ListItem() {
        Row({ space: 16 }) {
          Image($r('app.media.app_icon')).width(64).height(64).borderRadius(16).accessibilityText('RevTether 图标')
          Column({ space: 6 }) {
            Text($r('app.string.app_name')).fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
            Text('通过 USB 使用电脑的网络').fontSize(14).fontColor($r('sys.color.font_secondary'))
            if (this.version.length > 0) {
              Text('版本 ' + this.version).fontSize(12).fontColor($r('sys.color.font_secondary'))
            }
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%').padding(16)
      }
      this.section('了解与使用')
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        this.entry('连接指南', '从准备电脑到第一次连接', 'guide')
        this.entry('连接排查', '找出连接或联网失败的原因', 'troubleshooting')
        this.entry('反向供网如何工作', '用一张图看懂网络的路径', 'principle')
        this.entry('为什么专注反向供网', '使用场景，以及这条连接的价值', 'purpose')
        this.entry('其他平台的类似工具', '认识 Android 上的 gnirehtet', 'platforms')
      }.divider({ strokeWidth: 0.5, color: $r('sys.color.comp_divider'), startMargin: 16, endMargin: 16 })
      this.section('项目与支持')
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        this.entry('下载电脑端工具', '选择平台，前往 GitHub Releases', 'downloads')
        this.entry('开发者与开源项目', '联系 linloir、查看源码与致谢', 'developer')
        ListItem() {
          Row({ space: 12 }) {
            Text('隐私政策').fontSize(16).fontColor($r('sys.color.font_primary')).layoutWeight(1)
            Text('离线可读').fontSize(12).fontColor($r('sys.color.font_secondary'))
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('sys.color.icon_tertiary')])
          }.padding(16).width('100%').constraintSize({ minHeight: 56 })
        }.onClick(() => this.onPrivacy()).accessibilityGroup(true).accessibilityText('隐私政策，离线可读')
      }.divider({ strokeWidth: 0.5, color: $r('sys.color.comp_divider'), startMargin: 16, endMargin: 16 })
      ListItem() {
        Text('指南、原理和隐私政策均内置于应用，无需连接电脑即可阅读。')
          .fontSize(12).fontColor($r('sys.color.font_secondary')).lineHeight(20).width('100%').padding(16)
      }
    }.padding({ top: 8, bottom: 16 }).width('100%').height('100%')
      .constraintSize({ maxWidth: 600 }).scrollBar(BarState.Off)
  }
}
