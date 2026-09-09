import { readFile, writeFile } from 'node:fs/promises';
const status = JSON.parse(await readFile(new URL('../.local-docker/status.json',import.meta.url),'utf8'));
const url = status.API_URL;
if (!['127.0.0.1','localhost'].includes(new URL(url).hostname)) throw new Error('Fixtures must only target local services');
const password = 'Noto-local-only-2026!';
const accounts = ['alice@noto.local','bob@noto.local'];
for (const email of accounts) {
  const existing = await fetch(`${url}/auth/v1/admin/users`,{headers:{apikey:status.ANON_KEY,Authorization:`Bearer ${status.SERVICE_ROLE_KEY}`}}).then(r=>r.json());
  if (!existing.users?.some(user=>user.email === email)) {
    const r = await fetch(`${url}/auth/v1/admin/users`,{method:'POST',headers:{apikey:status.ANON_KEY,Authorization:`Bearer ${status.SERVICE_ROLE_KEY}`,'Content-Type':'application/json'},body:JSON.stringify({email,password,email_confirm:true})});
    if (!r.ok) throw new Error(await r.text());
  }
}
const all = await fetch(`${url}/auth/v1/admin/users`,{headers:{apikey:status.ANON_KEY,Authorization:`Bearer ${status.SERVICE_ROLE_KEY}`}}).then(r=>r.json());
const fixture = {supabaseURL:url,publishableKey:status.ANON_KEY,powerSyncURL:'http://127.0.0.1:8080',users:accounts.map(email=>({email,password,id:all.users.find(user=>user.email===email).id}))};
await writeFile(new URL('../.local-docker/client-fixture.json',import.meta.url),JSON.stringify(fixture,null,2));
console.log('Local test users ready. Client configuration: backend/.local-docker/client-fixture.json');
