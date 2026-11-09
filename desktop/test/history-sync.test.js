import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import {initializeApp, deleteApp} from 'firebase/app';
import {initializeAuth, inMemoryPersistence, connectAuthEmulator, createUserWithEmailAndPassword, signInWithEmailAndPassword, deleteUser} from 'firebase/auth';
import {initializeFirestore, memoryLocalCache, connectFirestoreEmulator, doc, getDocFromServer, runTransaction, serverTimestamp, terminate, writeBatch} from 'firebase/firestore';
import {syncHistory} from '../src/history-sync.js';

const binary = join(dirname(fileURLToPath(import.meta.url)), `../src-tauri/target/debug/examples/history_bridge${process.platform === 'win32' ? '.exe' : ''}`);
const config = {apiKey:'demo-key', projectId:'demo-devtrack'};
function environment(suffix) {
  const app = initializeApp(config, suffix), auth = initializeAuth(app, {persistence:inMemoryPersistence});
  connectAuthEmulator(auth,'http://127.0.0.1:9099',{disableWarnings:true});
  const db = initializeFirestore(app,{localCache:memoryLocalCache()}); connectFirestoreEmulator(db,'127.0.0.1',8080);
  return {app,auth,db};
}
function adapter(base, uid) {
  const call = (action, fields = {}) => {
    const process = spawnSync(binary,[],{input:JSON.stringify({base,uid,action,...fields}),encoding:'utf8',timeout:10000});
    if (process.status !== 0) throw new Error('SQLite test bridge failed');
    const result = JSON.parse(process.stdout); if (result.error) throw new Error(result.error); return result.ok;
  };
  return {call, pending:async()=>call('pending'), ack:async operationId=>call('ack',{operationId}), conflict:async record=>call('conflict',{record}),
    apply:async(record,cursor)=>call('apply',{record,cursor}),syncInfo:async()=>call('info'),markSweep:async()=>call('sweep')};
}
const draft=(note='first')=>({id:null,expectedVersion:null,projectName:'Shared Project',categoryName:'一般',start:100.123456,end:200.987654,note});
async function remoteEdit(db, uid, old, note) {
  const history=doc(db,'users',uid,'history',old.id), operationID=randomUUID(), op=doc(db,'users',uid,'historyOps',operationID);
  const record={...old,version:old.version+1,operationID,note};
  await runTransaction(db,async tx=>{const s=await tx.get(history);assert.equal(s.data().version,old.version);tx.set(history,record);tx.set(op,{...record,committedAt:serverTimestamp()});});
  return record;
}

test('PC SQLite and iOS-format Firestore changes synchronize, retry, and preserve conflicts', {timeout:45000}, async () => {
  const base=mkdtempSync(join(tmpdir(),'devtrack-pc-sync-')), suffix=randomUUID();
  const pc=environment(`pc-${suffix}`), ios=environment(`ios-${suffix}`), offlineApp=initializeApp(config,`offline-${suffix}`);
  const offline=initializeFirestore(offlineApp,{localCache:memoryLocalCache()});connectFirestoreEmulator(offline,'127.0.0.1',1);
  try {
    const email=`pc-sync-${suffix}@example.test`, password='test-password-123';
    const user=(await createUserWithEmailAndPassword(pc.auth,email,password)).user;
    assert.equal((await signInWithEmailAndPassword(ios.auth,email,password)).user.uid,user.uid);
    const local=adapter(base,user.uid), current=()=>pc.auth.currentUser?.uid===user.uid;
    let record=local.call('save',{edit:draft()});
    await assert.rejects(syncHistory({db:offline,uid:user.uid,current,local,timeoutMs:1000}));
    assert.equal(local.call('state').pending,1);
    assert.equal(adapter(base,'different-user').call('state').records.length,0);
    await syncHistory({db:pc.db,uid:user.uid,current,local});
    assert.equal(local.call('state').pending,0);
    assert.equal((await getDocFromServer(doc(ios.db,'users',user.uid,'history',record.id))).data().note,'first');
    record=await remoteEdit(ios.db,user.uid,record,'from iOS');
    await syncHistory({db:pc.db,uid:user.uid,current,local});
    assert.equal(local.call('state').records[0].note,'from iOS');
    assert.equal(local.call('state').records[0].start,100.123456);
    const localEdit=local.call('save',{edit:{...draft('from PC'),id:record.id,expectedVersion:2}});
    const remote=await remoteEdit(ios.db,user.uid,record,'simultaneous iOS');
    await syncHistory({db:pc.db,uid:user.uid,current,local});
    let state=local.call('state'); assert.equal(state.pending,1); assert.equal(state.conflicts.length,1);
    assert.equal(state.conflicts[0].local.note,'from PC');assert.equal(state.conflicts[0].remote.note,'simultaneous iOS');
    local.call('resolve',{id:record.id,keepLocal:true});
    await syncHistory({db:pc.db,uid:user.uid,current,local});
    record=(await getDocFromServer(doc(ios.db,'users',user.uid,'history',record.id))).data();
    assert.equal(record.note,'from PC');assert.equal(record.version,4);assert.notEqual(localEdit.operationID,remote.operationID);
    local.call('delete',{id:record.id,version:record.version}); await syncHistory({db:pc.db,uid:user.uid,current,local});
    assert.equal((await getDocFromServer(doc(ios.db,'users',user.uid,'history',record.id))).data().deleted,true);
    const second=local.call('save',{edit:draft('lost acknowledgement')});
    const batch=writeBatch(pc.db);batch.set(doc(pc.db,'users',user.uid,'history',second.id),second);batch.set(doc(pc.db,'users',user.uid,'historyOps',second.operationID),{...second,committedAt:serverTimestamp()});await batch.commit();
    await syncHistory({db:pc.db,uid:user.uid,current,local});assert.equal(local.call('state').pending,0);
    local.call('save',{edit:draft('account changed during sync')});
    let checks=0;
    await assert.rejects(syncHistory({db:pc.db,uid:user.uid,current:()=>++checks<3,local}));
    assert.equal(local.call('state').pending,1);
    assert.equal(adapter(base,'different-user').call('state').records.length,0);
    await syncHistory({db:pc.db,uid:user.uid,current,local});assert.equal(local.call('state').pending,0);
  } finally {
    if(pc.auth.currentUser) await deleteUser(pc.auth.currentUser).catch(()=>{});
    await Promise.all([terminate(pc.db),terminate(ios.db),terminate(offline)]);
    await Promise.all([deleteApp(pc.app),deleteApp(ios.app),deleteApp(offlineApp)]);
    rmSync(base,{recursive:true,force:true});
  }
});
