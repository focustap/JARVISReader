// JARVIS Reader: native glasses / WhatsApp -> Gemini Vision
// Supabase Edge Function. No database is required.

const encoder = new TextEncoder();

type WhatsAppMessage = {
  from?: string;
  id?: string;
  type?: string;
  image?: {
    id?: string;
    mime_type?: string;
    caption?: string;
  };
};

type WhatsAppValue = {
  metadata?: {
    phone_number_id?: string;
  };
  messages?: WhatsAppMessage[];
};

type ImageJob = {
  message: WhatsAppMessage;
  value: WhatsAppValue;
};

function env(name: string, required = true): string {
  const value = (Deno.env.get(name) || "").trim();
  if (required && !value) throw new Error(`Missing environment variable: ${name}`);
  return value;
}

function normalizePhone(value: string): string {
  return value.replace(/\D/g, "");
}

function hexToBytes(hex: string): Uint8Array | null {
  if (!/^[0-9a-f]+$/i.test(hex) || hex.length % 2 !== 0) return null;
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

async function verifyMetaSignature(rawBody: string, signatureHeader: string | null): Promise<boolean> {
  const appSecret = env("WHATSAPP_APP_SECRET");
  if (!signatureHeader?.startsWith("sha256=")) return false;

  const signature = hexToBytes(signatureHeader.slice("sha256=".length));
  if (!signature) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(appSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );

  return crypto.subtle.verify("HMAC", key, signature, encoder.encode(rawBody));
}

function collectImageJobs(payload: any): ImageJob[] {
  const jobs: ImageJob[] = [];

  for (const entry of payload?.entry || []) {
    for (const change of entry?.changes || []) {
      const value = change?.value as WhatsAppValue | undefined;
      if (!value) continue;

      for (const message of value.messages || []) {
        if (message?.type === "image" && message.image?.id && message.from) {
          jobs.push({ message, value });
        }
      }
    }
  }

  return jobs;
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

function graphUrl(path: string): string {
  const version = env("META_GRAPH_VERSION", false) || "v23.0";
  return `https://graph.facebook.com/${version}/${path.replace(/^\//, "")}`;
}

async function getWhatsAppMedia(mediaId: string): Promise<{ bytes: Uint8Array; mimeType: string }> {
  const accessToken = env("WHATSAPP_ACCESS_TOKEN");

  const metadataResponse = await fetch(graphUrl(encodeURIComponent(mediaId)), {
    headers: { Authorization: `Bearer ${accessToken}` },
  });

  if (!metadataResponse.ok) {
    throw new Error(`WhatsApp media metadata failed: ${metadataResponse.status}`);
  }

  const metadata = await metadataResponse.json();
  if (!metadata?.url) throw new Error("WhatsApp media response did not contain a download URL");

  const imageResponse = await fetch(metadata.url, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });

  if (!imageResponse.ok) {
    throw new Error(`WhatsApp media download failed: ${imageResponse.status}`);
  }

  const bytes = new Uint8Array(await imageResponse.arrayBuffer());
  const mimeType = metadata.mime_type || imageResponse.headers.get("content-type") || "image/jpeg";

  return { bytes, mimeType };
}

function extractGeminiText(payload: any): string {
  const parts = payload?.candidates?.[0]?.content?.parts || [];
  return parts
    .map((part: any) => (typeof part?.text === "string" ? part.text : ""))
    .filter(Boolean)
    .join("\n")
    .trim();
}

function plainTextForGlasses(input: string): string {
  let text = input;

  // Convert the most common LaTeX forms into simple readable ASCII.
  for (let i = 0; i < 4; i += 1) {
    const previous = text;
    text = text.replace(/\\frac\s*\{([^{}]+)\}\s*\{([^{}]+)\}/g, "$1/$2");
    text = text.replace(/\\sqrt\s*\{([^{}]+)\}/g, "sqrt($1)");
    text = text.replace(/\\(?:text|mathrm|mathbf|mathit)\s*\{([^{}]+)\}/g, "$1");
    if (text === previous) break;
  }

  text = text
    .replace(/\\\(/g, "")
    .replace(/\\\)/g, "")
    .replace(/\\\[/g, "")
    .replace(/\\\]/g, "")
    .replace(/\$\$/g, "")
    .replace(/\\left|\\right/g, "")
    .replace(/\\times|\\cdot/g, " * ")
    .replace(/\\div/g, " / ")
    .replace(/\\pm/g, " +/- ")
    .replace(/\\(?:leq|le)/g, " <= ")
    .replace(/\\(?:geq|ge)/g, " >= ")
    .replace(/\\(?:neq|ne)/g, " != ")
    .replace(/\\approx/g, " ~= ")
    .replace(/\\pi\b/g, "pi")
    .replace(/\\theta\b/g, "theta")
    .replace(/\\alpha\b/g, "alpha")
    .replace(/\\beta\b/g, "beta")
    .replace(/\\gamma\b/g, "gamma")
    .replace(/\\delta\b/g, "delta")
    .replace(/\^\s*\{([^{}]+)\}/g, "^$1")
    .replace(/_\s*\{([^{}]+)\}/g, "_$1")
    .replace(/\\([A-Za-z]+)/g, "$1")
    .replace(/[{}]/g, "")

    // Unicode math/punctuation -> ASCII equivalents that render reliably.
    .replace(/×/g, "*")
    .replace(/÷/g, "/")
    .replace(/[−–—]/g, "-")
    .replace(/≤/g, "<=")
    .replace(/≥/g, ">=")
    .replace(/≠/g, "!=")
    .replace(/≈/g, "~=")
    .replace(/±/g, "+/-")
    .replace(/√/g, "sqrt")
    .replace(/π/g, "pi")
    .replace(/∞/g, "infinity")
    .replace(/→/g, "->")
    .replace(/←/g, "<-")
    .replace(/²/g, "^2")
    .replace(/³/g, "^3")
    .replace(/¹/g, "^1")
    .replace(/₀/g, "_0")
    .replace(/₁/g, "_1")
    .replace(/₂/g, "_2")
    .replace(/₃/g, "_3")
    .replace(/₄/g, "_4")
    .replace(/₅/g, "_5")
    .replace(/₆/g, "_6")
    .replace(/₇/g, "_7")
    .replace(/₈/g, "_8")
    .replace(/₉/g, "_9")
    .replace(/\u00a0/g, " ");

  // Remove Markdown decoration while preserving the actual words and line breaks.
  text = text
    .replace(/^\s*#{1,6}\s+/gm, "")
    .replace(/\*\*|__/g, "")
    .replace(/`{1,3}/g, "")
    .replace(/^\s*[•●▪◦]\s*/gm, "- ")
    .replace(/[ \t]{2,}/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

  return text;
}

async function askGemini(bytes: Uint8Array, mimeType: string, caption = ""): Promise<string> {
  const apiKey = env("GEMINI_API_KEY");
  const model = env("GEMINI_MODEL", false) || "gemini-3.1-flash-lite";

  const prompt = [
    "Analyze the ENTIRE attached image for a studying/homework workflow where AI assistance is allowed.",
    "Read all clearly visible text yourself; do not require a separate OCR step.",
    "IMPORTANT: scan the whole image from top to bottom before answering and identify EVERY clearly visible question.",
    "Answer EVERY legible question in the image. Do not stop after the first question and do not silently omit later questions.",
    "Preserve the question order and numbering shown in the image. If numbering is not visible, number the answers 1, 2, 3, etc.",
    "For multiple-choice questions, give one compact line per question in the format: 1. B - answer text.",
    "For short-answer questions, give the shortest correct answer that is still useful.",
    "If a question is visible but too blurry or cut off to answer reliably, include its number and say 'unreadable' instead of skipping it.",
    "Do not add a long explanation unless the question specifically asks for one.",
    "If there is no clear question, briefly state the important visible text or what the image shows.",
    "OUTPUT FORMAT RULE: return plain text only. Never use Markdown, LaTeX, TeX, code fences, math delimiters, or formatting commands.",
    "Write all math in simple ASCII text. Examples: x^2, sqrt(16), 3/4, 2 * 5, x <= 4, y >= 2, a != b, pi.",
    "Do not output commands such as \\frac, \\sqrt, \\times, or \\boxed. Do not use Unicode math symbols when an ASCII equivalent exists.",
    "Keep the response compact because it will be read on smart glasses.",
    caption ? `The sender included this caption: ${caption}` : "",
  ].filter(Boolean).join("\n");

  const response = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`,
    {
      method: "POST",
      headers: {
        "x-goog-api-key": apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        contents: [
          {
            role: "user",
            parts: [
              { inline_data: { mime_type: mimeType, data: bytesToBase64(bytes) } },
              { text: prompt },
            ],
          },
        ],
        generationConfig: {
          maxOutputTokens: 1200,
        },
      }),
    },
  );

  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(`Gemini failed: ${response.status}${detail ? ` ${detail.slice(0, 250)}` : ""}`);
  }

  const data = await response.json();
  const answer = extractGeminiText(data);
  if (!answer) throw new Error("Gemini returned no text answer");
  return plainTextForGlasses(answer);
}

