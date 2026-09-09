import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';

// Real PostgreSQL SQL/PLpgSQL and role enforcement, with only Supabase Auth mocked.
const db = new PGlite();
await db.exec(`
  CREATE ROLE anon; CREATE ROLE authenticated;
  CREATE SCHEMA auth;
  CREATE TABLE auth.users(id uuid PRIMARY KEY);
  CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS
    $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  GRANT USAGE ON SCHEMA public, auth TO authenticated, anon;
  GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated, anon;
`);
await db.exec(await readFile(new URL('../supabase/migrations/202609090001_noto_sync.sql', import.meta.url), 'utf8'));
const alice = randomUUID(), bob = randomUUID(), id = randomUUID();
await db.query('INSERT INTO auth.users VALUES ($1),($2)', [alice,bob]);
const login = async (user, role = 'authenticated') => {
  await db.exec('RESET ROLE');
  await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [user ?? '']);
  await db.exec(`SET ROLE ${role}`);
};
const initial = {id,kind:'todo',text:'original',status:'pending',priority:'normal',completed:false,
  createdAt:'2026-09-09T00:00:00Z',updatedAt:'2026-09-09T00:00:00.000Z',hasConversation:true};
const mutate = async (document, base, operation = 'upsert', mutationID = randomUUID()) =>
  (await db.query('SELECT public.noto_apply_mutation($1,$2,$3,$4,$5) AS result',
    [mutationID,document.id,operation,document,base])).rows[0].result;
await login(alice);
await db.exec('RESET ROLE');
await db.query('SELECT public.noto_validate_document($1,$2)', [{...initial,text:'😀'.repeat(50000)},id]);
await login(alice);
const mutationID = randomUUID();
const created = await mutate(initial,null,'upsert',mutationID);
assert.equal(created.outcome,'applied');
assert.equal(created.revision,1);
assert.equal(created.document.hasConversation,false);
assert.deepEqual(await mutate(initial,null,'upsert',mutationID),created);
await assert.rejects(mutate({...initial,text:'reuse'},null,'upsert',mutationID), /Mutation ID already used/);
await assert.rejects(db.query('UPDATE public.noto_tasks SET deleted=true'), /permission denied/);
await assert.rejects(db.query('SELECT * FROM public.noto_mutations'), /permission denied/);

const mac = await mutate({...created.document,text:'Mac title'}, created.document);
const phone = await mutate({...created.document,priority:'important',due:'2026-09-12'},created.document);
assert.equal(phone.document.text,'Mac title');
assert.equal(phone.document.priority,'important');
assert.equal(phone.document.due,'2026-09-12');
const conflicting = {...created.document,text:'offline phone title'};
const conflicted = await mutate(conflicting,created.document);
assert.equal(conflicted.outcome,'conflict');
assert.equal(conflicted.document.text,'Mac title');
assert.equal((await db.query('SELECT document FROM public.noto_conflicts')).rows[0].document.text,conflicting.text);

// Formatting alone must not create date/completion conflicts.
const completed = await mutate({...phone.document,status:'completed',completed:true,completedAt:'2026-09-09T08:00:00+08:00'},phone.document);
const alternateFormat = {...completed.document,createdAt:'2026-09-09T00:00:00.000Z',completedAt:'2026-09-09T00:00:00Z'};
const normalized = await mutate({...alternateFormat,text:'formatted edit'},alternateFormat);
assert.equal(normalized.outcome,'applied');
assert.equal(normalized.document.completedAt,'2026-09-09T00:00:00.000Z');
const duplicate = await mutate(normalized.document,normalized.document);
assert.equal(duplicate.revision,normalized.revision);
// An immutable field cannot be changed even when another field changes.
const immutable = await mutate({...normalized.document,createdAt:'2030-01-01T00:00:00Z',text:'immutable check'},normalized.document);
assert.equal(immutable.document.createdAt,normalized.document.createdAt);
const deleted = await mutate(immutable.document,immutable.document,'delete');
assert.equal(deleted.outcome,'deleted');
const late = await mutate({...immutable.document,text:'late offline text'},immutable.document);
assert.equal(late.outcome,'deleted');
assert.equal(late.deleted,true);
assert.ok((await db.query('SELECT document FROM public.noto_conflicts')).rows.some(r => r.document.text === 'late offline text'));
const badRestore = await mutate({...immutable.document,text:'restore'},created.document,'restore');
assert.equal(badRestore.outcome,'conflict');
assert.equal(badRestore.deleted,true);
assert.equal((await mutate(deleted.document,null,'restore')).outcome,'conflict');
const restore = await mutate(deleted.document,deleted.document,'restore');
assert.equal(restore.deleted,false);
assert.equal(restore.outcome,'applied');

for (const change of [{kind:'note'},{status:'bad'},{priority:'bad'},{completed:false},{completedAt:'yesterday'},
  {text:'x'.repeat(50001)},{text:'😀'.repeat(50001)},
  {updatedAt:'not-a-date'},{due:'2026-02-30'},{text:''},{injected:true},{hasConversation:'yes'}]) {
  await assert.rejects(mutate({...restore.document,...change},restore.document));
}
await login(bob);
assert.equal((await db.query('SELECT * FROM public.noto_tasks')).rows.length,0);
assert.equal((await db.query('SELECT * FROM public.noto_conflicts')).rows.length,0);
await assert.rejects(mutate(initial,null), /Task unavailable/);
await assert.rejects(mutate(initial,null,'upsert',mutationID), /Mutation ID already used/);
await assert.rejects(mutate(initial,null,'delete'), /Task unavailable/);
await assert.rejects(mutate(initial,null,'restore'), /Task unavailable/);
await login(null,'anon');
await assert.rejects(mutate(initial,null), /permission denied/);
await assert.rejects(db.query('SELECT * FROM public.noto_tasks'), /permission denied/);
await login(null);
await assert.rejects(mutate(initial,null), /Authentication required/);
// Delete-before-first-upload must create a tombstone, never a visible zombie.
await login(alice);
const offline = {...initial,id:randomUUID()};
assert.equal((await mutate(offline,null,'delete')).deleted,true);
assert.equal((await mutate(offline,null)).deleted,true);
const chain = {...initial,id:randomUUID()};
await mutate(chain,null);
await mutate(chain,chain,'delete');
assert.equal((await mutate(chain,chain,'restore')).outcome,'applied');
await db.close();
console.log('PASS: PostgreSQL contract: merge, conflict retention, normalization, tombstones, restore, idempotency, validation, RLS and account isolation.');
