-- AQDAR: parent accounts, electronic student codes, teacher approval and read-only parent access.
-- Run this migration in Supabase SQL Editor. It does not disable or weaken existing RLS.
create extension if not exists pgcrypto;

alter table public.profiles
  add column if not exists role text;

-- Only allow self-registration to request student/parent roles. Never allow public self-promotion to teacher/admin.
create or replace function public.aqdar_apply_signup_role()
returns trigger language plpgsql security definer set search_path = public, auth
as $$
declare requested text;
begin
  select lower(coalesce(raw_user_meta_data->>'requested_role','student'))
    into requested from auth.users where id = new.id;
  if requested not in ('student','parent') then requested := 'student'; end if;
  if lower(coalesce(new.role,'')) not in ('teacher','admin') then
    new.role := requested;
  end if;
  return new;
end;
$$;

drop trigger if exists aqdar_signup_role_on_profile on public.profiles;
create trigger aqdar_signup_role_on_profile
before insert on public.profiles
for each row execute function public.aqdar_apply_signup_role();

-- Prevent a regular authenticated user from promoting their own profile to staff/admin.
create or replace function public.aqdar_protect_profile_role()
returns trigger language plpgsql security definer set search_path = public
as $
begin
  if auth.uid() is not null and auth.uid() = old.id
     and not public.aqdar_is_admin() then
    new.role := old.role;
  end if;
  return new;
end;
$;
drop trigger if exists aqdar_protect_profile_role_trigger on public.profiles;
create trigger aqdar_protect_profile_role_trigger
before update of role on public.profiles
for each row execute function public.aqdar_protect_profile_role();

create table if not exists public.student_link_codes (
  student_id uuid primary key references public.profiles(id) on delete cascade,
  code text not null unique,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '90 days'),
  active boolean not null default true
);
alter table public.student_link_codes enable row level security;

create table if not exists public.parent_link_requests (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  unique(parent_id, student_id)
);
alter table public.parent_link_requests enable row level security;

create table if not exists public.parent_students (
  parent_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  approved_by uuid not null references public.profiles(id),
  approved_at timestamptz not null default now(),
  active boolean not null default true,
  primary key(parent_id, student_id)
);
alter table public.parent_students enable row level security;

-- A student's code is generated and returned only to that authenticated student.
create or replace function public.aqdar_get_my_student_code()
returns text language plpgsql security definer set search_path = public, auth
as $$
declare uid uuid := auth.uid(); generated text;
begin
  if uid is null or not exists(select 1 from public.profiles p where p.id=uid and p.role='student') then
    raise exception 'هذه الخدمة متاحة للطالب فقط';
  end if;
  select code into generated from public.student_link_codes
   where student_id=uid and active and expires_at>now();
  if generated is null then
    generated := 'AQD-' || upper(substr(encode(gen_random_bytes(6),'hex'),1,10));
    insert into public.student_link_codes(student_id,code) values(uid,generated)
    on conflict(student_id) do update set code=excluded.code, created_at=now(),
      expires_at=now()+interval '90 days', active=true;
  end if;
  return generated;
end;
$$;

-- Parent submits a code. No student data is returned to the parent at this stage.
create or replace function public.aqdar_request_parent_link(p_code text)
returns uuid language plpgsql security definer set search_path = public, auth
as $$
declare uid uuid := auth.uid(); sid uuid; request_id uuid;
begin
  if uid is null or not exists(select 1 from public.profiles p where p.id=uid and p.role='parent') then
    raise exception 'هذه الخدمة متاحة لولي الأمر فقط';
  end if;
  select student_id into sid from public.student_link_codes
   where code=upper(trim(p_code)) and active and expires_at>now();
  if sid is null then raise exception 'الكود غير صحيح أو منتهي الصلاحية'; end if;
  insert into public.parent_link_requests(parent_id,student_id,status)
    values(uid,sid,'pending')
  on conflict(parent_id,student_id) do update set status='pending', reviewed_by=null, reviewed_at=null, created_at=now()
  returning id into request_id;
  return request_id;
