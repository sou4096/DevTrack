import { readFileSync } from 'node:fs';
import { after, before, beforeEach, test } from 'node:test';
import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, updateDoc, deleteDoc, collection, getDocs, Timestamp, writeBatch, serverTimestamp } from 'firebase/firestore';

let env;
const time = Timestamp.fromMillis(1000);
const profile = (uid = 'alice') => ({uid, displayName: 'Alice', createdAt: time, updatedAt: time, version: 1});
const ref = (db, uid = 'alice') => doc(db, 'users', uid);
before(async () => { env = await initializeTestEnvironment({projectId: 'demo-devtrack', firestore: {rules: readFileSync('firebase/firestore.rules', 'utf8')}}); });
beforeEach(async () => { await env.clearFirestore(); });
after(async () => { await env?.cleanup(); });

test('owner can create, read and update with consecutive version', async () => {
  const db = env.authenticatedContext('alice').firestore();
  await assertSucceeds(setDoc(ref(db), profile()));
  await assertSucceeds(getDoc(ref(db)));
  await assertSucceeds(updateDoc(ref(db), {displayName: 'A', version: 2}));
});
test('anonymous and other users cannot read or write', async () => {
  const owner = env.authenticatedContext('alice').firestore();
  await assertSucceeds(setDoc(ref(owner), profile()));
  for (const db of [env.unauthenticatedContext().firestore(), env.authenticatedContext('bob').firestore()]) {
    await assertFails(getDoc(ref(db)));
    await assertFails(setDoc(ref(db), profile()));
    await assertFails(updateDoc(ref(db), {version: 2}));
  }
});
test('rejects malformed, extra, or forged fields', async () => {
  const db = env.authenticatedContext('alice').firestore();
  for (const p of [{...profile(), uid: 'bob'}, {...profile(), version: 2}, {...profile(), version: '1'}, {...profile(), displayName: 'x'.repeat(101)}, {...profile(), extra: true}, {...profile(), updatedAt: 'now'}]) {
    await assertFails(setDoc(ref(db), p));
  }
});
test('rejects stale versions, changed creation time, physical deletes and collection scans', async () => {
  const db = env.authenticatedContext('alice').firestore();
  await assertSucceeds(setDoc(ref(db), profile()));
  await assertFails(updateDoc(ref(db), {displayName: 'stale', version: 1}));
  await assertFails(updateDoc(ref(db), {version: 3}));
  await assertFails(updateDoc(ref(db), {createdAt: Timestamp.fromMillis(0), version: 2}));
  await assertFails(deleteDoc(ref(db)));
  await assertFails(getDocs(collection(db, 'users')));
  await assertFails(setDoc(doc(db, 'users/alice/projects/p1'), {name: 'x'}));
});

test('a deletion marker blocks owner reads and writes and cannot be changed by a client', async () => {
  const db = env.authenticatedContext('alice').firestore();
  await assertSucceeds(setDoc(ref(db), profile()));
  await assertFails(setDoc(doc(db, 'deletionRequests/alice'), {status: 'pending'}));
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), 'deletionRequests/alice'), {status: 'pending'});
  });
  await assertFails(getDoc(ref(db)));
  await assertFails(updateDoc(ref(db), {version: 2}));
  await assertFails(deleteDoc(doc(db, 'deletionRequests/alice')));
});

const history = (version = 1, operationID = 'op1') => ({id: 'entry1', sessionID: 'session1', projectID: 'project1', projectName: 'Project', categoryID: 'general', categoryName: '一般', start: 100, end: 200, note: '', source: 'manual', deleted: false, version, operationID});
const historyRef = (db, uid = 'alice') => doc(db, 'users', uid, 'history', 'entry1');
const opRef = (db, id, uid = 'alice') => doc(db, 'users', uid, 'historyOps', id);
async function writeHistory(db, record, uid = 'alice') {
  const batch = writeBatch(db);
  batch.set(historyRef(db, uid), record);
  batch.set(opRef(db, record.operationID, uid), {...record, committedAt: serverTimestamp()});
  return batch.commit();
}

test('history and its immutable operation must be committed atomically in sequence', async () => {
  const db = env.authenticatedContext('alice').firestore();
  await assertSucceeds(writeHistory(db, history()));
  await assertSucceeds(getDoc(historyRef(db)));
  await assertSucceeds(getDocs(collection(db, 'users/alice/history')));
  await assertSucceeds(writeHistory(db, {...history(2, 'op2'), deleted: true}));
  await assertFails(writeHistory(db, history(1, 'op3')));
  await assertFails(writeHistory(db, history(4, 'op4')));
  await assertFails(writeHistory(db, {...history(3, 'op3'), sessionID: 'other'}));
  await assertFails(deleteDoc(historyRef(db)));
  await assertFails(updateDoc(opRef(db, 'op1'), {version: 2}));
  await assertSucceeds(getDocs(collection(db, 'users/alice/historyOps')));
  await assertFails(getDocs(collection(env.authenticatedContext('bob').firestore(), 'users/alice/historyOps')));
});

test('history and operation cannot be written independently', async () => {
  const db = env.authenticatedContext('alice').firestore();
  await assertFails(setDoc(historyRef(db), history()));
  await assertFails(setDoc(opRef(db, 'op1'), history()));
});

test('history operation rejects a forged timestamp and mismatched data', async () => {
  const db = env.authenticatedContext('alice').firestore();
  const badTimestamp = writeBatch(db);
  badTimestamp.set(historyRef(db), history());
  badTimestamp.set(opRef(db, 'op1'), {...history(), committedAt: Timestamp.fromMillis(1000)});
  await assertFails(badTimestamp.commit());
  const mismatched = writeBatch(db);
  mismatched.set(historyRef(db), history(1, 'op2'));
  mismatched.set(opRef(db, 'op2'), {...history(1, 'op2'), note: 'different', committedAt: serverTimestamp()});
  await assertFails(mismatched.commit());
});

test('history accepts multicodepoint names and notes within byte limits', async () => {
  const db = env.authenticatedContext('alice').firestore();
  const emoji = '👨‍👩‍👧‍👦';
  await assertSucceeds(writeHistory(db, {...history(), projectName: emoji.repeat(100), note: emoji.repeat(300)}));
});

test('history isolates accounts and rejects invalid fields and deleted accounts', async () => {
  const alice = env.authenticatedContext('alice').firestore();
  const bob = env.authenticatedContext('bob').firestore();
  const anon = env.unauthenticatedContext().firestore();
  await assertFails(writeHistory(alice, {...history(), note: 'x'.repeat(32001)}));
  await assertFails(writeHistory(alice, {...history(), start: 201}));
  await assertFails(writeHistory(alice, {...history(), extra: true}));
  await assertSucceeds(writeHistory(alice, history()));
  await assertFails(getDoc(historyRef(bob)));
  await assertFails(getDoc(historyRef(anon)));
  await assertFails(writeHistory(bob, history(2, 'op2'), 'alice'));
  await env.withSecurityRulesDisabled(async context => setDoc(doc(context.firestore(), 'deletionRequests/alice'), {status: 'pending'}));
  await assertFails(getDoc(historyRef(alice)));
  await assertFails(writeHistory(alice, history(2, 'op2')));
});
