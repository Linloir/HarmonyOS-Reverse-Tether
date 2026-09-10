@CustomDialog
export struct PrivacyDialog {
  controller: CustomDialogController;
  onRead: () => void = () => {};
  onAccept: () => void = () => {};
  onDecline: () => void = () => {};

  build() {
    Column({ space: 18 }) {
      Text('欢迎使用 RevTether').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary'))
      Text('请先阅读隐私政策')
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_emphasize'))
      Text('连接时，应用会通过系统 VPN 和 USB，在手机与所连接的电脑之间处理网络数据，并在本地保存连接状态。开发者不集中收集你的上网流量。')
        .fontSize(15).fontColor($r('sys.color.font_secondary')).lineHeight(23)
      Text('联网检查和外部工具发起的网络探测会访问相应的第三方服务器。请了解数据处理方式、权限用途和你的选择。')
        .fontSize(15).fontColor($r('sys.color.font_secondary')).lineHeight(23)
      Button('阅读完整隐私政策', { type: ButtonType.Normal })
        .fontColor($r('sys.color.font_emphasize')).backgroundColor($r('sys.color.comp_background_tertiary')).borderRadius(12)
        .width('100%').constraintSize({ minHeight: 44 }).onClick(() => this.onRead())
      Text('暂不同意也可浏览使用指南与关于；连接和网络检查需在同意后使用。')
        .fontSize(13).fontColor($r('sys.color.font_secondary')).lineHeight(20)
      Row({ space: 12 }) {
        Button('暂不同意').layoutWeight(1).constraintSize({ minHeight: 48 })
          .backgroundColor($r('sys.color.comp_background_secondary')).fontColor($r('sys.color.font_emphasize')).onClick(() => this.onDecline())
        Button('同意并继续').layoutWeight(1).constraintSize({ minHeight: 48 })
          .buttonStyle(ButtonStyleMode.EMPHASIZED).onClick(() => this.onAccept())
      }.width('100%')
    }.padding(24).width('100%').constraintSize({ maxWidth: 440 })
  }
}
