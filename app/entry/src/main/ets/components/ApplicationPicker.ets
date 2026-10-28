import { SelectableApplication, loadApplicationCatalog, applicationChoices, toggleApplication,
  requestApplicationCatalog, cancelApplicationCatalog, CATALOG_REQUEST_TTL } from '../common/ApplicationCatalog';
import { MAX_APPLICATIONS } from '../common/Settings';
import { loadState } from '../common/State';

@Component
struct ApplicationRow {
  app: SelectableApplication = new SelectableApplication();
  @Prop selected: boolean = false;
  onToggle: () => void = () => {};
  build() {
    Row({ space: 12 }) {
      Image($r('app.media.application_placeholder')).width(36).height(36)
        .fillColor($r('sys.color.font_secondary')).accessibilityLevel('no')
      Column({ space: 4 }) {
        Text(this.app.label).fontSize(16).fontColor($r('sys.color.font_primary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(this.app.bundleName).fontSize(11).fontColor($r('sys.color.font_secondary'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        if (!this.app.available) {
          Text('已添加的包名 · 未在本次列表中找到').fontSize(11).fontColor($r('sys.color.font_secondary'))
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Checkbox({ name: this.app.bundleName }).select(this.selected)
        .onClick(() => this.onToggle()).accessibilityText(this.app.label)
    }.padding(12).width('100%').constraintSize({ minHeight: 68 })
      .backgroundColor($r('sys.color.comp_background_list_card')).borderRadius(12)
      .onClick(() => this.onToggle())
  }
}

@Component
export struct ApplicationPicker {
  initialSelection: string[] = [];
  selfBundle: string = '';
  filesDir: string = '';
  onDone: (selected: string[], catalog: SelectableApplication[]) => void = () => {};
  @State selected: string[] = [];
  @State catalog: SelectableApplication[] = [];
  @State query: string = '';
  @State selectedOnly: boolean = false;
  @State phase: string = 'guide';
  @State message: string = '';
  private timer: number = -1;
  private request: number = 0;

  aboutToAppear(): void {
    this.selected = this.initialSelection.filter((name: string) => name !== this.selfBundle);
    this.phase = this.connected() ? 'guide' : 'disconnected';
    this.timer = setInterval(() => this.readCatalog(), 1000);
  }
  aboutToDisappear(): void {
    clearInterval(this.timer);
    cancelApplicationCatalog(this.filesDir, this.request);
  }
  private connected(): boolean {
    const state = loadState(this.filesDir);
    return state.controlReady && state.state === 'connected';
  }
  private refresh(): void {
    this.message = '';
    cancelApplicationCatalog(this.filesDir, this.request);
    if (!this.connected()) { this.phase = 'disconnected'; return; }
    try {
      this.request = requestApplicationCatalog(this.filesDir);
      this.phase = 'waiting';
    } catch (_) { this.phase = 'failed'; }
  }
  private readCatalog(): void {
    if (this.phase !== 'waiting') return;
    const value = loadApplicationCatalog(this.filesDir);
    if (value.request === this.request && value.updatedAt > 0) {
      if (value.error) { this.phase = value.error === 'unsupported' ? 'unsupported' : 'failed'; return; }
      this.catalog = value.applications; this.phase = 'loaded'; return;
    }
    if (!this.connected()) {
      cancelApplicationCatalog(this.filesDir, this.request); this.phase = 'disconnected';
    } else if (Date.now() - this.request > CATALOG_REQUEST_TTL) {
      cancelApplicationCatalog(this.filesDir, this.request); this.phase = 'timeout';
    }
  }
  private toggle(name: string): void {
    try { this.selected = toggleApplication(this.selected, name, this.selfBundle); this.message = ''; }
    catch (error) { this.message = (error as Error).message; }
  }
  private choices(): SelectableApplication[] {
    return applicationChoices(this.catalog, this.selected, this.selfBundle, this.query, this.selectedOnly);
  }
  private title(): string {
    if (this.phase === 'waiting') return '正在读取应用列表';
    if (this.phase === 'disconnected') return '尚未建立 USB 供网连接';
    if (this.phase === 'timeout') return '宿主机未响应';
    if (this.phase === 'unsupported') return '当前系统未提供应用列表';
    if (this.phase === 'failed') return '应用列表读取失败';
    return '通过 USB 添加应用';
  }
  private detail(): string {
    if (this.phase === 'waiting') return '正在等待宿主机读取，请保持 USB 连接。';
    if (this.phase === 'disconnected') return '请检查 USB 数据线、调试授权和宿主机服务，再重新读取。';
    if (this.phase === 'timeout') return '请确认宿主机工具已更新并正在运行，也可以按下方说明手动同步。';
    if (this.phase === 'unsupported' || this.phase === 'failed') return '你可以重试，或返回使用包名添加；现有名单不会改变。';
    return '由你授权的电脑读取这台手机的应用名称和包名，再传回手机供选择。';
  }
  @Builder
  private instructions() {
    Column({ space: 8 }) {
      Text('连接方法').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
      Text('1. 用 USB 数据线连接电脑，开启手机 USB 调试，并允许这台电脑调试。')
        .fontSize(13).lineHeight(20).fontColor($r('sys.color.font_secondary'))
      Text('2. 在电脑启动新版 RevTether 宿主机工具，并在主页建立供网连接。')
        .fontSize(13).lineHeight(20).fontColor($r('sys.color.font_secondary'))
      Text('3. 点击“读取应用列表”，然后选择要添加的应用。')
        .fontSize(13).lineHeight(20).fontColor($r('sys.color.font_secondary'))
      Text('手动同步：在本页开始读取后，于宿主机工具的 scripts 目录运行：')
        .fontSize(12).lineHeight(18).fontColor($r('sys.color.font_secondary'))
      Text('python3 harmony-tether.py sync-apps --serial <USB序列号>')
        .fontSize(11).fontFamily('monospace').fontColor($r('sys.color.font_secondary')).copyOption(CopyOptions.InApp)
      Text('Windows 可将 python3 替换为 python。序列号可通过 hdc list targets 查看。')
        .fontSize(12).lineHeight(18).fontColor($r('sys.color.font_secondary'))
    }.alignItems(HorizontalAlign.Start).width('100%').padding(16)
      .backgroundColor($r('sys.color.comp_background_list_card')).borderRadius(16)
  }
  build() {
    Column({ space: 12 }) {
      if (this.phase === 'loaded') {
        Search({ value: this.query, placeholder: '搜索应用名称或包名' })
          .onChange((value: string) => { this.query = value; }).height(44)
        Row({ space: 8 }) {
          Text('已选择 ' + this.selected.length + ' / ' + MAX_APPLICATIONS).fontSize(13)
            .fontColor($r('sys.color.font_secondary')).layoutWeight(1)
          Button(this.selectedOnly ? '显示全部' : '仅看已选', { buttonStyle: ButtonStyleMode.TEXTUAL })
            .fontSize(13).height(36).onClick(() => { this.selectedOnly = !this.selectedOnly; })
          Button('刷新', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(13).height(36).onClick(() => this.refresh())
        }.width('100%')
        List({ space: 8 }) {
          ForEach(this.choices(), (app: SelectableApplication) => {
            ListItem() {
              ApplicationRow({ app: app, selected: this.selected.includes(app.bundleName), onToggle: () => this.toggle(app.bundleName) })
            }
          }, (app: SelectableApplication) => app.bundleName)
          if (this.choices().length === 0) {
            ListItem() {
              Text(this.selectedOnly ? '尚未选择应用' : this.catalog.length ? '没有匹配的应用' : '本次未读取到可选应用')
                .fontSize(14).fontColor($r('sys.color.font_secondary')).padding(24).width('100%').textAlign(TextAlign.Center)
            }
          }
        }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
        Text('应用列表由本次 USB 读取获得；包含系统应用。RevTether 无需添加。')
          .fontSize(12).fontColor($r('sys.color.font_secondary')).lineHeight(18).width('100%')
        Button('完成选择').width('100%').constraintSize({ minHeight: 48 })
          .onClick(() => this.onDone(this.selected.slice(), this.catalog))
      } else {
        Scroll() {
          Column({ space: 20 }) {
            Column({ space: 12 }) {
              if (this.phase === 'waiting') { LoadingProgress().width(40).height(40) }
              else {
                Image(this.phase === 'guide' ? $r('app.media.usb_connection') : $r('app.media.connection_notice'))
                  .width(48).height(48).fillColor($r('sys.color.font_secondary')).accessibilityLevel('no')
              }
              Text(this.title()).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
              Text(this.detail()).fontSize(14).lineHeight(22).fontColor($r('sys.color.font_secondary')).textAlign(TextAlign.Center)
            }.width('100%').padding({ top: 16, bottom: 8 })
            this.instructions()
            Text('仅在你开始读取后访问应用列表；退出此页即取消。列表保存在手机，宿主机仅用于读取和传输，不上传云端。')
              .fontSize(12).lineHeight(18).fontColor($r('sys.color.font_secondary')).width('100%')
          }.width('100%')
        }.layoutWeight(1).width('100%')
        Button(this.phase === 'waiting' ? '读取中…' : '读取应用列表').width('100%').constraintSize({ minHeight: 48 })
          .enabled(this.phase !== 'waiting').onClick(() => this.refresh())
      }
      if (this.message) { Text(this.message).fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%') }
    }.padding({ left: 16, right: 16, top: 8, bottom: 24 }).width('100%').height('100%')
      .backgroundColor($r('sys.color.background_secondary'))
  }
}
