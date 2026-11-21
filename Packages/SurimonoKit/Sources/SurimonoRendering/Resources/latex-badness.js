// The integer approximation in TeX's badness routine. Input distances are CSS px;
// rounding to scaled points avoids platform-specific fitness changes near a threshold.
function texBadness(delta, available, sp = 72.27 / 96 * 65536) {
    const t = Math.round(Math.abs(delta) * sp), s = Math.round(available * sp);
    if (!t) return 0;
    if (s <= 0) return 10000;
    const r = t <= 7230584 ? Math.floor(t * 297 / s) :
        s >= 1663497 ? Math.floor(t / Math.floor(s/297)) : t;
    return r > 1290 ? 10000 : Math.floor((r*r*r + 131072) / 262144);
}
