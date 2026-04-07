import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";
import { canSendOutbound, fetchNotificationPreferences } from "../_shared/notificationPreferences.ts";
const DEFAULTS = {
  header_logo_url: "https://htqfxkbuuqgwthwxqnxf.supabase.co/storage/v1/object/public/cms-uploads/logos/global-logo-1767767068929.png",
  footer_logo_url: "https://htqfxkbuuqgwthwxqnxf.supabase.co/storage/v1/object/public/cms-uploads/logos/global-logo-1767767068929.png",
  from_name: "KidNCode Online",
  from_email: "noreply@kidncode.com",
  footer_company_name: "KidNCode Inc.",
  footer_tagline: null,
  footer_copyright_year: new Date().getFullYear(),
  footer_disclaimer: null,
  footer_contact_email: "support@kidncode.com",
  footer_contact_phone: ""
};
/**
 * Fetch the active default email template from email_template_settings.
 * Pass the Supabase client (with service role for RLS).
 */ export async function getEmailTemplate(supabase) {
  const { data, error } = await supabase.from("email_template_settings").select("*").eq("template_type", "default").order("is_active", {
    ascending: false,
    nullsFirst: false
  }).limit(1).maybeSingle();
  if (error || !data) {
    return {
      ...DEFAULTS
    };
  }
  const year = data.footer_copyright_year != null && Number.isFinite(Number(data.footer_copyright_year)) ? Number(data.footer_copyright_year) : new Date().getFullYear();
  return {
    header_logo_url: data.header_logo_url && String(data.header_logo_url).trim() || DEFAULTS.header_logo_url,
    footer_logo_url: data.footer_logo_url && String(data.footer_logo_url).trim() || data.header_logo_url?.trim() || DEFAULTS.footer_logo_url,
    from_name: data.from_name && String(data.from_name).trim() || DEFAULTS.from_name,
    from_email: data.from_email && String(data.from_email).trim() || DEFAULTS.from_email,
    footer_company_name: data.footer_company_name && String(data.footer_company_name).trim() || DEFAULTS.footer_company_name,
    footer_tagline: data.footer_tagline != null ? String(data.footer_tagline).trim() || null : null,
    footer_copyright_year: year,
    footer_disclaimer: data.footer_disclaimer != null ? String(data.footer_disclaimer).trim() || null : null,
    footer_contact_email: data.footer_contact_email && String(data.footer_contact_email).trim() || DEFAULTS.footer_contact_email,
    footer_contact_phone: data.footer_contact_phone && String(data.footer_contact_phone).trim() || ""
  };
}
/**
 * Build the Resend "from" address string from template: "Display Name <email@domain.com>"
 */ export function buildFromAddress(template) {
  if (template.from_name && template.from_email) {
    return `${template.from_name} <${template.from_email}>`;
  }
  return template.from_email ? `<${template.from_email}>` : DEFAULTS.from_email;
}
/**
 * Build a standard footer HTML fragment using template (company name, contact, copyright, disclaimer).
 * Optional logo img can be prepended by the caller using template.footer_logo_url.
 */ export function buildFooterHtml(template) {
  const parts = [];
  if (template.footer_company_name) {
    parts.push(`<p style="color:#94a3b8;font-size:12px;margin:0 0 8px;"><strong>${template.footer_company_name}</strong></p>`);
  }
  if (template.footer_contact_email || template.footer_contact_phone) {
    const contact = [
      template.footer_contact_email,
      template.footer_contact_phone
    ].filter(Boolean).join(" | ");
    parts.push(`<p style="color:#94a3b8;font-size:12px;margin:0 0 5px;">${contact}</p>`);
  }
  parts.push(`<hr style="border:none;border-top:1px solid #e2e8f0;margin:20px 0;">`);
  parts.push(`<p style="color:#94a3b8;font-size:11px;margin:0;">© ${template.footer_copyright_year} ${template.footer_company_name}. All rights reserved.</p>`);
  if (template.footer_disclaimer) {
    parts.push(`<p style="color:#94a3b8;font-size:11px;margin:10px 0 0;">${template.footer_disclaimer}</p>`);
  }
  return parts.join("\n");
}
/** Escape HTML for use in attributes */ function escapeHtmlAttr(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#039;");
}
/**
 * Wrap a body HTML fragment with template header (logo) and footer.
 * Use for all platform emails so branding is consistent.
 */ export function wrapEmailBody(template, bodyHtml) {
  const headerLogo = template.header_logo_url ? `<div style="text-align:center;padding:16px 24px;border-bottom:1px solid #e2e8f0;"><img src="${escapeHtmlAttr(template.header_logo_url)}" alt="${escapeHtmlAttr(template.footer_company_name)}" style="max-width:280px;height:auto;" /></div>` : "";
  const footerLogo = template.footer_logo_url ? `<p style="margin:0 0 12px;"><img src="${escapeHtmlAttr(template.footer_logo_url)}" alt="" style="max-height:40px;width:auto;" /></p>` : "";
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"></head><body style="margin:0;padding:0;font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;background:#f4f7fa;"><table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background:#f4f7fa;"><tr><td style="padding:24px 16px;"><table role="presentation" cellpadding="0" cellspacing="0" width="600" style="max-width:600px;margin:0 auto;background:#fff;border-radius:12px;box-shadow:0 4px 20px rgba(0,0,0,0.08);overflow:hidden;">${headerLogo ? `<tr><td>${headerLogo}</td></tr>` : ""}<tr><td style="padding:24px 32px;">${bodyHtml}</td></tr><tr><td style="padding:20px 32px;background:#f8fafc;border-top:1px solid #e2e8f0;">${footerLogo}${buildFooterHtml(template)}</td></tr></table></td></tr></table></body></html>`;
}
// ========== end inlined shared ==========
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type"
};
const handler = async (req)=>{
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: corsHeaders
    });
  }
  try {
    const { to, subject, message, html, recipientName, recipientUserIdForPreferences, notificationPreferenceKind = "reminder", trialRequestId } = await req.json();
    console.log("Sending custom email to:", to);
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const resendApiKey = Deno.env.get("RESEND_API_KEY");
    if (!resendApiKey) {
      throw new Error("RESEND_API_KEY not configured");
    }
    const supabase = createClient(supabaseUrl, supabaseServiceKey);
    if (recipientUserIdForPreferences) {
      const prefs = await fetchNotificationPreferences(supabase, recipientUserIdForPreferences);
      if (!canSendOutbound(prefs, "email", notificationPreferenceKind)) {
        return new Response(JSON.stringify({
          error: "Recipient has opted out of this type of email notification"
        }), {
          status: 403,
          headers: {
            "Content-Type": "application/json",
            ...corsHeaders
          }
        });
      }
    }
    const emailTemplate = await getEmailTemplate(supabase);
    const fromAddress = buildFromAddress(emailTemplate);
    let bodyContent;
    if (html) {
      bodyContent = html;
    } else if (message) {
      const messageWithLinks = message.replace(/(https?:\/\/[^\s]+)/g, '<a href="$1" style="color: #7C3AED; text-decoration: none; font-weight: bold;">$1</a>').replace(/\n/g, '<br>');
      bodyContent = `<div style="padding: 24px;">${recipientName ? `<h2>Dear ${recipientName},</h2>` : '<h2>Hello,</h2>'}<p>Thank you for contacting the KidNCode platform team.</p><div style="background-color: #f9f9f9; padding: 20px; border-radius: 8px; margin: 20px 0; white-space: pre-wrap;">${messageWithLinks}</div></div>`;
    } else {
      throw new Error("Either 'message' or 'html' must be provided");
    }
    const emailHtml = wrapEmailBody(emailTemplate, bodyContent);
    const recipients = Array.isArray(to) ? to : [
      to
    ];
    const emailResponse = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${resendApiKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        from: fromAddress,
        to: recipients,
        subject: subject,
        html: emailHtml
      })
    });
    if (!emailResponse.ok) {
      const error = await emailResponse.text();
      console.error("Resend error:", error);
      throw new Error(`Failed to send email: ${error}`);
    }
    const result = await emailResponse.json();
    console.log("Email sent successfully:", result);
    const bodyPreview = (message || html || "").replace(/<[^>]*>/g, " ").trim().slice(0, 500);
    let logError = null;
    const trialMeta = trialRequestId && String(trialRequestId).trim() ? {
      trial_request_id: String(trialRequestId).trim(),
      recipient_role: "parent",
      notification_kind: "trial_thank_you",
      resend_id: result.id
    } : {
      resend_id: result.id
    };
    for (const recipient of recipients){
      const { error } = await supabase.from("outbound_email_log").insert({
        recipient_email: recipient,
        recipient_name: recipientName || null,
        subject,
        body_preview: bodyPreview || null,
        source: trialRequestId && String(trialRequestId).trim() ? "trial_thank_you" : "manual_csr",
        metadata: trialMeta,
        provider_message_id: result.id,
        status: "sent"
      });
      if (error) {
        logError = error.message;
        console.error("outbound_email_log insert error:", error.message, error.code, error.details);
      }
    }
    return new Response(JSON.stringify({
      success: true,
      id: result.id,
      ...logError && {
        logWarning: "Email sent but history log failed. Ensure outbound_email_log table exists (run outbound_email_log_create_table.sql)."
      }
    }), {
      status: 200,
      headers: {
        "Content-Type": "application/json",
        ...corsHeaders
      }
    });
  } catch (error) {
    console.error("Error in send-custom-email function:", error);
    return new Response(JSON.stringify({
      error: error.message
    }), {
      status: 500,
      headers: {
        "Content-Type": "application/json",
        ...corsHeaders
      }
    });
  }
};
serve(handler);
