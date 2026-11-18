// JSZip schedules work between native Promise turns. Each pump runs a finite snapshot.
var self = globalThis;
const callbacks = new Map();
let nextTimer = 0;
function setTimeout(callback, delay, ...args) {
    callbacks.set(++nextTimer, () => callback(...args));
    return nextTimer;
}
function clearTimeout(id) { callbacks.delete(id); }
function setImmediate(callback, ...args) { return setTimeout(callback, 0, ...args); }
function pump() {
    for (const id of Array.from(callbacks.keys())) {
        const callback = callbacks.get(id);
        callbacks.delete(id);
        if (callback) callback();
    }
}
class TextDecoder {
    decode(input) {
        const bytes = ArrayBuffer.isView(input)
            ? new Uint8Array(input.buffer, input.byteOffset, input.byteLength) : new Uint8Array(input);
        let encoded = "";
        for (let i = 0; i < bytes.length; i += 8192)
            encoded += String.fromCharCode(...bytes.subarray(i, i + 8192));
        return decodeURIComponent(escape(encoded)).replace(/^\uFEFF/, "");
    }
}
class TextEncoder {
    encode(value) { return Uint8Array.from(unescape(encodeURIComponent(value)), c => c.charCodeAt(0)); }
}
globalThis.TextDecoder = TextDecoder;
globalThis.TextEncoder = TextEncoder;
