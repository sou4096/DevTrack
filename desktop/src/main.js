import { initializeApp } from 'firebase/app';
import { initializeAuth, inMemoryPersistence, connectAuthEmulator, onAuthStateChanged, createUserWithEmailAndPassword, signInWithEmailAndPassword, signInWithCredential, linkWithCredential, reauthenticateWithCredential, EmailAuthProvider, GoogleAuthProvider, signOut } from 'firebase/auth';
import { getFunctions, connectFunctionsEmulator, httpsCallable } from 'firebase/functions';
import { invoke } from '@tauri-apps/api/core';
import './style.css';

const root = document.querySelector('#app');
const key = import.meta.env.VITE_FIREBASE_API_KEY;
const emulator = import.meta.env.DEV && import.meta.env.VITE_AUTH_EMULATOR === '1';
if (!key && !emulator) {
  root.textContent = 'Firebaseの設定がありません。開発手順を確認してください。';
} else {
  const app = initializeApp({apiKey: key || 'demo-key', projectId: emulator ? 'demo-devtrack' : import.meta.env.VITE_FIREBASE_PROJECT_ID});
  const auth = initializeAuth(app, {persistence: inMemoryPersistence});
  if (emulator) connectAuthEmulator(auth, 'http://127.0.0.1:9099', {disableWarnings: true});
  const functions = getFunctions(app, 'asia-northeast1');
  if (emulator) connectFunctionsEmulator(functions, '127.0.0.1', 5001);
  const deletionEnabled = import.meta.env.VITE_ENABLE_DELETION === '1';
  root.innerHTML = `<h1>DevTrack</h1><section id="signed-out"><form><label>メールアドレス<input name="email" type="email" autocomplete="username" required></label><label>パスワード<input name="password" type="password" autocomplete="current-password" required></label><div><button type="submit">ログイン</button><button type="button" id="register">アカウント作成</button></div></form><button id="google">Googleでログイン</button></section><section id="signed-in" hidden><p id="account"></p><button id="link-google">Googleアカウントを連携</button><button id="sign-out">ログアウト</button><div id="deletion" hidden><label>削除確認用パスワード<input id="delete-password" type="password" autocomplete="current-password"></label><button id="delete-password-account">パスワードで再認証して削除</button><button id="delete-google-account">Googleで再認証して削除</button></div></section><p id="deletion-pending">アカウントの完全削除は準備中です。</p><p id="notice" role="status"></p><p id="error" role="alert"></p>`;
  const form = root.querySelector('form');
  const error = root.querySelector('#error');
  let busy = false;
  async function perform(operation) {
    if (busy) return;
    busy = true;
    root.querySelectorAll('button, input').forEach(element => { element.disabled = true; });
    error.textContent = '';
    try { await operation(); form.reset(); } catch (e) { error.textContent = typeof e === 'string' ? e : e.message; }
    finally {
      busy = false;
      root.querySelectorAll('button, input').forEach(element => { element.disabled = false; });
    }
  }
  const credentials = () => [form.elements.email.value, form.elements.password.value];
  form.addEventListener('submit', event => { event.preventDefault(); perform(() => signInWithEmailAndPassword(auth, ...credentials())); });
  root.querySelector('#register').addEventListener('click', () => { if (form.reportValidity()) perform(() => createUserWithEmailAndPassword(auth, ...credentials())); });
  let googleBusy = false;
  async function google(link) {
    if (googleBusy) return;
    googleBusy = true;
    try {
      const user = auth.currentUser;
      if (link && !user) throw new Error('先にログインしてください。');
      const token = await invoke('google_sign_in');
      const credential = GoogleAuthProvider.credential(token);
      if (link) {
        if (auth.currentUser !== user) throw new Error('ログイン状態が変更されました。');
        await linkWithCredential(user, credential);
      } else await signInWithCredential(auth, credential);
    } finally { googleBusy = false; }
  }
  root.querySelector('#google').addEventListener('click', () => perform(() => google(false)));
  root.querySelector('#link-google').addEventListener('click', () => perform(() => google(true)));
  async function removeAccount(useGoogle) {
    if (!window.confirm('アカウントとクラウド上のデータを削除します。この操作は取り消せません。')) return;
    const user = auth.currentUser;
    if (!user) throw new Error('先にログインしてください。');
    const field = root.querySelector('#delete-password');
    const password = field.value;
    field.value = '';
    let credential;
    if (useGoogle) credential = GoogleAuthProvider.credential(await invoke('google_sign_in'));
    else {
      if (!user.email || !password) throw new Error('再認証のためパスワードを入力してください。');
      credential = EmailAuthProvider.credential(user.email, password);
    }
    if (auth.currentUser !== user) throw new Error('ログイン状態が変更されました。');
    await reauthenticateWithCredential(user, credential);
    await user.getIdToken(true);
    if (auth.currentUser !== user) throw new Error('ログイン状態が変更されました。');
    await httpsCallable(functions, 'requestAccountDeletion')({});
    await signOut(auth);
    root.querySelector('#notice').textContent = '削除を受け付けました。クラウド上のデータ削除はバックグラウンドで進行します。';
  }
  root.querySelector('#delete-password-account').addEventListener('click', () => perform(() => removeAccount(false)));
  root.querySelector('#delete-google-account').addEventListener('click', () => perform(() => removeAccount(true)));
  root.querySelector('#sign-out').addEventListener('click', () => perform(() => signOut(auth)));
  onAuthStateChanged(auth, user => {
    root.querySelector('#signed-out').hidden = !!user;
    root.querySelector('#signed-in').hidden = !user;
    root.querySelector('#account').textContent = user?.email ?? '';
    root.querySelector('#deletion').hidden = !user || !deletionEnabled;
    root.querySelector('#deletion-pending').hidden = deletionEnabled;
    root.querySelector('#delete-password-account').hidden = !user?.providerData.some(p => p.providerId === 'password');
    root.querySelector('#delete-google-account').hidden = !user?.providerData.some(p => p.providerId === 'google.com');
  });
}
