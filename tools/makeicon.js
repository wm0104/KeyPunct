// Developer-only: draws the project icon (512x512 PNG) and writes it as base64
// to tools/icon.b64, so a shell `base64 -d` can turn it into apelin-icon.png.
// No image library on the device, so the PNG is written by hand with stored
// (uncompressed) deflate blocks.

var W = 512, H = 512;
var rgba = new Uint8Array(W * H * 4);

function put(x, y, r, g, b, a) {
  if (x < 0 || y < 0 || x >= W || y >= H) return;
  var i = (y * W + x) * 4;
  var sa = a / 255;
  var da = rgba[i + 3] / 255;
  var oa = sa + da * (1 - sa);
  if (oa <= 0) return;
  rgba[i] = Math.round((r * sa + rgba[i] * da * (1 - sa)) / oa);
  rgba[i + 1] = Math.round((g * sa + rgba[i + 1] * da * (1 - sa)) / oa);
  rgba[i + 2] = Math.round((b * sa + rgba[i + 2] * da * (1 - sa)) / oa);
  rgba[i + 3] = Math.round(oa * 255);
}

function roundShape(x, y, x0, y0, x1, y1, r) {
  var cx = Math.min(Math.max(x, x0 + r), x1 - r);
  var cy = Math.min(Math.max(y, y0 + r), y1 - r);
  var dx = x - cx, dy = y - cy;
  return dx * dx + dy * dy <= r * r;
}

// Card background.
for (var y = 0; y < H; y++) {
  for (var x = 0; x < W; x++) {
    if (roundShape(x, y, 24, 24, 487, 487, 112)) put(x, y, 20, 23, 28, 255);
  }
}

// Three keyboard keys along the bottom.
var keys = [[92, 344], [208, 344], [324, 344]];
for (var k = 0; k < keys.length; k++) {
  for (var yy = keys[k][1]; yy < keys[k][1] + 80; yy++) {
    for (var xx = keys[k][0]; xx < keys[k][0] + 96; xx++) {
      if (roundShape(xx, yy, keys[k][0], keys[k][1], keys[k][0] + 95, keys[k][1] + 79, 20)) {
        put(xx, yy, 44, 50, 60, 255);
      }
    }
  }
}

// Chinese 。 on the left: a ring.
var cx = 172, cy = 200, outer = 84, inner = 60;
for (var y2 = cy - outer; y2 <= cy + outer; y2++) {
  for (var x2 = cx - outer; x2 <= cx + outer; x2++) {
    var d = Math.sqrt((x2 - cx) * (x2 - cx) + (y2 - cy) * (y2 - cy));
    if (d <= outer && d >= inner) put(x2, y2, 242, 243, 245, 255);
  }
}

// English . on the right: a filled dot.
var cx2 = 352, cy2 = 200, radius = 30;
for (var y3 = cy2 - radius; y3 <= cy2 + radius; y3++) {
  for (var x3 = cx2 - radius; x3 <= cx2 + radius; x3++) {
    var d2 = Math.sqrt((x3 - cx2) * (x3 - cx2) + (y3 - cy2) * (y3 - cy2));
    if (d2 <= radius) put(x3, y3, 242, 243, 245, 255);
  }
}

// Arrow between them, in the accent green.
for (var i = 0; i < 26; i++) {
  for (var t = -2; t <= 2; t++) put(252 + i, 200 + t, 88, 214, 141, 255);
}
for (var i2 = 0; i2 < 12; i2++) {
  for (var t2 = -i2; t2 <= i2; t2++) put(278 - i2, 200 + t2, 88, 214, 141, 255);
}

// ---- PNG ----
var crcTable = (function () {
  var t = new Int32Array(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var j = 0; j < 8; j++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c;
  }
  return t;
})();

function crc32(bytes) {
  var c = 0xFFFFFFFF;
  for (var i = 0; i < bytes.length; i++) c = crcTable[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}

function adler32(bytes) {
  var a = 1, b = 0;
  for (var i = 0; i < bytes.length; i++) {
    a = (a + bytes[i]) % 65521;
    b = (b + a) % 65521;
  }
  return ((b << 16) | a) >>> 0;
}

function be32(v) {
  return [(v >>> 24) & 255, (v >>> 16) & 255, (v >>> 8) & 255, v & 255];
}

function chunk(type, data) {
  var body = [];
  for (var i = 0; i < type.length; i++) body.push(type.charCodeAt(i));
  for (var j = 0; j < data.length; j++) body.push(data[j]);
  var out = be32(data.length).concat(body);
  var crc = crc32(new Uint8Array(body));
  return out.concat(be32(crc));
}

var raw = [];
for (var row = 0; row < H; row++) {
  raw.push(0);
  for (var col = 0; col < W; col++) {
    var idx = (row * W + col) * 4;
    raw.push(rgba[idx], rgba[idx + 1], rgba[idx + 2], rgba[idx + 3]);
  }
}

var z = [0x78, 0x01];
var pos = 0;
while (pos < raw.length) {
  var len = Math.min(65535, raw.length - pos);
  var final = (pos + len >= raw.length) ? 1 : 0;
  z.push(final, len & 255, (len >> 8) & 255, (~len) & 255, ((~len) >> 8) & 255);
  for (var q = 0; q < len; q++) z.push(raw[pos + q]);
  pos += len;
}
var ad = adler32(raw);
z.push((ad >>> 24) & 255, (ad >>> 16) & 255, (ad >>> 8) & 255, ad & 255);

var png = [137, 80, 78, 71, 13, 10, 26, 10];
png = png.concat(chunk("IHDR", be32(W).concat(be32(H), [8, 6, 0, 0, 0])));
png = png.concat(chunk("IDAT", z));
png = png.concat(chunk("IEND", []));

var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
var b64 = "";
for (var p = 0; p < png.length; p += 3) {
  var b1 = png[p], b2 = (p + 1 < png.length) ? png[p + 1] : 0, b3 = (p + 2 < png.length) ? png[p + 2] : 0;
  b64 += alphabet[b1 >> 2];
  b64 += alphabet[((b1 & 3) << 4) | (b2 >> 4)];
  b64 += (p + 1 < png.length) ? alphabet[((b2 & 15) << 2) | (b3 >> 6)] : "=";
  b64 += (p + 2 < png.length) ? alphabet[b3 & 63] : "=";
}

fs.write("tools/icon.b64", b64);
console.log("png bytes " + png.length + ", base64 " + b64.length);
