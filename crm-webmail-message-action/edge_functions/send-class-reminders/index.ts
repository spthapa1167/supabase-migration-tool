import { createClient } from 'npm:@supabase/supabase-js@2';
import { parentMayReceive, profileMayReceive } from '../_shared/notificationPreferences.ts';
import { getWallClockParts, platformConfigFromSettingsMap } from '../_shared/platformDateTime.ts';
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
/**
 * Fetch the active default SMS template from sms_template_settings.
 * Pass the Supabase client (with service role for RLS).
 */ export async function getSmsTemplate(supabase) {
  const { data, error } = await supabase.from("sms_template_settings").select("header_message, footer_message").eq("template_type", "default").eq("is_active", true).order("updated_at", {
    ascending: false,
    nullsFirst: false
  }).limit(1).maybeSingle();
  if (error || !data) {
    return {
      header_message: null,
      footer_message: null
    };
  }
  return {
    header_message: data.header_message != null ? String(data.header_message).trim() || null : null,
    footer_message: data.footer_message != null ? String(data.footer_message).trim() || null : null
  };
}
/**
 * Wrap the feature-specific body with template header and footer.
 * Returns a single string: header + body + footer (each non-empty part separated by "\n\n").
 */ export function wrapSmsBody(template, body) {
  const parts = [
    template.header_message || "",
    (body || "").trim(),
    template.footer_message || ""
  ].filter(Boolean);
  return parts.join("\n\n");
}
// ========== end inlined shared ==========
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version'
};
const formatTimeDisplay = (t)=>{
  if (!t) return '';
  const [h, m] = t.split(':').map(Number);
  const period = h >= 12 ? 'PM' : 'AM';
  const displayH = h > 12 ? h - 12 : h === 0 ? 12 : h;
  return `${displayH}:${String(m).padStart(2, '0')} ${period} CST`;
};
async function sendSMSDirect(to, message) {
  const accountSid = Deno.env.get('TWILIO_ACCOUNT_SID');
  const authToken = Deno.env.get('TWILIO_AUTH_TOKEN');
  const twilioPhone = Deno.env.get('TWILIO_PHONE_NUMBER');
  if (!accountSid || !authToken || !twilioPhone) {
    console.error('Twilio credentials not configured');
    return false;
  }
  let phone = to.replace(/\D/g, '');
  if (!phone.startsWith('1') && phone.length === 10) phone = '1' + phone;
  if (!phone.startsWith('+')) phone = '+' + phone;
  try {
    const resp = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`, {
      method: 'POST',
      headers: {
        'Authorization': 'Basic ' + btoa(`${accountSid}:${authToken}`),
        'Content-Type': 'application/x-www-form-urlencoded'
      },
      body: new URLSearchParams({
        To: phone,
        From: twilioPhone,
        Body: message
      })
    });
    const data = await resp.json();
    if (!resp.ok) {
      console.error('Twilio error:', data);
      return false;
    }
    return true;
  } catch (e) {
    console.error('SMS send error:', e);
    return false;
  }
}
const normalizeDays = (input)=>{
  const raw = Array.isArray(input) ? input : typeof input === 'string' ? (()=>{
    try {
      const parsed = JSON.parse(input);
      return Array.isArray(parsed) ? parsed : [];
    } catch  {
      return [];
    }
  })() : [];
  return raw.map((day)=>String(day || '').trim()).filter(Boolean).map((day)=>day.charAt(0).toUpperCase() + day.slice(1).toLowerCase());
};
/** Cron runs every N minutes; accept any tick in (reminderMinutes-N, reminderMinutes] to avoid missing non-aligned class times. Dedup via class_reminder_logs. */ const CRON_STEP_MINUTES = 5;
const parseTimeSlot = (input)=>{
  const slot = typeof input === 'string' ? (()=>{
    try {
      return JSON.parse(input);
    } catch  {
      return null;
    }
  })() : input;
  if (!slot || typeof slot !== 'object') return null;
  const obj = slot;
  const start = String(obj.start || obj.start_time || '').trim();
  const end = String(obj.end || obj.end_time || '').trim();
  if (!start) return null;
  return {
    start,
    end
  };
};
async function sendEmailDirect(to, subject, html, from) {
  const resendApiKey = Deno.env.get('RESEND_API_KEY');
  if (!resendApiKey) {
    console.error('RESEND_API_KEY not configured');
    return false;
  }
  try {
    const resp = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${resendApiKey}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        from: from ?? 'KidNCode Online <noreply@kidncode.com>',
        to: Array.isArray(to) ? to : [
          to
        ],
        subject,
        html
      })
    });
    if (!resp.ok) {
      const err = await resp.text();
      console.error('Resend error:', err);
      return false;
    }
    const result = await resp.json();
    console.log('Email sent successfully:', result.id);
    return true;
  } catch (e) {
    console.error('Email send error:', e);
    return false;
  }
}
Deno.serve(async (req)=>{
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      headers: corsHeaders
    });
  }
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    const supabase = createClient(supabaseUrl, serviceRoleKey);
    const emailTemplate = await getEmailTemplate(supabase);
    const smsTemplate = await getSmsTemplate(supabase);
    const fromAddress = buildFromAddress(emailTemplate);
    // 1. Check system settings for enable/disable flags
    const { data: settingsData } = await supabase.from('system_settings').select('property_name, value').in('property_name', [
      'pre_class_reminder_enabled',
      'pre_class_reminder_teacher_email',
      'pre_class_reminder_teacher_sms',
      'pre_class_reminder_parent_email',
      'pre_class_reminder_parent_sms',
      'pre_class_reminder_minutes',
      'default_timezone',
      'time_format',
      'date_format'
    ]);
    const settings = {};
    (settingsData || []).forEach((s)=>{
      settings[s.property_name] = s.value;
    });
    if (settings['pre_class_reminder_enabled'] === 'false') {
      console.log('Pre-class reminders are disabled.');
      return new Response(JSON.stringify({
        message: 'Reminders disabled'
      }), {
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        }
      });
    }
    const reminderMinutes = parseInt(settings['pre_class_reminder_minutes'] || '30');
    const teacherEmail = settings['pre_class_reminder_teacher_email'] !== 'false';
    const teacherSms = settings['pre_class_reminder_teacher_sms'] !== 'false';
    const parentEmail = settings['pre_class_reminder_parent_email'] !== 'false';
    const parentSms = settings['pre_class_reminder_parent_sms'] !== 'false';
    const platformDt = platformConfigFromSettingsMap(settings);
    // 2. Current wall clock in org default timezone (matches batch days + time_slot)
    const { today, currentDay, currentTotalMinutes } = getWallClockParts(platformDt.timeZone);
    const currentHours = Math.floor(currentTotalMinutes / 60);
    const currentMinutes = currentTotalMinutes % 60;
    console.log(`Current (${platformDt.timeZone}): ${currentDay} ${currentHours}:${String(currentMinutes).padStart(2, '0')}, reminder target: ${reminderMinutes} min before (±${CRON_STEP_MINUTES} min cron window)`);
    // 3. Fetch all active batches
    const { data: batches, error: batchError } = await supabase.from('batches').select('id, batch_name, batch_code, days, time_slot, online_meeting_link, meeting_instructions, meeting_instructions_teacher, teacher_id, metadata, program_id').eq('status', 'active');
    if (batchError) throw batchError;
    let remindersSent = 0;
    for (const batch of batches || []){
      const days = normalizeDays(batch.days);
      if (!days.includes(currentDay)) continue;
      const timeSlot = parseTimeSlot(batch.time_slot);
      if (!timeSlot?.start) continue;
      const [startH, startM] = timeSlot.start.split(':').map(Number);
      const classStartMinutes = startH * 60 + startM;
      const minutesUntilClass = classStartMinutes - currentTotalMinutes;
      if (minutesUntilClass <= 0) continue;
      if (minutesUntilClass > reminderMinutes || minutesUntilClass <= reminderMinutes - CRON_STEP_MINUTES) {
        continue;
      }
      console.log(`Batch ${batch.batch_name} has class in ${minutesUntilClass} minutes`);
      // Fetch program name for friendly display
      let programName = '';
      if (batch.program_id) {
        const { data: prog } = await supabase.from('programs').select('name').eq('id', batch.program_id).single();
        programName = prog?.name || '';
      }
      const friendlyClassName = programName || batch.batch_name;
      // Fetch active students in this batch first (needed for teacher assignments)
      const { data: batchStudents } = await supabase.from('batch_students').select('student_id').eq('batch_id', batch.id).eq('status', 'active');
      const studentIds = (batchStudents || []).map((bs)=>bs.student_id);
      // Teachers: primary + metadata.teacher_ids + any active student_teacher_assignments on this batch
      const teacherIdSet = new Set([
        ...batch.teacher_id ? [
          batch.teacher_id
        ] : [],
        ...batch.metadata?.teacher_ids && Array.isArray(batch.metadata.teacher_ids) ? batch.metadata.teacher_ids : []
      ].filter(Boolean));
      if (studentIds.length > 0) {
        const { data: staRows } = await supabase.from('student_teacher_assignments').select('teacher_id').eq('batch_id', batch.id).eq('status', 'active').is('removed_at', null).in('student_id', studentIds);
        for (const row of staRows || []){
          if (row?.teacher_id) teacherIdSet.add(row.teacher_id);
        }
      }
      const teacherIds = [
        ...teacherIdSet
      ];
      // Fetch students and parent contacts (parents table + legacy profiles.parent_id)
      let students = [];
      /** Unified list: parents.id rows + profiles.id for legacy-only students */ let parentRecipients = [];
      if (studentIds.length > 0) {
        const { data: studentData } = await supabase.from('students').select('id, first_name, last_name, parent_id_new, parent_id').in('id', studentIds).is('deleted_at', null);
        students = studentData || [];
        const parentIdsFromTable = [
          ...new Set(students.map((s)=>s.parent_id_new).filter(Boolean))
        ];
        const legacyProfileIds = [
          ...new Set(students.filter((s)=>!s.parent_id_new && s.parent_id).map((s)=>s.parent_id))
        ];
        const seenRecipient = new Set();
        let parentIdsLoaded = new Set();
        if (parentIdsFromTable.length > 0) {
          const { data: parentData } = await supabase.from('parents').select('id, email, first_name, last_name, phone').in('id', parentIdsFromTable).is('deleted_at', null);
          const parentRows = parentData || [];
          parentIdsLoaded = new Set(parentRows.map((p)=>p.id));
          const { data: allPeRows } = await supabase.from('parent_emails').select('parent_id, email, is_primary, created_at').in('parent_id', parentIdsFromTable);
          const byParentPe = {};
          for (const row of allPeRows || []){
            const e = String(row.email || '').trim();
            if (!e) continue;
            const pid = row.parent_id;
            if (!byParentPe[pid]) byParentPe[pid] = [];
            byParentPe[pid].push({
              email: e,
              is_primary: !!row.is_primary,
              created_at: String(row.created_at || '')
            });
          }
          // Resolve email from parent_emails when parents.email is empty (prefer is_primary, else oldest row)
          const parentIdsNeedingEmail = parentRows.filter((p)=>!p.email || !String(p.email).trim()).map((p)=>p.id);
          for (const pid of parentIdsNeedingEmail){
            const list = byParentPe[pid];
            if (!list?.length) continue;
            const primary = list.find((x)=>x.is_primary);
            const rest = [
              ...list
            ].sort((a, b)=>a.created_at.localeCompare(b.created_at));
            const chosen = primary?.email ?? rest[0]?.email;
            const p = parentRows.find((x)=>x.id === pid);
            if (p && chosen) p.email = chosen;
          }
          // When students link both parents.id and profiles.id, login contact may only exist on profiles
          const profileIdsForParents = new Set();
          for (const p of parentRows){
            const needEmail = !p.email || !String(p.email).trim();
            const needPhone = !p.phone || !String(p.phone).trim();
            if (!needEmail && !needPhone) continue;
            const st = students.find((s)=>s.parent_id_new === p.id && s.parent_id);
            if (st?.parent_id) profileIdsForParents.add(st.parent_id);
          }
          if (profileIdsForParents.size > 0) {
            const { data: linkProfiles } = await supabase.from('profiles').select('id, email, phone').in('id', [
              ...profileIdsForParents
            ]);
            const profById = new Map((linkProfiles || []).map((pr)=>[
                pr.id,
                pr
              ]));
            for (const p of parentRows){
              const st = students.find((s)=>s.parent_id_new === p.id && s.parent_id);
              if (!st?.parent_id) continue;
              const prof = profById.get(st.parent_id);
              if (!prof) continue;
              if (!p.email || !String(p.email).trim()) {
                const em = prof.email ? String(prof.email).trim() : '';
                if (em) p.email = em;
              }
              if (!p.phone || !String(p.phone).trim()) {
                const ph = prof.phone ? String(prof.phone).trim() : '';
                if (ph) p.phone = ph;
              }
            }
          }
          // Fill gaps when CRM row is sparse but auth profile exists under parent_emails / same email
          for (const p of parentRows){
            const needEmail = !p.email || !String(p.email).trim();
            const needPhone = !p.phone || !String(p.phone).trim();
            if (!needEmail && !needPhone) continue;
            const extras = byParentPe[p.id] || [];
            const candidates = [
              ...new Set([
                ...p.email ? [
                  String(p.email).trim()
                ] : [],
                ...extras.map((x)=>x.email).filter(Boolean)
              ])
            ];
            for (const em of candidates){
              const { data: profMatch } = await supabase.from('profiles').select('id, email, phone').ilike('email', em).limit(1);
              const prof = profMatch?.[0];
              if (!prof) continue;
              if (!p.email || !String(p.email).trim()) {
                const pem = prof.email ? String(prof.email).trim() : '';
                if (pem) p.email = pem;
              }
              if (!p.phone || !String(p.phone).trim()) {
                const ph = prof.phone ? String(prof.phone).trim() : '';
                if (ph) p.phone = ph;
              }
              if (p.email && String(p.email).trim() && p.phone && String(p.phone).trim()) break;
            }
          }
          for (const p of parentRows){
            if (!p?.id || seenRecipient.has(p.id)) continue;
            seenRecipient.add(p.id);
            const prefsUserId = students.find((s)=>s.parent_id_new === p.id && s.parent_id)?.parent_id ?? null;
            parentRecipients.push({
              recipientId: p.id,
              first_name: p.first_name ?? null,
              last_name: p.last_name ?? null,
              email: p.email ? String(p.email).trim() || null : null,
              phone: p.phone ? String(p.phone).trim() || null : null,
              source: 'parents',
              prefsUserId
            });
          }
        }
        // Parent row missing or soft-deleted but student still links parents.id + legacy profile
        const fallbackProfileIds = [
          ...new Set(students.filter((s)=>s.parent_id_new && s.parent_id && !parentIdsLoaded.has(s.parent_id_new)).map((s)=>s.parent_id))
        ];
        if (fallbackProfileIds.length > 0) {
          const { data: fbProfiles } = await supabase.from('profiles').select('id, email, first_name, last_name, phone').in('id', fallbackProfileIds);
          for (const pr of fbProfiles || []){
            if (!pr?.id || seenRecipient.has(pr.id)) continue;
            seenRecipient.add(pr.id);
            parentRecipients.push({
              recipientId: pr.id,
              first_name: pr.first_name ?? null,
              last_name: pr.last_name ?? null,
              email: pr.email ? String(pr.email).trim() || null : null,
              phone: pr.phone ? String(pr.phone).trim() || null : null,
              source: 'profile',
              prefsUserId: pr.id
            });
          }
        }
        if (legacyProfileIds.length > 0) {
          const { data: profileParents } = await supabase.from('profiles').select('id, email, first_name, last_name, phone').in('id', legacyProfileIds);
          for (const pr of profileParents || []){
            if (!pr?.id || seenRecipient.has(pr.id)) continue;
            seenRecipient.add(pr.id);
            parentRecipients.push({
              recipientId: pr.id,
              first_name: pr.first_name ?? null,
              last_name: pr.last_name ?? null,
              email: pr.email ? String(pr.email).trim() || null : null,
              phone: pr.phone ? String(pr.phone).trim() || null : null,
              source: 'profile',
              prefsUserId: pr.id
            });
          }
        }
      }
      // Fetch teacher profiles
      let teacherProfiles = [];
      if (teacherIds.length > 0) {
        const { data: tData } = await supabase.from('profiles').select('id, email, first_name, last_name, phone').in('id', teacherIds);
        teacherProfiles = tData || [];
      }
      const teacherNames = teacherProfiles.map((t)=>`${t.first_name || ''} ${t.last_name || ''}`.trim()).filter(Boolean).join(', ') || 'Your Instructor';
      const studentList = students.map((s)=>`${s.first_name} ${s.last_name || ''}`.trim());
      const studentCount = studentList.length;
      const startTime = timeSlot?.start || '';
      const endTime = timeSlot?.end || '';
      const scheduleDisplay = `${days.join(', ')} | ${formatTimeDisplay(startTime)} – ${formatTimeDisplay(endTime)}`;
      // ── Teacher notifications ────────────────────────────────
      if (teacherProfiles.length > 0 && (teacherEmail || teacherSms)) {
        for (const teacher of teacherProfiles){
          const { data: existing } = await supabase.from('class_reminder_logs').select('id').eq('batch_id', batch.id).eq('class_date', today).eq('reminder_type', 'teacher').eq('recipient_id', teacher.id).maybeSingle();
          if (existing) continue;
          const notifLogs = [];
          const teacherAllowSms = teacherSms && teacher.phone && await profileMayReceive(supabase, teacher.id, 'sms', 'reminder', {
            requireClassReminders: true
          });
          if (teacherAllowSms) {
            const smsBodyContent = `Hi ${teacher.first_name || 'Teacher'}, your class starts in ~${minutesUntilClass} minutes!\n\n` + `📚 ${friendlyClassName}\n` + `⏰ ${scheduleDisplay}\n\n` + `📧 The meeting link has been sent to your email.`;
            const smsMsg = wrapSmsBody(smsTemplate, smsBodyContent);
            const smsOk = await sendSMSDirect(teacher.phone, smsMsg);
            notifLogs.push({
              batch_id: batch.id,
              notification_type: 'sms',
              trigger_type: 'reminder',
              recipient_type: 'teacher',
              recipient_id: teacher.id,
              recipient_name: `${teacher.first_name || ''} ${teacher.last_name || ''}`.trim(),
              recipient_contact: teacher.phone,
              subject: `Class reminder - ${friendlyClassName}`,
              status: smsOk ? 'sent' : 'failed',
              sent_by: 'system'
            });
          }
          const teacherAllowEmail = teacherEmail && teacher.email && await profileMayReceive(supabase, teacher.id, 'email', 'reminder', {
            requireClassReminders: true
          });
          if (teacherAllowEmail) {
            const studentRows = studentList.length > 0 ? studentList.map((name)=>`<tr><td style="padding:8px 14px;border-bottom:1px solid #f0f0f0;color:#333;">• ${name}</td></tr>`).join('') : '<tr><td style="padding:8px 14px;color:#999;">No students enrolled</td></tr>';
            const emailSubject = `⏰ Your class "${friendlyClassName}" starts in ${minutesUntilClass} minutes`;
            const emailBody = `
              <div style="font-family:Arial,sans-serif;max-width:620px;margin:0 auto;background:#ffffff;border-radius:12px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08);">
                <div style="background:linear-gradient(135deg,#1a237e 0%,#283593 100%);padding:24px 32px;">
                  <p style="color:#9fa8da;margin:0 0 4px;font-size:12px;letter-spacing:1px;text-transform:uppercase;">KidNCode · Teacher Reminder</p>
                  <h1 style="color:#ffffff;margin:0;font-size:20px;font-weight:700;">⏰ Class Starting in ${minutesUntilClass} Minutes</h1>
                </div>
                <div style="padding:28px 32px;">
                  <p style="color:#333;margin:0 0 6px;font-size:15px;">Hi <strong>${teacher.first_name || 'Teacher'}</strong>,</p>
                  <p style="color:#555;margin:0 0 20px;font-size:14px;line-height:1.6;">Your class <strong>${friendlyClassName}</strong> begins in approximately <strong style="color:#c62828;">${minutesUntilClass} minutes</strong>. Here's a quick summary:</p>

                  <table style="width:100%;border-collapse:collapse;border-radius:8px;overflow:hidden;border:1px solid #e8eaf6;margin-bottom:18px;">
                    <tr style="background:#e8eaf6;">
                      <td style="padding:10px 14px;font-weight:700;color:#1a237e;font-size:13px;width:130px;">Class</td>
                      <td style="padding:10px 14px;color:#333;font-size:14px;"><strong>${friendlyClassName}</strong></td>
                    </tr>
                    <tr style="background:#fafafa;">
                      <td style="padding:10px 14px;font-weight:700;color:#555;font-size:13px;">Schedule</td>
                      <td style="padding:10px 14px;color:#333;font-size:14px;">${days.join(', ')}</td>
                    </tr>
                    <tr style="background:#e8eaf6;">
                      <td style="padding:10px 14px;font-weight:700;color:#1a237e;font-size:13px;">Time</td>
                      <td style="padding:10px 14px;color:#333;font-size:14px;"><strong>${formatTimeDisplay(startTime)} – ${formatTimeDisplay(endTime)}</strong></td>
                    </tr>
                    <tr style="background:#fafafa;">
                      <td style="padding:10px 14px;font-weight:700;color:#555;font-size:13px;">Students</td>
                      <td style="padding:10px 14px;color:#333;font-size:14px;">${studentCount} enrolled</td>
                    </tr>
                  </table>

                  ${batch.online_meeting_link ? `
                  <div style="background:#e3f2fd;border-left:4px solid #1565c0;padding:14px 18px;border-radius:6px;margin-bottom:18px;">
                    <p style="margin:0 0 5px;font-weight:700;color:#1565c0;font-size:14px;">📹 Meeting Link</p>
                    <a href="${batch.online_meeting_link}" style="color:#1565c0;font-size:14px;word-break:break-all;">${batch.online_meeting_link}</a>
                  </div>` : ''}

                  <h3 style="color:#1a237e;margin:0 0 8px;font-size:14px;">👩‍🎓 Students Today (${studentCount})</h3>
                  <table style="width:100%;border-collapse:collapse;border:1px solid #e0e0e0;border-radius:6px;overflow:hidden;margin-bottom:18px;">
                    ${studentRows}
                  </table>

                  ${batch.meeting_instructions ? `
                  <div style="background:#fff8e1;border-left:4px solid #f9a825;padding:14px 18px;border-radius:6px;margin-bottom:14px;">
                    <p style="margin:0 0 5px;font-weight:700;color:#f57f17;font-size:14px;">📌 Parent / Student Instructions</p>
                    <p style="margin:0;color:#555;font-size:13px;line-height:1.6;">${batch.meeting_instructions.replace(/\n/g, '<br/>')}</p>
                  </div>` : ''}

                  ${batch.meeting_instructions_teacher ? `
                  <div style="background:#fce4ec;border-left:4px solid #c62828;padding:14px 18px;border-radius:6px;margin-bottom:14px;">
                    <p style="margin:0 0 5px;font-weight:700;color:#c62828;font-size:14px;">🔒 Teacher-Only Notes</p>
                    <p style="margin:0;color:#555;font-size:13px;line-height:1.6;">${batch.meeting_instructions_teacher.replace(/\n/g, '<br/>')}</p>
                  </div>` : ''}

                  <p style="color:#999;margin:24px 0 0;font-size:13px;border-top:1px solid #f0f0f0;padding-top:14px;">Best regards,<br/><strong style="color:#555;">KidNCode Team</strong></p>
                </div>
              </div>
            `;
            const emailOk = await sendEmailDirect(teacher.email, emailSubject, emailBody, fromAddress);
            notifLogs.push({
              batch_id: batch.id,
              notification_type: 'email',
              trigger_type: 'reminder',
              recipient_type: 'teacher',
              recipient_id: teacher.id,
              recipient_name: `${teacher.first_name || ''} ${teacher.last_name || ''}`.trim(),
              recipient_contact: teacher.email,
              subject: emailSubject,
              status: emailOk ? 'sent' : 'failed',
              sent_by: 'system'
            });
          }
          if (notifLogs.length > 0) {
            const { error: logErr } = await supabase.from('batch_notification_logs').insert(notifLogs);
            if (logErr) console.error('Notification log error:', logErr);
            await supabase.from('class_reminder_logs').insert({
              batch_id: batch.id,
              class_date: today,
              reminder_type: 'teacher',
              recipient_id: teacher.id
            }).catch(()=>{});
            remindersSent++;
          }
        }
      }
      // ── Parent notifications ─────────────────────────────────
      if ((parentEmail || parentSms) && studentIds.length > 0 && parentRecipients.length === 0) {
        console.warn(`Pre-class parent reminders: no recipients resolved for batch ${batch.id} (${students.length} students). Check students.parent_id_new / parent_id.`);
      }
      if ((parentEmail || parentSms) && parentRecipients.length > 0) {
        for (const parent of parentRecipients){
          const childrenInBatch = students.filter((s)=>{
            if (parent.source === 'parents') return s.parent_id_new === parent.recipientId;
            return s.parent_id === parent.recipientId;
          }).map((s)=>`${s.first_name} ${s.last_name || ''}`.trim());
          const childNamesText = childrenInBatch.join(', ') || 'your child';
          const parentDisplayName = `${parent.first_name || ''} ${parent.last_name || ''}`.trim() || 'Parent';
          const { data: existing } = await supabase.from('class_reminder_logs').select('id').eq('batch_id', batch.id).eq('class_date', today).eq('reminder_type', 'parent').eq('recipient_id', parent.recipientId).maybeSingle();
          if (existing) continue;
          const notifLogs = [];
          const parentRecipient = {
            source: parent.source,
            recipientId: parent.recipientId,
            email: parent.email,
            prefsUserId: parent.prefsUserId ?? undefined
          };
          const parentAllowSms = parentSms && parent.phone && await parentMayReceive(supabase, parentRecipient, 'sms', 'reminder');
          if (parentAllowSms) {
            const smsBodyContent = `Hi ${parent.first_name || 'Parent'}, ${childNamesText}'s class starts in ~${minutesUntilClass} minutes!\n\n` + `📚 ${friendlyClassName}\n` + `⏰ ${formatTimeDisplay(startTime)} – ${formatTimeDisplay(endTime)}` + (batch.meeting_instructions ? `\n\n📋 ${batch.meeting_instructions.split('\n')[0]}` : '') + `\n\n🔗 The meeting link has been sent to your email and is also available in your Parent Portal dashboard.`;
            const smsMsg = wrapSmsBody(smsTemplate, smsBodyContent);
            const smsOk = await sendSMSDirect(parent.phone, smsMsg);
            notifLogs.push({
              batch_id: batch.id,
              notification_type: 'sms',
              trigger_type: 'reminder',
              recipient_type: 'parent',
              recipient_id: parent.recipientId,
              recipient_name: parentDisplayName,
              recipient_contact: parent.phone,
              subject: `Class reminder - ${friendlyClassName}`,
              status: smsOk ? 'sent' : 'failed',
              sent_by: 'system'
            });
          }
          const parentAllowEmail = parentEmail && parent.email && await parentMayReceive(supabase, parentRecipient, 'email', 'reminder');
          if (parentAllowEmail) {
            const childDisplayHtml = childrenInBatch.map((n)=>`<strong>${n}</strong>`).join(', ');
            const emailSubject = `⏰ ${friendlyClassName} starts in ${minutesUntilClass} minutes — Join now!`;
            const emailBody = `
              <div style="font-family:Arial,sans-serif;max-width:620px;margin:0 auto;background:#ffffff;border-radius:12px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08);">
                <div style="background:linear-gradient(135deg,#1b5e20 0%,#2e7d32 100%);padding:24px 32px;">
                  <p style="color:#a5d6a7;margin:0 0 4px;font-size:12px;letter-spacing:1px;text-transform:uppercase;">KidNCode · Class Reminder</p>
                  <h1 style="color:#ffffff;margin:0;font-size:20px;font-weight:700;">⏰ Class Starting in ${minutesUntilClass} Minutes!</h1>
                </div>
                <div style="padding:28px 32px;">
                  <p style="color:#333;margin:0 0 6px;font-size:15px;">Hi <strong>${parent.first_name || 'Parent'}</strong>,</p>
                  <p style="color:#555;margin:0 0 20px;font-size:14px;line-height:1.6;">
                    Just a heads-up — ${childDisplayHtml}'s class is starting in approximately <strong style="color:#2e7d32;">${minutesUntilClass} minutes</strong>. Time to get ready!
                  </p>

                  <table style="width:100%;border-collapse:collapse;border-radius:8px;overflow:hidden;border:1px solid #c8e6c9;margin-bottom:18px;">
                    <tr style="background:#dcedc8;">
                      <td style="padding:10px 14px;font-weight:700;color:#2e7d32;font-size:13px;width:130px;">Class</td>
                      <td style="padding:10px 14px;color:#333;font-size:15px;"><strong>${friendlyClassName}</strong></td>
                    </tr>
                    <tr style="background:#fafff5;">
                      <td style="padding:10px 14px;font-weight:700;color:#555;font-size:13px;">Instructor</td>
                      <td style="padding:10px 14px;color:#333;font-size:14px;">${teacherNames}</td>
                    </tr>
                    <tr style="background:#dcedc8;">
                      <td style="padding:10px 14px;font-weight:700;color:#2e7d32;font-size:13px;">Time</td>
                      <td style="padding:10px 14px;color:#333;font-size:15px;"><strong>${formatTimeDisplay(startTime)} – ${formatTimeDisplay(endTime)}</strong></td>
                    </tr>
                    <tr style="background:#fafff5;">
                      <td style="padding:10px 14px;font-weight:700;color:#555;font-size:13px;">Schedule</td>
                      <td style="padding:10px 14px;color:#333;font-size:14px;">${days.join(', ')}</td>
                    </tr>
                  </table>

                  ${batch.online_meeting_link ? `
                  <div style="background:#f1f8e9;border:2px solid #66bb6a;padding:20px 24px;border-radius:10px;margin:18px 0;text-align:center;">
                    <p style="margin:0 0 5px;font-weight:700;font-size:15px;color:#2e7d32;">🔗 Join Your Class Now</p>
                    <p style="margin:0 0 14px;color:#666;font-size:13px;">Tap the button below to enter the virtual classroom</p>
                    <a href="${batch.online_meeting_link}" style="display:inline-block;background:#43a047;color:#ffffff;padding:14px 32px;border-radius:8px;text-decoration:none;font-weight:700;font-size:16px;">Join Now</a>
                    <p style="margin:10px 0 0;font-size:11px;color:#999;word-break:break-all;">${batch.online_meeting_link}</p>
                  </div>` : ''}

                  ${batch.meeting_instructions ? `
                  <div style="background:#fff8e1;border-left:4px solid #ff8f00;padding:14px 18px;border-radius:6px;margin-bottom:18px;">
                    <p style="margin:0 0 6px;font-weight:700;color:#e65100;font-size:14px;">📋 How to Join</p>
                    <p style="margin:0;color:#555;font-size:13px;line-height:1.7;">${batch.meeting_instructions.replace(/\n/g, '<br/>')}</p>
                  </div>` : ''}

                  <p style="color:#999;margin:24px 0 0;font-size:13px;border-top:1px solid #f0f0f0;padding-top:14px;">Warm regards,<br/><strong style="color:#555;">KidNCode Team</strong></p>
                </div>
              </div>
            `;
            const emailOk = await sendEmailDirect(parent.email, emailSubject, emailBody, fromAddress);
            notifLogs.push({
              batch_id: batch.id,
              notification_type: 'email',
              trigger_type: 'reminder',
              recipient_type: 'parent',
              recipient_id: parent.recipientId,
              recipient_name: parentDisplayName,
              recipient_contact: parent.email,
              subject: emailSubject,
              status: emailOk ? 'sent' : 'failed',
              sent_by: 'system'
            });
          }
          if (notifLogs.length === 0) {
            const hadContact = parentSms && !!parent.phone || parentEmail && !!parent.email;
            if (!hadContact) {
              console.warn(`Pre-class parent reminder skipped (no email/phone): batch=${batch.id} recipient=${parent.recipientId} source=${parent.source}`);
              continue;
            }
            console.log(`Pre-class parent reminder skipped (notification preferences): batch=${batch.id} recipient=${parent.recipientId}`);
            continue;
          }
          const { error: logErr2 } = await supabase.from('batch_notification_logs').insert(notifLogs);
          if (logErr2) console.error('Notification log error:', logErr2);
          await supabase.from('class_reminder_logs').insert({
            batch_id: batch.id,
            class_date: today,
            reminder_type: 'parent',
            recipient_id: parent.recipientId
          }).catch(()=>{});
          remindersSent++;
        }
      }
    }
    console.log(`Done. Sent ${remindersSent} reminders.`);
    return new Response(JSON.stringify({
      success: true,
      remindersSent
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  } catch (error) {
    console.error('Error in send-class-reminders:', error);
    return new Response(JSON.stringify({
      error: error.message
    }), {
      status: 500,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  }
});
