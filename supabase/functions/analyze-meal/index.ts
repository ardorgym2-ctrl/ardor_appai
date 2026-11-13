// =========================================================
// analyze-meal : 식단 사진 AI 분석 (Supabase Edge Function)
//  - 영양성분표 사진 → 표의 숫자를 그대로 읽어요.
//  - 음식 사진     → 어떤 음식인지 알아낸 뒤, 아르더짐 음식 DB
//                    (아르더짐 검수 → 공공데이터 → 유저등록 순)에서 먼저 찾아 계산해요.
//                    DB에 없을 때만 AI 추정값을 써요.
// 필요한 비밀값(Secrets): ANTHROPIC_API_KEY  (선택: CLAUDE_MODEL)
// =========================================================

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type N = { kcal: number; carb: number; protein: number; fat: number };
export type Item = {
  name: string; src: string; food_id: number | null;
  unit: string; base: number; amt: number; n: N;
  serving_g?: number | null; serving_label?: string | null;
  ai_name?: string; confidence?: number | null;
  candidates?: Item[];
};

const env = (k: string) => (globalThis as any).Deno?.env.get(k) ?? (globalThis as any).process?.env?.[k];
const num = (v: unknown) => { const x = Number(v); return Number.isFinite(x) && x >= 0 ? x : null; };
const r1 = (v: number) => Math.round(v * 10) / 10;

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

// ---------- 영양성분표 → 항목 ----------
export function labelToItem(L: any): { item: Item | null; food: any | null } {
  if (!L) return { item: null, food: null };
  const n: N = { kcal: num(L.kcal) ?? 0, carb: num(L.carb) ?? 0, protein: num(L.protein) ?? 0, fat: num(L.fat) ?? 0 };
  const name = (L.product_name || "").trim() || "포장 식품";
  const bAmt = num(L.basis_amount), bUnit = String(L.basis_unit || "").toLowerCase().trim();
  const tAmt = num(L.total_amount), tUnit = String(L.total_unit || "").toLowerCase().trim();
  const metric = (u: string) => (u === "g" || u === "ml" ? u : null);
  if (bAmt && metric(bUnit)) {
    const unit = metric(bUnit)!;
    const per100: N = { kcal: r1(n.kcal * 100 / bAmt), carb: r1(n.carb * 100 / bAmt), protein: r1(n.protein * 100 / bAmt), fat: r1(n.fat * 100 / bAmt) };
    const eaten = tAmt && metric(tUnit) === unit ? tAmt : bAmt;
    const item: Item = { name, src: "label", food_id: null, unit, base: 100, amt: eaten, n: per100,
      serving_g: eaten, serving_label: tAmt && metric(tUnit) === unit ? "1봉(총 내용량)" : `${bAmt}${unit}` };
    const food = { name, source: "user", ...per100, basis_unit: unit, serving_g: eaten,
      serving_label: item.serving_label, sugar: num(L.sugar) != null ? r1(num(L.sugar)! * 100 / bAmt) : null,
      sodium: num(L.sodium) != null ? r1(num(L.sodium)! * 100 / bAmt) : null, note: "영양성분표 사진으로 등록" };
    return { item, food };
  }
  // g/ml 기준이 없으면(예: 1개당) 1회 단위로
  return { item: { name, src: "label", food_id: null, unit: "회", base: 1, amt: 1, n, serving_label: bAmt ? `${bAmt}${bUnit}` : "1회" }, food: null };
}

// ---------- 음식 → DB 매칭 ----------
export function dbRowToItem(f: any, grams: number | null): Item {
  const unit = f.basis_unit || "g";
  return {
    name: f.name, src: f.source, food_id: f.id, unit, base: 100,
    amt: grams ?? (num(f.serving_g) ?? 100),
    n: { kcal: Number(f.kcal) || 0, carb: Number(f.carb) || 0, protein: Number(f.protein) || 0, fat: Number(f.fat) || 0 },
    serving_g: num(f.serving_g), serving_label: f.serving_label ?? null,
  };
}

export async function matchFoods(foods: any[], search: (q: string) => Promise<any[]>): Promise<Item[]> {
  const out: Item[] = [];
  for (const f of (foods || []).slice(0, 8)) {
    const grams = num(f.grams);
    const terms = [f.name, ...(Array.isArray(f.search_terms) ? f.search_terms : [])]
      .map((s: any) => String(s || "").trim()).filter(Boolean);
    const seen = new Set<number>(); const cands: Item[] = [];
    for (const t of [...new Set(terms)].slice(0, 4)) {
      let rows: any[] = [];
      try { rows = await search(t); } catch { rows = []; }
      for (const r of rows) if (!seen.has(r.id)) { seen.add(r.id); cands.push(dbRowToItem(r, grams)); }
      if (cands.length >= 4) break;
    }
    const e = f.est_per100 || {};
    const aiItem: Item = {
      name: String(f.name || "음식"), src: "ai", food_id: null, unit: "g", base: 100, amt: grams ?? 100,
      n: { kcal: num(e.kcal) ?? 0, carb: num(e.carb) ?? 0, protein: num(e.protein) ?? 0, fat: num(e.fat) ?? 0 },
    };
    const chosen = cands[0] ?? aiItem;
    out.push({ ...chosen, ai_name: String(f.name || ""), confidence: num(f.confidence),
      candidates: [...cands.slice(0, 4), aiItem] });
  }
  return out;
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
          { type: "text", text: PROMPT + (hint ? `\n회원 메모: ${hint.slice(0, 200)}` : "") },
        ],
      }],
    }),
  });
  if (!res.ok) {
    const t = await res.text();
    console.error("claude error", res.status, t.slice(0, 500));
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
  const rest = (path: string, body: unknown) => fetch(`${URL_}/rest/v1/${path}`, {
    method: "POST",
    headers: { apikey: ANON, Authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  try {
    const u = await fetch(`${URL_}/auth/v1/user`, { headers: { apikey: ANON, Authorization: auth } });
    if (!u.ok) return json({ error: "login" }, 401);

    const body = await req.json().catch(() => ({}));
    const image = String(body.image || "");
    const mediaType = ["image/jpeg", "image/png", "image/webp"].includes(body.media_type) ? body.media_type : "image/jpeg";
    if (!image || image.length > 7_000_000) return json({ error: "image" }, 400);

    const q = await rest("rpc/ai_take_quota", {});
    if (!q.ok) {
      const t = await q.text();
      return json({ error: t.includes("ai_limit") ? "ai_limit" : "quota" }, t.includes("ai_limit") ? 429 : 403);
    }
    const remaining = await q.json();

    const ai = await callClaude(image, mediaType, String(body.hint || ""));
    const search = async (term: string) => {
      const r = await rest("rpc/search_foods", { q: term, lim: 3 });
      return r.ok ? await r.json() : [];
    };

    if (ai.kind === "label") {
      const { item, food } = labelToItem(ai.label);
      return json({ kind: "label", items: item ? [item] : [], label_food: food, note: ai.note ?? null, remaining });
    }
    if (ai.kind === "food") {
      const items = await matchFoods(ai.foods, search);
      return json({ kind: "food", items, note: ai.note ?? null, remaining });
    }
    return json({ kind: "unknown", items: [], note: ai.note ?? "음식이나 영양성분표를 찾지 못했어요.", remaining });
  } catch (e) {
    console.error(e);
    return json({ error: (e as Error).message || "server" }, (e as any).status || 500);
  }
}

if ((globalThis as any).Deno?.serve) (globalThis as any).Deno.serve(handler);
