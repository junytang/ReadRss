import { describe, it, expect, MockKit } from '@ohos/hypium';
import { GoogleReaderApi, ApiParams } from '../main/ets/rss/GoogleReaderApi';
import { FeverApi } from '../main/ets/rss/FeverApi';
import { FullContentFetcher } from '../main/ets/rss/FullContentFetcher';

// Interfaces to access private methods (ArkTS: use `as object as Interface`).
interface QueryAccess { queryString(p: ApiParams): string; }
interface FormAccess { formBody(p: ApiParams, withToken: boolean): string; }
interface AddParamAccess { addParam(parts: string[], key: string, value: string | undefined): void; }
interface CsvAccess { csv(value: string | undefined): string[]; }
interface CharsetAccess { charsetFrom(value: string): string; }
interface ClassIdAccess { classAndId(attrs: string): string; }
interface MaskAccess { maskScripts(html: string): string; }

export default function privateApiTest(): void {
  describe('GoogleReaderApi parameter builders', () => {
    it('addParam skips undefined/empty, encodes values', 0, () => {
      const api: GoogleReaderApi = new GoogleReaderApi('https://x', 'u', 'p');
      const mock: MockKit = new MockKit();
      mock.mockPrivateFunc(api, 'addParam');
      const a = api as object as AddParamAccess;
      const parts: string[] = [];
      a.addParam(parts, 's', 'feed/abc');
      a.addParam(parts, 'empty', '');
      a.addParam(parts, 'undef', undefined);
      expect(parts.length).assertEqual(1);
      expect(parts[0]).assertEqual('s=feed%2Fabc');
      mock.clear(api);
    });

    it('queryString always starts with output=json and includes params', 0, () => {
      const api: GoogleReaderApi = new GoogleReaderApi('https://x', 'u', 'p');
      const mock: MockKit = new MockKit();
      mock.mockPrivateFunc(api, 'queryString');
      const q = (api as object as QueryAccess).queryString({ s: 'feed/abc', n: '100', xt: 'read' });
      expect(q.indexOf('output=json')).assertEqual(0);
      expect(q.indexOf('s=feed%2Fabc') >= 0).assertTrue();
      expect(q.indexOf('n=100') >= 0).assertTrue();
      expect(q.indexOf('xt=read') >= 0).assertTrue();
      mock.clear(api);
    });

    it('formBody includes token only when requested', 0, () => {
      const api: GoogleReaderApi = new GoogleReaderApi('https://x', 'u', 'p');
      const mock: MockKit = new MockKit();
      mock.mockPrivateFunc(api, 'formBody');
      const f = api as object as FormAccess;
      const withoutToken: string = f.formBody({ output: 'json', s: 'x' }, false);
      expect(withoutToken.indexOf('T=') >= 0).assertFalse();
      const withToken: string = f.formBody({ output: 'json' }, true);
      expect(withToken.indexOf('T=') >= 0).assertTrue();
      mock.clear(api);
    });
  });

  describe('FeverApi.csv', () => {
    it('csv splits and filters empty parts', 0, () => {
      const api: FeverApi = new FeverApi('https://x', 'u', 'p');
      const mock: MockKit = new MockKit();
      mock.mockPrivateFunc(api, 'csv');
      const c = api as object as CsvAccess;
      expect(c.csv('1,2,3').length).assertEqual(3);
      expect(c.csv('1,,3,').length).assertEqual(2);
      expect(c.csv('').length).assertEqual(0);
      expect(c.csv(undefined).length).assertEqual(0);
      mock.clear(api);
    });
  });

  describe('FullContentFetcher pure helpers', () => {
    it('charsetFrom extracts charset case-insensitively', 0, () => {
      const mock: MockKit = new MockKit();
      mock.mockPrivateFunc(FullContentFetcher as object, 'charsetFrom');
      const cf = FullContentFetcher as object as CharsetAccess;
      expect(cf.charsetFrom('text/html; charset=UTF-8')).assertEqual('utf-8');
      expect(cf.charsetFrom('text/html; charset="GBK"')).assertEqual('gbk');
      expect(cf.charsetFrom('text/html')).assertEqual('');
      mock.clear(FullContentFetcher as object);
    });

    it('classAndId collects tokens lowercased', 0, () => {
      const mock: MockKit = new MockKit();
      mock.mockPrivateFunc(FullContentFetcher as object, 'classAndId');
      const ci = FullContentFetcher as object as ClassIdAccess;
      const r: string = ci.classAndId('class="Article Content" id="MainBody"');
      expect(r.indexOf('article') >= 0).assertTrue();
      expect(r.indexOf('content') >= 0).assertTrue();
      expect(r.indexOf('mainbody') >= 0).assertTrue();
      mock.clear(FullContentFetcher as object);
    });

    it('maskScripts blanks script/style preserving length', 0, () => {
      const mock: MockKit = new MockKit();
      mock.mockPrivateFunc(FullContentFetcher as object, 'maskScripts');
      const ms = FullContentFetcher as object as MaskAccess;
      const input: string = '<p>keep</p><script>var x="<div>";</script><p>tail</p>';
      const masked: string = ms.maskScripts(input);
      expect(masked.length).assertEqual(input.length);
      expect(masked.indexOf('var x') >= 0).assertFalse();
      expect(masked.indexOf('keep') >= 0).assertTrue();
      expect(masked.indexOf('tail') >= 0).assertTrue();
      mock.clear(FullContentFetcher as object);
    });
  });
}
