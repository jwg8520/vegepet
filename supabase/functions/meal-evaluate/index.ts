// meal-evaluate: 식단 사진 AI 판정 + meal_logs / user_pets 갱신
// Flutter invoke body: { slot, imagePath, locale_code? }
// locale_code === 'en' 이면 feedback_text 를 자연스러운 영어 phrase 로 반환

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

type MealResultType = "good" | "supplement_needed" | "bad" | "uncertain";
type LocaleCode = "ko" | "en";

interface AiMealJson {
  result_type?: string;
  feedback_text?: string | null;
  affection_gain?: number;
}

function jsonResponse(
  body: Record<string, unknown>,
  status = 200,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function parseLocaleCode(body: Record<string, unknown>): LocaleCode {
  const raw =
    body.locale_code ?? body.localeCode ?? body.language ?? "ko";
  return raw === "en" ? "en" : "ko";
}

/** KST 기준 yyyy-MM-dd */
function kstMealDate(now = new Date()): string {
  const kst = new Date(now.getTime() + 9 * 60 * 60 * 1000);
  return kst.toISOString().slice(0, 10);
}

function gainForResult(resultType: MealResultType): number {
  switch (resultType) {
    case "good":
      return 5;
    case "supplement_needed":
      return 3;
    default:
      return 0;
  }
}

function normalizeResultType(raw: string | undefined): MealResultType {
  const v = (raw ?? "").trim().toLowerCase();
  if (
    v === "good" ||
    v === "supplement_needed" ||
    v === "bad" ||
    v === "uncertain"
  ) {
    return v;
  }
  return "uncertain";
}

const HANGUL_RE = /[\u3131-\u318E\uAC00-\uD7A3]/;

function containsHangul(text: string): boolean {
  return HANGUL_RE.test(text);
}

/**
 * 한국어: 기존 compact phrase 스타일 유지 (공백 제거·짧은 조언).
 * 영어: OpenAI phrase 그대로 사용. 한글이 섞이면 비우고 재요청 없이 빈 문자열.
 */
function normalizeFeedbackText(
  raw: string | null | undefined,
  resultType: MealResultType,
  localeCode: LocaleCode,
): string | null {
  if (resultType === "good" || resultType === "uncertain") {
    return null;
  }

  let text = (raw ?? "").trim();
  if (!text) return null;

  if (localeCode === "en") {
    if (containsHangul(text)) return null;
    text = text.replace(/^["'`]+|["'`]+$/g, "").trim();
    if (text.length > 120) {
      text = text.slice(0, 120).trim();
    }
    return text || null;
  }

  // ko: 공백 제거·끝 구두점 정리 (단백질높이기 형태 허용)
  text = text.replace(/\s+/g, "");
  text = text.replace(/[.!?…]+$/g, "");
  if (!text) return null;
  if (text.length > 40) {
    text = text.slice(0, 40);
  }
  return text;
}

function buildOpenAiPrompt(
  localeCode: LocaleCode,
  ctx: {
    gender: string | null;
    ageRange: string | null;
    dietGoal: string | null;
    mealSlot: string;
    mealDate: string;
  },
): { system: string; user: string } {
  const profileLines = [
    ctx.gender ? `gender: ${ctx.gender}` : null,
    ctx.ageRange ? `age_range: ${ctx.ageRange}` : null,
    ctx.dietGoal ? `diet_goal: ${ctx.dietGoal}` : null,
    `meal_slot: ${ctx.mealSlot}`,
    `meal_date: ${ctx.mealDate}`,
    `response_language: ${localeCode}`,
  ].filter(Boolean).join("\n");

  const sharedRules = `
You are a friendly meal coach for a virtual pet game (VegePet).
Evaluate the meal photo for general balance only.
Do NOT diagnose disease, prescribe treatment, or give medical/blood-sugar advice.
Return ONLY valid json (lowercase word json required) with this exact shape:
{
  "result_type": "good" | "supplement_needed" | "bad" | "uncertain",
  "feedback_text": "string"
}
Rules for result_type:
- good: clearly balanced, wholesome meal
- supplement_needed: acceptable but could improve balance
- bad: clearly unbalanced or low-quality pattern
- uncertain: photo too blurry/dark/obstructed to judge food
Rules for feedback_text:
- Must be a SHORT phrase (not a full sentence) that fits inside a parent app template.
- For result_type good: use empty string "".
- For result_type uncertain: use empty string "".
- For supplement_needed or bad only: provide feedback_text.
- Focus on improvement direction (protein, vegetables, fiber, carbs, hydration) — not food name lists.
- No markdown, no extra keys, no explanation outside json.
`.trim();

  const koFeedback = `
feedback_text MUST be written in Korean.
Examples: "단백질을 조금 더 보충하기", "채소를 조금 더 추가하기", "탄수화물 양을 조금 줄이기"
Use natural short Korean phrases (may be compact without spaces).
`.trim();

  const enFeedback = `
feedback_text MUST be written in natural English. Do NOT use Korean.
Use a short phrase that fits after "try adding ..." or "let's try ...".
Do NOT output awkward phrases like "increase protein", "protein up", or "protein increasing".
supplement_needed examples:
- "a little more protein"
- "more vegetables"
- "a bit more fiber"
- "a small portion of fruit"
- "more balanced protein and vegetables"
bad examples (use verb-ing or noun phrases that work after "let's try"):
- "choosing less fried or oily food"
- "reducing the carbohydrate portion"
- "adding more vegetables and lean protein"
- "choosing a more balanced meal"
- "avoiding overly sugary foods"
`.trim();

  const system = [sharedRules, localeCode === "en" ? enFeedback : koFeedback].join(
    "\n\n",
  );

  const user = `Analyze this meal photo for the user profile below.\n${profileLines}`;

  return { system, user };
}

async function callOpenAiVision(
  imageUrl: string,
  localeCode: LocaleCode,
  ctx: {
    gender: string | null;
    ageRange: string | null;
    dietGoal: string | null;
    mealSlot: string;
    mealDate: string;
  },
): Promise<AiMealJson> {
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) {
    throw new Error("OPENAI_API_KEY is not configured");
  }

  const { system, user } = buildOpenAiPrompt(localeCode, ctx);

  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "gpt-4.1-mini",
      temperature: 0.4,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: system },
        {
          role: "user",
          content: [
            { type: "text", text: user },
            { type: "image_url", image_url: { url: imageUrl } },
          ],
        },
      ],
    }),
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`OpenAI error ${res.status}: ${errText}`);
  }

  const payload = await res.json();
  const content = payload?.choices?.[0]?.message?.content;
  if (typeof content !== "string" || !content.trim()) {
    throw new Error("OpenAI returned empty content");
  }

  return JSON.parse(content) as AiMealJson;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonResponse({ ok: false, error: "Missing Authorization" }, 401);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser();
    if (userError || !user) {
      return jsonResponse({ ok: false, error: "Unauthorized" }, 401);
    }

    const body = await req.json() as Record<string, unknown>;
    const slotRaw = body.slot ?? body.meal_slot;
    const slot = typeof slotRaw === "string" ? slotRaw.trim() : "";
    const imagePathRaw = body.imagePath ?? body.storage_path;
    const imagePath = typeof imagePathRaw === "string"
      ? imagePathRaw.trim()
      : "";

    const localeCode = parseLocaleCode(body);
    console.log("meal-evaluate localeCode:", localeCode);

    if (slot !== "brunch" && slot !== "dinner") {
      return jsonResponse({ ok: false, error: "Invalid meal slot" }, 400);
    }
    if (!imagePath) {
      return jsonResponse({ ok: false, error: "Missing image path" }, 400);
    }

    const mealDate = kstMealDate();

    const { data: profile } = await adminClient
      .from("profiles")
      .select("gender, age_range, diet_goal")
      .eq("user_id", user.id)
      .maybeSingle();

    const { data: activePet, error: petError } = await adminClient
      .from("user_pets")
      .select("id, affection, stage, is_active")
      .eq("user_id", user.id)
      .eq("is_active", true)
      .maybeSingle();

    if (petError || !activePet) {
      return jsonResponse({ ok: false, error: "No active pet" }, 400);
    }

    const { data: existingLog } = await adminClient
      .from("meal_logs")
      .select("id")
      .eq("user_id", user.id)
      .eq("meal_date", mealDate)
      .eq("meal_slot", slot)
      .maybeSingle();

    if (existingLog) {
      return jsonResponse({
        ok: false,
        error: "Meal already certified for this slot today",
      }, 409);
    }

    const { data: signed, error: signError } = await adminClient.storage
      .from("meal-photos")
      .createSignedUrl(imagePath, 60 * 10);

    if (signError || !signed?.signedUrl) {
      return jsonResponse({ ok: false, error: "Failed to sign image URL" }, 500);
    }

    const aiRaw = await callOpenAiVision(signed.signedUrl, localeCode, {
      gender: profile?.gender ?? null,
      ageRange: profile?.age_range ?? null,
      dietGoal: profile?.diet_goal ?? null,
      mealSlot: slot,
      mealDate,
    });

    const resultType = normalizeResultType(aiRaw.result_type);
    const feedbackText = normalizeFeedbackText(
      aiRaw.feedback_text ?? null,
      resultType,
      localeCode,
    );

    console.log("meal-evaluate result:", {
      result_type: resultType,
      feedback_text: feedbackText,
    });

    const currentAffection = Number(activePet.affection ?? 0);
    const affectionGain = gainForResult(resultType);
    const nextAffection = currentAffection + affectionGain;

    if (resultType === "uncertain") {
      return jsonResponse({
        ok: true,
        meal_date: mealDate,
        meal_slot: slot,
        result_type: "uncertain",
        feedback_text: null,
        affection_gain: 0,
        next_affection: currentAffection,
      });
    }

    const { error: insertError } = await adminClient.from("meal_logs").insert({
      user_id: user.id,
      user_pet_id: activePet.id,
      meal_date: mealDate,
      meal_slot: slot,
      result_type: resultType,
      affection_gain: affectionGain,
      image_path: imagePath,
      memo: feedbackText,
    });

    if (insertError) {
      console.error("meal_logs insert failed:", insertError);
      return jsonResponse({ ok: false, error: "Failed to save meal log" }, 500);
    }

    const { error: updateError } = await adminClient
      .from("user_pets")
      .update({ affection: nextAffection })
      .eq("id", activePet.id);

    if (updateError) {
      console.error("user_pets update failed:", updateError);
      return jsonResponse({ ok: false, error: "Failed to update affection" }, 500);
    }

    return jsonResponse({
      ok: true,
      meal_date: mealDate,
      meal_slot: slot,
      result_type: resultType,
      feedback_text: feedbackText,
      affection_gain: affectionGain,
      next_affection: nextAffection,
    });
  } catch (e) {
    console.error("meal-evaluate error:", e);
    const message = e instanceof Error ? e.message : String(e);
    return jsonResponse({ ok: false, error: message }, 500);
  }
});
