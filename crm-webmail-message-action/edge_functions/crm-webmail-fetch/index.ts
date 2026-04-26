import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { ImapClient } from "jsr:@workingdevshero/deno-imap";
// ========== Inlined from _shared/crmWebmailBodyExtract.ts (single-file deploy) ==========
function stripUtf8Bom(s) {
  let t = s;
  if (t.length && t.charCodeAt(0) === 0xfeff) t = t.slice(1);
  if (t.startsWith("\u00EF\u00BB\u00BF")) t = t.slice(3);
  return t;
}
function isAllCodeUnitsAtMostLatin1(s) {
  for(let i = 0; i < s.length; i++){
    if (s.charCodeAt(i) > 255) return false;
  }
  return true;
}
function shouldAttemptLatin1Utf8Repair(s) {
  if (/â€/.test(s)) return true;
  if (/ï»¿/.test(s)) return true;
  if (/Ã[¡-ÿ]/.test(s)) return true;
  if (/Â[¢-¿]/.test(s)) return true;
  return false;
}
function tryRepairUtf8MisdecodedAsLatin1(s) {
  if (!shouldAttemptLatin1Utf8Repair(s) || !isAllCodeUnitsAtMostLatin1(s)) return s;
  const bytes = new Uint8Array(s.length);
  for(let i = 0; i < s.length; i++)bytes[i] = s.charCodeAt(i) & 0xff;
  const out = new TextDecoder("utf-8", {
    fatal: false
  }).decode(bytes);
  const replacements = (out.match(/\uFFFD/g) || []).length;
  if (replacements > 3 && replacements > s.length / 80) return s;
  return out;
}
function normalizeEmailBodyText(s) {
  if (!s) return s;
  let t = stripUtf8Bom(s);
  t = tryRepairUtf8MisdecodedAsLatin1(t);
  t = stripUtf8Bom(t);
  t = t.replace(/\u202F/g, " ").replace(/\u00A0/g, " ");
  t = t.replace(/\u2007/g, " ").replace(/\u2009/g, " ");
  return t;
}
function stripHtmlToText(html) {
  return html.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#(\d+);/g, (_, n)=>String.fromCharCode(parseInt(n, 10))).replace(/<br\s*\/?>/gi, "\n").replace(/<\/p>/gi, "\n").replace(/<[^>]+>/g, "").trim();
}
function decodeQuotedPrintable(s) {
  let out = s.replace(/=\r?\n/g, "");
  return out.replace(/=([0-9A-Fa-f]{2})/g, (_, hex)=>String.fromCharCode(parseInt(hex, 16)));
}
function stripMimeToPlainText(body) {
  if (!body || !body.trim()) return body;
  let s = body.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  if (/=([0-9A-Fa-f]{2})/.test(s) || /=\n/.test(s)) s = decodeQuotedPrintable(s);
  const boundary = /--[\w.-]+(?:--)?/g;
  const parts = s.split(boundary).map((p)=>p.trim()).filter(Boolean);
  const headerLine = /^(?:Content-Type|Content-Transfer-Encoding|MIME-Version|Content-Disposition|X-[A-Za-z-]+|[A-Za-z0-9-]+):\s*.+$/im;
  let plainText = "";
  for (const part of parts){
    const lines = part.split(/\n/);
    let i = 0;
    let isHtml = false;
    let isMultipart = false;
    while(i < lines.length){
      const t = lines[i].trim();
      if (!t) {
        i++;
        break;
      }
      if (/^Content-Type:\s*text\/html/i.test(t)) {
        isHtml = true;
        break;
      }
      if (/^Content-Type:\s*multipart/i.test(t)) {
        isMultipart = true;
        break;
      }
      if (headerLine.test(t)) {
        i++;
        continue;
      }
      break;
    }
    if (isHtml || isMultipart) continue;
    const rest = lines.slice(i).join("\n").trim();
    if (!rest) continue;
    if (rest.startsWith("<") && rest.includes(">")) {
      plainText = stripHtmlToText(rest);
    } else {
      plainText = rest;
    }
    break;
  }
  const outLines = plainText.split(/\n/).filter((line)=>{
    const t = line.trim();
    if (!t) return true;
    if (/^--[\w.-]/.test(t)) return false;
    if (/^Content-Type:\s*/i.test(t) || /^Content-Transfer-Encoding:\s*/i.test(t) || /^MIME-Version:\s*/i.test(t)) return false;
    if (/^[A-Za-z0-9-]+:\s*[\s\S]{0,200}$/i.test(t) && (t.includes("charset") || t.includes("boundary") || t.includes("encoding"))) return false;
    return true;
  });
  return outLines.join("\n").replace(/\n{3,}/g, "\n\n").trim();
}
function parseMimeHeaders(block) {
  const out = {};
  const raw = block.replace(/\r\n/g, "\n");
  const lines = raw.split("\n");
  let curKey = "";
  for (const line of lines){
    if (/^[ \t]/.test(line) && curKey) {
      out[curKey] += " " + line.trim();
    } else {
      const idx = line.indexOf(":");
      if (idx > 0) {
        curKey = line.slice(0, idx).trim().toLowerCase();
        out[curKey] = line.slice(idx + 1).trim();
      }
    }
  }
  return out;
}
function charsetFromContentType(ct) {
  const m = ct.match(/charset\s*=\s*["']?([^"'\s;]+)/i);
  const raw = (m && m[1] || "utf-8").replace(/["']+$/g, "");
  return raw || "utf-8";
}
function extractBoundary(contentTypeValue) {
  const m = contentTypeValue.match(/boundary\s*=\s*("([^"]*)"|([^;\s]+))/i);
  if (!m) return null;
  const b = (m[2] ?? m[3] ?? "").trim();
  return b.replace(/^"+|"+$/g, "");
}
function splitMultipartParts(payload, boundary) {
  const delim = `--${boundary}`;
  const norm = payload.replace(/\r\n/g, "\n");
  const chunks = norm.split(delim);
  const out = [];
  for (const c of chunks){
    let t = c.replace(/^\r?\n/, "").trimStart();
    if (t.startsWith("--")) continue;
    if (t.trim().length === 0) continue;
    out.push(t);
  }
  return out;
}
function extractBoundaryFromRaw(raw) {
  const window = raw.slice(0, 16000);
  const m = window.match(/boundary\s*=\s*("([^"]+)"|([^;\s\r\n]+))/i);
  if (!m) return null;
  const b = (m[2] ?? m[3] ?? "").trim().replace(/^"+|"+$/g, "");
  return b || null;
}
function decodePartPayload(payload, encoding, charset) {
  const enc = encoding.toLowerCase().trim();
  let s = payload.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  if (enc.includes("quoted-printable")) s = decodeQuotedPrintable(s);
  else if (enc.includes("base64")) {
    return decodeBase64ToString(s, charset);
  }
  return s.trimEnd();
}
function decodeBase64ToString(b64Body, charset) {
  const clean = b64Body.replace(/\s/g, "");
  try {
    const bin = atob(clean);
    const bytes = new Uint8Array(bin.length);
    for(let i = 0; i < bin.length; i++)bytes[i] = bin.charCodeAt(i);
    const cs = (charset || "utf-8").trim();
    const primary = new TextDecoder(cs || "utf-8", {
      fatal: false
    }).decode(bytes);
    const latinish = /^(iso-8859-1|iso_8859-1|latin1|windows-1252|us-ascii)$/i.test(cs.replace(/\s/g, ""));
    if (latinish) {
      const asUtf8 = new TextDecoder("utf-8", {
        fatal: false
      }).decode(bytes);
      if (/â€|ï»¿|Ã[¡-ÿ]/.test(primary) && !/â€/.test(asUtf8)) return asUtf8;
    }
    return primary;
  } catch  {
    return b64Body;
  }
}
function walkMimePart(headerBlock, body, acc) {
  const h = parseMimeHeaders(headerBlock);
  const ctRaw = h["content-type"] || "text/plain; charset=us-ascii";
  const ct = ctRaw.toLowerCase();
  const cte = (h["content-transfer-encoding"] || "7bit").toLowerCase().trim();
  const charset = charsetFromContentType(ctRaw);
  if (ct.includes("multipart/")) {
    let b = extractBoundary(ctRaw);
    if (!b) b = extractBoundaryFromRaw(`${headerBlock}\n\n${body.slice(0, 12000)}`);
    if (!b) return;
    for (const part of splitMultipartParts(body, b)){
      const sep = part.search(/\r?\n\r?\n/);
      if (sep < 0) continue;
      const ph = part.slice(0, sep).replace(/\r\n/g, "\n");
      const pb = part.slice(sep).replace(/^\r?\n\r?\n?/, "");
      walkMimePart(ph, pb, acc);
    }
    return;
  }
  if (ct.includes("message/rfc822")) {
    const embedded = body.replace(/^\r?\n/, "").trimStart();
    const sep = embedded.search(/\r?\n\r?\n/);
    if (sep < 0) return;
    const eh = embedded.slice(0, sep).replace(/\r\n/g, "\n");
    const eb = embedded.slice(sep).replace(/^\r?\n\r?\n?/, "");
    walkMimePart(eh, eb, acc);
    return;
  }
  const decoded = decodePartPayload(body, cte, charset);
  if (!decoded.trim()) return;
  if (ct.includes("text/html")) acc.htmls.push(decoded);
  else if (ct.includes("text/plain")) acc.plains.push(decoded);
}
function parseMimeMessageFromRaw(rawStr) {
  const acc = {
    plains: [],
    htmls: []
  };
  const norm = rawStr.replace(/\r\n/g, "\n").trimStart();
  if (!norm) return {
    plain: "",
    html: ""
  };
  const sep = norm.search(/\n\n/);
  let headerBlock;
  let body;
  if (sep < 0) {
    headerBlock = "";
    body = norm;
  } else {
    headerBlock = norm.slice(0, sep);
    body = norm.slice(sep + 2);
  }
  const looksLikeHeaders = /^[\w-]+:\s/m.test(headerBlock);
  if (looksLikeHeaders && headerBlock.trim()) {
    walkMimePart(headerBlock, body, acc);
  } else {
    const blob = headerBlock.trim() ? `${headerBlock}\n\n${body}` : body;
    const bTrim = blob.trim();
    const bd = extractBoundaryFromRaw(bTrim);
    if (bd) {
      walkMimePart(`Content-Type: multipart/mixed; boundary="${bd}"`, bTrim, acc);
    } else if (looksLikeHtml(bTrim)) {
      walkMimePart("Content-Type: text/html; charset=utf-8\n", bTrim, acc);
    } else {
      walkMimePart("Content-Type: text/plain; charset=utf-8\n", bTrim, acc);
    }
  }
  const plain = acc.plains.sort((a, b)=>b.length - a.length)[0] || "";
  const html = acc.htmls.sort((a, b)=>b.length - a.length)[0] || "";
  return {
    plain,
    html
  };
}
function looksLikeHtml(s) {
  return /<\/?[a-z][\s\S]*>/i.test(s);
}
function decodeBytes(data) {
  try {
    return new TextDecoder("utf-8", {
      fatal: false
    }).decode(data);
  } catch (_) {
    return "";
  }
}
function pushCandidate(out, v) {
  if (typeof v === "string" && v.trim()) out.push(v);
  if (v instanceof Uint8Array && v.length > 0) {
    const s = decodeBytes(v).trim();
    if (s) out.push(s);
  }
}
function collectBodyCandidates(node, out) {
  if (!node) return;
  if (typeof node === "string" || node instanceof Uint8Array) {
    pushCandidate(out, node);
    return;
  }
  if (Array.isArray(node)) {
    for (const item of node)collectBodyCandidates(item, out);
    return;
  }
  if (typeof node === "object") {
    const obj = node;
    pushCandidate(out, obj.text);
    pushCandidate(out, obj.content);
    pushCandidate(out, obj.html);
    pushCandidate(out, obj.data);
    for (const v of Object.values(obj))collectBodyCandidates(v, out);
  }
}
function isProbablyFullRfc822Message(s) {
  if (!s || s.length < 80) return false;
  const head = s.slice(0, 3500);
  const hasTransport = /\bReturn-Path:\s*/i.test(head) || /\bDelivered-To:\s*/i.test(head);
  const receivedHits = (head.match(/^Received:\s*/gim) || []).length;
  if (hasTransport && receivedHits >= 1) return true;
  if (receivedHits >= 2) return true;
  if (/^MIME-Version:\s*1/m.test(head) && /^Content-Type:\s*multipart\//im.test(head)) return true;
  return false;
}
function isGarbageEmailPayload(s) {
  if (!s || s.length < 60) return false;
  const head = s.slice(0, 8000);
  if (/\bReturn-Path:\s*/i.test(head) && /\bReceived:\s*/i.test(head)) return true;
  if ((head.match(/^Received:\s*/gim) || []).length >= 2) return true;
  if (/\bDKIM-Signature:\s*/i.test(head) && /\bAuthentication-Results:\s*/i.test(head)) return true;
  const lines = s.trimStart().split(/\r?\n/).slice(0, 80);
  let b64Lines = 0;
  for (const line of lines){
    const t = line.trim();
    if (t.length >= 40 && /^[A-Za-z0-9+/]+=*$/.test(t)) b64Lines++;
  }
  if (b64Lines >= 6 && !/<[a-z][\s>/]/i.test(s.slice(0, 500))) return true;
  return false;
}
/** Lines mistaken for bodies when MIME parsing fails (e.g. only the subtype line survived). */ function isTrivialMimeLabel(s) {
  const t = s.trim().toLowerCase();
  if (t.length > 120) return false;
  return /^text\/(plain|html)(\s*;\s*charset=[^;]+)?$/i.test(t);
}
function deepCollectUint8Arrays(v, out, depth = 0) {
  if (depth > 14) return;
  if (v instanceof Uint8Array && v.length > 0) out.push(v);
  else if (v && typeof v === "object") {
    const o = v;
    if (o.data instanceof Uint8Array && o.data.length > 0) out.push(o.data);
    for (const val of Object.values(o))deepCollectUint8Arrays(val, out, depth + 1);
  }
}
function scoreDecodedPayload(s) {
  const t = s.trim();
  if (t.length < 3) return -1;
  let score = Math.min(t.length, 500_000);
  if (/^[\w-]+:\s/m.test(t.slice(0, 4000))) score += 500;
  if (/MIME-Version|Content-Type:|multipart\//i.test(t.slice(0, 8000))) score += 300;
  if (looksLikeHtml(t)) score += 200;
  return score;
}
function extractRawString(msg) {
  const blobs = [];
  const raw = msg.raw ?? msg.source ?? msg.rfc822;
  if (raw instanceof Uint8Array && raw.length > 0) blobs.push(raw);
  deepCollectUint8Arrays(msg.parts, blobs);
  deepCollectUint8Arrays(msg.body, blobs);
  const decoded = [];
  const seenLen = new Set();
  for (const buf of blobs){
    if (seenLen.has(buf.length)) continue;
    seenLen.add(buf.length);
    const s = new TextDecoder("utf-8", {
      fatal: false
    }).decode(buf);
    const sc = scoreDecodedPayload(s);
    if (sc >= 0) decoded.push({
      s,
      score: sc
    });
  }
  if (typeof raw === "string" && raw.trim()) {
    decoded.push({
      s: raw,
      score: scoreDecodedPayload(raw)
    });
  }
  decoded.sort((a, b)=>b.score - a.score);
  const best = decoded[0]?.s?.trim() || "";
  return best;
}
function extractBodyText(msg) {
  const rawStr = extractRawString(msg);
  let htmlText = "";
  let plainText = "";
  if (rawStr.trim()) {
    const parsed = parseMimeMessageFromRaw(rawStr);
    if (parsed.html && !isProbablyFullRfc822Message(parsed.html) && !isGarbageEmailPayload(parsed.html)) {
      htmlText = parsed.html.trim();
    }
    if (parsed.plain && !isProbablyFullRfc822Message(parsed.plain) && !isGarbageEmailPayload(parsed.plain)) {
      plainText = parsed.plain.trim();
    }
  }
  const candidates = [];
  collectBodyCandidates(msg.body, candidates);
  collectBodyCandidates(msg.parts, candidates);
  const usable = (s)=>Boolean(s && !isProbablyFullRfc822Message(s));
  const cleanEnough = (s)=>usable(s) && !isGarbageEmailPayload(s);
  if (!htmlText || isGarbageEmailPayload(htmlText)) {
    const htmlCandidates = candidates.filter((c)=>looksLikeHtml(c) && cleanEnough(c));
    const best = htmlCandidates.sort((a, b)=>b.length - a.length)[0] || "";
    if (best) htmlText = best.trim();
  }
  if (!plainText || isGarbageEmailPayload(plainText)) {
    const plainCandidates = candidates.filter((c)=>!looksLikeHtml(c) && cleanEnough(c));
    const best = plainCandidates.sort((a, b)=>b.length - a.length)[0] || "";
    if (best) plainText = best.trim();
  }
  const b = msg.body;
  if (typeof b === "string" && b.trim() && usable(b) && !isGarbageEmailPayload(b)) {
    if (!htmlText && looksLikeHtml(b)) htmlText = b.trim();
    else if (!plainText && !looksLikeHtml(b)) plainText = b.trim();
  }
  if (!plainText && htmlText) plainText = stripHtmlToText(htmlText);
  if (!plainText.trim() && rawStr) {
    try {
      const byDoubleNewline = rawStr.split(/\r?\n\r?\n/);
      for(let i = 1; i < byDoubleNewline.length; i++){
        const block = byDoubleNewline[i];
        if (!block || block.length > 500_000) continue;
        if (/^[\x00-\x08\x0b\x0c\x0e-\x1f]/.test(block)) continue;
        const trimmed = block.trim();
        if (trimmed && !/^(Content-|MIME-|From:|To:|Date:|Subject:)/m.test(trimmed)) {
          plainText = trimmed;
          break;
        }
      }
    } catch (_) {}
  }
  plainText = stripMimeToPlainText(plainText || "").trim();
  htmlText = (htmlText || "").trim();
  if (isProbablyFullRfc822Message(htmlText) || isGarbageEmailPayload(htmlText)) htmlText = "";
  if (isProbablyFullRfc822Message(plainText) || isGarbageEmailPayload(plainText)) {
    plainText = htmlText ? stripHtmlToText(htmlText).trim() : "";
  }
  plainText = stripMimeToPlainText(plainText).trim();
  if (!plainText && htmlText) plainText = stripHtmlToText(htmlText).trim();
  if (isTrivialMimeLabel(plainText)) {
    plainText = htmlText ? stripHtmlToText(htmlText).trim() : "";
  }
  if (!plainText.trim() && !htmlText.trim()) {
    const desperate = [];
    collectBodyCandidates(msg.body, desperate);
    collectBodyCandidates(msg.parts, desperate);
    const rawAgain = extractRawString(msg);
    if (rawAgain) desperate.push(rawAgain);
    for (const c of desperate.sort((a, b)=>b.length - a.length)){
      const t = c.trim();
      if (t.length < 2) continue;
      if (isProbablyFullRfc822Message(t) || isGarbageEmailPayload(t)) {
        const inner = parseMimeMessageFromRaw(t);
        if (inner.html && !isGarbageEmailPayload(inner.html)) {
          htmlText = inner.html.trim();
          break;
        }
        if (inner.plain && !isGarbageEmailPayload(inner.plain)) {
          plainText = inner.plain.trim();
          break;
        }
        continue;
      }
      if (looksLikeHtml(t)) {
        htmlText = t;
        break;
      }
      plainText = stripMimeToPlainText(t).trim();
      if (plainText && !isTrivialMimeLabel(plainText)) break;
      plainText = "";
    }
    if (!plainText.trim() && htmlText.trim()) plainText = stripHtmlToText(htmlText).trim();
  }
  plainText = normalizeEmailBodyText(plainText);
  htmlText = normalizeEmailBodyText(htmlText);
  return {
    plainText,
    htmlText
  };
}
// ========== end inlined crmWebmailBodyExtract ==========
// ========== Inlined from _shared/crmWebmailImapFolders.ts (single-file deploy) ==========
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
    "Deleted",
    "INBOX.Deleted",
    "INBOX/Deleted"
  ],
  drafts: [
    "Drafts",
    "INBOX.Drafts",
    "[Gmail]/Drafts",
    "INBOX/Drafts",
    "Draft"
  ]
};
/**
 * If Drafts is mapped to the same mailbox as Inbox (or literally "INBOX"), ignore it so we do not open Inbox for the Drafts tab.
 */ function sanitizeFolderMappingForDraftsSelect(folderMapping) {
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
/**
 * Append an RFC822 message to the server Drafts folder (tries mapping, LIST match, then candidates).
 */ async function appendDraftMessage(client, folderMapping, rfc822) {
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
/** Resolve a writable target mailbox name (e.g. Trash) using LIST + mapping without leaving the current selection. */ async function resolveTargetMailboxName(client, folderMapping, folderKey) {
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
/** True if the opened mailbox name looks like a drafts folder (used when IMAP omits \\Draft on messages). */ function mailboxNameLooksLikeDrafts(resolvedName) {
  const n = (resolvedName || "").toLowerCase();
  return /\bdrafts?\b/.test(n) || n.includes("[gmail]/drafts");
}
// ========== end inlined crmWebmailImapFolders ==========
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
function formatAddrList(addrs) {
  if (!addrs?.length) return "";
  return addrs.map((a)=>formatAddr(a)).filter(Boolean).join(", ");
}
function formatEnvelope(env) {
  const fromAddr = env?.from?.[0];
  const toAddr = env?.to?.[0];
  return {
    from: formatAddr(fromAddr),
    to: formatAddrList(env?.to) || formatAddr(toAddr),
    cc: formatAddrList(env?.cc),
    subject: env?.subject || "",
    date: env?.date || ""
  };
}
/** True when IMAP \\Seen is present (message has been read). */ function messageReadFromFlags(flags) {
  if (!flags?.length) return true;
  return flags.some((f)=>/^\\?Seen$/i.test(String(f).trim()));
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
        const uidParsed = messageUid != null && String(messageUid).trim() !== "" ? parseInt(String(messageUid), 10) : NaN;
        const seqParsed = messageSeq != null && String(messageSeq).trim() !== "" ? parseInt(String(messageSeq), 10) : NaN;
        const uidOk = Number.isFinite(uidParsed) && uidParsed > 0;
        const seqOk = Number.isFinite(seqParsed) && seqParsed >= 1;
        if (!uidOk && !seqOk) {
          return new Response(JSON.stringify({
            error: "Valid messageUid or messageSeq is required"
          }), {
            status: 400,
            headers: {
              ...corsHeaders,
              "Content-Type": "application/json"
            }
          });
        }
        // Prefer UID fetch (stable when the mailbox changes); fall back to sequence number.
        // markSeen: true → BODY[] not BODY.PEEK[] so deno-imap returns literals for the body parser.
        const fetchOptsUid = {
          uid: true,
          envelope: true,
          full: true,
          byUid: true,
          markSeen: true
        };
        const fetchOptsSeq = {
          envelope: true,
          full: true,
          markSeen: true
        };
        let msg = null;
        if (uidOk) {
          try {
            const byUid = await client.fetch(String(uidParsed), fetchOptsUid);
            const candidate = Array.isArray(byUid) ? byUid[0] : byUid;
            if (candidate) msg = candidate;
          } catch  {
          /* will try seq */ }
        }
        if (!msg && seqOk) {
          const bySeq = await client.fetch(String(seqParsed), fetchOptsSeq);
          msg = Array.isArray(bySeq) ? bySeq[0] : bySeq;
        }
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
        ].reverse().map((msg)=>{
          const env = formatEnvelope(msg.envelope || {});
          const body = extractBodyText(msg);
          const preview = (body.plainText || stripHtmlToText(body.htmlText || "") || "").slice(0, 200);
          const seq = typeof msg.seq === "number" && msg.seq > 0 ? msg.seq : undefined;
          const uid = typeof msg.uid === "number" && msg.uid > 0 ? msg.uid : undefined;
          const rowUid = uid ?? seq ?? 0;
          return {
            uid: rowUid,
            seq,
            read: messageReadFromFlags(msg.flags),
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
        uid: true,
        flags: true
      });
      const arr = Array.isArray(messages) ? messages : [
        messages
      ];
      const list = arr.reverse().map((msg, i)=>{
        const env = formatEnvelope(msg.envelope || {});
        const body = extractBodyText(msg);
        const preview = (body.plainText || stripHtmlToText(body.htmlText || "") || "").slice(0, 200);
        const seq = typeof msg.seq === "number" && msg.seq > 0 ? msg.seq : undefined;
        const uid = typeof msg.uid === "number" && msg.uid > 0 ? msg.uid : undefined;
        const rowUid = uid ?? seq ?? Math.max(1, end - i);
        return {
          uid: rowUid,
          seq,
          read: messageReadFromFlags(msg.flags),
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
