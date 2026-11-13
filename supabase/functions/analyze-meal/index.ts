// =========================================================
// analyze-meal : 식단 사진 AI 분석 (Supabase Edge Function)
//  - 영양성분표 사진 → 표의 숫자를 그대로 읽어요.
//  - 음식 사진     → 어떤 음식인지(이름·검색어·양 g)를 알려 줘요.
//                    계산은 앱이 아르더짐 음식 DB(검수·공공데이터·유저등록)에서 찾아서 해요.
//                    DB에 없을 때만 AI 추정값(est_per100)을 써요.
// 필요한 비밀값(Secrets): ANTHROPIC_API_KEY  (선택: CLAUDE_MODEL)
// =========================================================

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const env = (k: string) => (globalThis as any).Deno?.env.get(k) ?? (globalThis as any).process?.env?.[k];
const num = (v: unknown) => { const x = Number(v); return Number.isFinite(x) && x >= 0 ? x : null; };

export const TOOL = {
  name: "report_meal",
  description: "사진 분석 결과를 보고합니다.",
  input_schema: {
    type: "object",
    properties: {
      kind: { type: "string", enum: ["label", "food", "unknown"] },
      label: {
        type: "object",
        description: "kind=label 일 때. 표에 적힌 숫자 그대로, 기준량당 값.",
        properties: {
          product_name: { type: ["string", "null"] },
          basis_amount: { type: ["number", "null"], description: "기준량 숫자 (예: 100, 30, 1)" },
          basis_unit: { type: ["string", "null"], description: "g, ml, 또는 개/회/봉 등" },
          total_amount: { type: ["number", "null"], description: "총 내용량 숫자" },
          total_unit: { type: ["string", "null"] },
          kcal: { type: ["number", "null"] }, carb: { type: ["number", "null"] },
          protein: { type: ["number", "null"] }, fat: { type: ["number", "null"] },
          sugar: { type: ["number", "null"] }, sodium: { type: ["number", "null"], description: "mg" },
        },
      },
      foods: {
        type: "array",
        description: "kind=food 일 때. 보이는 음식을 하나씩.",
        items: {
          type: "object",
          properties: {
            name: { type: "string", description: "한국 음식 DB에서 찾기 쉬운 일반 이름" },
            search_terms: { type: "array", items: { type: "string" }, description: "검색어 2~3개, 구체→일반" },
            grams: { type: ["number", "null"], description: "사진 속 양 추정(g)" },
            confidence: { type: ["number", "null"], description: "0~1" },
            est_per100: {
              type: "object",
              properties: { kcal: { type: "number" }, carb: { type: "number" }, protein: { type: "number" }, fat: { type: "number" } },
            },
          },
          required: ["name", "search_terms"],
        },
      },
      note: { type: ["string", "null"], description: "회원에게 보여줄 짧은 한 줄 안내(한국어)" },
    },
    required: ["kind"],
  },
};

export const PROMPT = `이 사진은 피트니스 회원이 먹은 음식 사진이거나, 포장 식품의 영양성분표 사진이에요.
1) 영양성분표(영양정보 표)가 보이면 kind="label"로 하고, 표의 숫자를 그대로 옮겨 주세요.
   - 기준량(예: "100g당", "1회 제공량 30g당", "총 내용량 200ml당", "1개당")을 basis_amount·basis_unit에 넣어요.
   - 열량·탄수화물·단백질·지방·당류·나트륨은 그 기준량 기준 숫자를 넣어요. 총 내용량이 있으면 total_amount·total_unit에 넣어요.
   - 제품명이 보이면 product_name에 넣어요. 읽히지 않는 숫자는 null로 두고 절대 추측하지 마세요.
2) 표가 없고 음식이 보이면 kind="food"로 하고, 보이는 음식을 하나씩 나눠 주세요(밥·국·반찬 따로).
   - name은 한국 식품 DB에서 찾기 쉬운 일반 이름(예: "쌀밥", "김치찌개", "닭가슴살", "계란말이")으로 써요.
   - search_terms에는 검색어 2~3개를 구체적인 것부터 일반적인 것 순서로 넣어요(예: ["현미밥","잡곡밥","밥"]).
   - grams에는 사진 속 양을 g으로 추정하고, est_per100에는 100g당 추정 영양값을 넣어요.
3) 음식도 영양성분표도 아니면 kind="unknown"으로 해요.
반드시 report_meal 도구로만 답해요.`;

