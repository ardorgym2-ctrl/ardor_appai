// Supabase Edge Function: 체크 알림(매일) + 트레이너 피드백 알림(즉시)
// 호출 방식 두 가지
//  1) pg_cron이 10분마다 body {} 로 호출  -> 체크 알림
//  2) Database Webhook(feedback 테이블 INSERT)이 호출 -> 피드백 알림
// 모든 호출은 x-cron-secret 헤더가 맞아야 한다.
import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

webpush.setVapidDetails(
  Deno.env.get('VAPID_SUBJECT')!,        // 예: mailto:admin@도메인
  Deno.env.get('VAPID_PUBLIC_KEY')!,
  Deno.env.get('VAPID_PRIVATE_KEY')!,
);
const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const WINDOW_MIN = 60; // 설정 시각 이후 60분 안에 한 번만 보낸다 (크론이 늦어져도 누락 방지)

type Sub = { id: string; member_id: string; endpoint: string; p256dh: string; auth: string; remind_time: string; last_sent: string | null };

async function send(s: Sub, payload: Record<string, string>) {
  try {
    await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify(payload));
    return true;
  } catch (e: any) {
    if (e.statusCode === 404 || e.statusCode === 410) await sb.from('push_subscriptions').delete().eq('id', s.id); // 만료된 구독 정리
    return false;
  }
}

const kstNow = () => {
  const t = new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' }); // "2026-10-15 20:03:00"
  return { date: t.slice(0, 10), min: +t.slice(11, 13) * 60 + +t.slice(14, 16) };
};

async function reminders() {
  const { date, min } = kstNow();
  const { data: subs } = await sb.from('push_subscriptions').select('*').or(`last_sent.is.null,last_sent.lt.${date}`);
  const due = (subs ?? []).filter((s: Sub) => {
    const [h, m] = s.remind_time.split(':').map(Number);
    const diff = min - (h * 60 + m);
    return diff >= 0 && diff < WINDOW_MIN;
  });
  if (!due.length) return { sent: 0 };
  // 오늘 이미 기록을 마친 회원은 건너뛴다. (테이블·열 이름은 실제 스키마에 맞게 수정)
  const ids = [...new Set(due.map((s: Sub) => s.member_id))];
  const { data: done } = await sb.from('daily_records').select('member_id').eq('record_date', date).in('member_id', ids);
  const doneSet = new Set((done ?? []).map((r: any) => r.member_id));
  let sent = 0;
  await Promise.allSettled(due.map(async (s: Sub) => {
    if (doneSet.has(s.member_id)) { await sb.from('push_subscriptions').update({ last_sent: date }).eq('id', s.id); return; }
    const ok = await send(s, { title: '오늘 체크 하셨나요?', body: '식단과 컨디션을 기록해 주세요.', url: '/', tag: 'daily' });
    if (ok) { sent++; await sb.from('push_subscriptions').update({ last_sent: date }).eq('id', s.id); }
  }));
  return { sent };
}

async function feedback(memberId: string) {
  const { data: subs } = await sb.from('push_subscriptions').select('*').eq('member_id', memberId).eq('notify_feedback', true);
  let sent = 0;
  await Promise.allSettled((subs ?? []).map(async (s: Sub) => {
    if (await send(s, { title: '트레이너 피드백이 도착했어요', body: '앱에서 확인해 보세요.', url: '/', tag: 'feedback' })) sent++;
  }));
  return { sent };
}

Deno.serve(async (req) => {
  if (req.headers.get('x-cron-secret') !== Deno.env.get('CRON_SECRET')) return new Response('forbidden', { status: 403 });
  const body = await req.json().catch(() => ({}));
  // Database Webhook 형식: { type:'INSERT', table:'feedback', record:{ member_id, ... } }
  const out = body?.type === 'INSERT' && body?.table === 'feedback' && body?.record?.member_id
    ? await feedback(body.record.member_id)
    : await reminders();
  return Response.json(out);
});
