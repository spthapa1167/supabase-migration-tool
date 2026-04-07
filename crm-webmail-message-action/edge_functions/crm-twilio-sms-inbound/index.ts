import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
/** Twilio webhook: validate X-Twilio-Signature (SHA1 HMAC, base64). */ async function twilioSignatureValid(authToken, signature, webhookUrl, bodyText) {
  if (!signature) return false;
  const params = new URLSearchParams(bodyText);
  const keys = [
    ...new Set(Array.from(params.keys()))
  ].sort();
  let data = webhookUrl;
  for (const key of keys){
    for (const value of params.getAll(key)){
      data += key + value;
    }
  }
  const enc = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey("raw", enc.encode(authToken), {
    name: "HMAC",
    hash: "SHA-1"
  }, false, [
    "sign"
  ]);
  const sigBuf = await crypto.subtle.sign("HMAC", cryptoKey, enc.encode(data));
  const expected = btoa(String.fromCharCode(...new Uint8Array(sigBuf)));
  if (expected.length !== signature.length) return false;
  let diff = 0;
  for(let i = 0; i < expected.length; i++){
    diff |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  }
  return diff === 0;
}
function addUnique(out, u) {
  const t = u.trim();
  if (t && !out.includes(t)) out.push(t);
}
/** URLs Twilio may have signed (config + Supabase project URL + this request’s forwarded host/path). */ function allWebhookUrlCandidates(req, configured, supabaseUrl) {
  const out = [];
  const derived = `${supabaseUrl.replace(/\/$/, "")}/functions/v1/crm-twilio-sms-inbound`;
  if (configured.trim()) {
    addUnique(out, configured.trim());
    addUnique(out, configured.trim().replace(/\/$/, ""));
    addUnique(out, configured.trim().endsWith("/") ? configured.trim() : `${configured.trim()}/`);
  }
  addUnique(out, derived);
  addUnique(out, `${derived}/`);
  try {
    const u = new URL(req.url);
    const path = u.pathname || "/functions/v1/crm-twilio-sms-inbound";
    addUnique(out, `${u.origin}${path}`);
    const fwdHost = req.headers.get("x-forwarded-host")?.split(",")[0]?.trim();
    const fwdProto = req.headers.get("x-forwarded-proto")?.split(",")[0]?.trim() || "https";
    if (fwdHost) {
      addUnique(out, `${fwdProto}://${fwdHost}${path}`);
      addUnique(out, `https://${fwdHost}${path}`);
    }
    const host = req.headers.get("host");
    if (host) {
      addUnique(out, `https://${host}${path}`);
    }
  } catch  {
  /* ignore */ }
  return out;
}
function digitsOnly(s) {
  return s.replace(/\D/g, "");
}
/** Twilio sends E.164, whatsapp:+..., client:xyz, etc. Match CRM on digits only after stripping channels. */ function normalizeTwilioFrom(raw) {
  let s = raw.trim();
  const low = s.toLowerCase();
  if (low.startsWith("whatsapp:")) {
    s = s.slice("whatsapp:".length).trim();
  }
  return s;
}
/** Same rule as SQL RPC: last 10 digits when enough digits exist. */ function phoneMatchKey(digits) {
  return digits.length >= 10 ? digits.slice(-10) : digits;
}
const CUSTOMER_PAGE = 500;
/** Full-table scan by last-10-digits (RPC missing or error). Ordered pages avoid PostgREST’s default row cap silently dropping matches. */ async function matchCustomerIdsByFromPaginated(supabase, fromKey) {
  const ids = [];
  for(let offset = 0;; offset += CUSTOMER_PAGE){
    const { data: rows, error: qErr } = await supabase.from("crm_customers").select("id, phone").not("phone", "is", null).order("id", {
      ascending: true
    }).range(offset, offset + CUSTOMER_PAGE - 1);
    if (qErr) {
      console.error("crm-twilio-sms-inbound fallback query:", qErr.message);
      return ids;
    }
    if (!rows?.length) break;
    for (const r of rows){
      if (r.phone && phoneMatchKey(digitsOnly(r.phone)) === fromKey) ids.push(r.id);
    }
    if (rows.length < CUSTOMER_PAGE) break;
  }
  return ids;
}
/** Resolve customer ids by phone; RPC first, then paginated digit match if RPC missing/empty. */ async function matchCustomerIdsByFrom(supabase, from) {
  const { data: rpcRows, error: rpcErr } = await supabase.rpc("match_crm_customer_ids_by_sms_from", {
    p_from: from
  });
  if (rpcErr) {
    console.error("crm-twilio-sms-inbound RPC (using paginated fallback):", rpcErr.message);
    const fromKey = phoneMatchKey(digitsOnly(from));
    if (!fromKey) return [];
    return matchCustomerIdsByFromPaginated(supabase, fromKey);
  }
  if (!Array.isArray(rpcRows)) {
    console.warn("crm-twilio-sms-inbound: RPC returned non-array");
    return [];
  }
  if (rpcRows.length === 0) return [];
  return rpcRows.map((r)=>r.id);
}
async function alreadyHaveInboundForMessageSid(supabase, customerId, messageSid) {
  if (!messageSid) return false;
  const { data, error } = await supabase.from("crm_interactions").select("id").eq("customer_id", customerId).eq("interaction_type", "sms").eq("direction", "inbound").contains("metadata", {
    message_sid: messageSid
  }).limit(1);
  if (error) {
    console.warn("crm-twilio-sms-inbound dedupe check:", error.message);
    return false;
  }
  return (data?.length ?? 0) > 0;
}
function emptyTwiML() {
  return new Response('<?xml version="1.0" encoding="UTF-8"?><Response></Response>', {
    status: 200,
    headers: {
      "Content-Type": "text/xml; charset=utf-8"
    }
  });
}
function normalizeNotifyVia(v) {
  if (v === "email" || v === "sms" || v === "both") return v;
  return "both";
}
function escapeHtmlNotify(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
function truncateNotify(s, max) {
  const t = s.replace(/\s+/g, " ").trim();
  if (t.length <= max) return t;
  return t.slice(0, max - 1) + "…";
}
async function sendInboundSmsWatcherEmail(supabase, to, subject, innerHtml) {
  const resendKey = Deno.env.get("RESEND_API_KEY");
  if (!resendKey) throw new Error("RESEND_API_KEY not configured");
  const { data } = await supabase.from("email_template_settings").select("from_name, from_email").eq("template_type", "default").eq("is_active", true).order("updated_at", {
    ascending: false,
    nullsFirst: false
  }).limit(1).maybeSingle();
  const fromName = data?.from_name && String(data.from_name).trim() || "KidNCode CRM";
  const fromEmail = data?.from_email && String(data.from_email).trim() || "noreply@kidncode.com";
  const from = `${fromName} <${fromEmail}>`;
  const html = `<div style="padding:20px;font-family:system-ui,sans-serif;font-size:15px;line-height:1.5;color:#111">${innerHtml}</div>`;
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendKey}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      from,
      to: [
        to.trim().toLowerCase()
      ],
      subject,
      html
    })
  });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`Resend: ${t}`);
  }
}
async function sendInboundSmsWatcherTwilioSms(to, message) {
  const accountSid = Deno.env.get("TWILIO_ACCOUNT_SID");
  const authToken = Deno.env.get("TWILIO_AUTH_TOKEN");
  const twilioPhoneNumber = Deno.env.get("TWILIO_PHONE_NUMBER");
  const twilioMsgSid = Deno.env.get("TWILIO_MESSAGING_SERVICE_SID");
  if (!accountSid || !authToken) throw new Error("Twilio not configured");
  if (!twilioPhoneNumber && !twilioMsgSid) {
    throw new Error("Twilio sender: set TWILIO_PHONE_NUMBER or TWILIO_MESSAGING_SERVICE_SID");
  }
  let formattedPhone = to.replace(/\D/g, "");
  if (!formattedPhone.startsWith("1") && formattedPhone.length === 10) formattedPhone = "1" + formattedPhone;
  if (!formattedPhone.startsWith("+")) formattedPhone = "+" + formattedPhone;
  const body = {
    To: formattedPhone,
    Body: message.length > 1500 ? message.slice(0, 1499) + "…" : message
  };
  if (twilioPhoneNumber) body.From = twilioPhoneNumber;
  else if (twilioMsgSid) body.MessagingServiceSid = twilioMsgSid;
  const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`, {
    method: "POST",
    headers: {
      Authorization: "Basic " + btoa(`${accountSid}:${authToken}`),
      "Content-Type": "application/x-www-form-urlencoded"
    },
    body: new URLSearchParams(body).toString()
  });
  if (!res.ok) {
    const err = await res.json().catch(()=>({}));
    throw new Error(err.message || `Twilio ${res.status}`);
  }
}
/** CRM Settings watchers with "inbound SMS" enabled (same table as webmail watchers). */ async function notifyInboundSmsWatchers(supabase, opts) {
  if (!opts.messageSid) return;
  const { data: watchers, error: wErr } = await supabase.from("crm_webmail_watchers").select("id, name, email, phone, notify_via").eq("enabled", true).eq("notify_on_inbound_sms", true);
  if (wErr || !watchers?.length) {
    if (wErr) console.error("notifyInboundSmsWatchers watchers:", wErr.message);
    return;
  }
  const { data: customers } = await supabase.from("crm_customers").select("id, first_name, last_name, phone").in("id", opts.customerIds);
  const labels = (customers || []).map((c)=>{
    const n = [
      c.first_name,
      c.last_name
    ].filter(Boolean).join(" ").trim();
    return n || c.phone || c.id;
  }).filter(Boolean);
  const customerLabel = labels.length ? labels.join("; ") : "Unknown customer";
  for (const w of watchers){
    const { data: dup } = await supabase.from("crm_inbound_sms_watcher_notify_log").select("id").eq("watcher_id", w.id).eq("message_sid", opts.messageSid).maybeSingle();
    if (dup) continue;
    const via = normalizeNotifyVia(w.notify_via);
    const wantEmail = via === "email" || via === "both";
    const wantSms = (via === "sms" || via === "both") && Boolean(w.phone?.trim());
    if (!wantEmail && !wantSms) continue;
    const subj = `CRM: SMS from ${truncateNotify(customerLabel, 60)}`;
    const inner = `
      <p style="margin:0 0 12px"><strong>Inbound customer SMS</strong> (Twilio → CRM)</p>
      <p style="margin:0 0 6px"><strong>Customer:</strong> ${escapeHtmlNotify(customerLabel)}</p>
      <p style="margin:0 0 6px"><strong>From:</strong> ${escapeHtmlNotify(opts.from)}</p>
      <p style="margin:0 0 6px"><strong>Message:</strong></p>
      <p style="margin:0;padding:12px;background:#f4f4f5;border-radius:8px;white-space:pre-wrap">${escapeHtmlNotify(truncateNotify(opts.text, 4000))}</p>
    `;
    let emailOk = false;
    let smsOk = false;
    if (wantEmail) {
      try {
        await sendInboundSmsWatcherEmail(supabase, w.email, subj, inner);
        emailOk = true;
      } catch (e) {
        console.error("inbound SMS watcher email:", w.id, e);
      }
    }
    if (wantSms && w.phone?.trim()) {
      try {
        const smsBody = `KidNCode CRM: Inbound SMS\nCustomer: ${truncateNotify(customerLabel, 80)}\nFrom: ${opts.from}\n${truncateNotify(opts.text, 280)}`;
        await sendInboundSmsWatcherTwilioSms(w.phone.trim(), smsBody);
        smsOk = true;
      } catch (e) {
        console.error("inbound SMS watcher sms:", w.id, e);
      }
    }
    if (!emailOk && !smsOk) continue;
    const { error: insErr } = await supabase.from("crm_inbound_sms_watcher_notify_log").insert({
      watcher_id: w.id,
      message_sid: opts.messageSid
    });
    if (insErr) console.error("crm_inbound_sms_watcher_notify_log:", insErr.message);
  }
}
Deno.serve(async (req)=>{
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204
    });
  }
  if (req.method === "GET" || req.method === "HEAD") {
    return new Response("crm-twilio-sms-inbound OK", {
      status: 200
    });
  }
  if (req.method !== "POST") {
    return new Response("Method not allowed", {
      status: 405
    });
  }
  const bodyText = await req.text();
  const webhookUrl = (Deno.env.get("CRM_TWILIO_SMS_WEBHOOK_URL") || "").trim();
  const authToken = (Deno.env.get("TWILIO_AUTH_TOKEN") || "").trim();
  const sig = req.headers.get("X-Twilio-Signature") || "";
  const skipVerify = (Deno.env.get("CRM_TWILIO_SMS_SKIP_SIGNATURE_VERIFY") || "").toLowerCase() === "true";
  /**
   * Default OFF: TWILIO_AUTH_TOKEN is usually set for outbound SMS; the signed URL often does not match
   * what Supabase Edge exposes, which caused 403 and zero inbound rows. Enable explicitly for production:
   * CRM_TWILIO_SMS_REQUIRE_SIGNATURE=true
   */ const requireSignature = (Deno.env.get("CRM_TWILIO_SMS_REQUIRE_SIGNATURE") || "").toLowerCase() === "true";
  if (!skipVerify && requireSignature && authToken) {
    const supabaseUrl = (Deno.env.get("SUPABASE_URL") || "").trim();
    const candidates = allWebhookUrlCandidates(req, webhookUrl, supabaseUrl);
    let ok = false;
    for (const u of candidates){
      if (await twilioSignatureValid(authToken, sig, u, bodyText)) {
        ok = true;
        break;
      }
    }
    if (!ok) {
      console.warn("crm-twilio-sms-inbound: signature verification failed (set CRM_TWILIO_SMS_REQUIRE_SIGNATURE=false or fix URL / use CRM_TWILIO_SMS_SKIP_SIGNATURE_VERIFY=true for debug only)");
      return new Response("Forbidden", {
        status: 403
      });
    }
  }
  try {
    let params;
    const ct = req.headers.get("content-type") || "";
    if (ct.includes("application/json")) {
      try {
        const j = JSON.parse(bodyText);
        params = new URLSearchParams();
        for (const [k, v] of Object.entries(j)){
          if (v != null) params.set(k, String(v));
        }
      } catch  {
        params = new URLSearchParams(bodyText);
      }
    } else {
      params = new URLSearchParams(bodyText);
    }
    const fromRaw = params.get("From")?.trim() || params.get("from")?.trim() || params.get("OriginalFrom")?.trim() || "";
    const from = normalizeTwilioFrom(fromRaw);
    const body = params.get("Body")?.trim() || params.get("body")?.trim() || "";
    const messageSid = params.get("MessageSid")?.trim() || params.get("SmsMessageSid")?.trim() || params.get("SmsSid")?.trim() || "";
    if (!from) {
      console.warn("crm-twilio-sms-inbound: no From in payload keys=", [
        ...new Set(params.keys())
      ].join(","));
      return emptyTwiML();
    }
    if (from.toLowerCase().startsWith("client:")) {
      console.warn("crm-twilio-sms-inbound: From is a Twilio Client identity (not a phone), cannot match CRM:", from);
      return emptyTwiML();
    }
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const supabase = createClient(supabaseUrl, serviceKey);
    const { data: recvRow } = await supabase.from("system_settings").select("value").eq("property_name", "crm_sms_receive_enabled").maybeSingle();
    const recvRaw = (recvRow?.value ?? "true").toString().trim().toLowerCase();
    const receiveEnabled = recvRaw !== "false" && recvRaw !== "0" && recvRaw !== "off";
    if (!receiveEnabled) {
      return emptyTwiML();
    }
    const ids = await matchCustomerIdsByFrom(supabase, from);
    if (ids.length === 0) {
      console.warn("crm-twilio-sms-inbound: no crm_customers match for From=", from, "digitsKey=", phoneMatchKey(digitsOnly(from)));
      return emptyTwiML();
    }
    const insertedCustomerIds = [];
    for (const customerId of ids){
      if (messageSid && await alreadyHaveInboundForMessageSid(supabase, customerId, messageSid)) {
        continue;
      }
      const { error: insErr } = await supabase.from("crm_interactions").insert({
        customer_id: customerId,
        interaction_type: "sms",
        direction: "inbound",
        subject: "SMS received",
        content: body || "(empty message)",
        channel: "sms",
        metadata: {
          source: "twilio_inbound",
          from,
          ...fromRaw && fromRaw !== from ? {
            from_raw: fromRaw
          } : {},
          ...messageSid ? {
            message_sid: messageSid
          } : {}
        }
      });
      if (insErr) {
        console.error("crm-twilio-sms-inbound insert:", customerId, insErr.message);
        continue;
      }
      insertedCustomerIds.push(customerId);
    }
    if (insertedCustomerIds.length > 0 && messageSid) {
      try {
        await notifyInboundSmsWatchers(supabase, {
          customerIds: insertedCustomerIds,
          from,
          text: body || "(empty message)",
          messageSid
        });
      } catch (e) {
        console.error("notifyInboundSmsWatchers:", e);
      }
    }
    return emptyTwiML();
  } catch (e) {
    console.error("crm-twilio-sms-inbound:", e);
    return emptyTwiML();
  }
});
