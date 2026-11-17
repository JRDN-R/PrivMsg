import test from 'node:test';
import assert from 'node:assert/strict';
import { setTimeout as tick } from 'node:timers/promises';
import fs from 'node:fs/promises';
import vm from 'node:vm';
import { spawnSync } from 'node:child_process';
import { installNativeBridge } from '../PrivMsg/WebContent/native-bridge.js';

function setup({document, input, native = true} = {}) {
  const window = new EventTarget();
  const snapshots = [];
  let authListener;
  const state = {
    user: {uid:'owner-1', getIdToken:async force => force ? 'refreshed-token' : 'token'},
    messages: [],
    snapshots,
    window,
    authChanged: () => authListener()
  };
  window.__privmsgActiveThreadId = 'thread-1';
  window.document = document;
  if (native) window.webkit = {messageHandlers:{privmsg:{postMessage: message => snapshots.push(message)}}};
  globalThis.window = window;
  installNativeBridge({
    getUser: () => state.user,
    getThreadID: () => window.__privmsgActiveThreadId || '',
    getMessages: () => state.messages,
    input,
    addFiles: async () => {},
    canAcceptFiles: () => Boolean(state.user),
    insertText: () => {},
    setReading: () => {},
    projectID:'privmsg-stream',
    watchAuth: callback => {authListener = callback;},
    signOut: async () => {state.user=null;}
  });
  return state;
}
const file = (key='key-1') => ({key, name:'original.pdf', type:'application/pdf', size:32, chunks:1, encoding:'base64-chunk-v1'});

function drawerDocument() {
  class Element extends EventTarget {
    children = [];
    hidden = false;
    append(element) { this.children.push(element); }
    setAttribute() {}
    click() { this.dispatchEvent(new Event('click')); }
  }
  const drawer = new Element();
  let closed = 0;
  return {
    drawer,
    get closed() { return closed; },
    createElement: () => new Element(),
    getElementById: id => drawer.children.find(element => element.id === id),
    querySelector: selector => selector.endsWith('.drawer-scroll') ? drawer : {click: () => { closed++; }}
  };
}

test('native actions require a signed-in account and send only allowlisted commands', async () => {
  const s = setup();
  await tick(5);
  for (const action of ['openFiles', 'reload', 'clearDownloads', 'signOut', 'pasteFiles']) {
    assert.equal(s.window.PrivMsgNative.action(action), true);
    assert.deepEqual(s.snapshots.at(-1), {type: 'action', action});
  }
  const count = s.snapshots.length;
  for (const invalid of [null, {}, ['openFiles'], '__proto__', 'session', 'openFiles ']) {
    assert.equal(s.window.PrivMsgNative.action(invalid), false);
  }
  s.user = null;
  for (const action of ['openFiles', 'reload', 'clearDownloads', 'signOut', 'pasteFiles']) {
    assert.equal(s.window.PrivMsgNative.action(action), false);
  }
  assert.equal(s.snapshots.length, count);
});

test('native menu lives in the existing drawer and hides after sign-out', async () => {
  const document = drawerDocument();
  const s = setup({document});
  await tick(5);
  const section = document.drawer.children[0];
  assert.equal(section.hidden, false);
  assert.deepEqual(section.children.map(button => button.textContent), ['Files', 'Reload', 'Clear downloaded copies', 'Sign out']);
  section.children[0].click();
  assert.deepEqual(s.snapshots.at(-1), {type:'action', action:'openFiles'});
  assert.equal(document.closed, 1);
  s.window.dispatchEvent(new Event('privmsg:drawer'));
  assert.equal(document.drawer.children.length, 1);
  await s.window.PrivMsgNative.signOut();
  assert.equal(section.hidden, true);
  const count = s.snapshots.length;
  section.children[0].click();
  assert.equal(s.snapshots.length, count);
});

test('ordinary browser does not receive native menu entries or bridge actions', () => {
  const document = drawerDocument();
  const s = setup({document, native:false});
  assert.equal(s.window.PrivMsgNative, undefined);
  assert.deepEqual(document.drawer.children, []);
});

