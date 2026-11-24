/**
 * Pure TypeScript MD5 (RFC 1321), UTF-8 input, lowercase hex output.
 *
 * The Fever API key is md5(username:password). Using cryptoFramework for this
 * tied the key to a device syscap and was observably empty in constrained
 * runtimes, producing "Forbidden (400)" from Fever-compatible servers. MD5 here
 * is a pure algorithm with no platform dependency, so the key is always valid.
 */

function rotl(value: number, shift: number): number {
  return ((value << shift) | (value >>> (32 - shift))) >>> 0;
}

function utf8Bytes(text: string): number[] {
  const bytes: number[] = [];
  for (let i = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (code < 0x80) {
      bytes.push(code);
    } else if (code < 0x800) {
      bytes.push(0xC0 | (code >> 6), 0x80 | (code & 0x3F));
    } else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
      const next: number = text.charCodeAt(i + 1);
      const cp: number = 0x10000 + ((code - 0xD800) << 10) + (next - 0xDC00);
      i++;
      bytes.push(
        0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
        0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)
      );
    } else {
      bytes.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
    }
  }
  return bytes;
}

export function md5Hex(text: string): string {
  const bytes: number[] = utf8Bytes(text);
  const bitLength: number = bytes.length * 8;
  bytes.push(0x80);
  while (bytes.length % 64 !== 56) {
    bytes.push(0);
  }
  const low: number = bitLength >>> 0;
  const high: number = Math.floor(bitLength / 0x100000000) >>> 0;
  for (let i = 0; i < 4; i++) {
    bytes.push((low >>> (i * 8)) & 0xFF);
  }
  for (let i = 0; i < 4; i++) {
    bytes.push((high >>> (i * 8)) & 0xFF);
  }

  const shift: number[] = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  ];
  const table: number[] = [];
  for (let i = 0; i < 64; i++) {
    table.push(Math.floor(Math.abs(Math.sin(i + 1)) * 0x100000000) >>> 0);
  }

  let a0: number = 0x67452301;
  let b0: number = 0xEFCDAB89;
  let c0: number = 0x98BADCFE;
  let d0: number = 0x10325476;
  const m: number[] = new Array<number>(16);
  for (let offset = 0; offset < bytes.length; offset += 64) {
    for (let i = 0; i < 16; i++) {
      const j: number = offset + i * 4;
      m[i] = (bytes[j] | (bytes[j + 1] << 8) | (bytes[j + 2] << 16) | (bytes[j + 3] << 24)) >>> 0;
    }
    let a: number = a0;
    let b: number = b0;
    let c: number = c0;
    let d: number = d0;
    for (let i = 0; i < 64; i++) {
      let f: number = 0;
      let g: number = 0;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) % 16;
      }
      const previousD: number = d;
      d = c;
      c = b;
      b = (b + rotl((a + f + table[i] + m[g]) >>> 0, shift[i])) >>> 0;
      a = previousD;
    }
    a0 = (a0 + a) >>> 0;
    b0 = (b0 + b) >>> 0;
    c0 = (c0 + c) >>> 0;
    d0 = (d0 + d) >>> 0;
  }

  const result: number[] = [a0, b0, c0, d0];
  let hex: string = '';
  for (const word of result) {
    for (let i = 0; i < 4; i++) {
      hex += ((word >>> (i * 8)) & 0xFF).toString(16).padStart(2, '0');
    }
  }
  return hex;
}
