// Developer-only. Run from the project root: icli probe tools/roundicons.js
// Preserve the existing icon artwork; add a transparent, antialiased rounded
// mask at a 9-point radius on the Settings row's 29-point canvas.
// No screen access, UIKit rendering or changes outside this project.
(function () {
    'use strict';
    var NSData = ObjC.classes.NSData;
    var alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var entries = [
        {path: 'Resources/icon.png', size: 29},
        {path: 'Resources/icon@2x.png', size: 58},
        {path: 'Resources/icon@3x.png', size: 87}
    ];

    function require(condition, message) {
        if (!condition) throw new Error(message);
    }
    function base64(bytes) {
        var out = [];
        for (var i = 0; i < bytes.length; i += 3) {
            var a = bytes[i], b = bytes[i + 1] || 0, c = bytes[i + 2] || 0;
            out.push(alphabet[a >> 2] + alphabet[((a & 3) << 4) | (b >> 4)] +
                (i + 1 < bytes.length ? alphabet[((b & 15) << 2) | (c >> 6)] : '=') +
                (i + 2 < bytes.length ? alphabet[c & 63] : '='));
        }
        return out.join('');
    }
    function unbase64(string) {
        var out = [], bits = 0, count = 0;
        for (var i = 0; i < string.length; i++) {
            var value = alphabet.indexOf(string[i]);
            if (value < 0) continue;
            bits = (bits << 6) | value;
            count += 6;
            if (count >= 8) {
                count -= 8;
                out.push((bits >> count) & 255);
            }
        }
        return out;
    }
    function dataFor(bytes) {
        var data = NSData['alloc']()['initWithBase64EncodedString:options:'](base64(bytes), 0);
        require(data, 'Could not create PNG data');
        return data;
    }
    function bytesFor(data) {
        require(data, 'Missing image data');
        return unbase64(data['base64EncodedStringWithOptions:'](0));
    }
    function u32(bytes, offset) {
        return (bytes[offset] * 0x1000000 + (bytes[offset + 1] << 16) +
            (bytes[offset + 2] << 8) + bytes[offset + 3]) >>> 0;
    }
    function be32(value) {
        return [value >>> 24, (value >>> 16) & 255, (value >>> 8) & 255, value & 255];
    }
    var crcTable = [];
    for (var t = 0; t < 256; t++) {
        var crc = t;
        for (var j = 0; j < 8; j++) crc = (crc & 1) ? (0xEDB88320 ^ (crc >>> 1)) : (crc >>> 1);
        crcTable[t] = crc;
    }
    function crc32(bytes) {
        var crc = 0xFFFFFFFF;
        for (var i = 0; i < bytes.length; i++) crc = crcTable[(crc ^ bytes[i]) & 255] ^ (crc >>> 8);
        return (crc ^ 0xFFFFFFFF) >>> 0;
    }
    function adler32(bytes) {
        var a = 1, b = 0;
        for (var i = 0; i < bytes.length; i++) {
            a = (a + bytes[i]) % 65521;
            b = (b + a) % 65521;
        }
        return ((b << 16) | a) >>> 0;
    }
    function chunk(type, payload) {
        var body = [];
        for (var i = 0; i < type.length; i++) body.push(type.charCodeAt(i));
        body = body.concat(payload);
        return be32(payload.length).concat(body, be32(crc32(body)));
    }
    function paeth(a, b, c) {
        var p = a + b - c, da = Math.abs(p - a), db = Math.abs(p - b), dc = Math.abs(p - c);
        return da <= db && da <= dc ? a : (db <= dc ? b : c);
    }
    function decodePNG(bytes) {
        require(bytes.slice(0, 8).join(',') === '137,80,78,71,13,10,26,10', 'Not a PNG');
        var width, height, channels, compressed = [], metadata = [], ended = false;
        for (var pos = 8; pos + 12 <= bytes.length;) {
            var length = u32(bytes, pos);
            require(pos + length + 12 <= bytes.length, 'Truncated PNG chunk');
            var type = String.fromCharCode.apply(null, bytes.slice(pos + 4, pos + 8));
            var payload = bytes.slice(pos + 8, pos + 8 + length);
            require(crc32(bytes.slice(pos + 4, pos + 8 + length)) === u32(bytes, pos + 8 + length), 'PNG CRC mismatch');
            if (type === 'IHDR') {
                require(length === 13 && !width, 'Invalid PNG header');
                width = u32(payload, 0);
                height = u32(payload, 4);
                require(width > 0 && width <= 87 && width === height, 'Unexpected icon dimensions');
                require(payload[8] === 8 && (payload[9] === 2 || payload[9] === 6) &&
                    payload[10] === 0 && payload[11] === 0 && payload[12] === 0,
                    'Expected non-interlaced RGB/RGBA8 PNG');
                channels = payload[9] === 2 ? 3 : 4;
            } else if (type === 'IDAT') {
                compressed = compressed.concat(payload);
            } else if (['sRGB', 'gAMA', 'cHRM', 'iCCP', 'pHYs'].indexOf(type) >= 0) {
                metadata.push({type: type, payload: payload});
            } else if (type === 'IEND') {
                ended = true;
                break;
            }
            pos += length + 12;
        }
        require(ended && channels && compressed.length >= 6, 'Incomplete PNG');
        require((compressed[0] & 15) === 8 && (compressed[0] >>> 4) <= 7 &&
            ((compressed[0] << 8) + compressed[1]) % 31 === 0 && !(compressed[1] & 32), 'Unsupported zlib stream');
        var deflate = dataFor(compressed.slice(2, compressed.length - 4));
        var raw = bytesFor(deflate['decompressedDataUsingAlgorithm:error:'](3, null));
        var stride = width * channels;
        require(raw.length === (stride + 1) * height, 'Unexpected PNG scanline size');
        require(adler32(raw) === u32(compressed, compressed.length - 4), 'PNG Adler checksum mismatch');
        var pixels = new Uint8Array(stride * height), source = 0;
        for (var y = 0; y < height; y++) {
            var filter = raw[source++];
            require(filter <= 4, 'Unsupported PNG filter');
            for (var x = 0; x < stride; x++) {
                var at = y * stride + x;
                var left = x >= channels ? pixels[at - channels] : 0;
                var above = y > 0 ? pixels[at - stride] : 0;
                var upperLeft = y > 0 && x >= channels ? pixels[at - stride - channels] : 0;
                var predictor = filter === 1 ? left : filter === 2 ? above :
                    filter === 3 ? Math.floor((left + above) / 2) : filter === 4 ? paeth(left, above, upperLeft) : 0;
                pixels[at] = (raw[source++] + predictor) & 255;
            }
        }
        var rgba = new Uint8Array(width * height * 4);
        for (var p = 0, q = 0; p < pixels.length; p += channels, q += 4) {
            rgba[q] = pixels[p]; rgba[q + 1] = pixels[p + 1]; rgba[q + 2] = pixels[p + 2];
            rgba[q + 3] = channels === 4 ? pixels[p + 3] : 255;
        }
        return {width: width, height: height, rgba: rgba, metadata: metadata};
    }
    function round(image) {
        var size = image.width, radius = 9 * size / 29, samples = 8;
        for (var y = 0; y < size; y++) {
            for (var x = 0; x < size; x++) {
                var inside = 0;
                for (var sy = 0; sy < samples; sy++) {
                    for (var sx = 0; sx < samples; sx++) {
                        var px = x + (sx + 0.5) / samples, py = y + (sy + 0.5) / samples;
                        var dx = px - Math.min(Math.max(px, radius), size - radius);
                        var dy = py - Math.min(Math.max(py, radius), size - radius);
                        if (dx * dx + dy * dy <= radius * radius) inside++;
                    }
                }
                var at = (y * size + x) * 4 + 3;
                // Idempotent: repeating this mask must not darken antialiased edges.
                image.rgba[at] = Math.min(image.rgba[at], Math.round(inside * 255 / (samples * samples)));
            }
        }
    }
    function encodePNG(image) {
        var size = image.width, raw = [];
        for (var y = 0; y < size; y++) {
            raw.push(0);
            for (var x = 0; x < size * 4; x++) raw.push(image.rgba[y * size * 4 + x]);
        }
        // These three small icons fit in one DEFLATE stored block.
        require(raw.length <= 65535, 'Icon is too large for this writer');
        var length = raw.length;
        var zlib = [0x78, 0x01, 1, length & 255, length >>> 8, (~length) & 255, ((~length) >>> 8) & 255]
            .concat(raw, be32(adler32(raw)));
        var out = [137, 80, 78, 71, 13, 10, 26, 10]
            .concat(chunk('IHDR', be32(size).concat(be32(size), [8, 6, 0, 0, 0])));
        image.metadata.forEach(function (entry) { out = out.concat(chunk(entry.type, entry.payload)); });
        return out.concat(chunk('IDAT', zlib), chunk('IEND', []));
    }
    var pending = entries.map(function (entry) {
        var image = decodePNG(bytesFor(NSData['dataWithContentsOfFile:'](entry.path)));
        require(image.width === entry.size, 'Wrong resource size: ' + entry.path);
        round(image);
        var encoded = encodePNG(image), check = decodePNG(encoded), size = check.width;
        var corners = [0, size - 1, (size - 1) * size, size * size - 1].map(function (p) { return check.rgba[p * 4 + 3]; });
        require(corners.every(function (alpha) { return alpha === 0; }), 'Corners are not transparent');
        require(check.rgba[(Math.floor(size / 2) * size + Math.floor(size / 2)) * 4 + 3] === 255, 'Center must stay opaque');
        var antialiased = 0;
        for (var i = 3; i < check.rgba.length; i += 4) if (check.rgba[i] > 0 && check.rgba[i] < 255) antialiased++;
        require(antialiased > 0, 'Rounded boundary must be antialiased');
        return {path: entry.path, data: dataFor(encoded), report: {size: size, radiusPoints: 9, cornerAlpha: corners, antialiasedPixels: antialiased}};
    });
    // All source files and generated PNGs have passed validation before writing.
    pending.forEach(function (entry) {
        require(entries.some(function (allowed) { return allowed.path === entry.path; }), 'Unsafe output path');
        require(entry.data['writeToFile:atomically:'](entry.path, true), 'Could not save: ' + entry.path);
        console.log(entry.path + ' ' + JSON.stringify(entry.report));
    });
    return {updated: pending.length, radiusPoints: 9, screenAccess: false};
})();
