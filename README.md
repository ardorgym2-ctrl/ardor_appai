# 아르더짐 회원 체크 앱

회원이 식단·몸 수치·컨디션을 직접 기록하고, 직원이 보는 아르더짐 전용 웹앱(PWA)입니다.
GitHub에 올리고 Vercel로 배포하며, 데이터·로그인·사진은 Supabase에 저장합니다.

```
index.html          앱 전체 (회원 화면 + 직원 화면)
config.js           ← 여기만 고치면 됩니다 (Supabase 주소·키 등)
push.js, sw.js      푸시 알림·서비스 워커
manifest.webmanifest, icons/, offline.html   홈 화면 추가(PWA)
vendor/supabase.js  Supabase 라이브러리 (v2.45.4, 직접 포함)
vercel.json         배포 설정(보안 헤더 포함)
supabase/           Supabase에 넣을 내용 (Vercel에는 올라가지 않음)
  schema.sql        테이블·권한·초대 가입·사진 저장소·실시간 (SQL Editor에 통째로 실행)
  seed_foods.sql    예시 음식 33개 (공공 DB를 넣기 전 임시)
  functions/send-reminders/   체크 알림·피드백 알림 발송
  functions/purge-photos/     오래된 식사 사진 자동 삭제
tools/import_foods.py         공공 식품영양성분 파일 → foods 테이블 SQL
```

## 1. 한 번에 보는 순서
1. Supabase 프로젝트 만들기 → 설정 3가지 → `schema.sql`, `seed_foods.sql` 실행
2. 첫 관리자(대표님) 초대 만들기
3. `config.js`에 주소·키 넣기 → GitHub에 올리기
4. Vercel에서 그 저장소 배포 → 도메인 연결
5. 첫 관리자 가입 → 직원·회원 초대 링크 만들기
6. (선택) 알림·사진 자동 삭제 함수 배포

## 2. Supabase
1. https://supabase.com 에서 프로젝트 생성. **Region은 Northeast Asia (Seoul)** 을 고르세요.
2. **Authentication > Sign In / Providers > Email**
   - Enable Email provider: 켜기
   - **Confirm email: 끄기** (회원 아이디를 내부 이메일 형태로 바꿔 쓰기 때문에 확인 메일을 보내지 않습니다)
   - Minimum password length: **8**
   - "Allow new users to sign up": 켜기 (가입은 초대 링크가 없으면 DB 트리거가 거부합니다)
3. **SQL Editor**에서 `supabase/schema.sql` 전체를 붙여넣고 Run. 이어서 `seed_foods.sql` Run.
   (오류 없이 끝나야 합니다. 여러 번 실행해도 됩니다.)
4. **Project Settings > API**에서 `Project URL`과 `anon public` 키를 복사해 둡니다.
   (service_role 키는 어디에도 붙여 넣지 마세요.)

### 첫 관리자 만들기
SQL Editor에서 한 번 실행합니다. 토큰은 영문 소문자·숫자 10자로 직접 정하세요(아래는 예시).
```sql
insert into public.invites (token, name, role, branch)
values ('k7m2x9q4ab', '용승현', 'admin', 'mangpo');
```
배포 후 `https://내도메인/#j-k7m2x9q4ab` 를 열어 아이디·비밀번호를 정하면 관리자 계정이 만들어집니다.
이 링크는 한 번만 쓸 수 있습니다.

## 3. config.js
`SUPABASE_URL`, `SUPABASE_ANON_KEY`를 채웁니다.
- `EMAIL_DOMAIN`: 실제로 메일을 보내지는 않지만, 아이디를 `아이디@도메인` 형태로 바꿔 로그인에 씁니다. **운영 도메인으로 바꾸는 것을 권장**하고, **한 번 정해서 회원이 생긴 뒤에는 바꾸지 마세요.**
- `VAPID_PUBLIC_KEY`: 알림을 쓸 때만 (6번). 비워 두면 알림 칸이 숨겨집니다.

## 4. GitHub와 Vercel
1. GitHub에 새 저장소를 만들고 이 폴더 전체를 올립니다.
2. https://vercel.com 에서 **Add New > Project**로 그 저장소를 선택합니다. Framework Preset은 **Other**, Build Command와 Output Directory는 비워 둡니다(정적 사이트).
3. 배포되면 Settings > Domains에서 도메인을 연결합니다. (HTTPS는 자동입니다. 알림과 홈 화면 앱은 HTTPS가 필수입니다.)
4. 수정할 때는 GitHub에 올리면 Vercel이 자동으로 다시 배포합니다.

