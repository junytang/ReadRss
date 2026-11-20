import { Account, AccountType } from '../account/AccountModels';
import { FeedSyncService } from './SyncService';
import { LocalSyncService } from './LocalSyncService';
import { FeverSyncService } from './FeverSyncService';
import { GoogleReaderSyncService } from './GoogleReaderSyncService';

const local: LocalSyncService = new LocalSyncService();
const fever: FeverSyncService = new FeverSyncService();
const googleReader: GoogleReaderSyncService = new GoogleReaderSyncService();

/** Mirrors Android's RssService: type → implementation. */
export function syncServiceFor(account: Account): FeedSyncService {
  switch (account.type) {
    case AccountType.FEVER:
      return fever;
    case AccountType.GOOGLE_READER:
    case AccountType.FRESH_RSS:
      return googleReader;
    case AccountType.FEEDLY:
    case AccountType.INOREADER:
    case AccountType.LOCAL:
    default:
      return local;
  }
}
