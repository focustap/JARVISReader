// JARVIS Reader: WhatsApp -> Gemini Vision -> WhatsApp
// Two-photo flow:
//   1) First image is saved as context.
//   2) Second image is treated as the question and sent to Gemini with the context image.

const encoder = new TextEncoder();
const CONTEXT_TTL_MS = 10 * 60 * 1000;

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

type PhotoSession = {
  sender: string;
  context_media_id: string | null;
  context_mime_type: string | null;
  context_caption: string | null;
  context_message_id: string | null;
  context_created_at: string | null;
  last_question_message_id: string | null;
  updated_at: string;
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
  // Chunking avoids blowing the JS call stack on camera images.
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
  const mimeType =
    metadata.mime_type || imageResponse.headers.get("content-type") || "image/jpeg";

  return { bytes, mimeType };
}

function supabaseAdminKey(): string {
  const secretKeys = env("SUPABASE_SECRET_KEYS", false);
  if (secretKeys) {
    try {
      const parsed = JSON.parse(secretKeys);
      if (typeof parsed?.default === "string" && parsed.default.trim()) {
        return parsed.default.trim();
      }
    } catch {
      // Fall back to the legacy hosted Edge Function secret below.
    }
  }

  return env("SUPABASE_SERVICE_ROLE_KEY");
}

function supabaseRestHeaders(): Record<string, string> {
  const key = supabaseAdminKey();
  const headers: Record<string, string> = {
    apikey: key,
    "Content-Type": "application/json",
  };

  // New sb_secret_* keys must not be sent as Bearer JWTs.
  if (!key.startsWith("sb_secret_")) {
    headers.Authorization = `Bearer ${key}`;
  }

  return headers;
}

function photoSessionUrl(sender = ""): URL {
  const url = new URL("/rest/v1/jarvis_photo_sessions", env("SUPABASE_URL"));
  if (sender) url.searchParams.set("sender", `eq.${sender}`);
  return url;
}

async function getPhotoSession(sender: string): Promise<PhotoSession | null> {
  const url = photoSessionUrl(sender);
  url.searchParams.set(
    "select",
    "sender,context_media_id,context_mime_type,context_caption,context_message_id,context_created_at,last_question_message_id,updated_at",
  );
  url.searchParams.set("limit", "1");

  const response = await fetch(url, {
    headers: supabaseRestHeaders(),
  });

  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(
      `Photo session lookup failed: ${response.status}${detail ? ` ${detail.slice(0, 250)}` : ""}`,
    );
  }

  const rows = await response.json();
  return Array.isArray(rows) && rows.length ? rows[0] as PhotoSession : null;
}

async function saveContext(
  sender: string,
  mediaId: string,
  mimeType: string,
  caption: string,
  messageId: string,
  lastQuestionMessageId: string | null,
): Promise<void> {
  const url = photoSessionUrl();
  url.searchParams.set("on_conflict", "sender");

  const now = new Date().toISOString();
  const response = await fetch(url, {
    method: "POST",
    headers: {
      ...supabaseRestHeaders(),
      Prefer: "resolution=merge-duplicates,return=minimal",
    },
    body: JSON.stringify({
      sender,
      context_media_id: mediaId,
      context_mime_type: mimeType || null,
      context_caption: caption || null,
      context_message_id: messageId || null,
      context_created_at: now,
      last_question_message_id: lastQuestionMessageId,
      updated_at: now,
    }),
  });

  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(
      `Context save failed: ${response.status}${detail ? ` ${detail.slice(0, 250)}` : ""}`,
    );
  }
}

async function completePhotoSession(sender: string, questionMessageId: string): Promise<void> {
  const url = photoSessionUrl(sender);
  const response = await fetch(url, {
    method: "PATCH",
    headers: {
      ...supabaseRestHeaders(),
      Prefer: "return=minimal",
    },
    body: JSON.stringify({
      context_media_id: null,
      context_mime_type: null,
      context_caption: null,
      context_created_at: null,
      last_question_message_id: questionMessageId || null,
      updated_at: new Date().toISOString(),
    }),
  });

  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(
      `Photo session completion failed: ${response.status}${detail ? ` ${detail.slice(0, 250)}` : ""}`,
    );
  }
}

function isFreshContext(session: PhotoSession | null): boolean {
  if (!session?.context_media_id || !session.context_created_at) return false;
  const createdAt = new Date(session.context_created_at).getTime();
  return Number.isFinite(createdAt) && Date.now() - createdAt <= CONTEXT_TTL_MS;
}

function extractGeminiText(payload: any): string {
  const parts = payload?.candidates?.[0]?.content?.parts || [];
  return parts
    .map((part: any) => (typeof part?.text === "string" ? part.text : ""))
    .filter(Boolean)
    .join("\n")
    .trim();
}

