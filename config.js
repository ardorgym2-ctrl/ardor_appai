// 이 파일만 고치면 됩니다. (anon 키는 공개돼도 되는 키이고, 데이터는 DB 권한(RLS)이 지킵니다.
// 절대 넣으면 안 되는 것: service_role 키, VAPID 비공개키)
window.ARDOR_CONFIG = {
     SUPABASE_URL: 'https://simmnjuqxrwvqbcywyut.supabase.co',
  SUPABASE_ANON_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNpbW1uanVxeHJ3dnFiY3l3eXV0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIzNTA1ODYsImV4cCI6MjEwNzkyNjU4Nn0.P4r19NH9HqOSUY5TAEjHSWK4iql70xc06v0xnwVuQHA',                     // 같은 화면의 anon public 키
EMAIL_DOMAIN: 'gmail.com',                          // 회원 아이디를 내부 로그인용 이메일로 바꿀 때 쓰는 도메인(실제 메일은 안 보냅니다). 실제 운영 도메인을 권장
  VAPID_PUBLIC_KEY: 'YOUR_VAPID_PUBLIC_KEY'               // 푸시 알림용 공개키. 아직 없으면 그대로 두세요(알림 칸이 숨겨집니다)
};
