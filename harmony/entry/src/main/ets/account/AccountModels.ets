import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer } from '@kit.ArkTS';

/** Mirrors AccountType in the Android app (id values 1..6). */
export enum AccountType {
  LOCAL = 1,
  FEVER = 2,
  GOOGLE_READER = 3,
  FRESH_RSS = 4,
  FEEDLY = 5,
  INOREADER = 6,
}

export interface Account {
  id: string;
  name: string;
  type: AccountType;
  securityKey: string;
  updateAt: number | null;
  lastArticleId: string | null;
  syncInterval: number;
  syncOnStart: boolean;
  syncOnlyOnWiFi: boolean;
  syncOnlyWhenCharging: boolean;
  keepArchived: number;
  syncBlockList: string;
}

export interface AccountSyncFields {
  syncInterval: number;
  syncOnStart: boolean;
  syncOnlyOnWiFi: boolean;
  syncOnlyWhenCharging: boolean;
  keepArchived: number;
  syncBlockList: string;
}

export function defaultAccountFields(): AccountSyncFields {
  const result: AccountSyncFields = {
    syncInterval: 30,
    syncOnStart: false,
    syncOnlyOnWiFi: false,
    syncOnlyWhenCharging: false,
    keepArchived: 2592000000,
    syncBlockList: '',
  };
  return result;
}

/** JSON shape shared by FeverSecurityKey / GoogleReaderSecurityKey / FreshRSSSecurityKey. */
export interface RemoteCredentials {
  serverUrl: string;
  username: string;
  password: string;
  clientCertificateAlias: string;
}

export function emptyCredentials(): RemoteCredentials {
  return { serverUrl: '', username: '', password: '', clientCertificateAlias: '' };
}

export function accountTypeName(type: AccountType): string {
  switch (type) {
    case AccountType.LOCAL: return 'Read You';
    case AccountType.FEVER: return 'Fever';
    case AccountType.GOOGLE_READER: return 'Google Reader';
    case AccountType.FRESH_RSS: return 'FreshRSS';
    case AccountType.FEEDLY: return 'Feedly';
    case AccountType.INOREADER: return 'Inoreader';
    default: return '未知';
  }
}

/** Short label used in page headers: "本地" instead of the product name. */
export function accountTypeShortName(type: AccountType): string {
  return type === AccountType.LOCAL ? '本地' : accountTypeName(type);
}

export function isValidAccountType(type: number): boolean {
  return type >= 1 && type <= 6;
}

export function usesLocalService(type: AccountType): boolean {
  return type === AccountType.LOCAL || type === AccountType.FEEDLY || type === AccountType.INOREADER;
}

// ----------------------------- ID conventions -----------------------------

export function dbId(accountId: string, remoteIdValue: string): string {
  return `${accountId}$${remoteIdValue}`;
}

/** Android: String.dollarLast() = split("$").last() */
export function remoteId(id: string): string {
  const index: number = id.lastIndexOf('$');
  return index < 0 ? id : id.substring(index + 1);
}

// --------------------------- credential codec -----------------------------

const SECRET: string = "mJn':4Nbk};AMVFGEWiY!(8&gp1xOv@/";
export const EMPTY_SECURITY_KEY: string = 'CvJ1PKM8EW8=';

function desKeyBytes(): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(8);
  for (let i = 0; i < 8; i++) {
    bytes[i] = SECRET.charCodeAt(i);
  }
  return bytes;
}

function toBytes(text: string): Uint8Array {
  return new Uint8Array(buffer.from(text, 'utf-8').buffer);
}

function fromBytes(bytes: Uint8Array): string {
  return buffer.from(bytes.buffer as ArrayBuffer, 0, bytes.byteLength).toString('utf-8');
}

export class CredentialCodec {
  private static key(): cryptoFramework.SymKey {
    const generator: cryptoFramework.SymKeyGenerator =
      cryptoFramework.createSymKeyGenerator('DES64');
    return generator.convertKeySync({ data: desKeyBytes() });
  }

