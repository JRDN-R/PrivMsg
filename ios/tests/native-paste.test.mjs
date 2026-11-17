import test from 'node:test';
import assert from 'node:assert/strict';
import { File } from 'node:buffer';
import { createNativePasteReceiver } from '../PrivMsg/WebContent/native-paste.js';

globalThis.File ??= File;
const context = {id:'paste-1', uid:'user-1', threadID:'thread-1'};
const metadata = (id, size, name='Copied.pdf', type='application/pdf') => ({id, size, name, type, lastModified:1234});

function setup(t, extra = {}) {
  const state = {user:{uid:context.uid}, threadID:context.threadID, reading:false, files:[], text:[]};
  const api = createNativePasteReceiver({
    getUser: () => state.user,
    getThreadID: () => state.threadID,
    canAcceptFiles: () => Boolean(state.user) && !state.reading,
    setReading: value => { state.reading=value; },
    addFiles: async files => { state.files.push(...files); },
    insertText: text => state.text.push(text),
    ...extra
  });
  t.after(() => api.cancelPaste(''));
  const begin = files => { api.preparePaste(context); api.beginPaste({...context,files}); };
  const chunk = (fileID, bytes, index=0) => api.appendPaste({id:context.id,fileID,index,base64:Buffer.from(bytes).toString('base64')});
  return {state,api,begin,chunk};
}

test('real file bytes, names and MIME types survive full-sized and final chunks', async t => {
  const {state,api,begin,chunk} = setup(t);
  const first = Buffer.alloc(256 * 1024, 0xab);
  const last = Buffer.from([0, 0xff, 1]);
  begin([metadata('pdf',first.length+last.length), metadata('png',3,'Screen.png','image/png')]);
  assert.equal(state.reading,true);
  chunk('pdf',first);
  chunk('pdf',last,1);
  chunk('png',last);
  await api.commitPaste(context.id);
  assert.equal(state.reading,false);
  assert.equal(state.files.length,2);
  assert.equal(state.files[0].name,'Copied.pdf');
  assert.equal(state.files[0].type,'application/pdf');
  assert.equal(state.files[0].lastModified,1234);
  assert.deepEqual(Buffer.from(await state.files[0].arrayBuffer()),Buffer.concat([first,last]));
  assert.deepEqual(Buffer.from(await state.files[1].arrayBuffer()),last);
});

test('provider preparation locks the composer and cancelled reservations cannot restart', t => {
  const {state,api} = setup(t);
  api.preparePaste(context);
  assert.equal(state.reading,true);
  assert.equal(api.keepPasteAlive(context.id),true);
  assert.throws(() => api.insertPastedText({...context,text:'during preparation'}),/busy/);
  api.cancelPaste(context.id);
  assert.equal(state.reading,false);
  assert.throws(() => api.beginPaste({...context,files:[metadata('pdf',1)]}),/no longer active/);
  assert.throws(() => api.keepPasteAlive(context.id),/no longer active/);
});

test('out-of-order, oversized and malformed chunks abort without staging', t => {
  for (const payload of [
    {index:1,base64:'AA=='},
    {index:0,base64:'%%%='},
    {index:0,base64:'AAAA'},
    {index:0,base64:Buffer.alloc(256*1024+1).toString('base64')}
  ]) {
    const {state,api,begin} = setup(t);
    begin([metadata('pdf',1)]);
    assert.throws(() => api.appendPaste({id:context.id,fileID:'pdf',...payload}));
    assert.equal(state.reading,false);
    assert.deepEqual(state.files,[]);
  }
});

test('incomplete files and invalid metadata do not stage attachments', async t => {
  const {state,api,begin,chunk} = setup(t);
  begin([metadata('pdf',2)]);
  chunk('pdf',[1]);
  await assert.rejects(api.commitPaste(context.id),/incomplete/);
  for (const file of [metadata('pdf',100*1024*1024+1),metadata('pdf',0),metadata('pdf',1,'../secret.pdf')]) {
    api.preparePaste(context);
    assert.throws(() => api.beginPaste({...context,files:[file]}));
    assert.equal(state.reading,false);
  }
  assert.deepEqual(state.files,[]);
});

test('account and thread changes reject data prepared for the earlier context', async t => {
  for (const change of [state => {state.user={uid:'user-2'};}, state => {state.threadID='thread-2';}, state => {state.user=null;}]) {
    const {state,api,begin,chunk} = setup(t);
    begin([metadata('pdf',1)]);
    chunk('pdf',[1]);
    change(state);
    await assert.rejects(api.commitPaste(context.id),/account or conversation changed/);
    assert.equal(state.reading,false);
    assert.deepEqual(state.files,[]);
  }
});

test('a context change during asynchronous staging invalidates its guard', async t => {
  let release;
  let guard;
  const wait = new Promise(resolve => {release=resolve;});
  const {state,api,begin,chunk} = setup(t,{addFiles:async (files,isCurrent) => {guard=isCurrent; await wait;}});
  begin([metadata('pdf',1)]);
  chunk('pdf',[1]);
  const committed = api.commitPaste(context.id);
  assert.equal(guard(),true);
  state.threadID='thread-2';
  assert.equal(guard(),false);
  release();
  await assert.rejects(committed,/account or conversation changed/);
  assert.equal(state.reading,false);
});

test('ordinary text and copied web URLs remain exact text, never file uploads', t => {
  const {state,api} = setup(t);
  const text='https://chatgpt.com/a/copied-file.pdf?token=example\nhello';
  assert.equal(api.insertPastedText({...context,text}),true);
  assert.deepEqual(state.text,[text]);
  assert.deepEqual(state.files,[]);
  state.threadID='thread-2';
  assert.throws(() => api.insertPastedText({...context,text}));
});
