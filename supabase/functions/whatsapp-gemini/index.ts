// JARVIS Reader: WhatsApp -> Gemini Vision -> WhatsApp
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

function extractGeminiText(payload: any): string {
  const parts = payload?.candidates?.[0]?.content?.parts || [];
  return parts
    .map((part: any) => (typeof part?.text === "string" ? part.text : ""))
    .filter(Boolean)
    .join("\n")
    .trim();
}

async function askGemini(bytes: Uint8Array, mimeType: string, caption = ""): Promise<string> {
  const apiKey = env("GEMINI_API_KEY");
  const model = env("GEMINI_MODEL", false) || "gemini-2.5-flash";

  const prompt = [
    "Analyze the attached image for a studying/homework workflow where AI assistance is allowed.",
    "Read all clearly visible text yourself; do not require a separate OCR step.",
    "If the image contains one or more questions, answer them accurately and concisely.",
    "For multiple-choice questions, start with the choice letter and answer text, then add at most one short explanation when useful.",
    "If there are multiple questions, number the answers in the same order as the image.",
    "If there is no clear question, briefly state the important visible text or what the image shows.",
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
          temperature: 0.1,
          maxOutputTokens: 500,
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

    // If media/Gemini fails, make one best-effort attempt to surface the failure in WhatsApp.
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

    // Acknowledge Meta immediately; Gemini/media work continues in the background.
    for (const job of jobs) {
      EdgeRuntime.waitUntil(processImageJob(job));
    }

    return Response.json({ ok: true, images_received: jobs.length });
  } catch (error) {
    console.error("Webhook error", error);
    return new Response("Bad webhook request", { status: 400 });
  }
});