// 숫자만 남기고 정리
const n = (v: unknown) => num(v);
export function cleanLabel(L: any) {
  if (!L) return null;
  return { product_name: L.product_name ? String(L.product_name).slice(0, 40) : null,
    basis_amount: n(L.basis_amount), basis_unit: L.basis_unit ? String(L.basis_unit).slice(0, 10) : null,
    total_amount: n(L.total_amount), total_unit: L.total_unit ? String(L.total_unit).slice(0, 10) : null,
    kcal: n(L.kcal), carb: n(L.carb), protein: n(L.protein), fat: n(L.fat), sugar: n(L.sugar), sodium: n(L.sodium) };
}
export function cleanFoods(F: any) {
  return (Array.isArray(F) ? F : []).slice(0, 8).map((f: any) => ({
    name: String(f?.name || "음식").slice(0, 40),
    search_terms: (Array.isArray(f?.search_terms) ? f.search_terms : []).slice(0, 4).map((s: any) => String(s).slice(0, 30)),
    grams: n(f?.grams), confidence: n(f?.confidence),
    est_per100: { kcal: n(f?.est_per100?.kcal) ?? 0, carb: n(f?.est_per100?.carb) ?? 0, protein: n(f?.est_per100?.protein) ?? 0, fat: n(f?.est_per100?.fat) ?? 0 },
  }));
}

async function callClaude(image: string, mediaType: string, hint: string) {
  const key = env("ANTHROPIC_API_KEY");
  if (!key) throw Object.assign(new Error("no_api_key"), { status: 500 });
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({
      model: env("CLAUDE_MODEL") || "claude-sonnet-5-5",
      max_tokens: 1500,
      tools: [TOOL],
      tool_choice: { type: "tool", name: "report_meal" },
      messages: [{
        role: "user",
        content: [
          { type: "image", source: { type: "base64", media_type: mediaType, data: image } },
          { type: "text", text: PROMPT + (hint ? `\n끼니: ${hint.slice(0, 50)}` : "") },
        ],
      }],
    }),
  });
  if (!res.ok) {
    console.error("claude error", res.status, (await res.text()).slice(0, 500));
    throw Object.assign(new Error("ai_failed"), { status: 502 });
  }
  const data = await res.json();
  const tu = (data.content || []).find((c: any) => c.type === "tool_use");
  if (!tu) throw Object.assign(new Error("ai_failed"), { status: 502 });
  return tu.input;
}

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "content-type": "application/json" } });

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const URL_ = env("SUPABASE_URL"), ANON = env("SUPABASE_ANON_KEY");
  const auth = req.headers.get("Authorization") || "";
  try {
    const u = await fetch(`${URL_}/auth/v1/user`, { headers: { apikey: ANON, Authorization: auth } });
    if (!u.ok) return json({ error: "login" }, 401);

    const body = await req.json().catch(() => ({}));
    const image = String(body.image || "");
    const mediaType = ["image/jpeg", "image/png", "image/webp"].includes(body.media_type) ? body.media_type : "image/jpeg";
    if (!image || image.length > 7_000_000) return json({ error: "image" }, 400);

    // 하루 사용 한도 (회원·직원 1명 기준)
    const q = await fetch(`${URL_}/rest/v1/rpc/ai_take_quota`, {
      method: "POST", headers: { apikey: ANON, Authorization: auth, "content-type": "application/json" }, body: "{}",
    });
    if (!q.ok) {
      const t = await q.text();
      return json({ error: t.includes("ai_limit") ? "ai_limit" : "quota" }, t.includes("ai_limit") ? 429 : 403);
    }
    const remaining = await q.json();

    const ai = await callClaude(image, mediaType, String(body.hint || ""));
    const kind = ["label", "food"].includes(ai.kind) ? ai.kind : "unknown";
    return json({
      kind,
      label: kind === "label" ? cleanLabel(ai.label) : null,
      foods: kind === "food" ? cleanFoods(ai.foods) : [],
      note: ai.note ? String(ai.note).slice(0, 200) : (kind === "unknown" ? "음식이나 영양성분표를 찾지 못했어요." : null),
      remaining,
    });
  } catch (e) {
    console.error(e);
    return json({ error: (e as Error).message || "server" }, (e as any).status || 500);
  }
}

if ((globalThis as any).Deno?.serve) (globalThis as any).Deno.serve(handler);