test('direct native paste preserves exact text fallback and never duplicates browser file paste', async () => {
  const input = new EventTarget();
  const s = setup({input});
  await tick(5);
  function paste(text, files = [], alreadyHandled = false) {
    const event = new Event('paste', {cancelable:true});
    Object.defineProperty(event, 'clipboardData', {value:{files, getData:() => text}});
    if (alreadyHandled) event.preventDefault();
    input.dispatchEvent(event);
    return event;
  }
  const text = 'https://example.com/file.pdf\nPlain text stays text.';
  assert.equal(paste(text).defaultPrevented, true);
  assert.deepEqual(s.snapshots.at(-1), {type:'action',action:'pasteFiles',fallbackText:text});
  const count = s.snapshots.length;
  paste('filename.pdf', [{}]);
  paste('already handled', [], true);
  assert.equal(s.snapshots.length, count);
  s.user = null;
  assert.equal(paste('Keep normal signed-out text paste').defaultPrevented, false);
  assert.equal(s.snapshots.length, count);
});

test('native file batch stays atomic when its account or thread changes during a later preview', async () => {
  const html = await fs.readFile(new URL('../PrivMsg/WebContent/index.html', import.meta.url), 'utf8');
  const source = html.match(/    (async function addFiles\([\s\S]*?\n    \})\n\n    function releaseStaged/)[1];
  let finishPreview;
  let isCurrent = true;
  const staged = [];
  const context = {
    saving:false, staged, preparingFiles:0, PREVIEW_THRESHOLD_BYTES:1,
    composerMeta:{}, toast() {}, updateSendState() {}, renderStaged() {}, releaseStaged() {},
    isImage:file => file.type.startsWith('image/'),
    createCompressedPreview:() => new Promise(resolve => { finishPreview = resolve; }),
    URL:{createObjectURL:() => { throw new Error('A stale file must not get a preview URL'); }}
  };
  const addFiles = vm.runInNewContext(`(${source})`, context);
  const pending = addFiles([
    {name:'first.pdf',type:'application/pdf',size:100,slice() {}},
    {name:'later.png',type:'image/png',size:100,slice() {}}
  ], () => isCurrent);
  assert.deepEqual(staged, [], 'The earlier PDF must wait for the later image preview');
  isCurrent = false;
  finishPreview({});
  await pending;
  assert.deepEqual(staged, []);
  assert.equal(context.preparingFiles, 0);
});

test('native file batch commits all prepared files together after its final preview', async () => {
  const html = await fs.readFile(new URL('../PrivMsg/WebContent/index.html', import.meta.url), 'utf8');
  const source = html.match(/    (async function addFiles\([\s\S]*?\n    \})\n\n    function releaseStaged/)[1];
  let finishPreview;
  const staged = [];
  const context = {
    saving:false, staged, preparingFiles:0, PREVIEW_THRESHOLD_BYTES:1,
    composerMeta:{}, toast() {}, updateSendState() {}, renderStaged() {},
    releaseStaged:items => { assert.equal(items.length, 0, 'Committed previews must stay valid'); },
    isImage:file => file.type.startsWith('image/'),
    createCompressedPreview:() => new Promise(resolve => { finishPreview = resolve; }),
    URL:{createObjectURL:() => 'blob:prepared-image'}
  };
  const addFiles = vm.runInNewContext(`(${source})`, context);
  const pending = addFiles([
    {name:'first.pdf',type:'application/pdf',size:100,slice() {}},
    {name:'later.png',type:'image/png',size:100,slice() {}}
  ], () => true);
  assert.deepEqual(staged, []);
  finishPreview({});
  await pending;
  assert.deepEqual(staged.map(item => item.name), ['first.pdf', 'later.png']);
  assert.equal(staged[1].objectUrl, 'blob:prepared-image');
  assert.equal(context.preparingFiles, 0);
});

