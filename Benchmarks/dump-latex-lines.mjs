// Drive one headless print-media renderer over DevTools pipes, without a server or an npm dependency.
// Swift provides the actual reader HTML, print measure and graphic preparation for every corpus case.
import {spawn} from 'node:child_process';
import {mkdtemp, mkdir, readdir, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';

const output = process.env.SURIMONO_LATEX_LINE_DUMP;
if (!output) process.exit(0);
const inputs = process.argv[2];
const root = fileURLToPath(new URL('../', import.meta.url));
const resources = path.join(root, 'Packages/SurimonoKit/Sources/SurimonoRendering/Resources');
const resource = name => readFile(path.join(resources, name), 'utf8');
const planner = await resource('latex-latin-plan.js');
const composer = await resource('latex-latin-lines.js');
const patterns = await resource('hyphen.tex');
const flow = (await Promise.all(['tikz-label-layout.js', 'latex-japanese-lines.js', 'latex-flow.js'].map(resource))).join('\n');
const profile = await mkdtemp(path.join(tmpdir(), 'surimono-line-chromium-'));
const chrome = process.env.CHROMIUM || 'chrome-headless-shell';
const flags = ['--headless', '--disable-gpu', '--disable-background-networking', '--remote-debugging-pipe',
    '--user-data-dir=' + profile];
if (process.env.SURIMONO_CHROMIUM_SINGLE_PROCESS === '1') {
    flags.push('--single-process', '--no-zygote', '--no-sandbox', '--disable-software-rasterizer');
}
const child = spawn(chrome, flags, {stdio:['ignore', 'ignore', 'inherit', 'pipe', 'pipe']});
const pending = new Map();
let next = 0, buffered = Buffer.alloc(0);
function failed(error) {
    for (const reply of pending.values()) reply.reject(error);
    pending.clear();
}
child.on('error', failed);
child.on('exit', (code, signal) => failed(new Error('Chromium exited: ' + (signal || code))));
child.stdio[4].on('data', bytes => {
    buffered = Buffer.concat([buffered, bytes]);
    let end;
    while ((end = buffered.indexOf(0)) >= 0) {
        const message = JSON.parse(buffered.toString('utf8', 0, end));
        buffered = buffered.subarray(end + 1);
        const reply = pending.get(message.id);
        if (!reply) continue;
        pending.delete(message.id);
        if (message.error) reply.reject(new Error(message.error.message));
        else reply.resolve(message.result);
    }
});
function send(method, params = {}, sessionId) {
    const id = ++next;
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(new Error(method + ' timed out')); }, 45000);
        pending.set(id, {resolve: value => { clearTimeout(timer); resolve(value); },
            reject: error => { clearTimeout(timer); reject(error); }});
        child.stdio[3].write(JSON.stringify({id, method, params, sessionId}) + '\0');
    });
}
try {
    const {targetId} = await send('Target.createTarget', {url:'about:blank'});
    const {sessionId} = await send('Target.attachToTarget', {targetId, flatten:true});
    const call = (method, params) => send(method, params, sessionId);
    async function evaluate(expression) {
        const reply = await call('Runtime.evaluate', {expression, awaitPromise:true, returnByValue:true});
        if (reply.exceptionDetails) throw new Error(reply.exceptionDetails.exception?.description || reply.exceptionDetails.text);
        return reply.result.value;
    }
    await call('Network.enable');
    await call('Network.setBlockedURLs', {urls:['http://*','https://*']});
    await call('Emulation.setEmulatedMedia', {media:'print'});
    await mkdir(output, {recursive:true});
    for (const filename of (await readdir(inputs)).filter(name => name.endsWith('.json')).sort()) {
        const name = filename.slice(0, -5), config = JSON.parse(await readFile(path.join(inputs, filename), 'utf8'));
        let report = {qualifying:0, composed:0, fallbacks:0, paragraphs:[], milliseconds:0};
        if (config.eligibleClass) {
            const htmlFile = path.join(inputs, name + '.html');
            // The stable reader dump uses synthetic paths. Resolve only this case's local companions.
            const realBase = pathToFileURL(path.join(root, 'Snapshots/corpus/latex', name)).href + '/';
            const html = (await readFile(htmlFile, 'utf8')).replaceAll('file:///corpus/' + name + '/', realBase);
            await writeFile(htmlFile, html);
            const url = pathToFileURL(htmlFile).href;
            await call('Page.navigate', {url});
            const isTiming = config.timing === true;
            const flowResult = isTiming
                ? 'return {...globalThis.surimonoLatinLast, flowMeasurement:JSON.parse(measured), width, bodyHeight};'
                : 'return globalThis.surimonoLatinLast;';
            const run = `(async () => {
                if (location.href !== ${JSON.stringify(url)}) throw Error('Unexpected corpus page');
                if (document.readyState !== 'complete') await new Promise(ok => addEventListener('load',ok,{once:true}));
                const {width,bodyHeight,paperHeight,leftMargin,rightMargin} = ${JSON.stringify(config)};
                document.documentElement.style.width = width + 'px';
                document.body.getBoundingClientRect(); await document.fonts.ready;
                ${config.preparation}
                globalThis.surimonoEnglishPatterns = ${JSON.stringify(patterns)};
                ${planner}
                ${composer}
                globalThis.surimonoComposeLatin = latinCompose;
                globalThis.surimonoLatinDiagnostics = true;
                ${config.flow ? 'const measured = await (async () => {' + flow + '})(); ' + flowResult
                    : 'return latinCompose(document.body);'}
            })()`;
            try { report = await evaluate(run); }
            catch (error) { throw new Error(name + ': ' + error.message); }
            if (!report) throw new Error(name + ': missing paragraph report');
        }
        report.path = config.flow ? 'flow' : 'native';
        await writeFile(path.join(output, filename), JSON.stringify(report, null, 2) + '\n');
    }
} finally {
    const closed = child.exitCode !== null || child.signalCode !== null || !child.pid
        ? Promise.resolve() : new Promise(resolve => child.once('exit', resolve));
    child.kill();
    await closed;
    await rm(profile, {recursive:true, force:true});
}
