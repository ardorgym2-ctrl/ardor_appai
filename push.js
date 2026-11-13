/* 알림 켜기/끄기 (클라이언트). Supabase 클라이언트와 VAPID 공개키를 받아 구독을 저장한다.
   enablePush는 반드시 사용자가 버튼을 누른 순간(클릭 핸들러) 안에서 호출해야 iOS·안드로이드 모두 허용 창이 뜬다. */

export const isIOS = () => /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
export const isStandalone = () => matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
export const isKakao = () => /KAKAOTALK/i.test(navigator.userAgent);

export function pushSupport() {
  if (isKakao()) return { ok: false, why: 'kakao' };                          // 카톡 내장 브라우저
  if (isIOS() && !isStandalone()) return { ok: false, why: 'ios-not-installed' }; // iOS는 홈 화면 앱에서만
  if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) return { ok: false, why: 'unsupported' };
  return { ok: true };
}

const b64ToU8 = (s) => {
  const p = '='.repeat((4 - (s.length % 4)) % 4), raw = atob((s + p).replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)));
};

export async function registerSW() {
  if (!('serviceWorker' in navigator)) return null;
  return navigator.serviceWorker.register('/sw.js');
}

export async function enablePush(supabase, vapidPublicKey, prefs = { remind_time: '20:00', notify_feedback: true }) {
  const sup = pushSupport();
  if (!sup.ok) return { ok: false, why: sup.why };
  const perm = await Notification.requestPermission();
  if (perm !== 'granted') return { ok: false, why: perm === 'denied' ? 'denied' : 'dismissed' };
  const reg = await navigator.serviceWorker.ready;
  const sub = (await reg.pushManager.getSubscription()) ||
    (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToU8(vapidPublicKey) }));
  const j = sub.toJSON();
  const { data: { user } } = await supabase.auth.getUser();
  const { error } = await supabase.from('push_subscriptions').upsert({
    member_id: user.id, endpoint: j.endpoint, p256dh: j.keys.p256dh, auth: j.keys.auth,
    remind_time: prefs.remind_time, notify_feedback: prefs.notify_feedback
  }, { onConflict: 'endpoint' });
  return error ? { ok: false, why: 'db', error } : { ok: true };
}

export async function disablePush(supabase) {
  const reg = await navigator.serviceWorker.ready;
  const sub = await reg.pushManager.getSubscription();
  if (!sub) return { ok: true };
  await supabase.from('push_subscriptions').delete().eq('endpoint', sub.endpoint);
  await sub.unsubscribe();
  return { ok: true };
}

/* 알림 시각·피드백 알림 설정만 바꿀 때 */
export async function updatePushPrefs(supabase, prefs) {
  const reg = await navigator.serviceWorker.getRegistration();
  const sub = reg && (await reg.pushManager.getSubscription());
  if (!sub) return { ok: false, why: 'no-subscription' };
  const { error } = await supabase.from('push_subscriptions')
    .update({ remind_time: prefs.remind_time, notify_feedback: prefs.notify_feedback }).eq('endpoint', sub.endpoint);
  return error ? { ok: false, why: 'db' } : { ok: true };
}
