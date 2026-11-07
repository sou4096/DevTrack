import { readFileSync } from 'node:fs';
import { after, before, beforeEach, test } from 'node:test';
import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, updateDoc, deleteDoc, collection, getDocs, Timestamp } from 'firebase/firestore';

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
