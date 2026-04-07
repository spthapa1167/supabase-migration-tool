import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";
import Stripe from "https://esm.sh/stripe@18.5.0";
import { canSendOutbound, fetchNotificationPreferences, resolveUserIdByEmail } from "../_shared/notificationPreferences.ts";
import { formatPlatformDateTime, loadPlatformDateTimeConfig } from "../_shared/platformDateTime.ts";
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
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version"
};
const logStep = (step, details)=>{
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : '';
  console.log(`[PAYMENT-NOTIFICATIONS] ${step}${detailsStr}`);
};
async function getSetting(supabase, key) {
  const { data } = await supabase.from('system_settings').select('value').eq('property_name', key).single();
  return data?.value ?? null;
}
async function sendEmail(to, subject, html, template) {
  const resendApiKey = Deno.env.get('RESEND_API_KEY');
  if (!resendApiKey) {
    console.error('RESEND_API_KEY not configured');
    return false;
  }
  try {
    const from = buildFromAddress(template);
    const resp = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${resendApiKey}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        from,
        to: [
          to
        ],
        subject,
        html
      })
    });
    if (!resp.ok) {
      console.error('Resend error:', await resp.text());
      return false;
    }
    return true;
  } catch (e) {
    console.error('Email send error:', e);
    return false;
  }
}
function getAppBaseUrl() {
  const appEnv = Deno.env.get("APP_ENV") || "dev";
  if (appEnv === "prod") return "https://kidncode.com";
  if (appEnv === "test") return "https://test.kidncode.com";
  return "https://kidncode.com";
}
// ─── Email Templates ───────────────────────────────────────────
function upcomingReminderEmailHtml(data, template) {
  const logoUrl = template.header_logo_url;
  const footerHtml = buildFooterHtml(template);
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"></head>
<body style="margin:0;padding:0;font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;background-color:#f4f7fa;">
<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background-color:#f4f7fa;">
<tr><td style="padding:40px 20px;">
<table role="presentation" cellpadding="0" cellspacing="0" width="600" style="max-width:600px;margin:0 auto;background-color:#ffffff;border-radius:12px;box-shadow:0 4px 20px rgba(0,0,0,0.1);overflow:hidden;">
<tr><td style="background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);padding:25px 40px;text-align:center;">
<img src="${logoUrl}" alt="${template.footer_company_name}" style="max-width:280px;height:auto;">
</td></tr>
<tr><td style="text-align:center;padding:35px 30px 15px;">
<div style="width:80px;height:80px;background-color:#dbeafe;border-radius:50%;display:inline-block;line-height:80px;">
<span style="color:#2563eb;font-size:40px;">📅</span>
</div>
<h1 style="color:#1e293b;margin:20px 0 10px;font-size:24px;">Upcoming Payment Reminder</h1>
<p style="color:#64748b;margin:0;font-size:16px;">Hi ${data.customerName}, your next payment is coming up!</p>
</td></tr>
<tr><td style="padding:20px 40px;">
<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background-color:#f8fafc;border-radius:12px;border:1px solid #e2e8f0;">
<tr><td style="padding:25px;">
<h3 style="color:#1e293b;margin:0 0 20px;padding-bottom:15px;border-bottom:2px solid #667eea;font-size:18px;">Payment Details</h3>
<table role="presentation" cellpadding="0" cellspacing="0" width="100%">
<tr><td style="padding:12px 0;color:#64748b;font-size:14px;border-bottom:1px solid #e2e8f0;">Student</td>
<td style="padding:12px 0;color:#1e293b;font-weight:600;text-align:right;border-bottom:1px solid #e2e8f0;">${data.childName}</td></tr>
<tr><td style="padding:12px 0;color:#64748b;font-size:14px;border-bottom:1px solid #e2e8f0;">Program</td>
<td style="padding:12px 0;color:#1e293b;font-weight:500;text-align:right;border-bottom:1px solid #e2e8f0;">${data.programName}</td></tr>
<tr><td style="padding:12px 0;color:#64748b;font-size:14px;border-bottom:1px solid #e2e8f0;">Payment Date</td>
<td style="padding:12px 0;color:#1e293b;font-weight:500;text-align:right;border-bottom:1px solid #e2e8f0;">${data.paymentDate}</td></tr>
<tr><td style="padding:18px 0 12px;color:#1e293b;font-weight:700;font-size:16px;">Amount</td>
<td style="padding:18px 0 12px;color:#2563eb;font-weight:700;font-size:24px;text-align:right;">$${(data.amount / 100).toFixed(2)}</td></tr>
</table>
</td></tr></table>
</td></tr>
<tr><td style="padding:0 40px 30px;">
<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background-color:#eff6ff;border-radius:10px;border:1px solid #93c5fd;">
<tr><td style="padding:18px 20px;">
<p style="color:#1e40af;font-size:14px;margin:0;">
<strong>ℹ️ No Action Required</strong><br>
Your payment will be automatically charged on the date above. If you need to update your payment method, please visit your parent portal or contact us.
</p>
</td></tr></table>
</td></tr>
<tr><td style="padding:30px 40px;background-color:#f8fafc;text-align:center;">
${footerHtml}
</td></tr>
</table></td></tr></table></body></html>`;
}
function paymentConfirmationEmailHtml(data, template) {
  const logoUrl = template.header_logo_url;
  const footerHtml = buildFooterHtml(template);
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"></head>
<body style="margin:0;padding:0;font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;background-color:#f4f7fa;">
<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background-color:#f4f7fa;">
<tr><td style="padding:40px 20px;">
<table role="presentation" cellpadding="0" cellspacing="0" width="600" style="max-width:600px;margin:0 auto;background-color:#ffffff;border-radius:12px;box-shadow:0 4px 20px rgba(0,0,0,0.1);overflow:hidden;">
<tr><td style="background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);padding:25px 40px;text-align:center;">
<img src="${logoUrl}" alt="${template.footer_company_name}" style="max-width:280px;height:auto;">
</td></tr>
<tr><td style="text-align:center;padding:35px 30px 15px;">
<div style="width:80px;height:80px;background-color:#dcfce7;border-radius:50%;display:inline-block;line-height:80px;">
<span style="color:#16a34a;font-size:40px;">✓</span>
</div>
<h1 style="color:#16a34a;margin:20px 0 10px;font-size:28px;">Payment Successful!</h1>
<p style="color:#64748b;margin:0;font-size:16px;">Thank you for your payment, ${data.customerName}!</p>
</td></tr>
<tr><td style="padding:20px 40px;">
<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background-color:#f8fafc;border-radius:12px;border:1px solid #e2e8f0;">
<tr><td style="padding:25px;">
<h3 style="color:#1e293b;margin:0 0 20px;padding-bottom:15px;border-bottom:2px solid #667eea;font-size:18px;">Payment Receipt</h3>
<table role="presentation" cellpadding="0" cellspacing="0" width="100%">
<tr><td style="padding:12px 0;color:#64748b;font-size:14px;border-bottom:1px solid #e2e8f0;">Receipt Number</td>
<td style="padding:12px 0;color:#1e293b;font-weight:600;text-align:right;border-bottom:1px solid #e2e8f0;">#${data.invoiceNumber}</td></tr>
<tr><td style="padding:12px 0;color:#64748b;font-size:14px;border-bottom:1px solid #e2e8f0;">Payment Date</td>
<td style="padding:12px 0;color:#1e293b;font-weight:500;text-align:right;border-bottom:1px solid #e2e8f0;">${data.paidDate}</td></tr>
<tr><td style="padding:12px 0;color:#64748b;font-size:14px;border-bottom:1px solid #e2e8f0;">Customer</td>
<td style="padding:12px 0;color:#1e293b;font-weight:500;text-align:right;border-bottom:1px solid #e2e8f0;">${data.customerName}</td></tr>
<tr><td style="padding:12px 0;color:#64748b;font-size:14px;border-bottom:1px solid #e2e8f0;">Email</td>
<td style="padding:12px 0;color:#1e293b;font-weight:500;text-align:right;border-bottom:1px solid #e2e8f0;">${data.customerEmail}</td></tr>
${data.childName ? `<tr><td style="padding:12px 0;color:#64748b;font-size:14px;border-bottom:1px solid #e2e8f0;">Student</td>
<td style="padding:12px 0;color:#1e293b;font-weight:500;text-align:right;border-bottom:1px solid #e2e8f0;">${data.childName}</td></tr>` : ''}
${data.programName ? `<tr><td style="padding:12px 0;color:#64748b;font-size:14px;border-bottom:1px solid #e2e8f0;">Program</td>
<td style="padding:12px 0;color:#1e293b;font-weight:500;text-align:right;border-bottom:1px solid #e2e8f0;">${data.programName}</td></tr>` : ''}
<tr><td style="padding:18px 0 12px;color:#1e293b;font-weight:700;font-size:16px;">Amount Paid</td>
<td style="padding:18px 0 12px;color:#16a34a;font-weight:700;font-size:24px;text-align:right;">$${(data.amount / 100).toFixed(2)}</td></tr>
</table>
</td></tr></table>
</td></tr>
<tr><td style="padding:0 40px 30px;">
<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background-color:#f0fdf4;border-radius:10px;border:1px solid #86efac;">
<tr><td style="padding:18px 20px;">
<p style="color:#166534;font-size:14px;margin:0;"><strong>✓ Payment Complete</strong><br>This email serves as your official receipt. Please save it for your records.</p>
</td></tr></table>
</td></tr>
<tr><td style="padding:30px 40px;background-color:#f8fafc;text-align:center;">
${footerHtml}
</td></tr>
</table></td></tr></table></body></html>`;
}
function paymentFailureEmailHtml(data, template) {
  const logoUrl = template.header_logo_url;
  const footerHtml = buildFooterHtml(template);
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"></head>
<body style="margin:0;padding:0;font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;background-color:#f4f7fa;">
<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background-color:#f4f7fa;">
<tr><td style="padding:40px 20px;">
<table role="presentation" cellpadding="0" cellspacing="0" width="600" style="max-width:600px;margin:0 auto;background-color:#ffffff;border-radius:12px;box-shadow:0 4px 20px rgba(0,0,0,0.1);overflow:hidden;">
<tr><td style="background:linear-gradient(135deg,#dc2626 0%,#991b1b 100%);padding:25px 40px;text-align:center;">
<img src="${logoUrl}" alt="${template.footer_company_name}" style="max-width:280px;height:auto;">
</td></tr>
<tr><td style="text-align:center;padding:35px 30px 15px;">
<div style="width:80px;height:80px;background-color:#fef2f2;border-radius:50%;display:inline-block;line-height:80px;">
<span style="color:#dc2626;font-size:40px;">⚠️</span>
</div>
<h1 style="color:#dc2626;margin:20px 0 10px;font-size:24px;">Payment Failed</h1>
<p style="color:#64748b;margin:0;font-size:16px;">Hi ${data.customerName}, we were unable to process your payment.</p>
</td></tr>
<tr><td style="padding:20px 40px;">
<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background-color:#fef2f2;border-radius:12px;border:1px solid #fecaca;">
<tr><td style="padding:25px;">
<h3 style="color:#991b1b;margin:0 0 20px;padding-bottom:15px;border-bottom:2px solid #dc2626;font-size:18px;">Payment Details</h3>
<table role="presentation" cellpadding="0" cellspacing="0" width="100%">
${data.childName ? `<tr><td style="padding:12px 0;color:#64748b;font-size:14px;border-bottom:1px solid #fecaca;">Student</td>
<td style="padding:12px 0;color:#1e293b;font-weight:600;text-align:right;border-bottom:1px solid #fecaca;">${data.childName}</td></tr>` : ''}
${data.programName ? `<tr><td style="padding:12px 0;color:#64748b;font-size:14px;border-bottom:1px solid #fecaca;">Program</td>
<td style="padding:12px 0;color:#1e293b;font-weight:500;text-align:right;border-bottom:1px solid #fecaca;">${data.programName}</td></tr>` : ''}
<tr><td style="padding:18px 0 12px;color:#1e293b;font-weight:700;font-size:16px;">Amount Due</td>
<td style="padding:18px 0 12px;color:#dc2626;font-weight:700;font-size:24px;text-align:right;">$${(data.amount / 100).toFixed(2)}</td></tr>
</table>
</td></tr></table>
</td></tr>
<tr><td style="padding:20px 40px;text-align:center;">
<a href="${data.updatePaymentUrl}" style="display:inline-block;background:linear-gradient(135deg,#2563eb 0%,#1d4ed8 100%);color:#ffffff;text-decoration:none;padding:16px 40px;border-radius:8px;font-size:16px;font-weight:700;box-shadow:0 4px 14px rgba(37,99,235,0.4);">Update Payment Method</a>
</td></tr>
<tr><td style="padding:0 40px 30px;">
<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background-color:#fff7ed;border-radius:10px;border:1px solid #fed7aa;">
<tr><td style="padding:18px 20px;">
<p style="color:#9a3412;font-size:14px;margin:0;">
<strong>📋 How to Update Your Payment Method:</strong><br>
1. Click the button above to open the secure payment page<br>
2. Enter your new card details<br>
3. <strong>Important:</strong> Make sure to save the new card as your primary payment method<br>
4. Your subscription will automatically retry the payment
</p>
</td></tr></table>
</td></tr>
<tr><td style="padding:0 40px 30px;">
<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background-color:#f0fdf4;border-radius:10px;border:1px solid #86efac;">
<tr><td style="padding:18px 20px;">
<p style="color:#166534;font-size:14px;margin:0;">
<strong>Need Help?</strong><br>
Contact us at <a href="mailto:support@kidncode.com" style="color:#166534;">support@kidncode.com</a>
</p>
</td></tr></table>
</td></tr>
<tr><td style="padding:30px 40px;background-color:#f8fafc;text-align:center;">
${footerHtml}
</td></tr>
</table></td></tr></table></body></html>`;
}
// ─── Enrollment Matching Helper ────────────────────────────────
async function getEnrollmentInfo(supabase, stripeCustomerId, stripeSubscriptionId) {
  let query = supabase.from('enrollments').select(`
      id, student_id, program_id, stripe_customer_id, stripe_subscription_id,
      students (first_name, last_name, parent_id_new),
      programs (name)
    `).eq('stripe_customer_id', stripeCustomerId).is('deleted_at', null);
  if (stripeSubscriptionId) {
    query = query.eq('stripe_subscription_id', stripeSubscriptionId);
  }
  const { data } = await query.limit(10);
  return data || [];
}
async function getCustomerName(supabase, stripeCustomerId) {
  // Try to find from enrollments → students → parents
  const { data: enrollments } = await supabase.from('enrollments').select('students (parent_id_new)').eq('stripe_customer_id', stripeCustomerId).is('deleted_at', null).limit(1);
  if (enrollments?.[0]?.students?.parent_id_new) {
    const { data: parent } = await supabase.from('parents').select('first_name, last_name, email').eq('id', enrollments[0].students.parent_id_new).is('deleted_at', null).single();
    if (parent) {
      return {
        name: `${parent.first_name || ''} ${parent.last_name || ''}`.trim(),
        email: parent.email
      };
    }
  }
  // Fallback: check parents table by stripe_customer_id
  const { data: parent } = await supabase.from('parents').select('first_name, last_name, email').eq('stripe_customer_id', stripeCustomerId).is('deleted_at', null).limit(1).maybeSingle();
  if (parent) {
    return {
      name: `${parent.first_name || ''} ${parent.last_name || ''}`.trim(),
      email: parent.email
    };
  }
  return {
    name: 'Customer',
    email: ''
  };
}
// ─── Main Handler ──────────────────────────────────────────────
Deno.serve(async (req)=>{
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: corsHeaders
    });
  }
  try {
    logStep("Function started");
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");
    const supabase = createClient(supabaseUrl, supabaseServiceKey);
    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: "2025-08-27.basil"
    });
    const template = await getEmailTemplate(supabase);
    const platformDt = await loadPlatformDateTimeConfig(supabase);
    const formatPaymentDate = (epochMs)=>{
      try {
        if (!epochMs || epochMs <= 0) return "Date unavailable";
        const d = new Date(epochMs);
        if (isNaN(d.getTime())) return "Date unavailable";
        return new Intl.DateTimeFormat("en-US", {
          timeZone: platformDt.timeZone,
          year: "numeric",
          month: "long",
          day: "numeric"
        }).format(d);
      } catch  {
        return "Date unavailable";
      }
    };
    const { mode = "auto", notification_type = "all", stripe_customer_id, stripe_subscription_id, payment_amount, payment_date: manualPaymentDate, recipient_email: manualRecipientEmail, customer_name: manualCustomerName, child_name: manualChildName, program_name: manualProgramName } = await req.json().catch(()=>({}));
    logStep("Request params", {
      mode,
      notification_type,
      stripe_customer_id,
      stripe_subscription_id
    });
    const results = {
      upcoming_reminder: {
        sent: 0,
        failed: 0,
        skipped: 0
      },
      payment_confirmation: {
        sent: 0,
        failed: 0,
        skipped: 0
      },
      payment_failure: {
        sent: 0,
        failed: 0,
        skipped: 0
      }
    };
    // ── A. Upcoming Payment Reminders ──────────────────────────
    if (notification_type === 'all' || notification_type === 'upcoming_reminder') {
      const enabled = await getSetting(supabase, 'payment_upcoming_reminder_enabled');
      if (enabled === 'false') {
        logStep("Upcoming reminders disabled");
        results.upcoming_reminder.skipped = -1;
      } else {
        logStep("Processing upcoming payment reminders", {
          isManualSingle: !!(mode === 'manual' && stripe_customer_id)
        });
        try {
          const now = Date.now();
          const threeDaysMs = 3 * 24 * 60 * 60 * 1000;
          const isManualSingle = mode === 'manual' && stripe_customer_id;
          // For manual single-customer, include trialing subscriptions too
          const statuses = isManualSingle ? [
            'active',
            'trialing'
          ] : [
            'active'
          ];
          let allSubs = [];
          for (const st of statuses){
            const listParams = {
              status: st,
              limit: 100
            };
            if (stripe_customer_id) listParams.customer = stripe_customer_id;
            const subs = await stripe.subscriptions.list(listParams);
            allSubs.push(...subs.data);
          }
          // Deduplicate
          const seenSubIds = new Set();
          const subscriptions = allSubs.filter((s)=>{
            if (seenSubIds.has(s.id)) return false;
            seenSubIds.add(s.id);
            return true;
          });
          for (const sub of subscriptions){
            if (isManualSingle && stripe_subscription_id && sub.id !== stripe_subscription_id) continue;
            // Determine next payment date: use trial_end for trialing subs, otherwise current_period_end
            const nextPaymentEpoch = sub.status === 'trialing' && sub.trial_end ? sub.trial_end : sub.current_period_end;
            const periodEnd = (nextPaymentEpoch || 0) * 1000;
            const timeUntil = periodEnd - now;
            // Skip 3-day window check for manual single-customer triggers
            if (!isManualSingle && (timeUntil <= 0 || timeUntil > threeDaysMs)) continue;
            const customerId = typeof sub.customer === 'string' ? sub.customer : sub.customer.id;
            let paymentDateLabel = formatPaymentDate(periodEnd);
            // If still unavailable, try to get date from upcoming invoice
            if (paymentDateLabel === 'Date unavailable') {
              try {
                const upcoming = await stripe.invoices.retrieveUpcoming({
                  subscription: sub.id
                });
                if (upcoming.next_payment_attempt) {
                  paymentDateLabel = formatPaymentDate(upcoming.next_payment_attempt * 1000);
                } else if (upcoming.period_end) {
                  paymentDateLabel = formatPaymentDate(upcoming.period_end * 1000);
                }
              } catch  {
                logStep("Could not retrieve upcoming invoice for date fallback", {
                  subId: sub.id
                });
              }
            }
            // Only dedupe for automatic runs
            if (!isManualSingle) {
              const threeDaysAgo = new Date(now - threeDaysMs).toISOString();
              const { data: existing } = await supabase.from('payment_notification_logs').select('id').eq('stripe_subscription_id', sub.id).eq('notification_type', 'upcoming_reminder').gte('created_at', threeDaysAgo).limit(1);
              if (existing && existing.length > 0) {
                results.upcoming_reminder.skipped++;
                continue;
              }
            }
            // Get enrollment info
            const enrollments = await getEnrollmentInfo(supabase, customerId, sub.id);
            const customerInfo = await getCustomerName(supabase, customerId);
            const recipientEmail = (manualRecipientEmail || customerInfo.email || '').trim();
            const customerName = (manualCustomerName || customerInfo.name || 'Customer').trim() || 'Customer';
            const childName = (manualChildName || '').trim() || (enrollments.length > 0 && enrollments[0].students ? `${enrollments[0].students.first_name || ''} ${enrollments[0].students.last_name || ''}`.trim() : 'Your child');
            const programName = (manualProgramName || '').trim() || (enrollments.length > 0 && enrollments[0].programs ? enrollments[0].programs.name : 'KidNCode Program');
            if (!recipientEmail || !recipientEmail.includes('@')) {
              if (isManualSingle) {
                await supabase.from('payment_notification_logs').insert({
                  stripe_customer_id: customerId,
                  stripe_subscription_id: sub.id,
                  notification_type: 'upcoming_reminder',
                  recipient_email: recipientEmail || 'missing-email',
                  customer_name: customerName,
                  amount: payment_amount ? Math.round((parseFloat(payment_amount) || 0) * 100) : 0,
                  status: 'failed',
                  triggered_by: mode,
                  metadata: {
                    child_name: childName,
                    program_name: programName,
                    payment_date: manualPaymentDate || paymentDateLabel,
                    error: 'Missing recipient email'
                  }
                });
                results.upcoming_reminder.failed++;
              } else {
                results.upcoming_reminder.skipped++;
              }
              continue;
            }
            // Calculate amount - use manual values if provided, else from Stripe
            let amount = 0;
            if (isManualSingle && payment_amount && Number.isFinite(parseFloat(payment_amount))) {
              amount = Math.round(parseFloat(payment_amount) * 100);
            } else {
              try {
                const upcoming = await stripe.invoices.retrieveUpcoming({
                  subscription: sub.id
                });
                amount = upcoming.amount_due || 0;
              } catch  {
                amount = sub.items?.data?.[0]?.price?.unit_amount || 0;
              }
            }
            // Use manual payment date if provided
            if (isManualSingle && manualPaymentDate && manualPaymentDate.trim()) {
              const parsed = new Date(`${manualPaymentDate}T12:00:00`);
              if (!Number.isNaN(parsed.getTime())) {
                paymentDateLabel = formatPaymentDate(parsed.getTime());
              } else {
                logStep("Manual payment date parse failed", {
                  manualPaymentDate
                });
              }
            }
            const html = upcomingReminderEmailHtml({
              customerName,
              childName,
              programName,
              amount,
              paymentDate: paymentDateLabel
            }, template);
            let prefsAllowEmail = true;
            const profileIdForPrefs = await resolveUserIdByEmail(supabase, recipientEmail);
            if (profileIdForPrefs) {
              const prefs = await fetchNotificationPreferences(supabase, profileIdForPrefs);
              prefsAllowEmail = canSendOutbound(prefs, 'email', 'reminder');
            }
            const emailSent = prefsAllowEmail ? await sendEmail(recipientEmail, `📅 Upcoming Payment Reminder - ${programName}`, html, template) : false;
            await supabase.from('payment_notification_logs').insert({
              stripe_customer_id: customerId,
              stripe_subscription_id: sub.id,
              notification_type: 'upcoming_reminder',
              recipient_email: recipientEmail,
              customer_name: customerName,
              amount,
              status: emailSent ? 'sent' : prefsAllowEmail ? 'failed' : 'skipped',
              triggered_by: mode,
              metadata: {
                child_name: childName,
                program_name: programName,
                payment_date: paymentDateLabel,
                ...prefsAllowEmail ? {} : {
                  skip_reason: 'email_notifications_disabled'
                }
              }
            });
            if (emailSent) results.upcoming_reminder.sent++;
            else if (!prefsAllowEmail) results.upcoming_reminder.skipped++;
            else results.upcoming_reminder.failed++;
            // Manual reminder should send only for the selected subscription
            if (isManualSingle) break;
          }
        } catch (e) {
          const errorMessage = e instanceof Error ? e.message : String(e);
          logStep("Error in upcoming reminders", {
            error: errorMessage
          });
          if (mode === 'manual' && stripe_customer_id) {
            try {
              await supabase.from('payment_notification_logs').insert({
                stripe_customer_id,
                stripe_subscription_id: stripe_subscription_id || null,
                notification_type: 'upcoming_reminder',
                recipient_email: (manualRecipientEmail || 'unknown').trim() || 'unknown',
                customer_name: (manualCustomerName || 'Customer').trim() || 'Customer',
                amount: payment_amount ? Math.round((parseFloat(payment_amount) || 0) * 100) : 0,
                status: 'failed',
                triggered_by: mode,
                metadata: {
                  child_name: manualChildName || 'Your child',
                  program_name: manualProgramName || 'KidNCode Program',
                  payment_date: manualPaymentDate || null,
                  error: errorMessage
                }
              });
              results.upcoming_reminder.failed++;
            } catch (logErr) {
              logStep('Failed to insert manual reminder error log', {
                error: String(logErr)
              });
            }
          }
        }
      }
    }
    // ── B. Payment Confirmations ───────────────────────────────
    if (notification_type === 'all' || notification_type === 'payment_confirmation') {
      const enabled = await getSetting(supabase, 'payment_confirmation_email_enabled');
      if (enabled === 'false') {
        logStep("Payment confirmations disabled");
        results.payment_confirmation.skipped = -1;
      } else {
        logStep("Processing payment confirmations");
        try {
          const lookbackHours = mode === 'manual' ? 7 * 24 : 24;
          const since = Math.floor((Date.now() - lookbackHours * 60 * 60 * 1000) / 1000);
          const listParams = {
            status: 'paid',
            created: {
              gte: since
            },
            limit: 100
          };
          if (stripe_customer_id) listParams.customer = stripe_customer_id;
          const invoices = await stripe.invoices.list(listParams);
          for (const invoice of invoices.data){
            if (!invoice.amount_paid || invoice.amount_paid <= 0) continue;
            const customerId = typeof invoice.customer === 'string' ? invoice.customer : invoice.customer?.id;
            if (!customerId) continue;
            // Check if confirmation already sent for this invoice
            const { data: existing } = await supabase.from('payment_notification_logs').select('id').eq('stripe_customer_id', customerId).eq('notification_type', 'payment_confirmation').contains('metadata', {
              stripe_invoice_id: invoice.id
            }).limit(1);
            if (existing && existing.length > 0) {
              results.payment_confirmation.skipped++;
              continue;
            }
            const customerInfo = await getCustomerName(supabase, customerId);
            if (!customerInfo.email) {
              results.payment_confirmation.skipped++;
              continue;
            }
            const enrollments = await getEnrollmentInfo(supabase, customerId, invoice.subscription);
            const childName = enrollments.length > 0 && enrollments[0].students ? `${enrollments[0].students.first_name || ''} ${enrollments[0].students.last_name || ''}`.trim() : '';
            const programName = enrollments.length > 0 && enrollments[0].programs ? enrollments[0].programs.name : '';
            const invoiceNumber = invoice.number || invoice.id.substring(0, 8).toUpperCase();
            const paidAtMs = invoice.status_transitions?.paid_at * 1000 || Date.now();
            const paidDate = formatPlatformDateTime(paidAtMs, platformDt);
            const html = paymentConfirmationEmailHtml({
              customerName: customerInfo.name,
              customerEmail: customerInfo.email,
              childName,
              programName,
              amount: invoice.amount_paid,
              invoiceNumber,
              paidDate
            }, template);
            const emailSent = await sendEmail(customerInfo.email, `Payment Confirmation - Receipt #${invoiceNumber}`, html, template);
            await supabase.from('payment_notification_logs').insert({
              stripe_customer_id: customerId,
              stripe_subscription_id: invoice.subscription || null,
              notification_type: 'payment_confirmation',
              recipient_email: customerInfo.email,
              customer_name: customerInfo.name,
              amount: invoice.amount_paid,
              status: emailSent ? 'sent' : 'failed',
              triggered_by: mode,
              metadata: {
                stripe_invoice_id: invoice.id,
                invoice_number: invoiceNumber,
                child_name: childName,
                program_name: programName
              }
            });
            if (emailSent) results.payment_confirmation.sent++;
            else results.payment_confirmation.failed++;
          }
        } catch (e) {
          logStep("Error in payment confirmations", {
            error: String(e)
          });
        }
      }
    }
    // ── C. Payment Failure Notifications ───────────────────────
    if (notification_type === 'all' || notification_type === 'payment_failure') {
      const enabled = await getSetting(supabase, 'payment_failure_notification_enabled');
      if (enabled === 'false') {
        logStep("Payment failure notifications disabled");
        results.payment_failure.skipped = -1;
      } else {
        logStep("Processing payment failure notifications");
        try {
          const lookbackHours = mode === 'manual' ? 7 * 24 : 24;
          const since = Math.floor((Date.now() - lookbackHours * 60 * 60 * 1000) / 1000);
          // Get open/past_due invoices
          for (const status of [
            'open',
            'past_due'
          ]){
            const listParams = {
              status,
              created: {
                gte: since
              },
              limit: 100
            };
            if (stripe_customer_id) listParams.customer = stripe_customer_id;
            let invoices;
            try {
              invoices = await stripe.invoices.list(listParams);
            } catch  {
              continue;
            }
            for (const invoice of invoices.data){
              const customerId = typeof invoice.customer === 'string' ? invoice.customer : invoice.customer?.id;
              if (!customerId) continue;
              // Check duplicate
              const { data: existing } = await supabase.from('payment_notification_logs').select('id').eq('stripe_customer_id', customerId).eq('notification_type', 'payment_failure').contains('metadata', {
                stripe_invoice_id: invoice.id
              }).limit(1);
              if (existing && existing.length > 0) {
                results.payment_failure.skipped++;
                continue;
              }
              const customerInfo = await getCustomerName(supabase, customerId);
              if (!customerInfo.email) {
                results.payment_failure.skipped++;
                continue;
              }
              const enrollments = await getEnrollmentInfo(supabase, customerId, invoice.subscription);
              const childName = enrollments.length > 0 && enrollments[0].students ? `${enrollments[0].students.first_name || ''} ${enrollments[0].students.last_name || ''}`.trim() : '';
              const programName = enrollments.length > 0 && enrollments[0].programs ? enrollments[0].programs.name : 'KidNCode Program';
              // Generate payment management link
              let updatePaymentUrl = `${getAppBaseUrl()}/auth`;
              try {
                // Create a payment management link directly
                const token = crypto.randomUUID();
                const expiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000); // 7 days
                // Invalidate old links
                await supabase.from('payment_management_links').update({
                  invalidated_at: new Date().toISOString()
                }).eq('stripe_customer_id', customerId).is('invalidated_at', null).is('used_at', null);
                const { data: linkData } = await supabase.from('payment_management_links').insert({
                  stripe_customer_id: customerId,
                  stripe_subscription_id: invoice.subscription || null,
                  customer_name: customerInfo.name,
                  customer_email: customerInfo.email,
                  token,
                  is_enabled: true,
                  expires_at: expiresAt.toISOString()
                }).select().single();
                if (linkData) {
                  updatePaymentUrl = `${getAppBaseUrl()}/manage-payment/${token}`;
                }
              } catch (e) {
                logStep("Error creating payment link", {
                  error: String(e)
                });
              }
              const html = paymentFailureEmailHtml({
                customerName: customerInfo.name,
                childName,
                programName,
                amount: invoice.amount_due || 0,
                updatePaymentUrl
              }, template);
              const emailSent = await sendEmail(customerInfo.email, `⚠️ Payment Failed - Action Required for ${programName}`, html, template);
              await supabase.from('payment_notification_logs').insert({
                stripe_customer_id: customerId,
                stripe_subscription_id: invoice.subscription || null,
                notification_type: 'payment_failure',
                recipient_email: customerInfo.email,
                customer_name: customerInfo.name,
                amount: invoice.amount_due || 0,
                status: emailSent ? 'sent' : 'failed',
                triggered_by: mode,
                metadata: {
                  stripe_invoice_id: invoice.id,
                  child_name: childName,
                  program_name: programName
                }
              });
              if (emailSent) results.payment_failure.sent++;
              else results.payment_failure.failed++;
            }
          }
        } catch (e) {
          logStep("Error in payment failure notifications", {
            error: String(e)
          });
        }
      }
    }
    logStep("Completed", results);
    return new Response(JSON.stringify({
      success: true,
      results
    }), {
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      },
      status: 200
    });
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    logStep("ERROR", {
      message: errorMessage
    });
    return new Response(JSON.stringify({
      error: errorMessage
    }), {
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      },
      status: 500
    });
  }
});