async function handleNativeImage(req: Request): Promise<Response> {
  const expectedToken = env("JARVIS_NATIVE_TOKEN", false);
  if (expectedToken) {
    const suppliedToken = (req.headers.get("x-jarvis-token") || "").trim();
    if (suppliedToken !== expectedToken) {
      return Response.json({ ok: false, error: "Unauthorized" }, { status: 401 });
    }
  }

  const mimeType = (req.headers.get("content-type") || "image/jpeg")
    .split(";", 1)[0]
    .trim()
    .toLowerCase();

  if (!mimeType.startsWith("image/")) {
    return Response.json({ ok: false, error: "Expected an image body" }, { status: 415 });
  }

  const bytes = new Uint8Array(await req.arrayBuffer());
  if (!bytes.length) {
    return Response.json({ ok: false, error: "Image body was empty" }, { status: 400 });
  }
  if (bytes.length > 8 * 1024 * 1024) {
    return Response.json({ ok: false, error: "Image is too large" }, { status: 413 });
  }

  try {
    const answer = await askGemini(bytes, mimeType);
    return Response.json({ ok: true, answer });
  } catch (error) {
    console.error("Native JARVIS request failed", error);
    const message = error instanceof Error ? error.message : "Unknown Gemini error";
    return Response.json({ ok: false, error: message }, { status: 502 });
  }
}

