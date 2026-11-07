// Authentication adapter for Firebase client SDK consumers. Never logs credentials.
import {
  createUserWithEmailAndPassword, signInWithEmailAndPassword,
  signOut, linkWithCredential, signInWithCredential, GoogleAuthProvider,
  EmailAuthProvider, reauthenticateWithCredential, deleteUser
} from 'firebase/auth';

export function createAuthService(auth) {
  return {
    register: (email, password) => createUserWithEmailAndPassword(auth, email, password),
    signIn: (email, password) => signInWithEmailAndPassword(auth, email, password),
    signOut: () => signOut(auth),
    signInWithGoogleToken: (idToken, accessToken) =>
      signInWithCredential(auth, GoogleAuthProvider.credential(idToken, accessToken)),
    // Call only after explicit user intent while signed in to the account to keep.
    linkGoogleToken: (idToken, accessToken) => {
      if (!auth.currentUser) throw new Error('Sign in before linking an account');
      return linkWithCredential(auth.currentUser, GoogleAuthProvider.credential(idToken, accessToken));
    },
    reauthenticatePassword: (password) => {
      const user = auth.currentUser;
      if (!user?.email) throw new Error('An email account must be signed in');
      return reauthenticateWithCredential(user, EmailAuthProvider.credential(user.email, password));
    },
    // Authentication account only: application data deletion requires a separate trusted workflow.
    deleteAuthAccount: () => {
      if (!auth.currentUser) throw new Error('No signed-in account');
      return deleteUser(auth.currentUser);
    }
  };
}
