import { describe, it, expect } from '@ohos/hypium';
import {
  dbId, remoteId, isLongItemId, isShortItemId, isValidItemId, shortItemId,
  hexToSignedDecimal, feedStreamId, feedIdFromStreamId,
  categoryStreamId, categoryIdFromStreamId,
  accountTypeName, accountTypeShortName, usesLocalService, isValidAccountType,
  defaultAccountFields, AccountType,
} from '../main/ets/account/AccountModels';

export default function modelTest(): void {
  describe('AccountModels id helpers', () => {
    it('dbId and remoteId are inverse for normal ids', 0, () => {
      const remote: string = '123456789';
      expect(remoteId(dbId('acc1', remote))).assertEqual(remote);
    });

    it('dbId prefixes with account id', 0, () => {
      expect(dbId('acc1', 'abc')).assertEqual('acc1$abc');
    });

    it('remoteId strips account prefix', 0, () => {
      expect(remoteId('acc1$abc')).assertEqual('abc');
      expect(remoteId('abc')).assertEqual('abc');
    });
  });

  describe('GReader item id helpers', () => {
    it('classifies long and short ids', 0, () => {
      expect(isLongItemId('tag:google.com,2005:reader/item/0000000000000001')).assertTrue();
      expect(isShortItemId('1')).assertTrue();
      expect(isShortItemId('abc')).assertFalse();
    });

    it('shortItemId converts long hex id to decimal', 0, () => {
      const short: string = shortItemId('tag:google.com,2005:reader/item/0000000000000001');
      expect(short).assertEqual('1');
    });

    it('isValidItemId accepts known forms', 0, () => {
      expect(isValidItemId('1')).assertTrue();
      expect(isValidItemId('tag:google.com,2005:reader/item/0000000000000001')).assertTrue();
      expect(isValidItemId('')).assertFalse();
    });

    it('hexToSignedDecimal handles zero and small values', 0, () => {
      expect(hexToSignedDecimal('0000000000000000')).assertEqual('0');
      expect(hexToSignedDecimal('0000000000000001')).assertEqual('1');
      expect(hexToSignedDecimal('000000000000000a')).assertEqual('10');
      expect(hexToSignedDecimal('00000000000000ff')).assertEqual('255');
    });

    it('shortItemId returns short ids unchanged', 0, () => {
      expect(shortItemId('12345')).assertEqual('12345');
    });
  });

  describe('Stream id helpers', () => {
    it('feedStreamId and feedIdFromStreamId are inverse', 0, () => {
      const stream: string = feedStreamId('abc');
      expect(stream).assertEqual('feed/abc');
      expect(feedIdFromStreamId(stream)).assertEqual('abc');
    });

    it('categoryStreamId and categoryIdFromStreamId are inverse', 0, () => {
      const stream: string = categoryStreamId('tech');
      expect(stream).assertEqual('user/-/label/tech');
      expect(categoryIdFromStreamId(stream)).assertEqual('tech');
    });

    it('extracts feed id from full GReader stream url', 0, () => {
      const stream: string = 'feed/http://example.com/rss';
      expect(feedIdFromStreamId(stream)).assertEqual('http://example.com/rss');
    });
  });

  describe('Account type helpers', () => {
    it('maps type names', 0, () => {
      expect(accountTypeName(AccountType.FEVER)).assertEqual('Fever');
      expect(accountTypeName(AccountType.GOOGLE_READER)).assertEqual('Google Reader');
      expect(accountTypeName(AccountType.MINIFLUX)).assertEqual('Miniflux');
    });

    it('local service detection', 0, () => {
      expect(usesLocalService(AccountType.LOCAL)).assertTrue();
      expect(usesLocalService(AccountType.FEEDLY)).assertTrue();
      expect(usesLocalService(AccountType.FEVER)).assertFalse();
      expect(usesLocalService(AccountType.MINIFLUX)).assertFalse();
    });

    it('valid account type range', 0, () => {
      expect(isValidAccountType(AccountType.GOOGLE_READER)).assertTrue();
      expect(isValidAccountType(AccountType.MINIFLUX)).assertTrue();
      expect(isValidAccountType(0)).assertFalse();
      expect(isValidAccountType(999)).assertFalse();
    });

    it('accountTypeShortName uses 本地 for local', 0, () => {
      expect(accountTypeShortName(AccountType.LOCAL)).assertEqual('本地');
      expect(accountTypeShortName(AccountType.FEVER)).assertEqual('Fever');
    });

    it('defaultAccountFields returns all fields', 0, () => {
      const f = defaultAccountFields();
      expect(f.syncInterval).assertEqual(30);
    });
  });
}
