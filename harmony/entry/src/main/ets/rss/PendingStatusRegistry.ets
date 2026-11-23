/**
 * Article ids with locally-pending read/star changes that have not yet reached
 * the server. Sync reconciliation must NOT overwrite these with stale server
 * state (the Android pendingSyncDiffs semantics). Kept in its own module so the
 * batcher and the sync services do not import each other (cycles).
 */
class PendingStatusRegistry {
  private ids: Set<string> = new Set<string>();

  add(id: string): void {
    this.ids.add(id);
  }

  remove(id: string): void {
    this.ids.delete(id);
  }

  has(id: string): boolean {
    return this.ids.has(id);
  }
}

export const pendingStatusRegistry: PendingStatusRegistry = new PendingStatusRegistry();
