-- Run as the Supabase migration owner. All client writes go through the RPC.
create table public.noto_tasks (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  document jsonb not null,
  revision bigint not null default 1 check (revision > 0),
  deleted boolean not null default false,
  updated_at timestamptz not null default now()
);
create index noto_tasks_owner on public.noto_tasks(user_id);
create table public.noto_conflicts (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  task_id uuid not null references public.noto_tasks(id) on delete cascade,
  document jsonb not null,
  created_at timestamptz not null default now()
);
create index noto_conflicts_owner on public.noto_conflicts(user_id);
create table public.noto_mutations (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  request jsonb not null,
  response jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.noto_tasks enable row level security;
alter table public.noto_conflicts enable row level security;
alter table public.noto_mutations enable row level security;
revoke all on public.noto_tasks, public.noto_conflicts, public.noto_mutations from anon, authenticated;
grant select on public.noto_tasks, public.noto_conflicts to authenticated;
create policy own_tasks on public.noto_tasks for select to authenticated using ((select auth.uid()) = user_id);
create policy own_conflicts on public.noto_conflicts for select to authenticated using ((select auth.uid()) = user_id);

create function public.noto_validate_document(doc jsonb, task_id uuid)
returns void language plpgsql set search_path = '' as $$
declare key text;
begin
  if jsonb_typeof(doc) is distinct from 'object'
    or (doc->>'id')::uuid is distinct from task_id
    or doc->>'kind' is distinct from 'todo'
    or jsonb_typeof(doc->'text') is distinct from 'string'
    or nullif(btrim(doc->>'text'), '') is null
    or char_length(doc->>'text') > 50000
    or doc->>'status' is null or doc->>'status' not in ('pending', 'in_progress', 'completed')
    or doc->>'priority' is null or doc->>'priority' not in ('normal', 'important')
    or jsonb_typeof(doc->'completed') is distinct from 'boolean'
    or (doc->>'completed')::boolean is distinct from (doc->>'status' = 'completed')
    or ((doc->>'completedAt') is not null) is distinct from (doc->>'status' = 'completed')
  then raise exception 'Invalid task document' using errcode = '22023'; end if;
  for key in select jsonb_object_keys(doc) loop
    if key not in ('id','kind','text','due','completed','status','priority','completedAt','createdAt','updatedAt','hasConversation') then
      raise exception 'Unknown task field: %', key using errcode = '22023';
    end if;
  end loop;
  if doc ? 'hasConversation' and jsonb_typeof(doc->'hasConversation') <> 'boolean' then
    raise exception 'Invalid hasConversation' using errcode = '22023';
  end if;
  foreach key in array array['createdAt', 'updatedAt'] loop
    if coalesce(doc->>key, '') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$' then
      raise exception 'Invalid ISO8601 date: %', key using errcode = '22023';
    end if;
    perform (doc->>key)::timestamptz;
  end loop;
  if doc->>'completedAt' is not null then
    if doc->>'completedAt' !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$' then
      raise exception 'Invalid completedAt' using errcode = '22023';
    end if;
    perform (doc->>'completedAt')::timestamptz;
  end if;
  if doc->>'due' is not null then
    if doc->>'due' !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Invalid due' using errcode = '22023'; end if;
    perform (doc->>'due')::date;
  end if;
end $$;
revoke all on function public.noto_validate_document(jsonb, uuid) from public, anon, authenticated;

create function public.noto_normalize_document(doc jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare key text;
begin
  if doc is null or doc = 'null'::jsonb then return null; end if;
  perform public.noto_validate_document(doc, (doc->>'id')::uuid);
  doc := doc || jsonb_build_object('id', lower(doc->>'id'), 'hasConversation', false);
  foreach key in array array['createdAt','updatedAt','completedAt'] loop
    if doc->>key is not null then
      doc := jsonb_set(doc,array[key],to_jsonb(to_char((doc->>key)::timestamptz at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')));
    else doc := doc - key; end if;
  end loop;
  if doc->>'due' is null then doc := doc - 'due'; end if;
  return doc;
end $$;
revoke all on function public.noto_normalize_document(jsonb) from public, anon, authenticated;

create function public.noto_apply_mutation(
  p_mutation_id uuid, p_task_id uuid, p_operation text,
  p_document jsonb, p_base_document jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  owner_id uuid := auth.uid();
  req jsonb := jsonb_build_object('task_id',p_task_id,'operation',p_operation,'document',p_document,'base_document',p_base_document);
  previous public.noto_mutations;
  task public.noto_tasks;
  merged jsonb;
  field text;
  local_completion jsonb;
  base_completion jsonb;
  server_completion jsonb;
  conflict boolean := false;
  result jsonb;
  outcome text := 'applied';
begin
  if owner_id is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if p_mutation_id is null or p_task_id is null or p_operation is null or p_operation not in ('upsert','delete','restore') then
    raise exception 'Invalid mutation' using errcode = '22023';
  end if;
  -- Serialize identical mutation IDs, then task IDs, including first insert races.
  perform pg_advisory_xact_lock(hashtextextended('noto-mutation:' || p_mutation_id::text, 0));
  select * into previous from public.noto_mutations where id = p_mutation_id;
  if found then
    if previous.user_id <> owner_id or previous.request <> req then
      raise exception 'Mutation ID already used' using errcode = '22023';
    end if;
    return previous.response;
  end if;
  perform public.noto_validate_document(p_document, p_task_id);
  p_document := public.noto_normalize_document(p_document);
  p_base_document := public.noto_normalize_document(p_base_document);
  if p_base_document is not null and p_base_document <> 'null'::jsonb then
    perform public.noto_validate_document(p_base_document, p_task_id);
  end if;
  perform pg_advisory_xact_lock(hashtextextended('noto-task:' || p_task_id::text, 0));
  select * into task from public.noto_tasks where id = p_task_id for update;
  if found then
    if task.user_id <> owner_id then raise exception 'Task unavailable' using errcode = '42501'; end if;
    if p_operation = 'delete' then
      -- Deletes win over offline edits, but preserve the server document for restore.
      if not task.deleted then
        update public.noto_tasks set deleted = true, revision = revision + 1, updated_at = now() where id = p_task_id returning * into task;
      end if;
      outcome := 'deleted';
    elsif task.deleted and p_operation = 'upsert' then
      outcome := 'deleted';
      -- Preserve a late offline edit even though it cannot resurrect a task.
      if p_document is distinct from task.document then
        insert into public.noto_conflicts(id,user_id,task_id,document) values(p_mutation_id,owner_id,p_task_id,p_document);
      end if;
    else
      merged := task.document;
      if p_base_document is null or p_base_document = 'null'::jsonb then
        conflict := p_operation = 'restore' or p_document <> task.document;
      elsif p_operation = 'restore' then
        conflict := not task.deleted or (p_base_document - 'updatedAt' - 'hasConversation') <> (task.document - 'updatedAt' - 'hasConversation');
        merged := p_document || jsonb_build_object('createdAt',task.document->'createdAt','id',task.document->'id','kind','todo');
      else
        -- Completion fields form one atomic group. Metadata never creates a conflict.
        if (p_document - 'updatedAt' - 'hasConversation' - 'createdAt' - 'id') = (p_base_document - 'updatedAt' - 'hasConversation' - 'createdAt' - 'id') then
          merged := task.document;
        else
          for field in select unnest(array['text','due','priority','status']) loop
            if field = 'status' then
              local_completion := jsonb_build_array(p_document->'status',p_document->'completed',p_document->'completedAt');
              base_completion := jsonb_build_array(p_base_document->'status',p_base_document->'completed',p_base_document->'completedAt');
              server_completion := jsonb_build_array(task.document->'status',task.document->'completed',task.document->'completedAt');
              if local_completion is distinct from base_completion then
                if server_completion is distinct from base_completion and server_completion is distinct from local_completion then conflict := true;
                else merged := (merged - 'completedAt') || jsonb_build_object('status',p_document->'status','completed',p_document->'completed') ||
                  case when p_document ? 'completedAt' then jsonb_build_object('completedAt',p_document->'completedAt') else '{}'::jsonb end; end if;
              end if;
            elsif (p_document->field) is distinct from (p_base_document->field) then
              if (task.document->field) is distinct from (p_base_document->field) and (task.document->field) is distinct from (p_document->field) then conflict := true;
              elsif p_document ? field then merged := jsonb_set(merged,array[field],p_document->field);
              else merged := merged - field; end if;
            end if;
          end loop;
          -- updatedAt is server-owned and does not influence conflict detection.
        end if;
      end if;
      if conflict then
        insert into public.noto_conflicts(id,user_id,task_id,document) values(p_mutation_id,owner_id,p_task_id,p_document);
        outcome := 'conflict';
      elsif merged <> task.document or task.deleted then
        merged := merged || jsonb_build_object('updatedAt',to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
        perform public.noto_validate_document(merged,p_task_id);
        update public.noto_tasks set document = merged, deleted = false, revision = revision + 1, updated_at = now() where id = p_task_id returning * into task;
      end if;
    end if;
  else
    if p_operation = 'restore' then raise exception 'Cannot restore missing task' using errcode = '22023'; end if;
    p_document := p_document || jsonb_build_object('updatedAt',to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
    insert into public.noto_tasks(id,user_id,document,deleted) values(p_task_id,owner_id,p_document,p_operation = 'delete') returning * into task;
    if task.deleted then outcome := 'deleted'; end if;
  end if;
  result := jsonb_build_object('outcome',outcome,'revision',task.revision,'document',task.document,'deleted',task.deleted);
  insert into public.noto_mutations(id,user_id,request,response) values(p_mutation_id,owner_id,req,result);
  return result;
end $$;
revoke all on function public.noto_apply_mutation(uuid,uuid,text,jsonb,jsonb) from public, anon;
grant execute on function public.noto_apply_mutation(uuid,uuid,text,jsonb,jsonb) to authenticated;

-- Configure the dedicated PowerSync replication role separately with a generated secret.
alter table public.noto_tasks replica identity full;
alter table public.noto_conflicts replica identity full;
create publication powersync for table public.noto_tasks, public.noto_conflicts;
