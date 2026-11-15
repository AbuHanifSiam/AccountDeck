// Draws the tray glyph: the mascot alone — a round dark body with a light rim and two white eyes.
// Writes assets/tray-16.png, tray-32.png (and @2x-style 20/24/40 for high-DPI). Pure Node, no deps.
const fs = require('fs'), zlib = require('zlib'), path = require('path');
function crc32(buf) { let c, t = []; for (let n = 0; n < 256; n++) { c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; }
  let crc = 0xffffffff; for (const b of buf) crc = t[(crc ^ b) & 0xff] ^ (crc >>> 8); return (crc ^ 0xffffffff) >>> 0; }
function chunk(type, data) { const l = Buffer.alloc(4); l.writeUInt32BE(data.length); const td = Buffer.concat([Buffer.from(type), data]);
  const c = Buffer.alloc(4); c.writeUInt32BE(crc32(td)); return Buffer.concat([l, td, c]); }
function png(w, h, rgba) { const raw = Buffer.alloc((w * 4 + 1) * h); for (let y = 0; y < h; y++) { raw[y * (w * 4 + 1)] = 0; rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4); }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]); }
function draw(S) {
  const SS = 8, out = Buffer.alloc(S * S * 4);
  // shape in unit space [0,1]
  const body = { x: 0.5, y: 0.54, r: 0.44 }, rim = 0.06;
  const eyes = [{ x: 0.36, y: 0.46 }, { x: 0.64, y: 0.46 }], er = 0.105, pr = 0.05;
  for (let py = 0; py < S; py++) for (let px = 0; px < S; px++) {
    let acc = [0, 0, 0, 0];
    for (let sy = 0; sy < SS; sy++) for (let sx = 0; sx < SS; sx++) {
      const x = (px + (sx + 0.5) / SS) / S, y = (py + (sy + 0.5) / SS) / S;
      const d = Math.hypot(x - body.x, y - body.y);
      let c = null;
      if (d <= body.r) {
        c = d >= body.r - rim ? [235, 235, 235, 255] : [24, 24, 24, 255];
        for (const e of eyes) {
          const de = Math.hypot(x - e.x, y - e.y);
          if (de <= er) c = [255, 255, 255, 255];
          if (Math.hypot(x - (e.x + 0.02), y - (e.y + 0.015)) <= pr) c = [24, 24, 24, 255];
        }
      }
      if (c) { acc[0] += c[0]; acc[1] += c[1]; acc[2] += c[2]; acc[3] += c[3]; }
    }
    const n = SS * SS, a = acc[3] / n, i = (py * S + px) * 4;
    out[i + 3] = Math.round(a);
    if (a > 0) { out[i] = Math.round(acc[0] / n * 255 / a); out[i + 1] = Math.round(acc[1] / n * 255 / a); out[i + 2] = Math.round(acc[2] / n * 255 / a); }
  }
  return png(S, S, out);
}
const dir = path.join(__dirname, '..', 'assets');
for (const s of [16, 20, 24, 32, 40, 48]) fs.writeFileSync(path.join(dir, `tray-${s}.png`), draw(s));
console.log('tray icons written');
