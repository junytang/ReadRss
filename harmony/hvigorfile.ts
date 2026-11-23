import { appTasks } from '@ohos/hvigor-ohos-plugin';
import * as fs from 'fs';
import * as path from 'path';

/**
 * Bump the build number on every hvigor build (DevEco GUI and CLI both run this
 * config script). versionName stays 1.0.0; versionCode is used as the build
 * number and increments once per build.
 */
function bumpBuildNumber(): void {
  try {
    const appJsonPath: string = path.join(__dirname, 'AppScope', 'app.json5');
    let content: string = fs.readFileSync(appJsonPath, 'utf8');
    const match: RegExpMatchArray | null = content.match(/"versionCode"\s*:\s*(\d+)/);
    if (match !== null) {
      const next: number = parseInt(match[1], 10) + 1;
      content = content.replace(/"versionCode"\s*:\s*\d+/, `"versionCode": ${next}`);
      fs.writeFileSync(appJsonPath, content, 'utf8');
    }
  } catch (error) {
    // Never fail a build just because the counter could not be bumped.
  }
}

bumpBuildNumber();

export default {
  system: appTasks,
  plugins: [],
};
