import { MAX_APPLICATIONS } from '../common/Settings';
import { SelectableApplication } from '../common/ApplicationCatalog';
import { hasPrivacyConsent } from '../common/PrivacyConsent';
import { ApplicationPicker } from './ApplicationPicker';

@Component
export struct ApplicationAdder {
  @Prop count: number = 0;
  onAdd: (name: string) => string = () => '';
  @Prop initialSelection: string[] = [];
  selfBundle: string = '';
  filesDir: string = '';
  onSelected: (selected: string[], catalog: SelectableApplication[]) => void = () => {};
  @State showingUsb: boolean = false;
  onDone: () => void = () => {};
  @State packageName: string = '';
  @State error: string = '';
  @State added: string = '';
  private add(): void {
    this.error = this.onAdd(this.packageName);
    if (!this.error) {
      this.added = this.packageName.trim(); this.packageName = '';
      this.getUIContext().getFocusController().clearFocus();
    }
  }
  private openUsb(): void {
    this.getUIContext().getFocusController().clearFocus();
    if (!hasPrivacyConsent(this.filesDir)) {
      this.error = '请先在主页阅读并同意隐私政策，再读取 USB 应用列表。'; return;
    }
    this.showingUsb = true;
  }
  @Builder
  private usbPicker() {
    ApplicationPicker({ initialSelection: this.initialSelection, selfBundle: this.selfBundle, filesDir: this.filesDir,
      onDone: (selected: string[], catalog: SelectableApplication[]) => {
        this.getUIContext().getFocusController().clearFocus();
        this.onSelected(selected, catalog); this.showingUsb = false;
      } })
  }
  build() {
    Column({ space: 16 }) {
      Scroll() {
        Column({ space: 20 }) {
          Column({ space: 12 }) {
            Text('输入包名').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
            Text('每次添加一个应用包名，例如 com.example.app。')
              .fontSize(13).fontColor($r('sys.color.font_secondary')).lineHeight(20).width('100%')
            TextInput({ text: this.packageName, placeholder: 'com.example.app' }).maxLength(255).fontSize(15)
              .enterKeyType(EnterKeyType.Done).onSubmit(() => this.add())
              .onChange((value: string) => { this.packageName = value; this.error = ''; this.added = ''; })
            if (this.error) {
              Text(this.error).fontSize(13).fontColor($r('sys.color.font_secondary')).lineHeight(20).width('100%')
            }
            if (this.added) {
              Text('已添加 ' + this.added).fontSize(13).fontColor($r('sys.color.font_secondary')).lineHeight(20).width('100%')
            }
            Button('添加包名').width('100%').constraintSize({ minHeight: 48 }).enabled(this.packageName.trim().length > 0)
              .onClick(() => this.add())
            Text('已添加 ' + this.count + ' / ' + MAX_APPLICATIONS).fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
          }.width('100%').padding(20).backgroundColor($r('sys.color.comp_background_list_card')).borderRadius(16)
          Column({ space: 12 }) {
            Text('通过 USB 选择').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).width('100%')
            Text('连接已授权的电脑后，读取这台手机的应用列表，再按名称搜索和选择。下一页提供连接说明。')
              .fontSize(13).fontColor($r('sys.color.font_secondary')).lineHeight(20).width('100%')
            Button('从 USB 应用列表添加').width('100%').constraintSize({ minHeight: 48 })
              .onClick(() => this.openUsb())
          }.width('100%').padding(20).backgroundColor($r('sys.color.comp_background_list_card')).borderRadius(16)
        }.padding({ bottom: 8 }).width('100%')
      }.layoutWeight(1).width('100%')
      Text('添加完成后，返回设置页点击“保存设置”生效。')
        .fontSize(12).fontColor($r('sys.color.font_secondary')).lineHeight(18).width('100%')
      Button('完成添加').width('100%').constraintSize({ minHeight: 48 }).onClick(() => this.onDone())
    }.padding({ left: 16, right: 16, top: 8, bottom: 24 }).width('100%').height('100%')
      .bindSheet($$this.showingUsb, this.usbPicker(), {
        height: '90%', dragBar: false, showClose: true,
        preferType: SheetType.BOTTOM, backgroundColor: $r('sys.color.background_secondary'),
        title: { title: '选择应用', subtitle: '按名称搜索并勾选应用' },
        keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
        scrollSizeMode: ScrollSizeMode.CONTINUOUS,
        onWillDismiss: (action: DismissSheetAction) => {
          this.getUIContext().getFocusController().clearFocus(); action.dismiss(); this.showingUsb = false;
        }
      })
  }
}
