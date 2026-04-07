import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { ImapClient } from "jsr:@workingdevshero/deno-imap";
import { selectMailboxResilient } from "../_shared/crmWebmailImapFolders.ts";
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
  return s.replace(/^@|@$/g, "") || "";
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
    if (req.method === "POST") {
      try {
        const body = await req.json();
        if (body.accountId) accountId = body.accountId;
        if (body.folder != null) folder = body.folder;
        if (body.page != null) page = Math.max(1, parseInt(String(body.page)) || 1);
        if (body.limit != null) limit = Math.min(100, Math.max(1, parseInt(String(body.limit)) || DEFAULT_PAGE_SIZE));
        if (body.messageUid != null) messageUid = String(body.messageUid);
      } catch (_) {}
    }
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
      const { mailbox } = await selectMailboxResilient(client, folderMapping, folder);
      const total = mailbox.exists || 0;
      if (messageUid) {
        const uid = parseInt(messageUid);
        if (!Number.isFinite(uid)) {
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
        const messages = await client.fetch(String(uid), {
          uid: true,
          envelope: true,
          body: true
        });
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
        let bodyText = "";
        const body = msg.body;
        if (body) {
          if (typeof body === "string") bodyText = body;
          else if (body.text) bodyText = body.text;
          else if (body[0]) bodyText = typeof body[0] === "string" ? body[0] : body[0].content || "";
        }
        return new Response(JSON.stringify({
          message: {
            uid: msg.uid,
            ...envelope,
            body: bodyText
          }
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
      const messages = await client.fetch(range, {
        envelope: true,
        body: true
      });
      const list = (Array.isArray(messages) ? messages : [
        messages
      ]).map((msg)=>{
        const env = formatEnvelope(msg.envelope || {});
        let preview = "";
        const b = msg.body;
        if (b) {
          if (typeof b === "string") preview = b.slice(0, 200);
          else if (b.text) preview = String(b.text).slice(0, 200);
          else if (b[0]) preview = (typeof b[0] === "string" ? b[0] : b[0].content || "").slice(0, 200);
        }
        return {
          uid: msg.uid,
          seq: msg.seq,
          ...env,
          preview
        };
      });
      return new Response(JSON.stringify({
        messages: list.reverse(),
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
    console.error("webmail-fetch:", err);
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