  static encodeCredentials(credentials: RemoteCredentials): string {
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('DES64|ECB|PKCS7');
    cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, CredentialCodec.key(), null);
    const encrypted: cryptoFramework.DataBlob =
      cipher.doFinalSync({ data: toBytes(JSON.stringify(credentials)) });
    return buffer.from(encrypted.data.buffer as ArrayBuffer, 0, encrypted.data.byteLength)
      .toString('base64');
  }

  static decodeCredentials(value: string): RemoteCredentials {
    const source: string = value.length > 0 ? value : EMPTY_SECURITY_KEY;
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('DES64|ECB|PKCS7');
    cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, CredentialCodec.key(), null);
    const raw: Uint8Array = new Uint8Array(buffer.from(source, 'base64').buffer);
    const decrypted: cryptoFramework.DataBlob = cipher.doFinalSync({ data: raw });
    const parsed: RemoteCredentials = JSON.parse(fromBytes(decrypted.data)) as RemoteCredentials;
    return {
      serverUrl: parsed.serverUrl ?? '',
      username: parsed.username ?? '',
      password: parsed.password ?? '',
      clientCertificateAlias: parsed.clientCertificateAlias ?? '',
    };
  }

  static md5Hex(text: string): string {
    const md: cryptoFramework.Md = cryptoFramework.createMd('MD5');
    md.updateSync({ data: toBytes(text) });
    const digest: cryptoFramework.DataBlob = md.digestSync();
    let hex: string = '';
    for (const byte of digest.data) {
      hex += byte.toString(16).padStart(2, '0');
    }
    return hex;
  }
}

// ------------------------ GReader ID / stream helpers ----------------------

export const GR_PREFIX: string = 'tag:google.com,2005:reader/item/';

export function isLongItemId(id: string): boolean {
  return id.startsWith(GR_PREFIX) && id.substring(GR_PREFIX.length).length === 16;
}

function compareDecimalMagnitude(a: string, b: string): number {
  const left: string = a.replace(/^[+-]/, '').replace(/^0+/, '') || '0';
  const right: string = b.replace(/^[+-]/, '').replace(/^0+/, '') || '0';
  if (left.length !== right.length) return left.length < right.length ? -1 : 1;
  return left < right ? -1 : (left > right ? 1 : 0);
}

/** Mirrors Kotlin String.toLongOrNull(): accepts optional +/- and 64-bit range. */
export function isShortItemId(id: string): boolean {
  if (!/^[+-]?\d+$/.test(id)) return false;
  const positive: string = id.replace(/^[+-]/, '');
  return compareDecimalMagnitude(positive, '9223372036854775807') <= 0;
}

export function isValidItemId(id: string): boolean {
  return isLongItemId(id) || isShortItemId(id);
}

function decimalMultiplyAdd(value: string, multiplier: number, addend: number): string {
  let carry: number = addend;
  let result: string = '';
  for (let i = value.length - 1; i >= 0; i--) {
    const current: number = (value.charCodeAt(i) - 48) * multiplier + carry;
    result = String.fromCharCode(48 + (current % 10)) + result;
    carry = Math.floor(current / 10);
  }
  while (carry > 0) {
    result = String.fromCharCode(48 + (carry % 10)) + result;
    carry = Math.floor(carry / 10);
  }
  return result;
}

function decimalSubtract(a: string, b: string): string {
  let i: number = a.length - 1;
  let j: number = b.length - 1;
  let borrow: number = 0;
  let result: string = '';
  while (i >= 0) {
    let digit: number = a.charCodeAt(i) - 48 - borrow - (j >= 0 ? b.charCodeAt(j) - 48 : 0);
    if (digit < 0) {
      digit += 10;
      borrow = 1;
    } else {
      borrow = 0;
    }
    result = String.fromCharCode(48 + digit) + result;
    i--;
    j--;
  }
  const trimmed: string = result.replace(/^0+/, '');
  return trimmed.length === 0 ? '0' : trimmed;
}

/** Signed 64-bit hex → decimal, matching Kotlin hexToLong().toString() without BigInt. */
export function hexToSignedDecimal(hex: string): string {
  let unsigned: string = '0';
  for (let i = 0; i < hex.length; i++) {
    unsigned = decimalMultiplyAdd(unsigned, 16, parseInt(hex.charAt(i), 16));
  }
  if (hex.length === 16 && parseInt(hex.charAt(0), 16) >= 8) {
    let power: string = '1';
    for (let i = 0; i < 64; i++) {
      power = decimalMultiplyAdd(power, 2, 0);
    }
    return `-${decimalSubtract(power, unsigned)}`;
  }
  return unsigned;
}

export function shortItemId(id: string): string {
  if (!isLongItemId(id)) {
    return id;
  }
  return hexToSignedDecimal(id.substring(GR_PREFIX.length));
}

export function feedStreamId(feedId: string): string {
  return `feed/${feedId}`;
}

export function feedIdFromStreamId(streamId: string): string {
  return streamId.replace('feed/', '');
}

export function categoryStreamId(categoryId: string): string {
  return `user/-/label/${categoryId}`;
}

/** Android regex is unanchored: "user/[^/]+/label/".toRegex() */
export function categoryIdFromStreamId(streamId: string): string {
  return streamId.replace(/user\/[^/]+\/label\//, '');
}
