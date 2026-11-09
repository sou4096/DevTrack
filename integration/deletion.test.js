import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { initializeApp, deleteApp } from 'firebase/app';
import { connectAuthEmulator, createUserWithEmailAndPassword, getAuth } from 'firebase/auth';
import { connectFunctionsEmulator, getFunctions, httpsCallable } from 'firebase/functions';
import { connectFirestoreEmulator, doc, getDoc, getFirestore, setDoc, Timestamp, writeBatch, serverTimestamp } from 'firebase/firestore';
import { createRequire } from 'node:module';
const require = createRequire(new URL('../functions/package.json', import.meta.url));
const {initializeApp: initializeAdmin, deleteApp: deleteAdmin} = require('firebase-admin/app');
const {getFirestore: adminDb} = require('firebase-admin/firestore');
const {getAuth: adminAuth} = require('firebase-admin/auth');

process.env.FIRESTORE_EMULATOR_HOST = '127.0.0.1:8080';
process.env.FIREBASE_AUTH_EMULATOR_HOST = '127.0.0.1:9099';
const projectId = 'demo-devtrack';
const client = initializeApp({apiKey:'demo-key', projectId}, 'deletion-test');
const auth = getAuth(client); connectAuthEmulator(auth, 'http://127.0.0.1:9099', {disableWarnings:true});
const db = getFirestore(client); connectFirestoreEmulator(db, '127.0.0.1', 8080);
const functions = getFunctions(client, 'asia-northeast1'); connectFunctionsEmulator(functions, '127.0.0.1', 5001);
const admin = initializeAdmin({projectId}, 'deletion-test-admin');
after(async () => { await deleteApp(client); await deleteAdmin(admin); });

test('authenticated request blocks access and worker deletes nested data before account', {timeout: 60000}, async () => {
  await assert.rejects(httpsCallable(functions, 'requestAccountDeletion')({}));
  const user = (await createUserWithEmailAndPassword(auth, `delete-${Date.now()}@example.test`, 'password123')).user;
  const uid = user.uid;
  const now = Timestamp.now();
  await setDoc(doc(db, 'users', uid), {uid, displayName:'Test', createdAt:now, updatedAt:now, version:1});
  const record = {id:'entry1', sessionID:'session1', projectID:'project1', projectName:'Project', categoryID:'general', categoryName:'一般', start:100, end:200, note:'test', source:'manual', deleted:false, version:1, operationID:'operation1'};
  const batch = writeBatch(db);
  batch.set(doc(db, 'users', uid, 'history', 'entry1'), record);
  batch.set(doc(db, 'users', uid, 'historyOps', 'operation1'), {...record, committedAt: serverTimestamp()});
  await batch.commit();
  await adminDb(admin).doc(`users/${uid}/nested/item`).set({value:1});
  const result = await httpsCallable(functions, 'requestAccountDeletion')({uid:'another-user'});
  assert.equal(result.data.accepted, true);
  await assert.rejects(getDoc(doc(db, 'users', uid)));
  await assert.rejects(getDoc(doc(db, 'users', uid, 'history', 'entry1')));
  const deadline = Date.now() + 45000;
  let completed = false;
  while (Date.now() < deadline) {
    const marker = await adminDb(admin).doc(`deletionRequests/${uid}`).get();
    if (marker.data()?.status === 'complete') { completed = true; break; }
    await new Promise(resolve => setTimeout(resolve, 500));
  }
  assert.equal(completed, true, 'deletion worker did not complete');
  assert.equal((await adminDb(admin).doc(`users/${uid}`).get()).exists, false);
  assert.equal((await adminDb(admin).doc(`users/${uid}/nested/item`).get()).exists, false);
  assert.equal((await adminDb(admin).doc(`users/${uid}/history/entry1`).get()).exists, false);
  assert.equal((await adminDb(admin).doc(`users/${uid}/historyOps/operation1`).get()).exists, false);
  await assert.rejects(adminAuth(admin).getUser(uid), {code:'auth/user-not-found'});
  assert.equal((await adminDb(admin).doc('deletionRequests/another-user').get()).exists, false);
});
