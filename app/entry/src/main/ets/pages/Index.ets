import { common, Want } from '@kit.AbilityKit';
import { vpnExtension, http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VPN_ABILITY, TetherState, loadState } from '../common/State';

@Entry
@Component
struct Index {
  @State status: TetherState = new TetherState();
  @State message: string = '';
  @State probing: boolean = false;
  private timer: number = -1;

  aboutToAppear(): void {
    this.refresh();
    this.timer = setInterval(() => this.refresh(), 1000);
  }
  aboutToDisappear(): void { if (this.timer >= 0) clearInterval(this.timer); }
  private refresh(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.status = loadState(context.filesDir);
  }

  private async start(): Promise<void> {
    this.message = '首次连接时，请允许系统的 VPN 请求';
    try {
      await vpnExtension.startVpnExtensionAbility(this.vpnWant());
    } catch (error) { this.message = '连接请求失败：' + String(error); }
  }
  private async stop(): Promise<void> {
    try {
      await vpnExtension.stopVpnExtensionAbility(this.vpnWant());
      this.message = '';
    } catch (error) { this.message = '断开失败：' + String(error); }
  }
  private vpnWant(): Want {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return {bundleName: context.abilityInfo.bundleName, abilityName: VPN_ABILITY};
  }
  private async probe(): Promise<void> {
    this.probing = true;
    const request = http.createHttp();
    try {
      const response = await request.request('https://www.example.com/?tether=' + Date.now().toString(), {
        method: http.RequestMethod.GET,
        connectTimeout: 10000,
        readTimeout: 10000,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING
      });
      this.message = 'HTTPS 检查：HTTP ' + response.responseCode.toString();
      hilog.info(0x0001, 'HarmonyTether', 'HTTPS_PROBE code=%{public}d bytes=%{public}d', response.responseCode, String(response.result).length);
    } catch (error) {
      this.message = '联网检查失败，请检查电脑的网络连接';
      hilog.error(0x0001, 'HarmonyTether', 'HTTPS_PROBE_FAILED %{public}s', JSON.stringify(error));
    } finally {
      request.destroy();
      this.probing = false;
    }
  }
  private formatBytes(value: number): string { return (value / 1048576).toFixed(2) + ' MB'; }

  build() {
    Scroll() {
      Column({space: 24}) {
        Column({space: 10}) {
          Text('USB 网络').fontSize(32).fontWeight(FontWeight.Bold).fontColor('#163B34')
          Text('通过 USB 使用电脑的网络').fontSize(16).fontColor('#60756E')
        }.width('100%').alignItems(HorizontalAlign.Start)
        Column({space: 18}) {
          Text(this.status.state === 'connected' ? '已连接' : this.status.state === 'stopped' ? '待连接' : '连接状态')
            .fontSize(23).fontWeight(FontWeight.Medium).fontColor('#176B5B')
          Text(this.status.message).fontSize(15).fontColor('#60756E').textAlign(TextAlign.Center)
          Row({space: 32}) {
            Column({space: 6}) {
              Text('发送').fontSize(13).fontColor('#60756E')
              Text(this.formatBytes(this.status.txBytes)).fontSize(18)
            }
            Column({space: 6}) {
              Text('接收').fontSize(13).fontColor('#60756E')
              Text(this.formatBytes(this.status.rxBytes)).fontSize(18)
            }
          }
        }.padding(28).width('100%').backgroundColor(Color.White).borderRadius(24)
        Button(this.status.state === 'stopped' ? '连接' : '断开')
          .width('100%').height(52).backgroundColor('#176B5B')
          .onClick(() => {
            if (this.status.state === 'stopped') this.start();
            else this.stop();
          })
        Button(this.probing ? '检查中…' : '检查互联网连接')
          .width('100%').height(48).backgroundColor('#E4EEE9').fontColor('#176B5B')
          .enabled(!this.probing).onClick(() => this.probe())
        if (this.message.length > 0) {
          Text(this.message).fontSize(14).fontColor('#60756E').width('100%')
        }
        Text('在电脑上启动配套服务并连接 USB。首次使用需要允许 VPN 连接，连接中断后会自动重试。')
          .fontSize(14).fontColor('#60756E').lineHeight(22).width('100%')
      }.padding(28).width('100%').constraintSize({maxWidth: 520}).margin({top: 30})
    }.width('100%').height('100%').backgroundColor('#F4F7F6')
  }
}
