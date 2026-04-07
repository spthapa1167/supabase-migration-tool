import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { ImapClient } from "jsr:@workingdevshero/deno-imap";
import { extractBodyText, stripHtmlToText } from "../_shared/crmWebmailBodyExtract.ts";
import { mailboxNameLooksLikeDrafts, selectMailboxResilient } from "../_shared/crmWebmailImapFolders.ts";
const ALG = "AES-GCM";
const KEY_LEN = 256;
const IV_LEN = 12;
async function decrypt(encryptedBase64, secretKeyBase64) {
  const keyBytes = Uint8Array.from(atob(secretKeyBase64), (c)=>c.charCodeAt(0));
  if (keyBytes.length !== 32) throw new Error("WEBMAIL_ENCRYPTION_KEY must be base64 of 32 bytes");
  const key = await crypto.subtle.importKey("raw", keyBytes, {
    name: ALG,
    length: KEY_LEN
  }, false, [
    "decrypt"
  ]);
  const combined = Uint8Array.from(atob(encryptedBase64), (c)=>c.charCodeAt(0));
  const iv = combined.slice(0, IV_LEN);
  const cipher = combined.slice(IV_LEN);
  const dec = await crypto.subtle.decrypt({
    name: ALG,
    iv
  }, key, cipher);
  return new TextDecoder().decode(dec);
}
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type"
};
const DEFAULT_PAGE_SIZE = 50;
function formatAddr(addr) {
  if (!addr) return "";
  const s = `${addr.mailbox || ""}@${addr.host || ""}`;
  return s.replace(/^@+|@+$/g, "") || "";
}
function formatEnvelope(env) {
  const fromAddr = env?.from?.[0];
  const toAddr = env?.to?.[0];
  return {
    from: formatAddr(fromAddr),
    to: formatAddr(toAddr),
    subject: env?.subject || "",
    date: env?.date || ""
  };
}
function hasDraftImapFlag(flags) {
  if (!flags?.length) return false;
  return flags.some((f)=>/^\\?draft$/i.test(String(f).trim()));
}
async function collectDraftSequenceNumbers(client, mailboxTotal, resolvedMailboxName) {
  try {
    const a = await client.search({
      flags: {
        has: [
          "\\Draft"
        ]
      }
    });
    if (Array.isArray(a) && a.length > 0) return [
      ...new Set(a)
    ];
  } catch  {
  /* criteria unsupported or server quirk */ }
  try {
    const b = await client.search({
      flags: {
        has: [
          "Draft"
        ]
      }
    });
    if (Array.isArray(b) && b.length > 0) return [
      ...new Set(b)
    ];
  } catch  {
  /* */ }
  const cap = Math.min(Math.max(mailboxTotal, 0), 400);
  if (cap >= 1) {
    try {
      const all = await client.fetch(`1:${cap}`, {
        envelope: true,
        uid: true,
        flags: true
      });
      const arr = Array.isArray(all) ? all : [
        all
      ];
      const out = [];
      for (const raw of arr){
        const m = raw;
        if (m.seq != null && hasDraftImapFlag(m.flags)) out.push(m.seq);
      }
      const uniq = [
        ...new Set(out)
      ];
      if (uniq.length > 0) return uniq;
    } catch  {
    /* */ }
  }
  if (mailboxTotal > 0 && mailboxNameLooksLikeDrafts(resolvedMailboxName)) {
    return Array.from({
      length: mailboxTotal
    }, (_, i)=>i + 1);
  }
  return [];
}
Deno.serve(async (req)=>{
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: corsHeaders
    });
  }
  if (req.method !== "GET" && req.method !== "POST") {
    return new Response(JSON.stringify({
      error: "Method not allowed"
    }), {
      status: 405,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  }
  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(JSON.stringify({
        error: "Unauthorized"
      }), {
        status: 401,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const encryptionKey = Deno.env.get("WEBMAIL_ENCRYPTION_KEY");
    if (!encryptionKey) {
      return new Response(JSON.stringify({
        error: "Webmail encryption not configured"
      }), {
        status: 500,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: {
        headers: {
          Authorization: authHeader
        }
      }
    });
    const { data: { user }, error: userError } = await userClient.auth.getUser(authHeader.replace("Bearer ", ""));
    if (userError || !user) {
      return new Response(JSON.stringify({
        error: "Invalid or expired token"
      }), {
        status: 401,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    const url = new URL(req.url);
    let accountId = url.searchParams.get("accountId");
    let folder = url.searchParams.get("folder") || "inbox";
    let page = Math.max(1, parseInt(url.searchParams.get("page") || "1"));
    let limit = Math.min(100, Math.max(1, parseInt(url.searchParams.get("limit") || String(DEFAULT_PAGE_SIZE))));
    let messageUid = url.searchParams.get("messageUid");
    let messageSeq = url.searchParams.get("messageSeq");
    if (req.method === "POST") {
      try {
        const body = await req.json();
        if (body.accountId) accountId = body.accountId;
        if (body.folder != null) folder = body.folder;
        if (body.page != null) page = Math.max(1, parseInt(String(body.page)) || 1);
        if (body.limit != null) limit = Math.min(100, Math.max(1, parseInt(String(body.limit)) || DEFAULT_PAGE_SIZE));
        if (body.messageUid != null) messageUid = String(body.messageUid);
        if (body.messageSeq != null) messageSeq = String(body.messageSeq);
      } catch (_) {}
    }
    folder = String(folder ?? "inbox").trim() || "inbox";
    const folderNorm = folder.toLowerCase();
    if (!accountId) {
      return new Response(JSON.stringify({
        error: "accountId is required"
      }), {
        status: 400,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    const { data: account, error: accError } = await userClient.from("crm_webmail_accounts").select("*").eq("id", accountId).eq("user_id", user.id).single();
    if (accError || !account) {
      return new Response(JSON.stringify({
        error: "Account not found"
      }), {
        status: 404,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    const password = await decrypt(account.imap_password_encrypted, encryptionKey);
    const useTls = account.imap_security === "ssl";
    const port = Number(account.imap_port) || 993;
    const folderMapping = account.folder_mapping;
    const client = new ImapClient({
      host: account.imap_host,
      port,
      tls: useTls,
      username: account.imap_username,
      password
    });
    try {
      await client.connect();
      await client.authenticate();
      const { mailbox, resolvedName } = await selectMailboxResilient(client, folderMapping, folderNorm);
      const total = mailbox.exists || 0;
      if (messageUid || messageSeq) {
        const bySeq = messageSeq != null && messageSeq !== "";
        const seqNum = bySeq ? parseInt(messageSeq) : null;
        const uidNum = !bySeq && messageUid ? parseInt(messageUid) : null;
        if (bySeq && (!Number.isFinite(seqNum) || seqNum < 1)) {
          return new Response(JSON.stringify({
            error: "Invalid messageSeq"
          }), {
            status: 400,
            headers: {
              ...corsHeaders,
              "Content-Type": "application/json"
            }
          });
        }
        if (!bySeq && (uidNum == null || !Number.isFinite(uidNum))) {
          return new Response(JSON.stringify({
            error: "Invalid messageUid"
          }), {
            status: 400,
            headers: {
              ...corsHeaders,
              "Content-Type": "application/json"
            }
          });
        }
        const fetchSet = bySeq ? String(seqNum) : String(uidNum);
        // markSeen: true → IMAP uses BODY[] not BODY.PEEK[]; deno-imap parseFetch only matches BODY[] literals,
        // otherwise raw/parts stay empty and no message body is returned.
        const fetchOpts = bySeq ? {
          envelope: true,
          full: true,
          markSeen: true
        } : {
          uid: true,
          envelope: true,
          full: true,
          byUid: true,
          markSeen: true
        };
        const messages = await client.fetch(fetchSet, fetchOpts);
        const msg = Array.isArray(messages) ? messages[0] : messages;
        if (!msg) {
          return new Response(JSON.stringify({
            error: "Message not found"
          }), {
            status: 404,
            headers: {
              ...corsHeaders,
              "Content-Type": "application/json"
            }
          });
        }
        const envelope = formatEnvelope(msg.envelope || {});
        const body = extractBodyText(msg);
        return new Response(JSON.stringify({
          message: {
            uid: msg.uid,
            ...envelope,
            body: body.plainText || "",
            body_html: body.htmlText && body.htmlText.trim() ? body.htmlText : null
          }
        }), {
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json"
          }
        });
      }
      if (folderNorm === "drafts") {
        const draftSeqs = await collectDraftSequenceNumbers(client, total, resolvedName);
        const totalDrafts = draftSeqs.length;
        if (totalDrafts === 0) {
          return new Response(JSON.stringify({
            messages: [],
            total: 0
          }), {
            headers: {
              ...corsHeaders,
              "Content-Type": "application/json"
            }
          });
        }
        const sortedDesc = [
          ...draftSeqs
        ].sort((a, b)=>b - a);
        const startIdx = (page - 1) * limit;
        const pageSeqs = sortedDesc.slice(startIdx, startIdx + limit);
        if (pageSeqs.length === 0) {
          return new Response(JSON.stringify({
            messages: [],
            total: totalDrafts
          }), {
            headers: {
              ...corsHeaders,
              "Content-Type": "application/json"
            }
          });
        }
        const fetchSet = pageSeqs.join(",");
        const draftFetch = await client.fetch(fetchSet, {
          envelope: true,
          uid: true,
          flags: true
        });
        const darr = Array.isArray(draftFetch) ? draftFetch : [
          draftFetch
        ];
        const list = [
          ...darr
        ].reverse().map((msg, i)=>{
          const env = formatEnvelope(msg.envelope || {});
          const body = extractBodyText(msg);
          const preview = (body.plainText || stripHtmlToText(body.htmlText || "") || "").slice(0, 200);
          const seq = msg.seq ?? pageSeqs[i] ?? i + 1;
          return {
            uid: msg.uid ?? seq,
            seq,
            ...env,
            preview
          };
        });
        return new Response(JSON.stringify({
          messages: list,
          total: totalDrafts
        }), {
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json"
          }
        });
      }
      if (total === 0) {
        return new Response(JSON.stringify({
          messages: [],
          total: 0
        }), {
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json"
          }
        });
      }
      const start = Math.max(1, total - (page - 1) * limit - limit + 1);
      const end = Math.max(1, total - (page - 1) * limit);
      const range = `${start}:${end}`;
      // Envelope-only: BODY.PEEK[TEXT] is not parsed by deno-imap (regex expects BODY[TEXT]).
      // Previews are optional; opening a message loads full body with markSeen (see above).
      const messages = await client.fetch(range, {
        envelope: true,
        uid: true
      });
      const arr = Array.isArray(messages) ? messages : [
        messages
      ];
      const list = arr.reverse().map((msg, i)=>{
        const env = formatEnvelope(msg.envelope || {});
        const body = extractBodyText(msg);
        const preview = (body.plainText || stripHtmlToText(body.htmlText || "") || "").slice(0, 200);
        const seq = msg.seq ?? end - i;
        return {
          uid: msg.uid ?? seq,
          seq,
          ...env,
          preview
        };
      });
      return new Response(JSON.stringify({
        messages: list,
        total
      }), {
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    } finally{
      try {
        client.disconnect();
      } catch (_) {}
    }
  } catch (err) {
    console.error("crm-webmail-fetch:", err);
    const message = err instanceof Error ? err.message : "Failed to fetch messages";
    return new Response(JSON.stringify({
      messages: [],
      total: 0,
      error: message
    }), {
      status: 200,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  }
});
