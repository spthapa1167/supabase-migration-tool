import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";
import { canSendOutbound, fetchNotificationPreferences, resolveUserIdByEmail } from "../_shared/notificationPreferences.ts";
import { Resend } from 'https://esm.sh/resend@4.0.0';
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
async function getEmailConfig(supabaseUrl, supabaseKey) {
  try {
    const supabase = createClient(supabaseUrl, supabaseKey);
    const { data: settings } = await supabase.from("system_settings").select("property_name, value").in("property_name", [
      "primary_email_domain",
      "secondary_email_domain",
      "active_email_domain",
      "sender_email",
      "support_email"
    ]);
    if (!settings || settings.length === 0) {
      console.warn("No email settings found in database, using fallback");
      return getFallbackConfig();
    }
    const activeDomainSetting = settings.find((s)=>s.property_name === "active_email_domain");
    const activeKey = activeDomainSetting?.value || "primary";
    const domainKey = activeKey === "primary" ? "primary_email_domain" : "secondary_email_domain";
    const domainSetting = settings.find((s)=>s.property_name === domainKey);
    const domain = domainSetting?.value || "kidncode.com";
    const senderSetting = settings.find((s)=>s.property_name === "sender_email");
    const supportSetting = settings.find((s)=>s.property_name === "support_email");
    const senderEmail = senderSetting?.value || `noreply@${domain}`;
    const supportEmail = supportSetting?.value || `support@${domain}`;
    console.log("Email config loaded:", {
      domain,
      senderEmail,
      supportEmail
    });
    return {
      senderEmail,
      supportEmail,
      domain
    };
  } catch (error) {
    console.error("Error fetching email config, using fallback:", error);
    return getFallbackConfig();
  }
}
function getFallbackConfig() {
  return {
    senderEmail: "onboarding@resend.dev",
    supportEmail: "support@kidncode.com",
    domain: "resend.dev"
  };
}
const resend = new Resend(Deno.env.get("RESEND_API_KEY"));
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
    const { recipientEmail, recipientName, senderName, messagePreview, recipientRole } = await req.json();
    if (!recipientEmail || !senderName) {
      throw new Error("Missing required fields");
    }
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const supabase = createClient(supabaseUrl, supabaseKey);
    const prefsUid = await resolveUserIdByEmail(supabase, recipientEmail);
    if (prefsUid) {
      const prefs = await fetchNotificationPreferences(supabase, prefsUid);
      if (!canSendOutbound(prefs, "email", "reminder")) {
        return new Response(JSON.stringify({
          success: true,
          skipped: true,
          reason: "email_notifications_disabled"
        }), {
          status: 200,
          headers: {
            "Content-Type": "application/json",
            ...corsHeaders
          }
        });
      }
    }
    // Get email domain settings
    const { data: domainSettings } = await supabase.from("system_settings").select("setting_value, is_active").eq("setting_key", "email_domain").maybeSingle();
    const { data: senderDomain } = await supabase.from("system_settings").select("setting_value").eq("setting_key", "email_sender_domain").eq("is_active", true).maybeSingle();
    const activeDomain = senderDomain?.setting_value || domainSettings?.setting_value || "resend.dev";
    const fromEmail = `KidNCode Portal <noreply@${activeDomain}>`;
    const subject = `New Message from ${senderName}`;
    const displayName = recipientName || (recipientRole === "parent" ? "Parent" : "Teacher");
    const truncatedMessage = messagePreview.length > 100 ? messagePreview.substring(0, 100) + "..." : messagePreview;
    const emailTemplate = await getEmailTemplate(supabase);
    const fromAddress = buildFromAddress(emailTemplate);
    const bodyContent = `
      <div style="padding: 24px;">
        <h2 style="color: #7C3AED; margin-top: 0;">💬 New Message Notification</h2>
        <p>Hello ${displayName},</p>
        <p>You have received a new message from <strong>${senderName}</strong> in the KidNCode Parent Portal.</p>
        <div style="background-color: #f8f9fa; border-left: 4px solid #7C3AED; padding: 15px; margin: 20px 0; border-radius: 4px;">
          <p style="font-style: italic; color: #555; margin: 0;">"${truncatedMessage}"</p>
        </div>
        <p>Please log in to the portal to view and respond to this message.</p>
        <div style="text-align: center;">
          <a href="${supabaseUrl.replace('.supabase.co', '')}/portal" style="display: inline-block; padding: 12px 30px; background-color: #7C3AED; color: #ffffff !important; text-decoration: none; border-radius: 5px; margin: 20px 0; font-weight: 600;">Open Portal Chat</a>
        </div>
      </div>
    `;
    const htmlContent = wrapEmailBody(emailTemplate, bodyContent);
    console.log(`Sending chat notification to ${recipientEmail} from ${senderName}`);
    const emailConfig = await getEmailConfig(supabaseUrl, supabaseKey);
    const emailResponse = await resend.emails.send({
      from: fromAddress,
      replyTo: emailConfig.supportEmail,
      to: [
        recipientEmail
      ],
      subject: subject,
      html: htmlContent
    });
    console.log("Email sent successfully:", emailResponse);
    return new Response(JSON.stringify({
      success: true,
      emailResponse
    }), {
      status: 200,
      headers: {
        "Content-Type": "application/json",
        ...corsHeaders
      }
    });
  } catch (error) {
    console.error("Error in send-chat-notification function:", error);
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
