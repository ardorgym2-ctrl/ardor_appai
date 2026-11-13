// 오래된 식사 사진 삭제: Storage 파일과 meal_photos 행을 함께 지운다.
// (SQL로 storage.objects 행만 지우면 실제 파일이 남을 수 있어서 반드시 Storage API로 지운다.)
// pg_cron이 매일 새벽에 호출한다. x-cron-secret 헤더가 맞아야 실행된다.
// 보관 기간: 환경변수 PHOTO_RETENTION_DAYS (기본 60일)
import { createClient } from 'npm:@supabase/supabase-js@2';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const DAYS = Math.max(7, Number(Deno.env.get('PHOTO_RETENTION_DAYS') ?? 60) || 60); // 실수로 0일이 되지 않게 최소 7일
const BATCH = 200;

Deno.serve(async (req) => {
  if (req.headers.get('x-cron-secret') !== Deno.env.get('CRON_SECRET')) return new Response('forbidden', { status: 403 });
  const cutoff = new Date(Date.now() - DAYS * 864e5).toISOString();
  let removed = 0, failed = 0;
  for (let round = 0; round < 50; round++) { // 한 번 실행에 최대 1만 장
    const { data: rows, error } = await sb.from('meal_photos').select('id,path').lt('created_at', cutoff).order('created_at').limit(BATCH);
    if (error) return Response.json({ ok: false, error: error.message, removed }, { status: 500 });
    if (!rows || !rows.length) break;
    const { error: rmErr } = await sb.storage.from('meal-photos').remove(rows.map((r) => r.path));
    if (rmErr) { failed += rows.length; break; }                       // 파일 삭제에 실패하면 행을 남겨서 다음에 다시 시도
    const { error: delErr } = await sb.from('meal_photos').delete().in('id', rows.map((r) => r.id));
    if (delErr) { failed += rows.length; break; }
    removed += rows.length;
    if (rows.length < BATCH) break;
  }
  return Response.json({ ok: failed === 0, cutoff, retention_days: DAYS, removed, failed });
});
