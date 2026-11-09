import { collection, doc, runTransaction, serverTimestamp, query, orderBy, documentId, where, limit, startAfter, getDocsFromServer, Timestamp } from 'firebase/firestore';

const fields = ['id','sessionID','projectID','projectName','categoryID','categoryName','start','end','note','source','deleted','version','operationID'];
function sameRecord(a, b) {
  return fields.every(key => a[key] === b[key]) && Object.keys(a).every(key => fields.includes(key) || key === 'committedAt');
}
async function bounded(promise, timeoutMs) {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('同期がタイムアウトしました。')), timeoutMs); })]); }
  finally { clearTimeout(timer); }
}

// The local adapter persists all changes and the outbox in SQLite. Firebase's
// offline write queue is not used; a late commit is safe to retry by operation ID.
export async function syncHistory({db, uid, current, local, timeoutMs = 8000}) {
  const check = () => { if (!current()) throw new Error('アカウントが変更されたため同期を停止しました。'); };
  check();
  const root = doc(db, 'users', uid), blocked = new Set();
  for (const record of await local.pending()) {
    check();
    if (blocked.has(record.id)) continue;
    const history = doc(collection(root, 'history'), record.id), operation = doc(collection(root, 'historyOps'), record.operationID);
    const result = await bounded(runTransaction(db, async tx => {
      const marker = await tx.get(operation);
      if (marker.exists()) {
        if (!sameRecord(marker.data(), record)) throw new Error('同期済みの操作を確認できません。');
        return {status:'ack'};
      }
      const remote = await tx.get(history);
      if (remote.exists()) {
        const value = remote.data();
        if (!Number.isSafeInteger(value.version)) throw new Error('同期データを確認できません。');
        if (value.version !== record.version - 1) return {status:'conflict', remote:value};
      } else if (record.version !== 1) throw new Error('同期先に以前の記録が見つかりません。');
      tx.set(history, record);
      tx.set(operation, {...record, committedAt:serverTimestamp()});
      return {status:'ack'};
    }), timeoutMs);
    check();
    if (result.status === 'ack') await local.ack(record.operationID);
    else { await local.conflict(result.remote); blocked.add(record.id); }
  }
  check();
  const info = await local.syncInfo();
  const clauses = [orderBy('committedAt'), orderBy(documentId())];
  if (!info.fullSweep && info.cursor) clauses.push(where('committedAt', '>=', new Timestamp(info.cursor.seconds - 300, 0)));
  let last;
  for (;;) {
    check();
    const q = query(collection(root, 'historyOps'), ...clauses, ...(last ? [startAfter(last)] : []), limit(100));
    const result = await bounded(getDocsFromServer(q), timeoutMs);
    check();
    for (const entry of result.docs) {
      check();
      const data = entry.data(), committedAt = data.committedAt;
      const record = Object.fromEntries(fields.map(key => [key, data[key]]));
      if (!(committedAt instanceof Timestamp) || record.operationID !== entry.id || fields.some(key => record[key] === undefined)) throw new Error('同期データを確認できません。');
      await local.apply(record, {seconds:committedAt.seconds, nanoseconds:committedAt.nanoseconds, operationID:entry.id});
    }
    if (result.docs.length < 100) break;
    last = result.docs[result.docs.length - 1];
  }
  check();
  if (info.fullSweep) await local.markSweep();
}
