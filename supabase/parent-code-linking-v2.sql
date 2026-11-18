-- AQDAR parent-code linking v2
-- Run after the existing parent-accounts-and-linking.sql migration.
-- Parent enters a one-time student code; the link is immediate and read-only.

create extension if not exists pgcrypto;

-- Keep account roles in the database. Public registration can create only student/parent.
create or replace function public.aqdar_apply_signup_role()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  requested_role text;
begin
  select lower(coalesce(u.raw_user_meta_data->>'requested_role', 'student'))
    into requested_role
  from auth.users u
  where u.id = new.id;

  if requested_role not in ('student', 'parent') then
    requested_role := 'student';
  end if;

  if lower(coalesce(new.role, '')) not in ('teacher', 'admin') then
    new.role := requested_role;
  end if;
  return new;
end;
$$;

drop trigger if exists aqdar_signup_role_on_profile on public.profiles;
create trigger aqdar_signup_role_on_profile
before insert on public.profiles
for each row execute function public.aqdar_apply_signup_role();

create or replace function public.aqdar_protect_profile_role()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and auth.uid() = old.id
     and not exists (
       select 1 from public.profiles p
       where p.id = auth.uid() and p.role = 'admin'
     ) then
    new.role := old.role;
  end if;
  return new;
end;
$$;

drop trigger if exists aqdar_protect_profile_role_trigger on public.profiles;
create trigger aqdar_protect_profile_role_trigger
before update of role on public.profiles
for each row execute function public.aqdar_protect_profile_role();

-- A student has one active code at a time. Only its SHA-256 hash is stored.
create table if not exists public.student_link_codes (
  student_id uuid primary key references public.profiles(id) on delete cascade,
  code text unique,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 days'),
  active boolean not null default true
);

alter table public.student_link_codes
  add column if not exists code_hash text,
  add column if not exists redeemed_at timestamptz,
  add column if not exists redeemed_by uuid references public.profiles(id);

alter table public.student_link_codes alter column code drop not null;

-- Migrate any legacy plaintext codes to hashes, then erase the plaintext values.
update public.student_link_codes
set code_hash = encode(digest(upper(btrim(code)), 'sha256'), 'hex'),
    code = null
where code is not null and code_hash is null;

create unique index if not exists student_link_codes_code_hash_uidx
  on public.student_link_codes(code_hash)
  where code_hash is not null;

create table if not exists public.parent_students (
  parent_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  approved_by uuid references public.profiles(id),
  approved_at timestamptz not null default now(),
  active boolean not null default true,
  primary key (parent_id, student_id)
);

-- Older versions required a teacher approver. Direct one-time code redemption does not.
alter table public.parent_students alter column approved_by drop not null;
alter table public.parent_students enable row level security;
alter table public.student_link_codes enable row level security;

-- Remove parent-side table mutation paths. Linking happens only through the checked RPC.
revoke all on public.student_link_codes from anon, authenticated;
revoke all on public.parent_students from anon, authenticated;
grant select on public.parent_students to authenticated;

drop policy if exists "parent reads own approved links" on public.parent_students;
drop policy if exists "parent reads own links" on public.parent_students;
create policy "parent reads own links" on public.parent_students
for select to authenticated
using (parent_id = auth.uid() and active = true);

create or replace function public.aqdar_get_my_student_code()
returns text
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
  generated_code text;
begin
  if uid is null or not exists (
    select 1 from public.profiles p where p.id = uid and p.role = 'student'
  ) then
    raise exception 'إنشاء الكود متاح لحساب الطالب فقط';
  end if;

  generated_code := 'AQD-' || upper(encode(gen_random_bytes(6), 'hex'));

  insert into public.student_link_codes
    (student_id, code, code_hash, created_at, expires_at, active, redeemed_at, redeemed_by)
  values
    (uid, null, encode(digest(generated_code, 'sha256'), 'hex'),
     now(), now() + interval '30 days', true, null, null)
  on conflict (student_id) do update
    set code = null,
        code_hash = excluded.code_hash,
        created_at = now(),
        expires_at = now() + interval '30 days',
        active = true,
        redeemed_at = null,
        redeemed_by = null;

  -- This is the only time the clear-text code is returned.
  return generated_code;
