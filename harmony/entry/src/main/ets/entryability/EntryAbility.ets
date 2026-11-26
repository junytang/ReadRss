import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { database } from '../data/Database';
import { settingsStore } from '../data/SettingsStore';
import { accountRepository } from '../account/AccountRepository';
import { rssRepository } from '../rss/RssRepository';
import { readStatusStore } from '../rss/ReadStatusStore';
import { gReaderTokenStore } from '../rss/GReaderTokenStore';
import { FILTER_UNREAD } from '../common/Constants';
import { Logger } from '../common/Logger';
import { WindowInsets } from '../common/WindowInsets';

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;
  private avoidAreaCallback?: () => void;

  /** Convert physical pixels to vp using the standard display density API. */
  private pxToVp(px: number): number {
    try {
      const density: number = display.getDefaultDisplaySync().densityDPI / 160;
      return density > 0 ? px / density : px;
    } catch (error) {
      Logger.warn(`Display density unavailable: ${(error as Error).message}`);
      return px;
    }
  }

  /** Read the real system-safe-area insets and publish them to the UI. */
  private applySafeArea(win: window.Window): void {
    let top: number = 0;
    let bottom: number = 0;
    try {
      const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      top = this.pxToVp(area.topRect.height);
      bottom = this.pxToVp(area.bottomRect.height);
    } catch (error) {
      Logger.warn(`Avoid area unavailable: ${(error as Error).message}`);
    }
    // Some devices report zero avoid areas; fall back to typical system-bar sizes.
    WindowInsets.top = top > 0 ? top : 28;
    WindowInsets.bottom = bottom > 0 ? bottom : 16;
    AppStorage.setOrCreate<number>('topInset', WindowInsets.top);
    AppStorage.setOrCreate<number>('bottomInset', WindowInsets.bottom);
    // Publish the usable window height so the article list can size its first
    // batch to roughly two screens instead of a hard-coded row count.
    try {
      const heightVp: number = this.pxToVp(win.getWindowProperties().windowRect.height);
      const published: number = heightVp > 0 ? heightVp : 800;
      WindowInsets.height = published;
      AppStorage.setOrCreate<number>('windowHeightVp', published);
    } catch (error) {
      Logger.warn(`window height unavailable: ${(error as Error).message}`);
      AppStorage.setOrCreate<number>('windowHeightVp', 800);
    }
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
        // System-bar tinting is not available on every device form factor
        // (e.g. 2in1); the transparent full-screen layout works without it.
        try {
          if (canIUse('SystemCapability.WindowManager.WindowManager.Core')) {
            await win.setWindowSystemBarProperties({
              statusBarColor: '#00000000',
              navigationBarColor: '#00000000',
              statusBarContentColor: '#FF1A1C1E',
            } as window.SystemBarProperties);
          }
        } catch (error) {
          Logger.warn(`setWindowSystemBarProperties skipped: ${(error as Error).message}`);
        }
        this.mainWindow = win;
        this.avoidAreaCallback = (): void => this.applySafeArea(win);
        win.on('avoidAreaChange', this.avoidAreaCallback);
      })
      .catch((error: Error) => {
        Logger.error(`Window setup failed: ${error.message}`);
      });

    // Only the data needed for the first frame blocks loadContent. Token
    // stores, pending-mark caches, cleanup and network sync start afterwards.
    const context = this.context;
    const uiReady: Promise<void> = database.init(context)
      .then(() => settingsStore.init(context))
      // Pending read/star diffs must be restored BEFORE the first list query:
      // the list uses them both for row projection and for pending-filter IDs.
      .then(() => readStatusStore.init(context))
      .then(async () => {
        // Apply the persisted color mode BEFORE loadContent. Calling setColorMode
        // after the UI starts building triggers a global config change that
        // re-lays out every Text component, visible as a one-frame font jitter.
        try {
          context.getApplicationContext().setColorMode(
            settingsStore.get().darkMode
              ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
              : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
          );
        } catch (error) {
          Logger.warn(`setColorMode skipped: ${(error as Error).message}`);
        }
        await accountRepository.ensureDefault();
        AppStorage.setOrCreate<boolean>('darkMode', settingsStore.get().darkMode);
        AppStorage.setOrCreate<string>('activeAccountId', settingsStore.get().activeAccountId);
        AppStorage.setOrCreate<number>(
          'firstRunTick', accountRepository.isFirstRun() ? Date.now() : 0
        );
        AppStorage.set<string>('currentFilter', FILTER_UNREAD);
      });

    const finishDeferredInit = async (): Promise<void> => {
      await gReaderTokenStore.init(context);
      AppStorage.setOrCreate<number>('accountSwitchTick', 0);
      AppStorage.setOrCreate<number>('feedDataTick', 0);
      AppStorage.setOrCreate<number>('syncFirstBatchTick', 0);
      AppStorage.setOrCreate<number>('syncFinishedTick', 0);
      AppStorage.setOrCreate<number>('navBackTick', 0);
      AppStorage.setOrCreate<number>('fontDataTick', 0);
      AppStorage.setOrCreate<number>('listSettingsTick', 0);
      AppStorage.setOrCreate<number>('readStatusTick', 0);
      AppStorage.setOrCreate<number>('readStatusFlushedTick', 0);
      AppStorage.setOrCreate<number>('feedIconTick', 0);
      rssRepository.cleanExpiredArticles(settingsStore.get().keepArticleDays)
        .catch((error: Error) => {
          Logger.error(`Article cleanup failed: ${error.message}`);
        });
      // 首装不再自动创建账号；没有账号时由引导页让用户添加后再同步。
      if (!accountRepository.isFirstRun() && settingsStore.get().syncOnLaunch) {
        rssRepository.syncAll().catch((error: Error) => {
          Logger.error(`Startup sync failed: ${error.message}`);
        });
      }
    };

    Promise.all([windowReady, uiReady]).then(() => {
      // Note: the custom font is registered in Index.aboutToAppear using the
      // page's own UIContext. Registering here via the window's UIContext (before
      // loadContent) has no bound page yet and the registration is discarded.
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          Logger.error(`loadContent failed: ${err.code} ${err.message}`);
        } else {
          Logger.info('loadContent succeeded');
          finishDeferredInit().catch((error: Error) => {
            Logger.error(`deferred init failed: ${error.message}`);
          });
        }
      });
    }).catch((error: Error) => {
      Logger.error(`init failed: ${error.message}`);
      windowStage.loadContent('pages/Index', () => {});
    });
  }

  onWindowStageDestroy(): void {
    if (this.mainWindow !== undefined && this.avoidAreaCallback !== undefined) {
      this.mainWindow.off('avoidAreaChange', this.avoidAreaCallback);
    }
    this.mainWindow = undefined;
    this.avoidAreaCallback = undefined;
    Logger.info('EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    Logger.info('EntryAbility onForeground');
  }

  onBackground(): void {
    Logger.info('EntryAbility onBackground');
  }
}
