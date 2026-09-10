import { common } from '@kit.AbilityKit';

export const PROJECT_URL = 'https://github.com/Linloir/HarmonyOS-Reverse-Tether';
export const RELEASES_URL = PROJECT_URL + '/releases';
export const PRIVACY_URL = 'https://linloir.github.io/HarmonyOS-Reverse-Tether/privacy/';
export const DEVELOPER_URL = 'https://github.com/Linloir';
export const GNIREHTET_URL = 'https://github.com/Genymobile/gnirehtet';
export const CONTACT_EMAIL = '3145078758@qq.com';

// Open only on an explicit tap; offline help never loads a remote WebView.
export async function openWebsite(context: common.UIAbilityContext, url: string): Promise<void> {
  await context.openLink(url);
}
