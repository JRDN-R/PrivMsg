import test from 'node:test';
import assert from 'node:assert/strict';
import { setTimeout as tick } from 'node:timers/promises';
import fs from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { installNativeBridge } from '../PrivMsg/WebContent/native-bridge.js';

function setup() {
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
  window.webkit = {messageHandlers:{privmsg:{postMessage: message => snapshots.push(message)}}};
  globalThis.window = window;
  installNativeBridge({
    getUser: () => state.user,
    getMessages: () => state.messages,
    projectID:'privmsg-stream',
    watchAuth: callback => {authListener = callback;},
    signOut: async () => {state.user=null;}
  });
  return state;
}
const file = (key='key-1') => ({key, name:'original.pdf', type:'application/pdf', size:32, chunks:1, encoding:'base64-chunk-v1'});

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
  const main=html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  for(const source of [main,...await Promise.all(['clipboard.js','enhancements.js','native-bridge.js'].map(name=>fs.readFile(new URL(name,resources),'utf8')))]) {
    const result=spawnSync(process.execPath,['--input-type=module','--check'],{input:source,encoding:'utf8'});
    assert.equal(result.status,0,result.stderr);
  }
});
