import { UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VPN_ABILITY } from '../common/State';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want): void { this.handleCommand(want); }
  onNewWant(want: Want): void { this.handleCommand(want); }

  private handleCommand(want: Want): void {
    // Host control through `hdc shell aa start --ps command ...`.
    // First use still goes through the OS VPN consent dialog.
    const command = want.parameters?.command;
    const vpnWant: Want = {bundleName: this.context.abilityInfo.bundleName, abilityName: VPN_ABILITY};
    if (command === 'start') {
      const dns = want.parameters?.dns;
      const parameters: Record<string, string> = {};
      if (typeof dns === 'string' && dns.length > 0) {
        parameters['dns'] = dns;
      }
      const port = want.parameters?.port;
      if (typeof port === 'string' || typeof port === 'number') parameters['port'] = String(port);
      vpnWant.parameters = parameters;
      vpnExtension.startVpnExtensionAbility(vpnWant).catch((error: Error) => {
        hilog.error(0x0001, 'HarmonyTether', 'START_REQUEST_FAILED %{public}s', error.message);
      });
    } else if (command === 'stop') {
      vpnExtension.stopVpnExtensionAbility(vpnWant).catch((error: Error) => {
        hilog.error(0x0001, 'HarmonyTether', 'STOP_REQUEST_FAILED %{public}s', error.message);
      });
    }
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    try {
      stage.loadContent('pages/Index');
    } catch (error) {
      hilog.error(0x0001, 'HarmonyTether', 'LOAD_UI_FAILED %{public}s', String(error));
    }
  }
}