end;
$$;

-- Teachers may review only requests for students actively assigned to them.
create or replace function public.aqdar_review_parent_link(p_request_id uuid, p_approve boolean)
returns void language plpgsql security definer set search_path = public, auth
as $$
declare uid uuid := auth.uid(); req public.parent_link_requests%rowtype;
begin
  if uid is null or not exists(select 1 from public.profiles p where p.id=uid and p.role in ('teacher','admin')) then
    raise exception 'غير مصرح';
  end if;
  select * into req from public.parent_link_requests where id=p_request_id and status='pending' for update;
  if not found then raise exception 'الطلب غير موجود أو تمت مراجعته'; end if;
  if not exists(select 1 from public.profiles p where p.id=req.student_id and p.role='student') then
    raise exception 'الحساب المطلوب ليس حساب طالب';
  end if;
  if not exists(select 1 from public.profiles p where p.id=uid and p.role='admin')
     and not exists(select 1 from public.teacher_students ts where ts.teacher_id=uid and ts.student_id=req.student_id and ts.is_active=true) then
    raise exception 'لا يمكنك مراجعة طلب طالب غير مسند إليك';
  end if;
  update public.parent_link_requests set status=case when p_approve then 'approved' else 'rejected' end,
    reviewed_by=uid, reviewed_at=now() where id=req.id;
  if p_approve then
    insert into public.parent_students(parent_id,student_id,approved_by)
      values(req.parent_id,req.student_id,uid)
    on conflict(parent_id,student_id) do update set active=true, approved_by=uid, approved_at=now();
  end if;
end;
$$;

-- Read-only parent access is scoped to approved parent_students rows.
drop policy if exists "parent reads own approved links" on public.parent_students;
create policy "parent reads own approved links" on public.parent_students
for select to authenticated using (parent_id=auth.uid() and active);

drop policy if exists "parent reads own link requests" on public.parent_link_requests;
create policy "parent reads own link requests" on public.parent_link_requests
for select to authenticated using (parent_id=auth.uid());

drop policy if exists "teacher reads assigned parent requests" on public.parent_link_requests;
create policy "teacher reads assigned parent requests" on public.parent_link_requests
for select to authenticated using (
  exists(select 1 from public.teacher_students ts where ts.teacher_id=auth.uid()
    and ts.student_id=parent_link_requests.student_id and ts.is_active=true)
  or exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin')
);

-- Do not grant table writes to browser clients. Mutations are only through the checked RPCs.
revoke all on public.student_link_codes from anon, authenticated;
revoke all on public.parent_link_requests from anon, authenticated;
revoke all on public.parent_students from anon, authenticated;
grant select on public.parent_link_requests, public.parent_students to authenticated;
grant execute on function public.aqdar_get_my_student_code() to authenticated;
grant execute on function public.aqdar_request_parent_link(text) to authenticated;
grant execute on function public.aqdar_review_parent_link(uuid,boolean) to authenticated;

-- Parent dashboard read access to linked student's profile and learning records must be
-- added to each existing table's SELECT policy using EXISTS(parent_students ...).
-- Keep current teacher/admin policies intact; apply the supplemental policies below.
do $$
declare t text;
begin
  foreach t in array array['profiles','student_subjects','assessment_results','activity_submissions','student_activity_events','student_sessions'] loop
    if to_regclass('public.'||t) is not null then
      execute format('drop policy if exists %I on public.%I', 'parent reads linked student '||t, t);
      execute format(
        'create policy %I on public.%I for select to authenticated using (%s)',
        'parent reads linked student '||t, t,
        case when t='profiles' then
          'id in (select student_id from public.parent_students where parent_id=auth.uid() and active=true)'
        else
          'student_id in (select student_id from public.parent_students where parent_id=auth.uid() and active=true)'
        end
      );
    end if;
  end loop;
end $$;
