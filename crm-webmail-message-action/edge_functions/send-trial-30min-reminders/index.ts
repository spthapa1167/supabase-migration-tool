import { createClient } from "npm:@supabase/supabase-js@2";
import { formatPlatformDateFromYmd, formatTimezoneShort, getWallClockParts, loadPlatformDateTimeConfig } from "../_shared/platformDateTime.ts";
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
// ----- inlined: trialNotificationLog.ts -----
/** Log outbound email tied to a trial request (parent/teacher only — use metadata.recipient_role). */ export async function logTrialOutboundEmail(supabase, params) {
  const preview = (params.body_preview || "").replace(/\s+/g, " ").trim().slice(0, 500);
  /** Always store trial_request_id in metadata so CSR history can query via `metadata` without a dedicated column. */ const metadata = {
    ...params.metadata ?? {},
    trial_request_id: params.trial_request_id
  };
  const { error } = await supabase.from("outbound_email_log").insert({
    recipient_email: params.recipient_email,
    recipient_name: params.recipient_name ?? null,
    subject: params.subject,
    body_preview: preview || "(no preview)",
    source: params.source,
    status: params.status,
    metadata,
    created_by: params.created_by ?? null,
    provider_message_id: params.provider_message_id ?? null
  });
  if (error) {
    console.error("outbound_email_log insert (trial):", error.message, error.code, error.details);
  }
}
/** Log outbound SMS tied to a trial request. */ export async function logTrialOutboundSms(supabase, params) {
  const preview = (params.body_preview || "").replace(/\s+/g, " ").trim().slice(0, 500);
  const metadata = {
    ...params.metadata ?? {},
    trial_request_id: params.trial_request_id
  };
  const { error } = await supabase.from("outbound_sms_log").insert({
    recipient_phone: params.recipient_phone,
    body_preview: preview || "(no preview)",
    source: params.source,
    status: params.status,
    metadata,
    created_by: params.created_by ?? null,
    provider_message_sid: params.provider_message_sid ?? null
  });
  if (error) {
    console.error("outbound_sms_log insert (trial):", error.message, error.code, error.details);
  }
}
// ========== end inlined shared ==========
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version"
};
/** pg_cron every 5 min; class start times may fall between ticks — use a window; dedup via trial_reminder_* columns. */ const CRON_STEP_MINUTES = 5;
/** Parse stored time like "3:30 PM CST" or "15:30" → minutes from midnight (CST wall clock). */ function parseTrialTimeToMinutes(scheduledTime) {
  const cleaned = scheduledTime.replace(/\s*CST\s*/i, "").replace(/\s*CDT\s*/i, "").trim();
  const ampm = cleaned.match(/^(\d{1,2}):(\d{2})\s*(AM|PM)\s*$/i);
  if (ampm) {
    let h = parseInt(ampm[1], 10);
    const mm = parseInt(ampm[2], 10);
    const p = ampm[3].toUpperCase();
    if (p === "PM" && h !== 12) h += 12;
    if (p === "AM" && h === 12) h = 0;
    return h * 60 + mm;
  }
  const hm = cleaned.match(/^(\d{1,2}):(\d{2})$/);
  if (hm) {
    const h = parseInt(hm[1], 10);
    const mm = parseInt(hm[2], 10);
    return h * 60 + mm;
  }
  return null;
}
const PAGE_LABELS = {
  kidnmath: "KidN Math",
  kidnai: "KidN AI",
  kidntech: "KidN Tech",
  kidnrobotics: "KidN Robotics",
  kidngamedev: "KidN GameDev",
  kidncamp: "KidN Camp",
  kidnb2b: "KidN B2B",
  kidnprogram: "KidN Program"
};
Deno.serve(async (req)=>{
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: corsHeaders
    });
  }
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const resendApiKey = Deno.env.get("RESEND_API_KEY");
    if (!resendApiKey) {
      throw new Error("RESEND_API_KEY not configured");
    }
    const supabase = createClient(supabaseUrl, serviceRoleKey);
    const emailTemplate = await getEmailTemplate(supabase);
    const fromAddress = buildFromAddress(emailTemplate);
    const platformDt = await loadPlatformDateTimeConfig(supabase);
    const wall = getWallClockParts(platformDt.timeZone);
    const todayKey = wall.today;
    const { data: settingsData } = await supabase.from("system_settings").select("property_name, value").in("property_name", [
      "pre_class_reminder_enabled",
      "pre_class_reminder_minutes",
      "pre_class_reminder_teacher_email",
      "pre_class_reminder_parent_email"
    ]);
    const settings = {};
    (settingsData || []).forEach((s)=>{
      settings[s.property_name] = s.value;
    });
    if (settings["pre_class_reminder_enabled"] === "false") {
      return new Response(JSON.stringify({
        message: "Pre-class / trial reminders disabled globally"
      }), {
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    const reminderMinutes = parseInt(settings["pre_class_reminder_minutes"] || "30", 10);
    const teacherEmailEnabled = settings["pre_class_reminder_teacher_email"] !== "false";
    const parentEmailEnabled = settings["pre_class_reminder_parent_email"] !== "false";
    const { data: trials, error } = await supabase.from("trial_requests").select("id, status, do_not_notify, trial_remind_parent, trial_remind_teacher, trial_reminder_parent_sent_at, trial_reminder_teacher_sent_at, scheduled_date, scheduled_time, meeting_link, meeting_instructions_parent, meeting_instructions_teacher, parent_email, parent_first_name, parent_last_name, child_first_name, child_last_name, request_type, page_slug, preferred_mode, assigned_teacher_id, assigned_teacher_email, assigned_teacher_name, program_id").eq("status", "confirmed").eq("do_not_notify", false).not("scheduled_date", "is", null).not("scheduled_time", "is", null);
    if (error) throw error;
    let parentSent = 0;
    let teacherSent = 0;
    const skipped = [];
    for (const t of trials || []){
      if (!t.scheduled_date || !t.scheduled_time) continue;
      if (t.scheduled_date !== todayKey) {
        skipped.push(`${t.id}: not today (${platformDt.timeZone})`);
        continue;
      }
      const startMins = parseTrialTimeToMinutes(t.scheduled_time);
      if (startMins === null) {
        skipped.push(`${t.id}: bad time`);
        continue;
      }
      const minutesUntil = startMins - wall.currentTotalMinutes;
      if (minutesUntil <= 0) continue;
      if (minutesUntil > reminderMinutes || minutesUntil <= reminderMinutes - CRON_STEP_MINUTES) {
        continue;
      }
      const minutesLabel = minutesUntil;
      let programName = PAGE_LABELS[t.page_slug] || t.page_slug;
      if (t.program_id) {
        const { data: prog } = await supabase.from("programs").select("name").eq("id", t.program_id).maybeSingle();
        if (prog?.name) programName = prog.name;
      }
      const sessionKind = t.request_type === "consultation" ? "Consultation" : "Trial class";
      const childName = `${t.child_first_name} ${t.child_last_name}`.trim();
      const parentName = `${t.parent_first_name} ${t.parent_last_name}`.trim();
      const datePretty = formatPlatformDateFromYmd(t.scheduled_date, platformDt);
      const tzShort = formatTimezoneShort(platformDt.timeZone);
      const timeLine = t.scheduled_time.includes("CST") || t.scheduled_time.includes("CDT") || t.scheduled_time.includes(tzShort) ? t.scheduled_time : `${t.scheduled_time} ${tzShort}`;
      const meetingBlock = (forTeacher)=>{
        const instr = forTeacher ? t.meeting_instructions_teacher : t.meeting_instructions_parent;
        return `
          ${t.meeting_link ? `
          <div style="background:#e3f2fd;border-left:4px solid #1565c0;padding:14px 18px;border-radius:6px;margin:16px 0;">
            <p style="margin:0 0 6px;font-weight:700;color:#1565c0;">Meeting link</p>
            <a href="${t.meeting_link}" style="color:#1565c0;word-break:break-all;">${t.meeting_link}</a>
          </div>` : ""}
          ${instr ? `
          <div style="background:#fff8e1;border-left:4px solid #f9a825;padding:14px 18px;border-radius:6px;margin:16px 0;">
            <p style="margin:0 0 6px;font-weight:700;color:#f57f17;">${forTeacher ? "Instructions for you" : "Instructions"}</p>
            <p style="margin:0;color:#555;line-height:1.6;">${String(instr).replace(/\n/g, "<br/>")}</p>
          </div>` : ""}
        `;
      };
      // Parent
      if (t.trial_remind_parent && parentEmailEnabled && t.parent_email && !t.trial_reminder_parent_sent_at) {
        const inner = `
          <h2 style="color:#1a237e;">Starting in ${minutesLabel} minutes</h2>
          <p>Hi ${parentName || "there"},</p>
          <p>Your <strong>${sessionKind.toLowerCase()}</strong> for <strong>${childName}</strong> (${programName}) begins in about <strong>${minutesLabel} minutes</strong>.</p>
          <table style="width:100%;border-collapse:collapse;margin:16px 0;">
            <tr><td style="padding:8px 0;font-weight:bold;width:100px;">When</td><td>${datePretty}</td></tr>
            <tr><td style="padding:8px 0;font-weight:bold;">Time</td><td>${timeLine}</td></tr>
            <tr><td style="padding:8px 0;font-weight:bold;">Mode</td><td>${t.preferred_mode === "online" ? "Online" : "In-center"}</td></tr>
          </table>
          ${meetingBlock(false)}
          <p style="color:#666;font-size:12px;">Request ID: ${t.id}</p>
        `;
        const html = wrapEmailBody(emailTemplate, `<div style="padding:24px;">${inner}</div>`);
        const resp = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: {
            Authorization: `Bearer ${resendApiKey}`,
            "Content-Type": "application/json"
          },
          body: JSON.stringify({
            from: fromAddress,
            to: [
              t.parent_email
            ],
            subject: `⏰ ${sessionKind} for ${childName} starts in ${minutesLabel} minutes`,
            html
          })
        });
        const rawP = await resp.text();
        if (resp.ok) {
          await supabase.from("trial_requests").update({
            trial_reminder_parent_sent_at: new Date().toISOString()
          }).eq("id", t.id);
          parentSent++;
          let pid = null;
          try {
            const j = JSON.parse(rawP);
            if (j.id) pid = j.id;
          } catch  {
          /* ignore */ }
          await logTrialOutboundEmail(supabase, {
            trial_request_id: t.id,
            recipient_email: t.parent_email,
            recipient_name: parentName,
            subject: `⏰ ${sessionKind} for ${childName} starts in ${minutesLabel} minutes`,
            body_preview: `${reminderMinutes}-minute reminder (parent) — ${childName}`,
            source: "trial_30min_reminder",
            status: "sent",
            metadata: {
              recipient_role: "parent",
              notification_kind: "reminder_30min"
            },
            created_by: null,
            provider_message_id: pid
          });
        } else {
          console.error("Parent trial reminder failed:", rawP);
        }
      }
      // Teacher
      if (t.trial_remind_teacher && teacherEmailEnabled && t.assigned_teacher_email && !t.trial_reminder_teacher_sent_at) {
        const inner = `
          <h2 style="color:#1a237e;">Trial starts in ${minutesLabel} minutes</h2>
          <p>Hi ${t.assigned_teacher_name || "Teacher"},</p>
          <p>Your assigned <strong>${sessionKind.toLowerCase()}</strong> with <strong>${childName}</strong> (${programName}) begins in about <strong>${minutesLabel} minutes</strong>.</p>
          <table style="width:100%;border-collapse:collapse;margin:16px 0;">
            <tr><td style="padding:8px 0;font-weight:bold;width:120px;">Parent</td><td>${parentName} &lt;${t.parent_email}&gt;</td></tr>
            <tr><td style="padding:8px 0;font-weight:bold;">When</td><td>${datePretty}</td></tr>
            <tr><td style="padding:8px 0;font-weight:bold;">Time</td><td>${timeLine}</td></tr>
          </table>
          ${meetingBlock(true)}
          <p style="color:#666;font-size:12px;">Request ID: ${t.id}</p>
        `;
        const html = wrapEmailBody(emailTemplate, `<div style="padding:24px;">${inner}</div>`);
        const resp = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: {
            Authorization: `Bearer ${resendApiKey}`,
            "Content-Type": "application/json"
          },
          body: JSON.stringify({
            from: fromAddress,
            to: [
              t.assigned_teacher_email
            ],
            subject: `⏰ Trial reminder: ${childName} in ${minutesLabel} minutes`,
            html
          })
        });
        const rawT = await resp.text();
        if (resp.ok) {
          await supabase.from("trial_requests").update({
            trial_reminder_teacher_sent_at: new Date().toISOString()
          }).eq("id", t.id);
          teacherSent++;
          let tid = null;
          try {
            const j = JSON.parse(rawT);
            if (j.id) tid = j.id;
          } catch  {
          /* ignore */ }
          await logTrialOutboundEmail(supabase, {
            trial_request_id: t.id,
            recipient_email: t.assigned_teacher_email,
            recipient_name: t.assigned_teacher_name,
            subject: `⏰ Trial reminder: ${childName} in ${minutesLabel} minutes`,
            body_preview: `${reminderMinutes}-minute reminder (teacher) — ${childName}`,
            source: "trial_30min_reminder",
            status: "sent",
            metadata: {
              recipient_role: "teacher",
              notification_kind: "reminder_30min"
            },
            created_by: null,
            provider_message_id: tid
          });
        } else {
          console.error("Teacher trial reminder failed:", rawT);
        }
      }
    }
    return new Response(JSON.stringify({
      message: "ok",
      parentSent,
      teacherSent,
      reminderMinutes,
      todayCst: todayKey,
      skippedSample: skipped.slice(0, 5)
    }), {
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  } catch (e) {
    console.error("send-trial-30min-reminders:", e);
    return new Response(JSON.stringify({
      error: String(e)
    }), {
      status: 500,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  }
});
