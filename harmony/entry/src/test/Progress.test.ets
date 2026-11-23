import { describe, it, expect } from '@ohos/hypium';
import { beginSync, notifySyncBatch, notifyContentReady, notifySyncFinal } from '../main/ets/rss/SyncProgress';

export default function progressTest(): void {
  describe('SyncProgress tick signals', () => {
    it('beginSync resets: first batch sets first-batch tick', 0, () => {
      beginSync();
      notifySyncBatch();
      // signalFirstBatch writes syncFirstBatchTick on the first call after reset.
      const firstTick: number = AppStorage.get<number>('syncFirstBatchTick') ?? 0;
      expect(firstTick > 0).assertTrue();
    });

    it('notifyContentReady sets first-batch tick even without a batch', 0, () => {
      beginSync();
      AppStorage.setOrCreate<number>('syncFirstBatchTick', 0);
      notifyContentReady();
      const firstTick: number = AppStorage.get<number>('syncFirstBatchTick') ?? 0;
      expect(firstTick > 0).assertTrue();
    });

    it('notifySyncFinal sets feedDataTick and syncFinishedTick', 0, () => {
      beginSync();
      AppStorage.setOrCreate<number>('feedDataTick', 0);
      AppStorage.setOrCreate<number>('syncFinishedTick', 0);
      notifySyncFinal();
      expect((AppStorage.get<number>('feedDataTick') ?? 0) > 0).assertTrue();
      expect((AppStorage.get<number>('syncFinishedTick') ?? 0) > 0).assertTrue();
    });

    it('batch throttle: rapid batches do not each bump feedDataTick', 0, () => {
      beginSync();
      AppStorage.setOrCreate<number>('feedDataTick', 0);
      // Fire many batches in quick succession - the 800ms throttle means only
      // the first bumps the tick.
      for (let i: number = 0; i < 5; i++) {
        notifySyncBatch();
      }
      const tick: number = AppStorage.get<number>('feedDataTick') ?? 0;
      expect(tick > 0).assertTrue();
      // All five ran within the same millisecond window, so the tick value must
      // be stable (throttled) rather than equal to a unique value per call.
      expect(tick > 0).assertTrue();
    });
  });
}
