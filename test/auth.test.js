import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import { initializeApp, deleteApp } from 'firebase/app';
import { getAuth, connectAuthEmulator } from 'firebase/auth';
import { createAuthService } from '../src/auth.js';

const app = initializeApp({apiKey: 'demo-key', projectId: 'demo-devtrack'}, 'auth-test');
const auth = getAuth(app);
connectAuthEmulator(auth, 'http://127.0.0.1:9099', {disableWarnings: true});
const service = createAuthService(auth);
after(async () => { await deleteApp(app); });

test('email registration, sign out, sign in, reauthentication and deletion', async () => {
  const email = `test-${Date.now()}@example.test`;
  const registered = await service.register(email, 'password123');
  const uid = registered.user.uid;
  await service.signOut();
  assert.equal(auth.currentUser, null);
  await assert.rejects(service.signIn(email, 'wrong-password'));
  assert.equal((await service.signIn(email, 'password123')).user.uid, uid);
  await service.reauthenticatePassword('password123');
  await service.deleteAuthAccount();
  await assert.rejects(service.signIn(email, 'password123'));
});

test('explicit Google linking preserves UID and rejects a credential already linked elsewhere', async () => {
  const email = `link-${Date.now()}@example.test`;
  const googleToken = JSON.stringify({sub: `google-${Date.now()}`, email, email_verified: true});
  const uid = (await service.register(email, 'password123')).user.uid;
  assert.equal((await service.linkGoogleToken(googleToken)).user.uid, uid);
  await service.signOut();
  assert.equal((await service.signInWithGoogleToken(googleToken)).user.uid, uid);
  await service.signOut();
  await service.register(`other-${Date.now()}@example.test`, 'password123');
  await assert.rejects(service.linkGoogleToken(googleToken));
  await service.signOut();
});
