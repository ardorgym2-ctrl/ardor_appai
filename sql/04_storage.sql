-- =========================================================
-- 04_storage.sql : 식단 사진 보관함 (여러 번 실행해도 안전)
-- 사진 경로 규칙: 회원ID/날짜(YYYY-MM-DD)/끼니-번호.jpg
-- =========================================================
insert into storage.buckets (id, name, public)
values ('meal-photos', 'meal-photos', false)
on conflict (id) do update set public = false;

drop policy if exists mp_sel on storage.objects;
create policy mp_sel on storage.objects for select to authenticated
  using (bucket_id = 'meal-photos'
         and public.can_see_member(((storage.foldername(name))[1])::uuid));

drop policy if exists mp_ins on storage.objects;
create policy mp_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'meal-photos'
              and (storage.foldername(name))[1] = auth.uid()::text
              and (storage.foldername(name))[2] ~ '^\d{4}-\d{2}-\d{2}$'
              and public.in_edit_window(((storage.foldername(name))[2])::date));

drop policy if exists mp_del on storage.objects;
create policy mp_del on storage.objects for delete to authenticated
  using (bucket_id = 'meal-photos'
         and (storage.foldername(name))[1] = auth.uid()::text
         and (storage.foldername(name))[2] ~ '^\d{4}-\d{2}-\d{2}$'
         and public.in_edit_window(((storage.foldername(name))[2])::date));
