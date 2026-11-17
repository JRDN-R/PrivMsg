import test from 'node:test';
import assert from 'node:assert/strict';
import { filesFromClipboard, installClipboardUploads } from '../clipboard.js';

function setup({ allowed = true, clipboard } = {}) {
  Object.defineProperty(navigator, 'clipboard', { value: clipboard, configurable: true });
  const input = new EventTarget();
  input.focus = () => { state.focused = true; };
  const state = { files: [], text: [], notices: [], busy: [], allowed };
  const controller = installClipboardUploads({
    input,
    addFiles: files => { state.files.push(...files); },
    insertText: text => state.text.push(text),
    closeMenu: () => {},
    canAcceptFiles: () => state.allowed,
    setReading: busy => state.busy.push(busy),
    notify: text => state.notices.push(text)
  });
  function paste(data) {
    const event = new Event('paste', { cancelable: true });
    event.clipboardData = data;
    input.dispatchEvent(event);
    return event;
  }
  return { state, paste, ...controller };
}

const pdf = () => new File(['%PDF-1.7\noriginal bytes'], 'report.pdf', { type: 'application/pdf' });
const item = (values, extra = {}) => ({
  types: Object.keys(values),
  getType: async type => values[type],
  ...extra
});

test('native paste stages all files once, retaining filenames, MIME and original bytes', async () => {
  const files = [pdf(), new File(['a,b\n1,2'], 'data.csv', { type: 'text/csv' }), new File(['raw'], 'unknown')];
  const { state, paste } = setup();
  const event = paste({ files, items: files.map(file => ({ kind: 'file', getAsFile: () => file })) });
  assert.equal(event.defaultPrevented, true);
  assert.deepEqual(state.files, files);
  assert.equal(await state.files[0].text(), '%PDF-1.7\noriginal bytes');
  assert.equal(state.files[0].name, 'report.pdf');
  assert.equal(state.files[0].type, 'application/pdf');
  assert.deepEqual(state.text, []);
});

test('item fallback accepts non-image files and ignores unreadable items', () => {
  const file = pdf();
  assert.deepEqual(filesFromClipboard({ items: [
    { kind: 'string', getAsFile: () => null },
    { kind: 'file', getAsFile: () => null },
    { kind: 'file', type: '', getAsFile: () => file }
  ] }), [file]);
  assert.deepEqual(filesFromClipboard(null), []);
});

test('text and path-only paste keep native textarea behavior', () => {
  const { state, paste } = setup();
  assert.equal(paste({ files: [], items: [{ kind: 'string', type: 'text/plain' }] }).defaultPrevented, false);
  assert.equal(paste(null).defaultPrevented, false);
  assert.deepEqual(state.files, []);
  assert.deepEqual(state.text, []);
});

test('unavailable composer blocks file ingestion', async () => {
  const { state, paste, pasteFromClipboard } = setup({ allowed: false });
  assert.equal(paste({ files: [pdf()] }).defaultPrevented, true);
  await pasteFromClipboard();
  assert.deepEqual(state.files, []);
  assert.equal(state.notices.length, 2);
  assert.deepEqual(state.busy, []);
});

test('clipboard button stages binary formats and only one representation per item', async () => {
  const original = pdf();
  const { state, pasteFromClipboard } = setup({ clipboard: { read: async () => [
    item({ 'text/plain': new Blob(['report.pdf']), 'application/pdf': original }),
    item({ 'image/png': new Blob(['png']), 'image/jpeg': new Blob(['jpeg']) }),
    item({ 'application/zip': new Blob(['zip bytes']) })
  ] } });
  await pasteFromClipboard();
  assert.equal(state.files.length, 3);
  assert.equal(state.files[0], original);
  assert.match(state.files[1].name, /-2\.png$/);
  assert.match(state.files[2].name, /-3\.zip$/);
  assert.equal(await state.files[2].text(), 'zip bytes');
  assert.deepEqual(state.text, []);
  assert.deepEqual(state.busy, [true, false]);
});

test('explicit text attachments become files; ordinary copied text stays text', async () => {
  const filePaste = setup({ clipboard: { read: async () => [
    item({ 'text/plain': new Blob(['file content']) }, { presentationStyle: 'attachment' })
  ] } });
  await filePaste.pasteFromClipboard();
  assert.equal(filePaste.state.files.length, 1);
  assert.match(filePaste.state.files[0].name, /\.txt$/);
  const textPaste = setup({ clipboard: { read: async () => [
    item({ 'text/plain': new Blob(['hello']), 'text/html': new Blob(['<b>hello</b>']) })
  ] } });
  await textPaste.pasteFromClipboard();
  assert.deepEqual(textPaste.state.text, ['hello']);
  assert.deepEqual(textPaste.state.files, []);
});

test('text-only Clipboard API remains usable', async () => {
  const { state, pasteFromClipboard } = setup({ clipboard: { readText: async () => 'plain text' } });
  await pasteFromClipboard();
  assert.deepEqual(state.text, ['plain text']);
  assert.deepEqual(state.busy, [true, false]);
});

test('permission denial and unavailable API offer native paste and file picker fallback', async () => {
  for (const clipboard of [undefined, { read: async () => { throw new Error('NotAllowedError'); } }]) {
    const { state, pasteFromClipboard } = setup({ clipboard });
    await pasteFromClipboard();
    assert.match(state.notices[0], /touch and hold on iPhone/);
    assert.match(state.notices[0], /Upload files/);
    assert.equal(state.focused, true);
    assert.deepEqual(state.files, []);
    assert.equal(state.busy.at(-1) ?? false, false);
  }
});

test('pending clipboard reads do not duplicate on repeated clicks or stage after sign-out', async () => {
  let resolve;
  const pending = new Promise(done => { resolve = done; });
  let reads = 0;
  const { state, pasteFromClipboard } = setup({ clipboard: { read: () => { reads++; return pending; } } });
  const first = pasteFromClipboard();
  await pasteFromClipboard();
  assert.equal(reads, 1);
  assert.deepEqual(state.busy, [true]);
  state.allowed = false;
  resolve([item({ 'application/pdf': pdf() })]);
  await first;
  assert.deepEqual(state.files, []);
  assert.deepEqual(state.busy, [true, false]);
});

test('an unreadable item does not discard other readable files', async () => {
  const { state, pasteFromClipboard } = setup({ clipboard: { read: async () => [
    item({ 'application/pdf': null }, { getType: async () => { throw new Error('unsupported'); } }),
    item({ 'application/pdf': pdf() })
  ] } });
  await pasteFromClipboard();
  assert.equal(state.files.length, 1);
  assert.match(state.notices[0], /Some clipboard items/);
  assert.deepEqual(state.busy, [true, false]);
});
