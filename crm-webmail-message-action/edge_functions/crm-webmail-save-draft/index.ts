import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { ImapClient } from "jsr:@workingdevshero/deno-imap";
const WEBMAIL_FOLDER_CANDIDATES = {
  inbox: [
    "INBOX",
    "Inbox"
  ],
  sent: [
    "Sent",
    "INBOX.Sent",
    "Sent Items",
    "INBOX/Sent",
    "INBOX.Sent Items",
    "Sent Messages",
    "[Gmail]/Sent Mail"
  ],
  junk: [
    "Spam",
    "Junk",
    "Junk Email",
    "INBOX.Junk",
    "Junk E-mail",
    "[Gmail]/Spam",
    "Bulk Mail",
    "INBOX/Spam"
  ],
  trash: [
    "Trash",
    "Deleted Items",
    "INBOX.Trash",
    "[Gmail]/Trash",
    "Bin",
    "INBOX/Trash",
    "Deleted"
  ],
  drafts: [
    "Drafts",
    "INBOX.Drafts",
    "[Gmail]/Drafts",
    "INBOX/Drafts",
    "Draft"
  ]
};
function sanitizeFolderMappingForDraftsSelect(folderMapping) {
  if (!folderMapping?.drafts) return folderMapping;
  const d = folderMapping.drafts.trim();
  const di = d.toLowerCase();
  if (di === "inbox") {
    const next = {
      ...folderMapping
    };
    delete next.drafts;
    return next;
  }
  const inboxVal = (folderMapping.inbox || "").trim().toLowerCase();
  if (inboxVal && di === inboxVal) {
    const next = {
      ...folderMapping
    };
    delete next.drafts;
    return next;
  }
  return folderMapping;
}
function mailboxCandidatesForFolder(folderMapping, folder) {
  const key = folder.toLowerCase();
  const defaults = WEBMAIL_FOLDER_CANDIDATES[key] || WEBMAIL_FOLDER_CANDIDATES.inbox;
  const seen = new Set();
  const out = [];
  const push = (s)=>{
    const t = (s || "").trim();
    if (!t || seen.has(t)) return;
    seen.add(t);
    out.push(t);
  };
  const raw = folderMapping?.[key];
  const user = typeof raw === "string" ? raw.trim() : "";
  if (user) push(user);
  for (const d of defaults)push(d);
  return out;
}
function pickMailboxFromServerList(folderKey, listed) {
  const L = [
    ...new Set((listed || []).map((x)=>(x || "").trim()).filter(Boolean))
  ];
  const k = folderKey.toLowerCase();
  if (k === "inbox") {
    const exact = L.find((x)=>/^inbox$/i.test(x));
    if (exact) return exact;
    return L.find((x)=>/^inbox\./i.test(x)) || null;
  }
  if (k === "sent") {
    const scored = L.map((name)=>{
      const n = name.toLowerCase();
      let score = 0;
      if (/^\[gmail\]\/sent mail$/i.test(name)) score = 100;
      else if (/^sent items$/i.test(name)) score = 95;
      else if (/^sent$/i.test(name)) score = 92;
      else if (/sent messages/i.test(name)) score = 90;
      else if (/\.sent$/i.test(n) && !/draft/.test(n)) score = 75;
      else if (/\bsent\b/.test(n) && !/(draft|unsent|consent|resent)/.test(n)) score = 45;
      return {
        name,
        score
      };
    }).filter((x)=>x.score > 0).sort((a, b)=>b.score - a.score);
    return scored[0]?.name ?? null;
  }
  if (k === "junk") {
    const scored = L.map((name)=>{
      const n = name.toLowerCase();
      let score = 0;
      if (/^\[gmail\]\/spam$/i.test(name)) score = 100;
      else if (/^junk email$/i.test(name) || /^junk e-mail$/i.test(name)) score = 96;
      else if (/^spam$/i.test(name)) score = 93;
      else if (/^junk$/i.test(name)) score = 88;
      else if (/^bulk mail$/i.test(name)) score = 85;
      else if (/\.junk$/i.test(n) || /\.spam$/i.test(n)) score = 72;
      else if (/\bspam\b/.test(n) || /\bjunk\b/.test(n)) score = 48;
      return {
        name,
        score
      };
    }).filter((x)=>x.score > 0).sort((a, b)=>b.score - a.score);
    return scored[0]?.name ?? null;
  }
  if (k === "trash") {
    const scored = L.map((name)=>{
      const n = name.toLowerCase();
      let score = 0;
      if (/^\[gmail\]\/trash$/i.test(name)) score = 100;
      else if (/^deleted items$/i.test(name)) score = 96;
      else if (/^trash$/i.test(name)) score = 93;
      else if (/^bin$/i.test(name)) score = 90;
      else if (/^deleted$/i.test(name)) score = 85;
      else if (/\.trash$/i.test(n)) score = 72;
      else if (/\btrash\b/.test(n) || /\bdeleted items\b/i.test(name)) score = 50;
      return {
        name,
        score
      };
    }).filter((x)=>x.score > 0).sort((a, b)=>b.score - a.score);
    return scored[0]?.name ?? null;
  }
  if (k === "drafts") {
    const scored = L.map((name)=>{
      const n = name.toLowerCase();
      if (/^inbox$/i.test(name)) return {
        name,
        score: 0
      };
      let score = 0;
      if (/^\[gmail\]\/drafts$/i.test(name)) score = 100;
      else if (/^drafts$/i.test(name)) score = 96;
      else if (/^draft$/i.test(name)) score = 88;
      else if (/\.drafts$/i.test(n)) score = 78;
      else if (/\bdrafts\b/.test(n)) score = 45;
      return {
        name,
        score
      };
    }).filter((x)=>x.score > 0).sort((a, b)=>b.score - a.score);
    return scored[0]?.name ?? null;
  }
  return null;
}
async function appendDraftMessage(client, folderMapping, rfc822) {
  const mapping = sanitizeFolderMappingForDraftsSelect(folderMapping);
  const candidates = mailboxCandidatesForFolder(mapping, "drafts");
  let listed = [];
  try {
    const raw = await client.listMailboxes();
    listed = (raw || []).map((m)=>m?.name || "").filter(Boolean);
  } catch  {
    listed = [];
  }
  const picked = pickMailboxFromServerList("drafts", listed);
  const tryOrder = picked ? [
    picked,
    ...candidates.filter((c)=>c !== picked)
  ] : [
    ...candidates
  ];
  let lastMessage = "";
  for (const name of tryOrder){
    try {
      await client.appendMessage(name, rfc822, [
        "\\Draft"
      ]);
      return;
    } catch (e) {
      lastMessage = e instanceof Error ? e.message : String(e);
    }
    try {
      await client.appendMessage(name, rfc822);
      return;
    } catch (e2) {
      lastMessage = e2 instanceof Error ? e2.message : String(e2);
    }
  }
  const hint = listed.length ? ` Server mailboxes include: ${listed.slice(0, 14).join(", ")}${listed.length > 14 ? "…" : ""}. Set Drafts under Webmail Settings if needed.` : "";
  throw new Error(`Could not save draft. ${lastMessage ? `${lastMessage}.` : ""}${hint}`);
}
async function selectMailboxResilient(client, folderMapping, folder) {
  const key = folder.toLowerCase();
  const mapping = key === "drafts" ? sanitizeFolderMappingForDraftsSelect(folderMapping) : folderMapping;
  const candidates = mailboxCandidatesForFolder(mapping, key);
  let lastMessage = "";
  for (const name of candidates){
    try {
      const mailbox = await client.selectMailbox(name);
      return {
        mailbox,
        resolvedName: name
      };
    } catch (e) {
      lastMessage = e instanceof Error ? e.message : String(e);
    }
  }
  let listed = [];
  try {
    const raw = await client.listMailboxes();
    listed = (raw || []).map((m)=>m?.name || "").filter(Boolean);
  } catch  {
    listed = [];
  }
  const picked = pickMailboxFromServerList(key, listed);
  if (picked) {
    try {
      const mailbox = await client.selectMailbox(picked);
      return {
        mailbox,
        resolvedName: picked
      };
    } catch (e) {
      lastMessage = e instanceof Error ? e.message : String(e);
    }
  }
  const hint = listed.length ? ` Server reports mailboxes such as: ${listed.slice(0, 14).join(", ")}${listed.length > 14 ? "…" : ""}. Set exact names under Webmail Settings if needed.` : "";
  throw new Error(`Could not open folder "${folder}". ${lastMessage ? `${lastMessage}.` : ""}${hint}`);
}
async function resolveTargetMailboxName(client, folderMapping, folderKey) {
  let listed = [];
  try {
    const raw = await client.listMailboxes();
    listed = (raw || []).map((m)=>m?.name || "").filter(Boolean);
  } catch  {
    listed = [];
  }
  const picked = pickMailboxFromServerList(folderKey, listed);
  if (picked) return picked;
  const candidates = mailboxCandidatesForFolder(folderMapping, folderKey);
  const first = candidates[0];
  if (first) return first;
  throw new Error(`Could not resolve "${folderKey}" mailbox on the server.`);
}
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
function quoteDisplayName(s) {
  const t = s.trim();
  if (!t) return "";
  if (/^[\w.\s'-]+$/.test(t) && !/[\r\n"]/.test(t)) return t;
  return `"${t.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}
function foldSubject(s) {
  return s.replace(/\r?\n/g, " ").trim().slice(0, 998);
}
function buildDraftRfc822(opts) {
  const crlf = "\r\n";
  const fromLine = opts.fromLabel?.trim() ? `${quoteDisplayName(opts.fromLabel.trim())} <${opts.fromEmail.trim()}>` : opts.fromEmail.trim();
  const toLine = (opts.to || "").trim() || "undisclosed-recipients:;";
  const body = (opts.body || "").replace(/\r?\n/g, crlf);
  const lines = [
    `From: ${fromLine}`,
    `To: ${toLine}`,
    `Subject: ${foldSubject(opts.subject || "")}`,
    `Message-ID: <${crypto.randomUUID()}@crm-webmail-draft>`,
    `Date: ${new Date().toUTCString()}`,
    `MIME-Version: 1.0`,
    `Content-Type: text/plain; charset=UTF-8`,
    `Content-Transfer-Encoding: 8bit`,
    ``,
    body
  ];
  return lines.join(crlf);
}
Deno.serve(async (req)=>{
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: corsHeaders
    });
  }
  if (req.method !== "POST") {
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
    let accountId = "";
    let to = "";
    let subject = "";
    let content = "";
    let replaceDraftUid = null;
    try {
      const body = await req.json();
      accountId = String(body?.accountId || "").trim();
      to = String(body?.to || "").trim();
      subject = String(body?.subject || "").trim();
      content = String(body?.content ?? body?.body ?? "").trim();
      const ru = body?.replaceDraftUid ?? body?.replace_draft_uid;
      if (ru != null && ru !== "") {
        const n = parseInt(String(ru), 10);
        if (Number.isFinite(n) && n > 0) replaceDraftUid = n;
      }
    } catch  {
      return new Response(JSON.stringify({
        error: "Invalid JSON body"
      }), {
        status: 400,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
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
    const rfc822 = buildDraftRfc822({
      fromEmail: String(account.email || "").trim(),
      fromLabel: account.label != null ? String(account.label) : null,
      to,
      subject,
      body: content
    });
    try {
      await client.connect();
      await client.authenticate();
      await appendDraftMessage(client, folderMapping, rfc822);
      if (replaceDraftUid != null) {
        try {
          await selectMailboxResilient(client, folderMapping, "drafts");
          const trashName = await resolveTargetMailboxName(client, folderMapping, "trash");
          await client.moveMessages(String(replaceDraftUid), trashName, true);
        } catch (e) {
          console.warn("crm-webmail-save-draft: could not replace old draft uid", replaceDraftUid, e);
        }
      }
      return new Response(JSON.stringify({
        success: true
      }), {
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    } finally{
      try {
        await client.disconnect();
      } catch (_) {}
    }
  } catch (err) {
    console.error("crm-webmail-save-draft:", err);
    const message = err instanceof Error ? err.message : "Failed to save draft";
    return new Response(JSON.stringify({
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
