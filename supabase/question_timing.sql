-- Grammar Lab · per-question timing
-- Run once in Supabase SQL Editor.

alter table public.answers
  add column if not exists response_seconds integer;

create or replace function public.save_attempt_question_times(
  p_attempt_id uuid,
  p_timings jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  x jsonb;
  qid uuid;
  secs integer;
begin
  if p_timings is null or jsonb_typeof(p_timings) <> 'array' then
    raise exception 'Invalid timings payload';
  end if;
  for x in select value from jsonb_array_elements(p_timings) loop
    begin
      qid := (x->>'question_id')::uuid;
      secs := greatest(0, least(7200, coalesce((x->>'response_seconds')::integer,0)));
    exception when others then
      continue;
    end;
    update public.answers
      set response_seconds = secs
      where attempt_id = p_attempt_id and question_id = qid;
  end loop;
end;
$$;

revoke all on function public.save_attempt_question_times(uuid,jsonb) from public;
grant execute on function public.save_attempt_question_times(uuid,jsonb) to anon, authenticated;

create or replace function public.teacher_question_timings(p_attempt_id uuid)
returns table(question_id uuid, response_seconds integer)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_teacher() then raise exception 'Teacher access required'; end if;
  return query
    select a.question_id, a.response_seconds
    from public.answers a
    where a.attempt_id = p_attempt_id;
end;
$$;

revoke all on function public.teacher_question_timings(uuid) from public;
grant execute on function public.teacher_question_timings(uuid) to authenticated;
