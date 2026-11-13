-- =========================================================
-- 01_schema.sql  : 테이블 만들기 (여러 번 실행해도 안전)
-- =========================================================
create extension if not exists pg_trgm;

-- 한국 시간 기준 오늘 날짜
create or replace function public.kst_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Seoul')::date $$;

-- 회원·직원 프로필
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  login_id    text unique not null,
  name        text not null default '',
  branch      text not null default '망포',
  role        text not null default 'member',
  goal        jsonb not null default '{}'::jsonb,
  trainer_id  uuid references public.profiles(id) on delete set null,
  consent_at  timestamptz,
  created_at  timestamptz not null default now()
);
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('member','staff','admin','applicant','rejected'));
alter table public.profiles drop constraint if exists profiles_branch_check;
alter table public.profiles add constraint profiles_branch_check
  check (branch in ('서천','망포'));

-- 하루 기록 (회원 1명 x 날짜 1개 = 1줄)
create table if not exists public.daily_records (
  id          bigserial primary key,
  member_id   uuid not null references public.profiles(id) on delete cascade,
  record_date date not null,
  status      text not null default 'draft',
  weight      numeric, sleep numeric, steps int, water numeric,
  muscle      numeric, body_fat numeric,
  trained     text,
  workouts    jsonb not null default '[]'::jsonb,
  cond int, fatigue int, stress int,
  pain        text[] not null default '{}',
  pain_level  int,
  meals       jsonb not null default '{}'::jsonb,
  tot         jsonb not null default '{}'::jsonb,
  goal        jsonb,
  updated_at  timestamptz not null default now(),
  unique (member_id, record_date)
);

create table if not exists public.meal_photos (
  id          bigserial primary key,
  member_id   uuid not null references public.profiles(id) on delete cascade,
  record_date date not null,
  meal        text not null,
  path        text not null,
  created_at  timestamptz not null default now()
);
create index if not exists meal_photos_m_d on public.meal_photos(member_id, record_date);

create table if not exists public.feedback (
  id          bigserial primary key,
  member_id   uuid not null references public.profiles(id) on delete cascade,
  record_date date not null,
  meal        text not null default 'day',
  author_id   uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body        text not null,
  created_at  timestamptz not null default now()
);
create index if not exists feedback_m_d on public.feedback(member_id, record_date);

-- 음식 DB (모든 값은 100g 또는 100ml 기준)
-- source: public=공공데이터(식약처·농진청), ardor=아르더짐 검수, user=유저등록
create table if not exists public.foods (
  id          bigserial primary key,
  name        text not null,
  brand       text,
  source      text not null default 'user',
  kcal        numeric not null default 0,
  carb        numeric not null default 0,
  protein     numeric not null default 0,
  fat         numeric not null default 0,
  sugar       numeric, sodium numeric,
  basis_unit  text not null default 'g',
  serving_g   numeric,
  serving_label text,
  note        text,
  created_by  uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
alter table public.foods drop constraint if exists foods_source_check;
alter table public.foods add constraint foods_source_check check (source in ('public','ardor','user'));
create index if not exists foods_name_trgm on public.foods using gin (name gin_trgm_ops);

-- 가입 때 건강 설문
create table if not exists public.intake (
  member_id   uuid primary key references public.profiles(id) on delete cascade,
  answers     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

-- 1회용 초대 링크
create table if not exists public.invites (
  token       text primary key,
  role        text not null default 'member',
  branch      text not null,
  trainer_id  uuid references public.profiles(id) on delete set null,
  created_by  uuid references public.profiles(id) on delete set null,
  used_by     uuid references public.profiles(id) on delete set null,
  used_at     timestamptz,
  expires_at  timestamptz not null default now() + interval '14 days',
  created_at  timestamptz not null default now()
);

create table if not exists public.app_settings (
  key   text primary key,
  value jsonb not null
);
insert into public.app_settings(key, value) values
  ('open_signup', 'true'::jsonb),
  ('open_staff_signup', 'true'::jsonb),
  ('ai_daily_limit', '20'::jsonb)
on conflict (key) do nothing;

-- AI 사진 분석 사용 기록 (하루 한도 계산용)
create table if not exists public.ai_usage (
  id       bigserial primary key,
  user_id  uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  used_at  timestamptz not null default now()
);
create index if not exists ai_usage_u_t on public.ai_usage(user_id, used_at);
