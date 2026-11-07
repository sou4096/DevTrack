import { test } from 'node:test';
import assert from 'node:assert/strict';
import { beginDeletion, continueDeletion } from '../server/deletion.js';

function adapters(log, failAt) {
  return Object.fromEntries(['blockWritesAndEnqueue','disableUserIfPresent','deleteUserDataRecursively','deleteAuthUserIfPresent','markComplete'].map(name => [name, async uid => {
    log.push([name, uid]);
    if (name === failAt) throw new Error('simulated failure');
  }]));
}
test('rejects missing or stale authentication before performing deletion', async () => {
  const log = [];
  for (const authTime of [undefined, 699, 1001]) {
    await assert.rejects(beginDeletion({uid: 'u', authTime}, adapters(log), 1000));
  }
  assert.deepEqual(log, []);
});
test('blocks writes before disabling access and deleting data and auth', async () => {
  const log = [];
  await beginDeletion({uid: 'u', authTime: 900}, adapters(log), 1000);
  assert.deepEqual(log.map(x => x[0]), ['blockWritesAndEnqueue','disableUserIfPresent','deleteUserDataRecursively','deleteAuthUserIfPresent','markComplete']);
});
test('does not delete the auth user when data deletion fails; trusted worker can retry', async () => {
  const log = [];
  await assert.rejects(beginDeletion({uid: 'u', authTime: 900}, adapters(log, 'deleteUserDataRecursively'), 1000));
  assert.equal(log.some(x => x[0] === 'deleteAuthUserIfPresent'), false);
  const retry = [];
  await continueDeletion('u', adapters(retry));
  assert.deepEqual(retry.map(x => x[0]), ['disableUserIfPresent','deleteUserDataRecursively','deleteAuthUserIfPresent','markComplete']);
});