async function sendWhatsAppText(phoneNumberId: string, to: string, text: string): Promise<void> {
  const accessToken = env("WHATSAPP_ACCESS_TOKEN");
  const body = text.length > 3900 ? `${text.slice(0, 3897)}...` : text;

  const response = await fetch(graphUrl(`${encodeURIComponent(phoneNumberId)}/messages`), {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to,
      type: "text",
      text: { body },
    }),
  });

  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(`WhatsApp reply failed: ${response.status}${detail ? ` ${detail.slice(0, 250)}` : ""}`);
  }
}

async function processImageJob(job: ImageJob): Promise<void> {
  const from = normalizePhone(job.message.from || "");
  const allowed = normalizePhone(env("ALLOWED_WHATSAPP_NUMBER", false));
  const phoneNumberId = job.value.metadata?.phone_number_id || "";
  const mediaId = job.message.image?.id || "";

  if (!from || !phoneNumberId || !mediaId) return;

  if (allowed && from !== allowed) {
    console.warn(`Ignoring image from unapproved WhatsApp number ending in ${from.slice(-4)}`);
    return;
  }

  try {
    const { bytes, mimeType } = await getWhatsAppMedia(mediaId);
    const answer = await askGemini(bytes, mimeType, job.message.image?.caption || "");
    await sendWhatsAppText(phoneNumberId, from, answer);
  } catch (error) {
    console.error("JARVIS image processing failed", error);

    try {
      await sendWhatsAppText(
        phoneNumberId,
        from,
        "JARVIS couldn't process that image. Try sending it again.",
      );
    } catch (replyError) {
      console.error("Could not send JARVIS failure reply", replyError);
    }
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "POST" && (req.headers.get("x-jarvis-mode") || "").toLowerCase() === "native") {
    return handleNativeImage(req);
  }

  if (req.method === "GET") {
    const url = new URL(req.url);
    const mode = url.searchParams.get("hub.mode");
    const token = url.searchParams.get("hub.verify_token");
    const challenge = url.searchParams.get("hub.challenge") || "";

    if (mode === "subscribe" && token && token === env("WHATSAPP_VERIFY_TOKEN")) {
      return new Response(challenge, {
        status: 200,
        headers: { "Content-Type": "text/plain" },
      });
    }

    return new Response("Webhook verification failed", { status: 403 });
  }

  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const rawBody = await req.text();

  try {
    const validSignature = await verifyMetaSignature(
      rawBody,
      req.headers.get("x-hub-signature-256"),
    );

    if (!validSignature) {
      return new Response("Invalid Meta signature", { status: 401 });
    }

    const payload = JSON.parse(rawBody);
    const jobs = collectImageJobs(payload);

    for (const job of jobs) {
      EdgeRuntime.waitUntil(processImageJob(job));
    }

    return Response.json({ ok: true, images_received: jobs.length });
  } catch (error) {
    console.error("Webhook error", error);
    return new Response("Bad webhook request", { status: 400 });
  }
});
