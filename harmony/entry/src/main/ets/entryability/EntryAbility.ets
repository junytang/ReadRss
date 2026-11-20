import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { database } from '../data/Database';
import { settingsStore } from '../data/SettingsStore';
import { accountRepository } from '../account/AccountRepository';
import { rssRepository } from '../rss/RssRepository';
import { gReaderTokenStore } from '../rss/GReaderTokenStore';
import { FILTER_UNREAD, fontScaleForIndex } from '../common/Constants';
import { Logger } from '../common/Logger';
import { WindowInsets } from '../common/WindowInsets';

export default class EntryAbility extends UIAbility {
  /** Convert physical pixels to vp using the standard display density API. */
  private pxToVp(px: number): number {
    const density: number = display.getDefaultDisplaySync().densityDPI / 160;
    return density > 0 ? px / density : px;
  }

  /** Read the real system-safe-area insets and publish them to the UI. */
  private applySafeArea(win: window.Window): void {
    const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const top: number = this.pxToVp(area.topRect.height);
    const bottom: number = this.pxToVp(area.bottomRect.height);
    // Some devices report zero avoid areas; fall back to typical system-bar sizes.
    WindowInsets.top = top > 0 ? top : 28;
    WindowInsets.bottom = bottom > 0 ? bottom : 16;
    AppStorage.set<number>('topInset', WindowInsets.top);
    AppStorage.set<number>('bottomInset', WindowInsets.bottom);
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info('EntryAbility onCreate');
  }

  onDestroy(): void {
    Logger.info('EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Standard edge-to-edge setup: full-screen window + transparent system bars.
    // Pages consume the system-provided safe-area insets via AppStorage.
    const windowReady: Promise<void> = windowStage.getMainWindow()
      .then(async (win: window.Window) => {
        // Read safe-area before full-screen, then go edge-to-edge. Pages offset
        // their headers by these system-provided values.
        this.applySafeArea(win);
        // Set the color before full-screen: some ROMs reject it in full-screen state.
        try {
          await win.setWindowBackgroundColor('#00000000');
        } catch (error) {
          Logger.warn(`setWindowBackgroundColor skipped: ${(error as Error).message}`);
        }
        await win.setWindowLayoutFullScreen(true);
        try {
          await win.setWindowSystemBarProperties({
            statusBarColor: '#00000000',
            navigationBarColor: '#00000000',
            statusBarContentColor: '#FF1A1C1E',
          } as window.SystemBarProperties);
        } catch (error) {
          Logger.warn(`setWindowSystemBarProperties skipped: ${(error as Error).message}`);
        }
        win.on('avoidAreaChange', () => this.applySafeArea(win));
      })
      .catch((error: Error) => {
        Logger.error(`Window setup failed: ${error.message}`);
      });

    // Initialise persistence before loading UI so pages can read data immediately.
    const context = this.context;
    const dataReady: Promise<void> = database.init(context)
      .then(() => settingsStore.init(context))
      .then(() => gReaderTokenStore.init(context))
      .then(async () => {
        await accountRepository.ensureDefault();
        // Startup retention cleanup (non-blocking for UI).
        rssRepository.cleanExpiredArticles(settingsStore.get().keepArticleDays)
          .catch((error: Error) => {
            Logger.error(`Article cleanup failed: ${error.message}`);
          });
        if (accountRepository.isFirstRun()) {
          // Android enqueues a one-time WorkManager job; never block UI loading on it.
          rssRepository.syncAll().catch((error: Error) => {
            Logger.error(`Initial sync failed: ${error.message}`);
          });
        }
        AppStorage.setOrCreate<boolean>('darkMode', settingsStore.get().darkMode);
        AppStorage.setOrCreate<string>('activeAccountId', settingsStore.get().activeAccountId);
        AppStorage.setOrCreate<number>('accountSwitchTick', 0);
        AppStorage.setOrCreate<number>('feedDataTick', 0);
        AppStorage.setOrCreate<number>('syncFirstBatchTick', 0);
        AppStorage.setOrCreate<number>('syncFinishedTick', 0);
        AppStorage.setOrCreate<number>('navBackTick', 0);
        AppStorage.setOrCreate<number>('fontDataTick', 0);
        AppStorage.setOrCreate<number>('readStatusTick', 0);
        AppStorage.setOrCreate<number>('feedIconTick', 0);
        AppStorage.setOrCreate<string>('lastChangedArticle', '');
        AppStorage.setOrCreate<number>('fontScale',
          fontScaleForIndex(settingsStore.get().fontSizeIndex));
        AppStorage.set<string>('currentFilter', FILTER_UNREAD);
        context.getApplicationContext().setFontSizeScale(
          fontScaleForIndex(settingsStore.get().fontSizeIndex)
        );
      });

    Promise.all([windowReady, dataReady]).then(() => {
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          Logger.error(`loadContent failed: ${err.code} ${err.message}`);
        } else {
          Logger.info('loadContent succeeded');
        }
      });
    }).catch((error: Error) => {
      Logger.error(`init failed: ${error.message}`);
      windowStage.loadContent('pages/Index', () => {});
    });
  }

  onWindowStageDestroy(): void {
    Logger.info('EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    Logger.info('EntryAbility onForeground');
  }

  onBackground(): void {
    Logger.info('EntryAbility onBackground');
  }
}
