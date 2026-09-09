// SPDX-License-Identifier: Apache-2.0
import { UIAbility, Want } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ProbeRun, parseRequest } from './NetworkProbe';
import { probeResultServer } from './ProbeResultServer';

// A short-lived, non-launcher ability. It never imports or starts VPN APIs.
export default class ProbeAbility extends UIAbility {
  private run?: ProbeRun;
  private id: string = '';
  private delayId: number = -1;
  private timer: number = -1;
  private finished: boolean = false;

  onCreate(want: Want): void { this.start(want); }
  onNewWant(want: Want): void {
    // Keep an active request intact; the caller enforces one request per device.
    if (!this.run) this.start(want);
  }
  onForeground(): void {
    this.context.moveAbilityToBackground().catch(() => {});
  }
  private async start(want: Want): Promise<void> {
    try {
      const encoded = want.parameters?.request;
      if (typeof encoded !== 'string') throw new Error('invalid_request');
      const request = parseRequest(encoded);
      this.id = request.request_id;
      this.run = new ProbeRun();
      const delay = backgroundTaskManager.requestSuspendDelay('Network quality check', () => this.finish());
      this.delayId = delay.requestId;
      // actualDelayTime is expressed in milliseconds by BackgroundTasksKit.
      if (delay.actualDelayTime < 20000) throw new Error('background_time_unavailable');
      this.timer = setTimeout(() => this.finish(), 20000);
      await probeResultServer.begin(this.id, () => this.finish());
      const reply = await this.run.run(request);
      probeResultServer.finish(reply);
      hilog.info(0x0001, 'HarmonyProbe', 'PROBE_FINISHED received=%{public}d sent=%{public}d error=%{public}s',
        reply.value?.received ?? 0, reply.value?.sent ?? 0, reply.error ?? '');
    } catch (error) {
      hilog.error(0x0001, 'HarmonyProbe', 'PROBE_FAILED %{public}s', (error as Error).message);
      this.finish();
    }
  }
  private finish(): void {
    if (this.finished) return;
    this.finished = true;
    this.cleanup();
    this.context.terminateSelf().catch(() => {});
  }
  private cleanup(): void {
    this.run?.cancel();
    if (this.timer >= 0) clearTimeout(this.timer);
    if (this.delayId >= 0) {
      try { backgroundTaskManager.cancelSuspendDelay(this.delayId); } catch (_) {}
      this.delayId = -1;
    }
    probeResultServer.end(this.id);
  }
  onDestroy(): void { this.cleanup(); }
}
