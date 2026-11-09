import {invoke} from '@tauri-apps/api/core';
import {syncHistory} from './history-sync.js';

const element = (tag, text) => { const node = document.createElement(tag); if (text !== undefined) node.textContent = text; return node; };
const labelTime = value => new Date(value * 1000).toLocaleString();
const inputTime = value => { const d = new Date(value * 1000); const pad = x => String(x).padStart(2,'0'); return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${String(d.getMilliseconds()).padStart(3,'0')}`; };

export function mountHistory({root, user, auth, db, emulator}) {
  const uid = user.uid;
  let disposed = false, running = false, again = false, editing = null, timer, lastRendered = null;
  const current = () => !disposed && auth.currentUser?.uid === uid;
  root.innerHTML = `<h2>履歴</h2><p id="sync-status" role="status">同期を準備中</p><button id="sync-now" type="button">今すぐ同期</button><section id="conflicts"></section><h3 id="editor-title">手動記録を追加</h3><form id="history-form"><label>プロジェクト<input name="project" maxlength="100" required></label><label>カテゴリ<input name="category" maxlength="100" required value="一般"></label><label>開始<input name="start" type="datetime-local" step="0.001" required></label><label>終了<input name="end" type="datetime-local" step="0.001" required></label><label>作業メモ<textarea name="note" maxlength="2000" rows="3"></textarea></label><div><button type="submit">保存</button><button id="history-cancel" type="button" hidden>編集をキャンセル</button></div></form><p id="history-error" role="alert"></p><h3>作業記録</h3><div id="history-list"></div>`;
  const form = root.querySelector('#history-form'), error = root.querySelector('#history-error'), status = root.querySelector('#sync-status');
  const call = (name, args = {}) => invoke(`history_${name}`, {uid, emulator, ...args});
  const local = {
    pending: () => call('pending'), ack: operationId => call('ack', {operationId}),
    conflict: record => call('conflict', {record}), syncInfo: () => call('sync_info'),
    apply: (record, cursor) => call('apply_remote', {record, cursor}), markSweep: () => call('mark_sweep'),
  };
  function resetForm() {
    editing = null; form.reset(); form.elements.category.value = '一般';
    const t = Date.now()/1000; form.elements.start.value = inputTime(t-3600); form.elements.end.value = inputTime(t);
    root.querySelector('#editor-title').textContent = '手動記録を追加'; root.querySelector('#history-cancel').hidden = true;
  }
  function button(text, fn) { const b = element('button', text); b.type = 'button'; b.addEventListener('click', fn); return b; }
  function confirmAction(message) {
    return new Promise(resolve => {
      const dialog = element('dialog'), text = element('p', message);
      text.id = 'history-confirm-message'; dialog.setAttribute('aria-labelledby', text.id);
      const finish = value => { dialog.close(); dialog.remove(); resolve(value); };
      dialog.append(text, button('キャンセル', () => finish(false)), button('実行する', () => finish(true)));
      dialog.addEventListener('cancel', event => { event.preventDefault(); finish(false); });
      root.append(dialog); dialog.showModal();
    });
  }
  function describe(record) {
    const div = element('div'); div.append(element('strong', record.deleted ? '削除された記録' : record.projectName), element('p', `${labelTime(record.start)} ～ ${labelTime(record.end)} · ${record.categoryName}`));
    if (record.note) div.append(element('p', record.note)); return div;
  }
  async function refresh() {
    const data = await call('state'); if (!current()) return null;
    const fingerprint = JSON.stringify([data.records, data.conflicts]);
    if (fingerprint === lastRendered) return data;
    lastRendered = fingerprint;
    const list = root.querySelector('#history-list'); list.replaceChildren();
    if (!data.records.length) list.append(element('p','作業記録はまだありません。'));
    for (const record of data.records) {
      const card = element('article'); card.className = 'history-card'; card.append(describe(record));
      card.append(button('編集', () => {
        form.elements.project.value = record.projectName; form.elements.category.value = record.categoryName;
        form.elements.start.value = inputTime(record.start); form.elements.end.value = inputTime(record.end); form.elements.note.value = record.note;
        editing = {id:record.id, version:record.version, start:record.start, end:record.end, startInput:form.elements.start.value, endInput:form.elements.end.value};
        root.querySelector('#editor-title').textContent = '記録を編集'; root.querySelector('#history-cancel').hidden = false; form.elements.project.focus();
      }));
      card.append(button('削除', async () => {
        if (!await confirmAction('この作業記録を削除しますか？') || !current()) return;
        try { await call('delete', {id:record.id, version:record.version}); if (!current()) return; await refresh(); requestSync(); }
        catch (e) { if (current()) error.textContent = String(e); }
      }));
      list.append(card);
    }
    const conflicts = root.querySelector('#conflicts'); conflicts.replaceChildren();
    if (data.conflicts.length) conflicts.append(element('h3', '同期の競合'));
    for (const conflict of data.conflicts) {
      const card = element('article'); card.className = 'history-card';
      card.append(element('h4','このPCの変更'), describe(conflict.local), element('h4','別の端末の変更'), describe(conflict.remote));
      card.append(element('p','同期する内容を選んでください。選ばなかった変更はこのPCに保管されます。'));
      for (const [title, keepLocal] of [['このPCの変更を同期',true], ['別の端末の変更を採用',false]]) card.append(button(title, async () => {
        if (!await confirmAction('選択した内容を履歴に反映しますか？') || !current()) return;
        try { await call('resolve', {id:conflict.local.id, keepLocal}); if (!current()) return; await refresh(); requestSync(); }
        catch (e) { if (current()) error.textContent = String(e); }
      }));
      conflicts.append(card);
    }
    return data;
  }
  async function requestSync() {
    if (!current()) return;
    if (running) { again = true; return; }
    running = true;
    try {
      do {
        again = false; status.textContent = '同期中';
        try {
          await syncHistory({db,uid,current,local}); if (!current()) return;
          const data = await refresh(); if (!data || !current()) return;
          status.textContent = data.conflicts.length ? `同期の競合が${data.conflicts.length}件あります` : data.pending ? `同期待ち ${data.pending}件` : '同期済み';
        } catch {
          if (!current()) return;
          const data = await refresh().catch(() => null);
          if (!current()) return;
          status.textContent = data ? `同期できません · 同期待ち ${data.pending}件` : '端末の履歴を開けません';
        }
      } while (again && current());
    } finally { running = false; }
  }
  form.addEventListener('submit', async event => {
    event.preventDefault(); error.textContent = '';
    const start = editing && form.elements.start.value === editing.startInput ? editing.start : new Date(form.elements.start.value).getTime()/1000;
    const end = editing && form.elements.end.value === editing.endInput ? editing.end : new Date(form.elements.end.value).getTime()/1000;
    if (!Number.isFinite(start) || !Number.isFinite(end) || start >= end || end > Date.now()/1000) { error.textContent = '開始・終了時刻を確認してください。'; return; }
    const edit = {id:editing?.id ?? null, expectedVersion:editing?.version ?? null, projectName:form.elements.project.value, categoryName:form.elements.category.value, start, end, note:form.elements.note.value};
    const saveButton = form.querySelector('[type=submit]'); saveButton.disabled = true;
    try { await call('save', {edit}); if (!current()) return; resetForm(); requestSync(); try { await refresh(); } catch { error.textContent = '保存しましたが、一覧を更新できませんでした。'; } }
    catch (e) { if (current()) error.textContent = String(e); }
    finally { saveButton.disabled = false; }
  });
  root.querySelector('#history-cancel').addEventListener('click', resetForm);
  root.querySelector('#sync-now').addEventListener('click', requestSync);
  const onOnline = () => requestSync(), onFocus = () => requestSync();
  window.addEventListener('online',onOnline); window.addEventListener('focus',onFocus);
  resetForm(); refresh().then(requestSync).catch(() => { if (current()) status.textContent = '端末の履歴を開けません'; });
  timer = setInterval(requestSync, 60000);
  return () => { disposed = true; clearInterval(timer); window.removeEventListener('online',onOnline); window.removeEventListener('focus',onFocus); root.replaceChildren(); };
}
