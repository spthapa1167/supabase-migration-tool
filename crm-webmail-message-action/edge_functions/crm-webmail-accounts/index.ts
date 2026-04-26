import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
const ALG = "AES-GCM";
const KEY_LEN = 256;
const IV_LEN = 12;
async function encrypt(plaintext, secretKeyBase64) {
  const keyBytes = Uint8Array.from(atob(secretKeyBase64), (c)=>c.charCodeAt(0));
  if (keyBytes.length !== 32) throw new Error("WEBMAIL_ENCRYPTION_KEY must be base64 of 32 bytes");
  const key = await crypto.subtle.importKey("raw", keyBytes, {
    name: ALG,
    length: KEY_LEN
  }, false, [
    "encrypt"
  ]);
  const iv = crypto.getRandomValues(new Uint8Array(IV_LEN));
  const encoded = new TextEncoder().encode(plaintext);
  const cipher = await crypto.subtle.encrypt({
    name: ALG,
    iv
  }, key, encoded);
  const combined = new Uint8Array(iv.length + cipher.byteLength);
  combined.set(iv);
  combined.set(new Uint8Array(cipher), iv.length);
  return btoa(String.fromCharCode(...combined));
}
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS"
};
Deno.serve(async (req)=>{
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: corsHeaders
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
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const encryptionKey = Deno.env.get("WEBMAIL_ENCRYPTION_KEY");
    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: {
        headers: {
          Authorization: authHeader
        }
      }
    });
    const serviceClient = createClient(supabaseUrl, supabaseServiceKey);
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
    const userId = user.id;
    const method = req.method;
    let body = null;
    if (method === "POST" || method === "PUT" || method === "DELETE") {
      body = await req.json().catch(()=>({}));
      if (body && typeof body !== "object") body = null;
    }
    const op = typeof body?.op === "string" ? body.op : null;
    // POST + op avoids PUT/DELETE + body issues (some gateways and clients drop DELETE bodies).
    const isListRequest = method === "GET" || method === "POST" && op !== "update" && op !== "delete" && (!body || !body.email);
    if (isListRequest) {
      const { data, error } = await userClient.from("crm_webmail_accounts").select("id, email, label, imap_host, imap_port, imap_security, imap_username, smtp_host, smtp_port, smtp_security, smtp_username, folder_mapping, is_active, email_signature_html, email_signature_enabled, email_signature_on_reply, email_signature_on_new, external_webmail_url, email_provider, created_at, updated_at").eq("user_id", userId).eq("is_active", true).order("created_at", {
        ascending: false
      });
      if (error) throw error;
      return new Response(JSON.stringify({
        accounts: data || []
      }), {
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    const treatAsDelete = method === "DELETE" || method === "POST" && op === "delete";
    if (treatAsDelete) {
      const { id: accountId, reason, confirmationPhrase } = body || {};
      const requiredPhrase = "REMOVE";
      if (!accountId) {
        return new Response(JSON.stringify({
          error: "Account id is required"
        }), {
          status: 400,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json"
          }
        });
      }
      if (!reason || typeof reason !== "string" || !reason.trim()) {
        return new Response(JSON.stringify({
          error: "Reason for removal is required"
        }), {
          status: 400,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json"
          }
        });
      }
      if (confirmationPhrase !== requiredPhrase) {
        return new Response(JSON.stringify({
          error: `Type ${requiredPhrase} to confirm removal`
        }), {
          status: 400,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json"
          }
        });
      }
      const { data: account } = await userClient.from("crm_webmail_accounts").select("id").eq("id", accountId).eq("user_id", userId).single();
      if (!account) {
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
      await serviceClient.from("crm_webmail_account_deletions").insert({
        account_id: accountId,
        user_id: userId,
        reason: reason.trim(),
        confirmation_phrase_used: String(confirmationPhrase)
      });
      const { error: delError } = await userClient.from("crm_webmail_accounts").delete().eq("id", accountId).eq("user_id", userId);
      if (delError) throw delError;
      return new Response(JSON.stringify({
        success: true
      }), {
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    if (method === "POST" || method === "PUT") {
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
      if (!body || typeof body !== "object") {
        return new Response(JSON.stringify({
          error: "Request body is required"
        }), {
          status: 400,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json"
          }
        });
      }
      const { id, email, label, imap_host, imap_port, imap_security, imap_username, imap_password, smtp_host, smtp_port, smtp_security, smtp_username, smtp_password, folder_mapping, email_signature_html, email_signature_enabled, email_signature_on_reply, email_signature_on_new, external_webmail_url, email_provider } = body;
      const isPut = method === "PUT" && id || method === "POST" && op === "update" && id;
      if (op === "update" && !id) {
        return new Response(JSON.stringify({
          error: "Account id is required for update"
        }), {
          status: 400,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json"
          }
        });
      }
      const hasImapPassword = imap_password != null && String(imap_password).trim().length > 0;
      if (!email?.trim() || !imap_host?.trim() || !imap_username?.trim()) {
        return new Response(JSON.stringify({
          error: "Email, IMAP host, and username are required"
        }), {
          status: 400,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json"
          }
        });
      }
      if (!isPut && !hasImapPassword) {
        return new Response(JSON.stringify({
          error: "IMAP password is required when adding an account"
        }), {
          status: 400,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json"
          }
        });
      }
      if (!smtp_host?.trim()) {
        return new Response(JSON.stringify({
          error: "SMTP host is required"
        }), {
          status: 400,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json"
          }
        });
      }
      const externalUrlRaw = typeof external_webmail_url === "string" ? external_webmail_url.trim() : "";
      let externalWebmailUrlNorm = null;
      if (externalUrlRaw) {
        try {
          const u = new URL(externalUrlRaw);
          if (u.protocol !== "http:" && u.protocol !== "https:") {
            return new Response(JSON.stringify({
              error: "External webmail URL must start with http:// or https://"
            }), {
              status: 400,
              headers: {
                ...corsHeaders,
                "Content-Type": "application/json"
              }
            });
          }
          externalWebmailUrlNorm = u.toString();
        } catch  {
          return new Response(JSON.stringify({
            error: "External webmail URL is not a valid URL"
          }), {
            status: 400,
            headers: {
              ...corsHeaders,
              "Content-Type": "application/json"
            }
          });
        }
      }
      const emailProviderNorm = typeof email_provider === "string" && email_provider.trim().length > 0 ? email_provider.trim() : null;
      let imapEncrypted;
      let smtpEncrypted;
      if (isPut && !hasImapPassword) {
        const { data: existingRow, error: existingError } = await userClient.from("crm_webmail_accounts").select("imap_password_encrypted, smtp_password_encrypted").eq("id", id).eq("user_id", userId).single();
        if (existingError || !existingRow) {
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
        imapEncrypted = existingRow.imap_password_encrypted;
        const hasSmtpPassword = smtp_password != null && String(smtp_password).trim().length > 0;
        smtpEncrypted = hasSmtpPassword ? await encrypt(String(smtp_password), encryptionKey) : existingRow.smtp_password_encrypted ?? existingRow.imap_password_encrypted;
      } else {
        imapEncrypted = await encrypt(String(imap_password).trim(), encryptionKey);
        smtpEncrypted = smtp_password != null && String(smtp_password).trim().length > 0 ? await encrypt(String(smtp_password), encryptionKey) : imapEncrypted;
      }
      const row = {
        user_id: userId,
        email: email.trim(),
        label: label?.trim() || null,
        imap_host: imap_host.trim(),
        imap_port: Number(imap_port) || 993,
        imap_security: [
          "ssl",
          "starttls",
          "none"
        ].includes(imap_security) ? imap_security : "ssl",
        imap_username: imap_username.trim(),
        imap_password_encrypted: imapEncrypted,
        smtp_host: smtp_host.trim(),
        smtp_port: Number(smtp_port) || 587,
        smtp_security: [
          "ssl",
          "starttls",
          "none"
        ].includes(smtp_security) ? smtp_security : "starttls",
        smtp_username: smtp_username?.trim() || null,
        smtp_password_encrypted: smtpEncrypted,
        folder_mapping: folder_mapping && typeof folder_mapping === "object" ? folder_mapping : {
          inbox: "INBOX"
        },
        is_active: true,
        updated_at: new Date().toISOString()
      };
      const signatureForInsert = {
        email_signature_html: typeof email_signature_html === "string" && email_signature_html.trim().length > 0 ? email_signature_html.trim() : null,
        email_signature_enabled: email_signature_enabled === true,
        email_signature_on_reply: email_signature_on_reply === false ? false : true,
        email_signature_on_new: email_signature_on_new === false ? false : true,
        external_webmail_url: externalWebmailUrlNorm,
        email_provider: emailProviderNorm
      };
      if (isPut && id) {
        const { data: existing } = await userClient.from("crm_webmail_accounts").select("id").eq("id", id).eq("user_id", userId).single();
        if (!existing) {
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
        const updatePayload = {
          email: row.email,
          label: row.label,
          imap_host: row.imap_host,
          imap_port: row.imap_port,
          imap_security: row.imap_security,
          imap_username: row.imap_username,
          imap_password_encrypted: row.imap_password_encrypted,
          smtp_host: row.smtp_host,
          smtp_port: row.smtp_port,
          smtp_security: row.smtp_security,
          smtp_username: row.smtp_username,
          smtp_password_encrypted: row.smtp_password_encrypted,
          folder_mapping: row.folder_mapping,
          updated_at: row.updated_at
        };
        // Webmail Settings always sends folder_mapping with the full form; merge signature in the same write.
        const fromSettingsDialog = Object.prototype.hasOwnProperty.call(body, "folder_mapping") && body.folder_mapping && typeof body.folder_mapping === "object";
        if (fromSettingsDialog) {
          updatePayload.email_signature_html = typeof email_signature_html === "string" && email_signature_html.trim().length > 0 ? email_signature_html.trim() : null;
          updatePayload.email_signature_enabled = email_signature_enabled === true;
          updatePayload.email_signature_on_reply = email_signature_on_reply !== false;
          updatePayload.email_signature_on_new = email_signature_on_new !== false;
          updatePayload.external_webmail_url = externalWebmailUrlNorm;
          updatePayload.email_provider = emailProviderNorm;
        }
        // Service role avoids RLS gaps on optional columns; ownership is enforced with .eq("user_id", userId).
        const { data: updated, error } = await serviceClient.from("crm_webmail_accounts").update(updatePayload).eq("id", id).eq("user_id", userId).select("id, email, label, created_at, updated_at").single();
        if (error) throw error;
        return new Response(JSON.stringify(updated), {
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json"
          }
        });
      }
      if (method === "POST" && !isPut) {
        const insertRow = {
          ...row,
          ...signatureForInsert
        };
        const { data: inserted, error } = await serviceClient.from("crm_webmail_accounts").insert(insertRow).select("id, email, label, created_at, updated_at").single();
        if (error) throw error;
        return new Response(JSON.stringify(inserted), {
          status: 201,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json"
          }
        });
      }
    }
    return new Response(JSON.stringify({
      error: "Method not allowed"
    }), {
      status: 405,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  } catch (err) {
    console.error("crm-webmail-accounts:", err);
    return new Response(JSON.stringify({
      error: err instanceof Error ? err.message : "Internal server error"
    }), {
      status: 500,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  }
});
