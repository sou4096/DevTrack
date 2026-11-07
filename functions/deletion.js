// Domain workflow only. This is not deployed or exposed to clients.
// adapters must be trusted server-side implementations; operations must be idempotent.
export async function beginDeletion({ uid, authTime }, adapters, nowSeconds = Date.now() / 1000) {
  if (!uid || !Number.isFinite(authTime) || authTime > nowSeconds || nowSeconds - authTime > 300) {
    throw new Error('recent authentication required');
  }
  // Persist an access-blocking tombstone before touching account data. Rules and
  // every server writer must enforce it; a separate trusted worker must retry.
  await adapters.blockWritesAndEnqueue(uid);
  await continueDeletion(uid, adapters);
}

export async function continueDeletion(uid, adapters) {
  // A retry after account deletion must treat an absent Auth user as success.
  await adapters.disableUserIfPresent(uid);
  // Must recursively remove every documented UID-scoped store and local data
  // must be addressed separately. Deleting only the parent document is unsafe.
  await adapters.deleteUserDataRecursively(uid);
  await adapters.deleteAuthUserIfPresent(uid);
  await adapters.markComplete(uid);
}
