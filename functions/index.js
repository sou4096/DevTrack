import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore, FieldValue } from 'firebase-admin/firestore';
import { onCall, HttpsError } from 'firebase-functions/v2/https';
import { onDocumentCreated } from 'firebase-functions/v2/firestore';
import { continueDeletion } from './deletion.js';

initializeApp();
const db = getFirestore();
const auth = getAuth();
const region = 'asia-northeast1';

// Authentication is checked by callable middleware; the UID is never accepted from client data.
export const requestAccountDeletion = onCall({region}, async request => {
  const uid = request.auth?.uid;
  const signedInAt = request.auth?.token?.auth_time;
  const now = Math.floor(Date.now() / 1000);
  if (!uid) throw new HttpsError('unauthenticated', 'Sign in first.');
  if (!Number.isFinite(signedInAt) || signedInAt > now || now - signedInAt > 300) {
    throw new HttpsError('failed-precondition', 'Recent authentication is required.');
  }
  const marker = db.collection('deletionRequests').doc(uid);
  await db.runTransaction(async tx => {
    const existing = await tx.get(marker);
    if (!existing.exists) tx.create(marker, {status: 'pending', createdAt: FieldValue.serverTimestamp()});
  });
  return {accepted: true};
});

// The durable marker both blocks client reads/writes and triggers a retried worker.
// It deliberately contains no profile information. It must remain after Auth deletion
// while previously issued ID tokens may remain valid; retention policy is unfinished.
export const processAccountDeletion = onDocumentCreated({document: 'deletionRequests/{uid}', region, retry: true}, async event => {
  const uid = event.params.uid;
  const ignoreMissing = async operation => {
    try { await operation(); } catch (error) {
      if (error.code !== 'auth/user-not-found') throw error;
    }
  };
  await continueDeletion(uid, {
    disableUserIfPresent: () => ignoreMissing(() => auth.updateUser(uid, {disabled: true})),
    deleteUserDataRecursively: () => db.recursiveDelete(db.collection('users').doc(uid)),
    deleteAuthUserIfPresent: () => ignoreMissing(() => auth.deleteUser(uid)),
    markComplete: () => event.data.ref.set({status: 'complete', completedAt: FieldValue.serverTimestamp()}, {merge: true}),
  });
});
