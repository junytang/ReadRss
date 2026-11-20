import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x5A17;
const TAG: string = 'ReadYou';

/** Thin wrapper around hilog so log calls stay readable in feature code. */
export class Logger {
  static info(message: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', message);
  }

  static warn(message: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', message);
  }

  static error(message: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', message);
  }

  static debug(message: string): void {
    hilog.debug(DOMAIN, TAG, '%{public}s', message);
  }
}
