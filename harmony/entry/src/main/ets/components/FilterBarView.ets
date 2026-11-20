import { HdsTabs, hdsMaterial } from '@kit.UIDesignKit';
import { FILTER_ALL, FILTER_STARRED, FILTER_UNREAD } from '../common/Constants';

interface FilterTab {
  key: string;
  label: string;
  icon: Resource;
}

// Unread first so HdsTabs' default selected index (0) is the Android default filter.
const FILTER_TABS: FilterTab[] = [
  { key: FILTER_UNREAD, label: '未读', icon: $r('app.media.ic_filter_unread') },
  { key: FILTER_STARRED, label: '星标', icon: $r('app.media.ic_filter_star') },
  { key: FILTER_ALL, label: '全部', icon: $r('app.media.ic_filter_all') },
];

/** HarmonyOS 7 native floating bottom tab bar (HdsTabs + barFloatingStyle). */
@Component
export struct FilterBarView {
  @StorageProp('bottomInset') bottomInset: number = 0;
  onFilterChange: (filter: string) => void = () => {};

  build() {
    HdsTabs() {
      TabContent() {
        Column().width('100%').height(1)
      }
      .tabBar(new BottomTabBarStyle(FILTER_TABS[0].icon, FILTER_TABS[0].label))

      TabContent() {
        Column().width('100%').height(1)
      }
      .tabBar(new BottomTabBarStyle(FILTER_TABS[1].icon, FILTER_TABS[1].label))

      TabContent() {
        Column().width('100%').height(1)
      }
      .tabBar(new BottomTabBarStyle(FILTER_TABS[2].icon, FILTER_TABS[2].label))
    }
    .barOverlap(true)
    .barPosition(BarPosition.End)
    .vertical(false)
    .scrollable(false)
    .barFloatingStyle({
      barBottomMargin: 64,

      // System immersive material: adapts to system color/appearance settings.
      // gradientMask and animation parameters are intentionally left at system defaults.
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
      },
    })
    .onChange((index: number) => {
      if (index >= 0 && index < FILTER_TABS.length) {
        this.onFilterChange(FILTER_TABS[index].key);
      }
    })
    // Enough room for the floating capsule; empty area must not block page touches.
    .height(144)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