## 5. 운영
- **초대**: 직원 화면 위쪽 "초대 링크 만들기" → 이름 입력 → 링크를 카톡으로 전달. 링크는 한 번만 쓸 수 있고, 가입이 곧 승인입니다.
  관리자는 직원·회원, 지점(망포/서천)을 골라 만들 수 있습니다. 직원은 자기 지점 회원만 만들 수 있습니다.
- **지점 분리**: 직원은 자기 지점 회원의 기록·사진만 봅니다. 관리자는 전체를 봅니다.
- **음식 DB**: 공공 파일을 받아 `python3 tools/import_foods.py 파일.csv --pick 목록.txt --units 단위.csv -o foods_import.sql` → 생성된 SQL을 SQL Editor에서 실행. 이용 조건은 데이터포털에서 직접 확인하세요. 검수한 음식은 Table Editor의 `foods`에서 `source`를 `A`(아르더짐 검수)로 바꿉니다.
- **비밀번호 재설정**: 아이디 기반이라 메일 재설정이 없습니다. 관리자가 SQL Editor에서 임시 비밀번호를 설정합니다(테스트 계정으로 먼저 확인하세요).
  ```sql
  update auth.users set encrypted_password = extensions.crypt('새비밀번호', extensions.gen_salt('bf'))
  where email = '아이디@config.js의 EMAIL_DOMAIN';
  ```
- **회원 탈퇴/삭제**: Authentication > Users에서 삭제하면 기록·가입정보는 함께 지워지지만 **Storage의 사진 파일은 남습니다.**
  Storage > meal-photos에서 해당 회원 폴더(회원 uuid)를 먼저 삭제하세요.
- **직원 계정**: 관리자가 직원 초대 링크를 만들어 가입시킵니다.

## 6. (선택) 알림과 사진 자동 삭제
Supabase CLI가 필요합니다(`npm i -g supabase`, `supabase login`, `supabase link --project-ref <PROJECT_REF>`).
1. `npx web-push generate-vapid-keys`로 키 생성 → 공개키는 `config.js`의 `VAPID_PUBLIC_KEY`에, 비공개키는 서버 비밀값에만.
2. 비밀값 설정:
   `supabase secrets set VAPID_PUBLIC_KEY=... VAPID_PRIVATE_KEY=... VAPID_SUBJECT=mailto:관리자메일 CRON_SECRET=임의의긴문자열 PHOTO_RETENTION_DAYS=60`
3. 배포: `supabase functions deploy send-reminders --no-verify-jwt` 와 `supabase functions deploy purge-photos --no-verify-jwt`
4. Dashboard > Database > Extensions에서 `pg_cron`, `pg_net`을 켜고, `schema.sql` 아래쪽의 주석 처리된 `cron.schedule` 두 개를 `<PROJECT_REF>`, `<CRON_SECRET>`을 바꿔 실행합니다.
5. 피드백 즉시 알림: Dashboard > Database > Webhooks에서 `feedback` 테이블 INSERT → `send-reminders` 함수 URL, 헤더 `x-cron-secret` 추가.
- 사진 보관 기간 기본값은 60일입니다(최소 7일). 텍스트 기록은 계속 남습니다.

## 7. 처음 배포 후 꼭 확인할 것 (실기기)
- [ ] 관리자 가입 → 직원 화면이 열린다
- [ ] 회원 초대 링크 → 카톡에서 누르면 "다른 브라우저로 열기" 안내 → Chrome/Safari에서 가입된다
- [ ] 회원: 식단 입력·사진 올리기·제출 → 앱을 닫았다 열어도 남아 있다
- [ ] 직원: 회원 목록·상세·사진이 보이고, 피드백을 남기면 회원 화면에 새 글로 뜬다
- [ ] 다른 지점 직원 계정으로는 이 회원이 보이지 않는다
- [ ] 안드로이드·iPhone에서 홈 화면에 추가된다 (iPhone은 Safari 공유 버튼 → 홈 화면에 추가)
- [ ] (알림을 켠 경우) 설정한 시각에 알림이 오고, 눌러서 앱이 열린다

## 8. 아직 없는 것 / 알아둘 점
- 회원이 직접 음식을 추가하는 기능, 트레이너가 회원 목표를 고치는 기능, AI 식단 사진 분석, 인바디 사진 자동 인식은 포함되지 않았습니다.
- **개인정보 문구는 법률 검토가 필요합니다.** 가입 화면의 동의 문구(`index.html`에서 "개인정보 수집"을 검색)와 개인정보처리방침(별도 페이지 필요), 처리위탁·국외이전 고지, 사진 보관 기간을 확정해 주세요.
- 가입 화면 하단의 초기 질문과 건강정보는 DB에 그대로 저장됩니다(Supabase가 디스크 암호화). 더 강한 보호가 필요하면 별도 설계가 필요합니다.
- 로그인 시도 횟수 제한은 Supabase 기본값을 따릅니다.
