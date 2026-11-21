// PDFKit infers spaces between separately painted glyphs. Read the natural and
// adjusted formulas in one small WebKit PDF before accepting them for printing.
const pairs = globalThis.surimonoMathProofs;
delete globalThis.surimonoMathProofs;
const host = document.createElement('div'), root = document.documentElement, body = document.body;
const savedRoot = root.style.cssText, savedBody = body.style.cssText;
const mask = document.createElement('style');
globalThis.surimonoFinishMathProof = rejected => {
    mask.remove();
    host.remove();
    body.style.cssText = savedBody;
    root.style.cssText = savedRoot;
    if (rejected.length) globalThis.surimonoNextRigidMath = new Set(rejected);
    delete globalThis.surimonoFinishMathProof;
};
const samples = [], rejected = [];
let height = 0, width = 0, remainingItems = 2048;
for (const pair of pairs) {
    const views = [pair.old,pair.svg].map(svg=>svg.viewBox.baseVal);
    const row = Math.ceil(Math.max(...views.map(b=>b.height))) + 24;
    const span = Math.ceil(Math.max(...views.map(b=>b.width))) + 24;
    if (span > 1024 || height + 2*row > 4096 || pair.svg.childElementCount > remainingItems) {
        rejected.push(pair.index);
        continue;
    }
    remainingItems -= pair.svg.childElementCount;
    const top = height;
    for (const original of [pair.old,pair.svg]) {
        const box = original.viewBox.baseVal, copy = original.cloneNode(true);
        copy.style.cssText = 'position:absolute;left:12px;top:' + (height+12) +
            'px;width:' + box.width + 'px;height:' + box.height + 'px;overflow:visible';
        // Preserve the actual face chosen by a conference stylesheet. The old
        // source node is detached, so resolve the style on the live adjusted copy.
        for (let i=0;i<copy.children.length;i++) {
            const glyph = copy.children[i], style = getComputedStyle(pair.svg.children[i]);
            Object.assign(glyph.style, {fontFamily:style.fontFamily, fontStyle:style.fontStyle, fontWeight:style.fontWeight});
        }
        host.append(copy);
        height += row;
    }
    samples.push({index:pair.index,top,row});
    width = Math.max(width,span);
}
root.style.setProperty('zoom','1','important');
root.style.setProperty('transform','none','important');
mask.textContent = 'body > :not([data-math-samples]) {display:none!important}';
body.style.cssText += ';zoom:1!important;transform:none!important;margin:0!important;padding:0!important;position:static!important';
host.dataset.mathSamples='';
document.head.append(mask);
host.style.cssText='position:absolute;top:0;left:0;background:white;color:black;line-height:normal';
host.style.width=width+'px'; host.style.height=height+'px';
body.append(host);
const bounds = host.getBoundingClientRect();
await document.fonts.ready;
return JSON.stringify({x:bounds.x+scrollX,y:bounds.y+scrollY,width,height,samples,rejected});
