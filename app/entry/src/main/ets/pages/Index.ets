import { common, Want } from '@kit.AbilityKit';
import { vpnExtension, http } from '@kit.NetworkKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { Info } from './Info';
import { Privacy } from './Privacy';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VPN_ABILITY, TetherState, loadState } from '../common/State';
import { hasPrivacyConsent, acceptPrivacy } from '../common/PrivacyConsent';
import { tetherParameters, clearTetherRequest } from '../common/TetherRequest';
import { PrivacyDialog } from '../components/PrivacyDialog';
import { AboutView } from '../components/AboutView';

interface TopicParams { topic: string; }

@Entry
@Component
struct Index {
  @State status: TetherState = new TetherState();
  @State message: string = '';
  @State probing: boolean = false;
  @State acting: boolean = false;
  @State consent: boolean = false;
  @State selectedTab: number = 0;
  private navigationStack: NavPathStack = new NavPathStack();
  private timer: number = -1;
  private promptOnShow: boolean = true;
  private dialogVisible: boolean = false;
  private request?: http.HttpRequest;
  private privacyDialog: CustomDialogController = new CustomDialogController({
    builder: PrivacyDialog({
      onRead: () => this.readPrivacy(),
      onAccept: () => this.agree(),
      onDecline: () => this.decline()
    }),
    autoCancel: false,
    alignment: DialogAlignment.Center,
    cornerRadius: 24,
    onWillDismiss: () => { /* A back gesture must not imply consent. */ }
  });

  aboutToAppear(): void {
    this.refresh();
    this.timer = setInterval(() => this.refresh(), 1000);
  }
  onPageShow(): void {
    this.refresh();
    if (!this.consent && this.promptOnShow) this.showPrivacy();
  }
  aboutToDisappear(): void {
    if (this.timer >= 0) clearInterval(this.timer);
    this.request?.destroy();
    this.request = undefined;
    this.privacyDialog.close();
  }
  private refresh(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.status = loadState(context.filesDir);
    this.consent = hasPrivacyConsent(context.filesDir);
  }