test('snapshot includes current conversation originals and recordings only for signed-in owner', async () => {
  const s = setup();
  s.messages = [
    {id:'m1',owner:'owner-1',threadId:'thread-1',attachments:[file()]},
    {id:'m2',owner:'owner-1',threadId:'thread-2',attachments:[file('hidden')]},
    {id:'m3',owner:'someone-else',threadId:'thread-1',attachments:[file('private')]}
  ];
  s.window.dispatchEvent(new CustomEvent('privmsg:recordings',{detail:{recordings:[
    {id:'r1',owner:'owner-1',threadId:'thread-1',...file('recording'),name:'voice.m4a',type:'audio/mp4'}
  ]}}));
  await tick(5);
  const snapshot = s.snapshots.at(-1);
  assert.deepEqual(snapshot.attachments.map(x=>x.key), ['key-1','recording']);
  assert.equal(snapshot.attachments[0].name,'original.pdf');
  assert.equal(snapshot.attachments[0].mimeType,'application/pdf');
  assert.ok(!JSON.stringify(snapshot).includes('token'));
});

test('thread switch refreshes native attachment list', async () => {
  const s = setup();
  s.messages = [{id:'m1',owner:'owner-1',threadId:'thread-2',attachments:[file()]}];
  await tick(5);
  assert.equal(s.snapshots.at(-1).attachments.length,0);
  s.window.__privmsgActiveThreadId='thread-2';
  s.window.dispatchEvent(new Event('privmsg:thread'));
  await tick(5);
  assert.equal(s.snapshots.at(-1).attachments.length,1);
});

test('incomplete files are reported without breaking valid native entries', async () => {
  const s=setup();
  s.messages=[{id:'m1',owner:'owner-1',threadId:'thread-1',attachments:[file(),{key:'missing'},file()]}];
  await tick(5);
  assert.equal(s.snapshots.at(-1).unavailable,1);
  assert.equal(s.snapshots.at(-1).attachments.length,1);
});

test('session tokens are returned only on request and can refresh before cross-app dragging', async () => {
  const s=setup();
  await tick(5);
  assert.deepEqual(await s.window.PrivMsgNative.session(true),{uid:'owner-1',token:'refreshed-token',projectID:'privmsg-stream'});
  s.user=null;
  await assert.rejects(s.window.PrivMsgNative.session(),/Sign in/);
});

test('auth change while a token is loading rejects that session', async () => {
  const s=setup();
  let finish;
  s.user.getIdToken=()=>new Promise(resolve=>{finish=resolve;});
  const pending=s.window.PrivMsgNative.session();
  s.user={uid:'owner-2'};
  finish('old-user-token');
  await assert.rejects(pending,/account changed/);
  await tick(5);
});

test('sign-out publishes an empty native file list', async () => {
  const s=setup();
  s.messages=[{id:'m1',owner:'owner-1',threadId:'thread-1',attachments:[file()]}];
  await tick(5);
  await s.window.PrivMsgNative.signOut();
  assert.equal(s.snapshots.at(-1).signedIn,false);
  assert.deepEqual(s.snapshots.at(-1).attachments,[]);
  assert.equal(s.snapshots.at(-1).uid,'');
});

test('bundled app JavaScript parses and has native hooks with no remote bootstrap', async () => {
  const resources=new URL('../PrivMsg/WebContent/',import.meta.url);
  const html=await fs.readFile(new URL('index.html',resources),'utf8');
  assert.ok(!html.includes('raw.githubusercontent.com'));
  assert.ok(html.includes('installNativeBridge({'));
  assert.ok(html.includes('window.__privmsgRecorderBusy?.()'));
  assert.ok(html.includes('alt="Vagaries" width="168" height="56"'));
  assert.ok(html.includes('alt="Vagaries" width="240" height="80"'));
  assert.ok(!html.includes('identity-wordmark'));
  assert.ok(!html.includes('<h1 id="authTitle">PrivMsg</h1>'));
  assert.ok(html.includes('window.PrivMsgNative?.action("pasteFiles")'));
  assert.ok(html.includes('staged.push(...prepared)'));
  const main=html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  for(const source of [main,...await Promise.all(['clipboard.js','enhancements.js','native-bridge.js','native-paste.js'].map(name=>fs.readFile(new URL(name,resources),'utf8')))]) {
    const result=spawnSync(process.execPath,['--input-type=module','--check'],{input:source,encoding:'utf8'});
    assert.equal(result.status,0,result.stderr);
  }
});