end;
$$;

create or replace function public.aqdar_redeem_student_code(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
  normalized_code text := upper(regexp_replace(coalesce(p_code, ''), '\s+', '', 'g'));
  linked_student uuid;
begin
  if uid is null or not exists (
    select 1 from public.profiles p where p.id = uid and p.role = 'parent'
  ) then
    raise exception 'ربط الطالب متاح لحساب ولي الأمر فقط';
  end if;

  if normalized_code !~ '^AQD-[A-F0-9]{12}$' then
    raise exception 'صيغة الكود غير صحيحة';
  end if;

  update public.student_link_codes c
     set redeemed_at = now(),
         redeemed_by = uid,
         active = false
   where c.code_hash = encode(digest(normalized_code, 'sha256'), 'hex')
     and c.active = true
     and c.redeemed_at is null
     and c.expires_at > now()
   returning c.student_id into linked_student;

  if linked_student is null then
    raise exception 'الكود غير صحيح أو منتهي أو تم استخدامه من قبل';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = linked_student and p.role = 'student'
  ) then
    raise exception 'الكود لا يخص حساب طالب صالح';
  end if;

  insert into public.parent_students(parent_id, student_id, approved_by, approved_at, active)
  values (uid, linked_student, null, now(), true)
  on conflict (parent_id, student_id) do update
    set active = true, approved_by = null, approved_at = now();

  return linked_student;
end;
$$;

revoke all on function public.aqdar_get_my_student_code() from public, anon;
revoke all on function public.aqdar_redeem_student_code(text) from public, anon;
grant execute on function public.aqdar_get_my_student_code() to authenticated;
grant execute on function public.aqdar_redeem_student_code(text) to authenticated;

-- Parents can read only the linked student's profile and learning records.
-- These are SELECT-only policies; no parent INSERT/UPDATE/DELETE policy is created.
do $$
declare
  tbl_name text;
  policy_name text;
  has_student_id boolean;
begin
  foreach tbl_name in array array[
    'student_subjects',
    'assessment_results',
    'activity_submissions',
    'student_activity_events',
    'student_sessions',
    'student_activity_logs'
  ] loop
    if to_regclass('public.' || tbl_name) is not null then
      select exists (
        select 1 from information_schema.columns
        where table_schema = 'public'
          and information_schema.columns.table_name = tbl_name
          and column_name = 'student_id'
      ) into has_student_id;

      if has_student_id then
        policy_name := 'parent reads linked student ' || tbl_name;
        execute format('drop policy if exists %I on public.%I', policy_name, table_name);
        execute format(
          'create policy %I on public.%I for select to authenticated using ' ||
          '(exists (select 1 from public.parent_students ps where ps.parent_id = auth.uid() and ps.student_id = %I.student_id and ps.active = true))',
          policy_name, tbl_name, tbl_name
        );
      end if;
    end if;
  end loop;
end;
$$;

drop policy if exists "parent reads linked student profiles" on public.profiles;
create policy "parent reads linked student profiles" on public.profiles
for select to authenticated
using (
  id in (
    select ps.student_id from public.parent_students ps
    where ps.parent_id = auth.uid() and ps.active = true
  )
);

-- Disable the previous approval-request RPC for parents; the new flow links immediately.
do $$
begin
  if to_regprocedure('public.aqdar_request_parent_link(text)') is not null then
    execute 'revoke execute on function public.aqdar_request_parent_link(text) from authenticated';
  end if;
end;
$$;

comment on function public.aqdar_redeem_student_code(text) is
'Redeems a one-time student code and creates a read-only parent/student link.';
