// 登录口令的前端 MD5（对齐「登录口令规范」A 档：明文不出浏览器）。
//
// - 提交前把 `#Password` 的明文替换为 **32 位小写 MD5(UTF-8(明文))**；
// - 后端同时接受明文与 MD5（`password.verify` 的兼容分支），所以脚本没加载时照样能登录；
// - 只用标准库 `TextEncoder` 取 UTF-8 字节（中文口令与 C#/Rust 端一致）；
// - 刻意不依赖任何第三方库：本文件由服务端 `materializeDefaults()` 落地到
//   `wwwroot/static/admin/js/login-md5.js`。
(function () {
    'use strict';

    // ———— 极简 MD5（RFC 1321），输入按字节处理 ————
    var S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
             5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
             4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
             6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
    var K = [];
    for (var i = 0; i < 64; i++) K[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) | 0;

    function md5Bytes(bytes) {
        var len = bytes.length;
        var padded = new Uint8Array((((len + 8) >>> 6) + 1) * 64);
        padded.set(bytes);
        padded[len] = 0x80;
        var bitLen = len * 8;
        var view = new DataView(padded.buffer);
        view.setUint32(padded.length - 8, bitLen >>> 0, true);
        view.setUint32(padded.length - 4, Math.floor(bitLen / 4294967296), true);

        var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
        var M = new Int32Array(16);
        var f, g, tmp;
        for (var offset = 0; offset < padded.length; offset += 64) {
            for (var j = 0; j < 16; j++) M[j] = view.getInt32(offset + j * 4, true);
            var A = a0, B = b0, C = c0, D = d0;
            for (var i2 = 0; i2 < 64; i2++) {
                if (i2 < 16) { f = (B & C) | (~B & D); g = i2; }
                else if (i2 < 32) { f = (D & B) | (~D & C); g = (5 * i2 + 1) % 16; }
                else if (i2 < 48) { f = B ^ C ^ D; g = (3 * i2 + 5) % 16; }
                else { f = C ^ (B | ~D); g = (7 * i2) % 16; }
                tmp = D;
                D = C;
                C = B;
                var sum = (A + f + K[i2] + M[g]) | 0;
                B = (B + ((sum << S[i2]) | (sum >>> (32 - S[i2])))) | 0;
                A = tmp;
            }
            a0 = (a0 + A) | 0; b0 = (b0 + B) | 0; c0 = (c0 + C) | 0; d0 = (d0 + D) | 0;
        }

        var out = new Uint8Array(16);
        var outView = new DataView(out.buffer);
        outView.setInt32(0, a0, true);
        outView.setInt32(4, b0, true);
        outView.setInt32(8, c0, true);
        outView.setInt32(12, d0, true);
        return out;
    }

    function utf8Bytes(text) {
        if (typeof TextEncoder === 'function') return new TextEncoder().encode(text);
        // 极老浏览器兜底（面板不支持 IE，这里只是不报错）
        var encoded = unescape(encodeURIComponent(text));
        var bytes = new Uint8Array(encoded.length);
        for (var i = 0; i < encoded.length; i++) bytes[i] = encoded.charCodeAt(i);
        return bytes;
    }

    function md5Hex(text) {
        var digest = md5Bytes(utf8Bytes(text));
        var hex = '';
        for (var i = 0; i < digest.length; i++) {
            var value = digest[i].toString(16);
            hex += value.length === 1 ? '0' + value : value;
        }
        return hex;
    }

    // 暴露给页面与控制台自检用（与 C#/Rust 端同口径：小写十六进制）
    window.dsmalluiMd5 = md5Hex;

    function bind() {
        var form = document.querySelector('form[action$="/login/login"]');
        if (!form) return;
        var input = form.querySelector('input[name="Password"]');
        if (!input) return;

        form.addEventListener('submit', function () {
            // 只哈希一次：脚本重复触发（回车 + 点击）不再二次散列
            if (input.dataset.md5 === '1') return;
            if (!input.value) return;
            input.value = md5Hex(input.value);
            input.dataset.md5 = '1';
        }, true);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', bind);
    } else {
        bind();
    }
})();
