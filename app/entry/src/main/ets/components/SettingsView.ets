import { common } from '@kit.AbilityKit';
import { TetherSettings, loadSettings, saveSettings } from '../common/Settings';
import { loadState } from '../common/State';
import { newRequestId } from '../common/ControlAuth';
import { controlRequest } from '../common/ControlClient';
import { hasPrivacyConsent } from '../common/PrivacyConsent';
import { addApplication, SelectableApplication, loadApplicationCatalog } from '../common/ApplicationCatalog';
import { ApplicationAdder } from './ApplicationAdder';

@Component
export struct SettingsView {
  @State ipv6: boolean = false;
  @State mode: string = 'all';
  @State applications: string[] = [];
  @State catalog: SelectableApplication[] = [];
  @Link addingApplications: boolean;
  @State message: string = '';
  @State saving: boolean = false;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const settings = loadSettings(context.filesDir);
    this.ipv6 = settings.ipv6; this.mode = settings.appMode; this.applications = settings.applications.filter((name: string) => name !== context.abilityInfo.bundleName);
    this.catalog = loadApplicationCatalog(context.filesDir).applications;
  }
  private async save(): Promise<void> {
    if (this.saving) return;
    this.saving = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const settings = new TetherSettings();
      settings.ipv6 = this.ipv6; settings.appMode = this.mode; settings.applications = this.applications.slice();
      saveSettings(context.filesDir, settings);
      const state = loadState(context.filesDir);
      if (state.controlReady && state.state !== 'stopped' && hasPrivacyConsent(context.filesDir)) {
        try {
          await controlRequest(context.filesDir, '/v1/configure', JSON.stringify({request_id: newRequestId(), reloadSettings: true}));
          this.message = '设置已保存，连接状态可在主页查看。';
        } catch (_) { this.message = '设置已保存，将在下次连接时生效。当前连接未更改。'; }
      } else this.message = '设置已保存，将在下次连接时生效。';
    } catch (error) { this.message = (error as Error).message || '无法保存设置，请重试'; }
    finally { this.saving = false; }
  }

  private add(name: string): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try { this.applications = addApplication(this.applications, name, context.abilityInfo.bundleName); return ''; }
    catch (error) { return (error as Error).message; }
  }
  private label(name: string): string {
    return this.catalog.find((app: SelectableApplication) => app.bundleName === name)?.label || name;
  }
  @Builder
  private applicationAdder() {
    ApplicationAdder({ count: this.applications.length, initialSelection: this.applications,
      filesDir: (this.getUIContext().getHostContext() as common.UIAbilityContext).filesDir,
      selfBundle: (this.getUIContext().getHostContext() as common.UIAbilityContext).abilityInfo.bundleName,
      onAdd: (name: string) => this.add(name),
      onSelected: (selected: string[], catalog: SelectableApplication[]) => {
        this.applications = selected; this.catalog = catalog;
      },
      onDone: () => { this.addingApplications = false; }
    })
  }
  @Builder
  private modeOption(value: string, title: string, detail: string) {
    Row({ space: 12 }) {
      Radio({value: value, group: 'applicationMode'}).checked(this.mode === value)
        .onChange((checked: boolean) => { if (checked) this.mode = value; })
      Column({ space: 4 }) {
        Text(title).fontSize(16).fontColor($r('sys.color.font_primary'))
        Text(detail).fontSize(12).fontColor($r('sys.color.font_secondary')).lineHeight(18)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').padding({ top: 8, bottom: 8 }).onClick(() => { this.mode = value; })
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Column({ space: 12 }) {
          Row({ space: 12 }) {
            Text('IPv6 流量').fontSize(18).fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary')).layoutWeight(1)
            Toggle({type: ToggleType.Switch, isOn: this.ipv6}).onChange((value: boolean) => { this.ipv6 = value; })
          }.width('100%')
          Text('默认关闭。宿主机明确指定开启或关闭时，以宿主机配置为准；旧版宿主机仅支持 IPv4。')
            .fontSize(13).fontColor($r('sys.color.font_secondary')).lineHeight(20).width('100%')
        }.padding(20).width('100%').backgroundColor($r('sys.color.comp_background_list_card')).borderRadius(16)
        Column({ space: 8 }) {
          Text('应用流量管理').fontSize(18).fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary')).width('100%')
          this.modeOption('all', '全局', '所有应用都经过 VPN')
          this.modeOption('allow', '白名单', '仅名单中的应用经过 VPN')
          this.modeOption('deny', '黑名单', '名单中的应用不经过 VPN')
          if (this.mode !== 'all') {
            Text('已添加 ' + this.applications.length + ' 个应用').fontSize(13)
              .fontColor($r('sys.color.font_secondary')).width('100%')
            ForEach(this.applications, (name: string) => {
              Row({ space: 8 }) {
                Column({ space: 4 }) {
                  Text(this.label(name)).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (this.label(name) !== name) {
                    Text(name).fontSize(11).fontColor($r('sys.color.font_secondary')).width('100%')
                      .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                Button('移除', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(13).constraintSize({ minHeight: 44 })
                  .accessibilityText('移除 ' + name)
                  .onClick(() => { this.applications = this.applications.filter((item: string) => item !== name); })
              }.width('100%').padding({ top: 6, bottom: 6 })
            }, (name: string) => name)
            Button('添加应用', { buttonStyle: ButtonStyleMode.TEXTUAL }).width('100%').constraintSize({ minHeight: 48 })
              .onClick(() => { this.addingApplications = true; })
            Text('支持逐个输入包名，或通过 USB 读取应用列表。最多 63 个；绕过 VPN 的应用使用手机自身网络。')
              .fontSize(12).fontColor($r('sys.color.font_secondary')).lineHeight(18).width('100%')
          }
          Text('RevTether 始终经过 VPN，用于验证实际供网连接；无需添加到名单，也不能将其排除。')
            .fontSize(12).fontColor($r('sys.color.font_secondary')).lineHeight(18).width('100%')
        }.padding(20).width('100%').backgroundColor($r('sys.color.comp_background_list_card')).borderRadius(16)
        Text('连接期间保存设置会短暂重建 VPN。后台检查使用当前 VPN；系统结束 VPN 服务后，需要重新启动服务。')
          .fontSize(13).fontColor($r('sys.color.font_secondary')).lineHeight(20).width('100%')
        Button(this.saving ? '保存中…' : '保存设置').width('100%').constraintSize({ minHeight: 48 })
          .enabled(!this.saving).onClick(() => this.save())
        if (this.message) {
          Text(this.message).fontSize(14).fontColor($r('sys.color.font_secondary')).lineHeight(22).width('100%')
        }
      }.padding({ left: 16, right: 16, top: 16, bottom: 24 }).width('100%').constraintSize({ maxWidth: 600 })
    }.width('100%').height('100%').align(Alignment.Top)
      .bindSheet($$this.addingApplications, this.applicationAdder(), {
        height: '90%', dragBar: false, showClose: true,
        preferType: SheetType.BOTTOM, backgroundColor: $r('sys.color.background_secondary'),
        title: { title: '添加应用', subtitle: '输入包名，或通过 USB 选择' },
        keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
        scrollSizeMode: ScrollSizeMode.CONTINUOUS,
        onWillDismiss: (action: DismissSheetAction) => {
          this.getUIContext().getFocusController().clearFocus(); action.dismiss(); this.addingApplications = false;
        }
      })
  }
}
