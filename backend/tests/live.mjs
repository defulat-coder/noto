import assert from 'node:assert/strict';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { PowerSyncDatabase, Schema, Table, column } from '@powersync/node';

const fixture = JSON.parse(await readFile(new URL('../.local-docker/client-fixture.json',import.meta.url),'utf8'));
if (new URL(fixture.supabaseURL).hostname !== '127.0.0.1') throw new Error('Live test is restricted to local services');
const call = async (path, token, body, method = 'POST') => {
  const r = await fetch(fixture.supabaseURL+path,{method,headers:{apikey:fixture.publishableKey,Authorization:`Bearer ${token ?? fixture.publishableKey}`,'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})});
  if (!r.ok) throw new Error(`${r.status}: ${await r.text()}`);
  return r.json();
};
const login = ({email,password}) => call('/auth/v1/token?grant_type=password',null,{email,password});
const alice = await login(fixture.users[0]), bob = await login(fixture.users[1]);
const schema = new Schema({
  noto_tasks:new Table({user_id:column.text,document:column.text,revision:column.integer,deleted:column.integer,updated_at:column.text}),
  noto_conflicts:new Table({user_id:column.text,task_id:column.text,document:column.text,created_at:column.text})
});
const directory = await mkdtemp(join(tmpdir(),'noto-live-'));
const clients = [];
const connect = async (name,session) => {
  const db = new PowerSyncDatabase({schema,database:{dbFilename:join(directory,`${name}.sqlite`)}});
  clients.push(db);
  await db.init();
  await db.connect({fetchCredentials:async()=>({endpoint:fixture.powerSyncURL,token:session.access_token}),uploadData:async()=>{throw new Error('This test uploads through RPC, never direct table writes');}});
  await db.waitForFirstSync(AbortSignal.timeout(45000));
  return db;
};
const wait = async (test,label) => {
  const end = Date.now()+30000;
  while (Date.now()<end) {if (await test()) return; await new Promise(resolve=>setTimeout(resolve,100));}
  throw new Error(`Timed out: ${label}`);
};
try {
  const mac = await connect('mac',alice), phone = await connect('phone',alice), other = await connect('other-account',bob);
  const id = randomUUID();
  const document = {id,kind:'todo',text:'Live original',status:'pending',priority:'normal',completed:false,createdAt:new Date().toISOString(),updatedAt:new Date().toISOString(),hasConversation:false};
  const mutate = (doc,base,operation='upsert',mutationID=randomUUID(),session=alice) => call('/rest/v1/rpc/noto_apply_mutation',session.access_token,{p_mutation_id:mutationID,p_task_id:id,p_operation:operation,p_document:doc,p_base_document:base});
  const get = async db => {const rows=await db.getAll('SELECT * FROM noto_tasks WHERE id = ?',[id]);return rows[0];};
  await assert.rejects(mutate({...document,text:'x'.repeat(50001)},null),/400|22023/);
  await assert.rejects(mutate({...document,text:'😀'.repeat(50001)},null),/400|22023/);
  const createID = randomUUID();
  const [created,replayed] = await Promise.all([mutate(document,null,'upsert',createID),mutate(document,null,'upsert',createID)]);
  assert.deepEqual(created,replayed);
  await wait(async()=>Boolean(await get(mac))&&Boolean(await get(phone)),'initial two-client download');
  assert.equal(await get(other),undefined);
  assert.equal(JSON.parse((await get(phone)).document).text,'Live original');
  console.log('PASS: real Auth, RPC, logical replication and two independent SQLite downloads; third account isolated.');

  const macEdit = await mutate({...created.document,text:'Mac title'},created.document);
  const phoneEdit = await mutate({...created.document,due:'2026-10-01'},created.document);
  assert.equal(phoneEdit.document.text,'Mac title');
  await wait(async()=>Number((await get(mac)).revision)===phoneEdit.revision&&Number((await get(phone)).revision)===phoneEdit.revision,'merged revision');
  const conflict = await mutate({...created.document,text:'Phone offline title'},created.document);
  assert.equal(conflict.outcome,'conflict');
  await wait(async()=>(await phone.getAll('SELECT * FROM noto_conflicts WHERE task_id = ?',[id])).length===1,'conflict download');
  assert.equal((await other.getAll('SELECT * FROM noto_conflicts WHERE task_id = ?',[id])).length,0);
  console.log('PASS: different-field merge and same-field conflict retention downloaded through PowerSync.');

  await Promise.all([
    mutate({...phoneEdit.document,priority:'important'},phoneEdit.document),
    mutate({...phoneEdit.document,status:'in_progress'},phoneEdit.document)
  ]);
  await wait(async()=>{const d=JSON.parse((await get(phone)).document);return d.priority==='important'&&d.status==='in_progress';},'concurrent merge');
  console.log('PASS: multi-session identical-mutation replay and concurrent independent-field writes.');
  const deletion = await mutate(phoneEdit.document,phoneEdit.document,'delete');
  await wait(async()=>Number((await get(phone)).deleted)===1,'tombstone download');
  assert.equal((await mutate({...phoneEdit.document,text:'Late offline'},phoneEdit.document)).outcome,'deleted');
  const restored = await mutate(deletion.document,deletion.document,'restore');
  await wait(async()=>Number((await get(phone)).revision)===restored.revision&&Number((await get(phone)).deleted)===0,'restore download');
  await assert.rejects(mutate(document,null,'upsert',randomUUID(),bob),/403|42501/);
  const bobRows = await call('/rest/v1/noto_tasks?select=id',bob.access_token,undefined,'GET');
  assert.ok(!bobRows.some(row=>row.id===id));
  console.log('PASS: deletion, stale-upload rejection, restore and REST/RPC account isolation.');
  await mutate(restored.document,restored.document,'delete');
} finally {
  await Promise.allSettled(clients.map(db=>db.close()));
  await rm(directory,{recursive:true,force:true});
}
