// Developer-only: the Settings row icon (29/58/87 px) in the project icon's
// style — dark rounded card, the Chinese 。 ring, the English . dot.
// Rendered at 4x and box-downsampled, so the ring has clean antialiased edges.
// Writes base64 files that a shell `base64 -d` turns into Resources/icon*.png.

function render(S, SS) {
  var R = S * SS;
  var out = new Uint8Array(S * S * 4);
  var hi = new Uint8Array(R * R * 4);

  function put(x, y, r, g, b) {
    if (x < 0 || y < 0 || x >= R || y >= R) return;
    var i = (y * R + x) * 4;
    hi[i] = r;
    hi[i + 1] = g;
    hi[i + 2] = b;
    hi[i + 3] = 255;
  }

  function roundShape(x, y, x0, y0, x1, y1, r) {
    var cx = Math.min(Math.max(x, x0 + r), x1 - r);
    var cy = Math.min(Math.max(y, y0 + r), y1 - r);
    var dx = x - cx, dy = y - cy;
    return dx * dx + dy * dy <= r * r;
  }

  var pad = R * 0.01, radius = R * 0.24;
  for (var y = 0; y < R; y++) {
    for (var x = 0; x < R; x++) {
      if (roundShape(x, y, pad, pad, R - pad, R - pad, radius)) put(x, y, 20, 23, 28);
    }
  }

  // 。 ring on the left — thick enough to stay crisp at 29 pt.
  var cx = R * 0.35, cy = R * 0.5, outer = R * 0.25, inner = R * 0.12;
  for (var y2 = 0; y2 < R; y2++) {
    for (var x2 = 0; x2 < R; x2++) {
      var d = Math.sqrt((x2 - cx) * (x2 - cx) + (y2 - cy) * (y2 - cy));
      if (d <= outer && d >= inner) put(x2, y2, 242, 243, 245);
    }
  }

  // . dot on the right.
  var cx2 = R * 0.735, cy2 = R * 0.5, r2 = R * 0.105;
  for (var y3 = 0; y3 < R; y3++) {
    for (var x3 = 0; x3 < R; x3++) {
      var d2 = Math.sqrt((x3 - cx2) * (x3 - cx2) + (y3 - cy2) * (y3 - cy2));
      if (d2 <= r2) put(x3, y3, 88, 214, 141);
    }
  }

  // Box downsample, alpha-weighted.
  for (var oy = 0; oy < S; oy++) {
    for (var ox = 0; ox < S; ox++) {
      var r = 0, g = 0, b = 0, a = 0, n = 0;
      for (var sy = 0; sy < SS; sy++) {
        for (var sx = 0; sx < SS; sx++) {
          var i = ((oy * SS + sy) * R + (ox * SS + sx)) * 4;
          var al = hi[i + 3];
          r += hi[i] * al;
          g += hi[i + 1] * al;
          b += hi[i + 2] * al;
          a += al;
          n++;
        }
      }
      var o = (oy * S + ox) * 4;
      if (a > 0) {
        out[o] = Math.round(r / a);
        out[o + 1] = Math.round(g / a);
        out[o + 2] = Math.round(b / a);
        out[o + 3] = Math.round(a / n);
      }
    }
  }

  var crcTable = (function () {
    var t = new Int32Array(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var j = 0; j < 8; j++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      t[i] = c;
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
    return be32(data.length).concat(body, be32(crc32(new Uint8Array(body))));
  }

  var raw = [];
  for (var row = 0; row < S; row++) {
    raw.push(0);
    for (var col = 0; col < S; col++) {
      var idx = (row * S + col) * 4;
      raw.push(out[idx], out[idx + 1], out[idx + 2], out[idx + 3]);
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
  png = png.concat(chunk("IHDR", be32(S).concat(be32(S), [8, 6, 0, 0, 0])));
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
  return b64;
}

var sizes = [29, 58, 87];
var names = ["icon.b64", "icon2x.b64", "icon3x.b64"];
for (var i = 0; i < sizes.length; i++) {
  fs.write("tools/" + names[i], render(sizes[i], 4));
  console.log(names[i] + " " + sizes[i] + "px");
}