async function askGemini(
  contextBytes: Uint8Array,
  contextMimeType: string,
  questionBytes: Uint8Array,
  questionMimeType: string,
  contextCaption = "",
  questionCaption = "",
): Promise<string> {
  const apiKey = env("GEMINI_API_KEY");
  const model = env("GEMINI_MODEL", false) || "gemini-2.5-flash";

  const prompt = [
    "This is a two-image studying/homework workflow where AI assistance is allowed.",
    "IMAGE 1 is CONTEXT / REFERENCE MATERIAL. IMAGE 2 contains the QUESTION to answer.",
    "Read all clearly visible text, tables, graphs, diagrams, formulas, and labels in both images yourself.",
    "Use IMAGE 1 when it is relevant to interpreting or solving IMAGE 2.",
    "Answer the question from IMAGE 2 accurately and concisely.",
    "For multiple-choice questions, start with the choice letter and answer text, then add at most one short explanation when useful.",
    "If IMAGE 2 contains multiple questions, number the answers in the same order.",
    "If the question cannot be answered from the visible information, say exactly what is missing rather than guessing.",
    "Keep the response compact because it will be read on smart glasses.",
    contextCaption ? `Context caption: ${contextCaption}` : "",
    questionCaption ? `Question caption: ${questionCaption}` : "",
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
              { text: "IMAGE 1 — CONTEXT / REFERENCE" },
              {
                inline_data: {
                  mime_type: contextMimeType,
                  data: bytesToBase64(contextBytes),
                },
              },
              { text: "IMAGE 2 — QUESTION" },
              {
                inline_data: {
                  mime_type: questionMimeType,
                  data: bytesToBase64(questionBytes),
                },
              },
              { text: prompt },
            ],
          },
        ],
        generationConfig: {
          temperature: 0.1,
          maxOutputTokens: 500,
        },
      }),
    },
  );

  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(
      `Gemini failed: ${response.status}${detail ? ` ${detail.slice(0, 250)}` : ""}`,
    );
  }

  const data = await response.json();
  const answer = extractGeminiText(data);
  if (!answer) throw new Error("Gemini returned no text answer");
  return answer;
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
    throw new Error(
      `WhatsApp reply failed: ${response.status}${detail ? ` ${detail.slice(0, 250)}` : ""}`,
    );
  }
}

async function processImageJob(job: ImageJob): Promise<void> {
  const from = normalizePhone(job.message.from || "");
  const allowed = normalizePhone(env("ALLOWED_WHATSAPP_NUMBER", false));
  const phoneNumberId = job.value.metadata?.phone_number_id || "";
  const mediaId = job.message.image?.id || "";
  const messageId = job.message.id || "";
  const imageMimeType = job.message.image?.mime_type || "image/jpeg";
  const imageCaption = job.message.image?.caption || "";

  if (!from || !phoneNumberId || !mediaId) return;

  if (allowed && from !== allowed) {
    console.warn(`Ignoring image from unapproved WhatsApp number ending in ${from.slice(-4)}`);
    return;
  }

  try {
    const session = await getPhotoSession(from);

    // Ignore webhook retries for an image we have already accepted or completed.
    if (
      messageId &&
      (messageId === session?.context_message_id ||
        messageId === session?.last_question_message_id)
    ) {
      console.log(`Ignoring duplicate WhatsApp image message ${messageId}`);
      return;
    }

    if (!isFreshContext(session)) {
      await saveContext(
        from,
        mediaId,
        imageMimeType,
        imageCaption,
        messageId,
        session?.last_question_message_id || null,
      );
      await sendWhatsAppText(
        phoneNumberId,
        from,
        "CONTEXT SAVED · Take/send the question photo.",
      );
      return;
    }

    const [contextImage, questionImage] = await Promise.all([
      getWhatsAppMedia(session!.context_media_id!),
      getWhatsAppMedia(mediaId),
    ]);

    const answer = await askGemini(
      contextImage.bytes,
      contextImage.mimeType || session!.context_mime_type || "image/jpeg",
      questionImage.bytes,
      questionImage.mimeType,
      session!.context_caption || "",
      imageCaption,
    );

    await sendWhatsAppText(phoneNumberId, from, answer);
    await completePhotoSession(from, messageId);
  } catch (error) {
    console.error("JARVIS image processing failed", error);

    try {
      await sendWhatsAppText(
        phoneNumberId,
        from,
        "JARVIS couldn't process that photo pair. If the context was already saved, resend the question photo.",
      );
    } catch (replyError) {
      console.error("Could not send JARVIS failure reply", replyError);
    }
  }
}

Deno.serve(async (req: Request) => {
  // Meta webhook verification handshake.
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

    // Acknowledge Meta immediately; media/Gemini work continues after the response.
    for (const job of jobs) {
      EdgeRuntime.waitUntil(processImageJob(job));
    }

    return Response.json({ ok: true, images_received: jobs.length });
  } catch (error) {
    console.error("Webhook error", error);
    return new Response("Bad webhook request", { status: 400 });
  }
});
