import { initializeApp } from 'firebase/app';
import { initializeAuth, inMemoryPersistence, connectAuthEmulator, onAuthStateChanged, createUserWithEmailAndPassword, signInWithEmailAndPassword, signOut } from 'firebase/auth';
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
  root.innerHTML = `<h1>DevTrack</h1><section id="signed-out"><form><label>メールアドレス<input name="email" type="email" autocomplete="username" required></label><label>パスワード<input name="password" type="password" autocomplete="current-password" required></label><div><button type="submit">ログイン</button><button type="button" id="register">アカウント作成</button></div></form></section><section id="signed-in" hidden><p id="account"></p><button id="sign-out">ログアウト</button></section><p>Googleログインとアカウントの完全削除は準備中です。</p><p id="error" role="alert"></p>`;
  const form = root.querySelector('form');
  const error = root.querySelector('#error');
  async function perform(operation) {
    error.textContent = '';
    try { await operation(); form.reset(); } catch (e) { error.textContent = e.message; }
  }
  const credentials = () => [form.elements.email.value, form.elements.password.value];
  form.addEventListener('submit', event => { event.preventDefault(); perform(() => signInWithEmailAndPassword(auth, ...credentials())); });
  root.querySelector('#register').addEventListener('click', () => { if (form.reportValidity()) perform(() => createUserWithEmailAndPassword(auth, ...credentials())); });
  root.querySelector('#sign-out').addEventListener('click', () => perform(() => signOut(auth)));
  onAuthStateChanged(auth, user => {
    root.querySelector('#signed-out').hidden = !!user;
    root.querySelector('#signed-in').hidden = !user;
    root.querySelector('#account').textContent = user?.email ?? '';
  });
}