  private showPrivacy(): void {
    if (this.dialogVisible) return;
    this.dialogVisible = true;
    this.privacyDialog.open();
  }
  private readPrivacy(): void {
    this.privacyDialog.close();
    this.dialogVisible = false;
    this.promptOnShow = true;
    this.navigationStack.pushPath({ name: 'Privacy' });
  }
  private agree(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      acceptPrivacy(context.filesDir);
      this.consent = true;
      this.message = '';
    } catch (_) {
      this.message = '无法保存隐私选择，请重试。连接和联网检查尚未启用。';
    }
    this.promptOnShow = false;
    this.dialogVisible = false;
    this.privacyDialog.close();
  }
  private decline(): void {
    this.promptOnShow = false;
    this.dialogVisible = false;
    this.privacyDialog.close();
  }
  private requireConsent(): boolean {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.consent = hasPrivacyConsent(context.filesDir);
    if (!this.consent) this.showPrivacy();
    return this.consent;
  }

  private async start(): Promise<void> {
    if (this.acting || !this.requireConsent()) return;
    this.acting = true;
    this.message = '首次连接时，请允许系统的 VPN 请求';
    try {
      await vpnExtension.startVpnExtensionAbility(this.vpnWant());
    } catch (_) { this.message = '连接请求失败，请检查系统 VPN 授权后重试。'; }
    finally { this.acting = false; this.refresh(); }
  }
  private async stop(): Promise<void> {
    if (this.acting) return;
    this.acting = true;
    try {
      await vpnExtension.stopVpnExtensionAbility(this.vpnWant());
      clearTetherRequest();
      this.message = '';
    } catch (_) { this.message = '断开失败，请重试或在系统设置中断开 VPN。'; }
    finally { this.acting = false; this.refresh(); }
  }
  private vpnWant(): Want {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return {bundleName: context.abilityInfo.bundleName, abilityName: VPN_ABILITY, parameters: tetherParameters()};
  }
  private async probe(): Promise<void> {
    if (this.probing || !this.requireConsent()) return;
    this.probing = true;
    const request = http.createHttp();
    this.request = request;
    try {
      const response = await request.request('https://www.example.com/?tether=' + Date.now().toString(), {
        method: http.RequestMethod.GET,
        connectTimeout: 10000,
        readTimeout: 10000,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING
      });
      this.message = '当前网络 HTTPS 已响应：HTTP ' + response.responseCode.toString();
      hilog.info(0x0001, 'HarmonyTether', 'HTTPS_PROBE code=%{public}d bytes=%{public}d', response.responseCode, String(response.result).length);
    } catch (error) {
      this.message = '联网检查失败，请检查电脑的网络连接';
      hilog.error(0x0001, 'HarmonyTether', 'HTTPS_PROBE_FAILED %{public}s', JSON.stringify(error));
    } finally {
      request.destroy();
      this.request = undefined;
      this.probing = false;
    }
  }
  private formatBytes(value: number): string { return (value / 1048576).toFixed(2) + ' MB'; }

  @Builder
  private home() {
    Scroll() {
      Column({ space: 24 }) {
        Column({ space: 16 }) {
          Text(this.status.state === 'connected' ? '已连接' : this.status.state === 'stopped' ? '待连接' : '连接状态')
            .fontSize(24).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
          Text(this.status.message).fontSize(14).fontColor($r('sys.color.font_secondary'))
            .textAlign(TextAlign.Center).lineHeight(22)
          Row({ space: 48 }) {
            Column({ space: 8 }) {
              Text('发送').fontSize(12).fontColor($r('sys.color.font_secondary'))
              Text(this.formatBytes(this.status.txBytes)).fontSize(20).fontColor($r('sys.color.font_primary'))
            }
            Column({ space: 8 }) {
              Text('接收').fontSize(12).fontColor($r('sys.color.font_secondary'))
              Text(this.formatBytes(this.status.rxBytes)).fontSize(20).fontColor($r('sys.color.font_primary'))
            }
          }.margin({ top: 12 })
        }.padding(32).width('100%').backgroundColor($r('sys.color.comp_background_list_card')).borderRadius(16)
        Column({ space: 12 }) {
          Button(this.status.state === 'stopped' ? '连接' : '断开')
            .width('100%').constraintSize({ minHeight: 48 }).enabled(!this.acting)
            .onClick(() => {
              if (this.status.state === 'stopped') this.start();
              else this.stop();
            })
          Button(this.probing ? '检查中…' : '检查互联网连接', { buttonStyle: ButtonStyleMode.TEXTUAL })
            .width('100%').constraintSize({ minHeight: 48 })
            .enabled(!this.probing).onClick(() => this.probe())
          if (this.message.length > 0) {
            Text(this.message).fontSize(14).fontColor($r('sys.color.font_secondary'))
              .lineHeight(22).textAlign(TextAlign.Center).width('100%')
          }
          if (!this.consent) {
            Button('阅读并同意隐私政策', { buttonStyle: ButtonStyleMode.TEXTUAL })
              .fontSize(14).constraintSize({ minHeight: 44 }).onClick(() => this.showPrivacy())
          }
        }.width('100%')
      }.padding({ left: 16, right: 16, top: 16, bottom: 24 }).width('100%').constraintSize({ maxWidth: 600 })
    }.width('100%').height('100%').align(Alignment.Top)
  }

  @Builder
  private destination(name: string, params: Object) {
    if (name === 'Info') {
      Info({ topicId: (params as TopicParams).topic })
    } else if (name === 'Privacy') {
      Privacy()
    }
  }

  build() {
    Navigation(this.navigationStack) {
      Tabs({ barPosition: BarPosition.End, index: this.selectedTab }) {
        TabContent() { this.home() }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.house')),
            selected: new SymbolGlyphModifier($r('sys.symbol.house_fill'))
          }, '主页'))
        TabContent() {
          AboutView({
            onOpen: (topic: string) => this.navigationStack.pushPath({ name: 'Info', param: { topic: topic } as TopicParams }),
            onPrivacy: () => this.navigationStack.pushPath({ name: 'Privacy' })
          })
        }.tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.info_circle')),
          selected: new SymbolGlyphModifier($r('sys.symbol.info_circle_fill'))
        }, '关于'))
      }.scrollable(false).animationDuration(0).backgroundColor($r('sys.color.background_secondary'))
        .onChange((index: number) => { this.selectedTab = index; })
        .width('100%').height('100%')
    }.title(this.selectedTab === 0 ? 'RevTether' : '关于', { backgroundColor: $r('sys.color.background_secondary') })
      .titleMode(NavigationTitleMode.Mini).hideBackButton(true).mode(NavigationMode.Stack)
      .navDestination(this.destination)
      .onNavBarStateChange((visible: boolean) => {
        if (visible) {
          this.refresh();
          if (!this.consent && this.promptOnShow) this.showPrivacy();
        }
      })
      .width('100%').height('100%').backgroundColor($r('sys.color.background_secondary'))
  }
}
