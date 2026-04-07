import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { addDays, addMonths, differenceInCalendarDays, endOfMonth, getDay, startOfDay, startOfMonth } from "https://esm.sh/date-fns@3.6.0";
// --- Semi-monthly pay YMD helpers (inlined; America/Chicago civil calendar) ---
function ymdParse(ymd) {
  const [y, m, d] = ymd.split("-").map(Number);
  return {
    y,
    m,
    d
  };
}
function daysInMonth(y, m) {
  return new Date(Date.UTC(y, m, 0)).getUTCDate();
}
function ymdFromParts(y, m, day) {
  const dim = daysInMonth(y, m);
  const d = Math.min(Math.max(1, Math.round(day)), dim);
  return `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}
function ymdToUtcNoonDate(ymd) {
  const { y, m, d } = ymdParse(ymd);
  return new Date(Date.UTC(y, m - 1, d, 12, 0, 0));
}
function bumpMonth(y, m) {
  if (m === 12) return {
    y: y + 1,
    m: 1
  };
  return {
    y,
    m: m + 1
  };
}
function nextSemiMonthlyPayYmd(todayYmd, d1, d2) {
  const L = Math.min(d1, d2);
  const H = Math.max(d1, d2);
  const { y: sy, m: sm } = ymdParse(todayYmd);
  let y = sy;
  let m = sm;
  for(let guard = 0; guard < 48; guard++){
    const a = ymdFromParts(y, m, L);
    const b = ymdFromParts(y, m, H);
    const cands = a <= b ? [
      a,
      b
    ] : [
      b,
      a
    ];
    for (const py of cands){
      if (py >= todayYmd) return py;
    }
    const n = bumpMonth(y, m);
    y = n.y;
    m = n.m;
  }
  return todayYmd;
}
function semiPeriodYmds(payYmd, d1, d2) {
  const L = Math.min(d1, d2);
  const H = Math.max(d1, d2);
  const { y, m } = ymdParse(payYmd);
  const ymdL = ymdFromParts(y, m, L);
  const ymdH = ymdFromParts(y, m, H);
  if (payYmd === ymdL) {
    let py = y;
    let pm = m - 1;
    if (pm < 1) {
      pm = 12;
      py -= 1;
    }
    const periodStart = ymdFromParts(py, pm, H);
    const periodEnd = L > 1 ? ymdFromParts(y, m, L - 1) : ymdFromParts(py, pm, daysInMonth(py, pm));
    return {
      start: periodStart,
      end: periodEnd
    };
  }
  if (payYmd === ymdH) {
    return {
      start: ymdFromParts(y, m, L),
      end: ymdFromParts(y, m, H - 1)
    };
  }
  return {
    start: ymdFromParts(y, m, L),
    end: ymdFromParts(y, m, H - 1)
  };
}
function clampDayOfMonth(n) {
  if (!Number.isFinite(n)) return 1;
  return Math.min(31, Math.max(1, Math.round(n)));
}
function clampDayOfWeek(n) {
  if (!Number.isFinite(n)) return 5;
  return Math.min(6, Math.max(0, Math.round(n)));
}
function normalizeHrPayPeriodConfig(p) {
  const base = {
    frequency: "semi_monthly",
    weeklyEndDayOfWeek: 5,
    semiMonthlyDay1: 1,
    semiMonthlyDay2: 15,
    monthlyDayOfMonth: 1
  };
  if (!p || typeof p !== "object") return base;
  const freq = p.frequency;
  const frequency = freq === "weekly" || freq === "semi_monthly" || freq === "monthly" ? freq : base.frequency;
  return {
    frequency,
    weeklyEndDayOfWeek: clampDayOfWeek(p.weeklyEndDayOfWeek ?? base.weeklyEndDayOfWeek),
    semiMonthlyDay1: clampDayOfMonth(p.semiMonthlyDay1 ?? base.semiMonthlyDay1),
    semiMonthlyDay2: clampDayOfMonth(p.semiMonthlyDay2 ?? base.semiMonthlyDay2),
    monthlyDayOfMonth: clampDayOfMonth(p.monthlyDayOfMonth ?? base.monthlyDayOfMonth)
  };
}
function parseHrPayPeriodConfigJson(raw) {
  if (!raw?.trim()) return normalizeHrPayPeriodConfig(null);
  try {
    const j = JSON.parse(raw);
    return normalizeHrPayPeriodConfig(j);
  } catch  {
    return normalizeHrPayPeriodConfig(null);
  }
}
function dateInCalendarMonth(year, monthIndex0, day) {
  const dim = endOfMonth(new Date(year, monthIndex0, 1)).getDate();
  const d = Math.min(Math.max(1, day), dim);
  return startOfDay(new Date(year, monthIndex0, d));
}
function nextWeeklyPayDate(now, endDow) {
  const t0 = startOfDay(now);
  for(let i = 0; i < 370; i++){
    const d = addDays(t0, i);
    if (getDay(d) === endDow) return d;
  }
  return t0;
}
function weeklySnapshot(now, config) {
  const nextPayDate = nextWeeklyPayDate(now, config.weeklyEndDayOfWeek);
  const periodEnd = nextPayDate;
  const periodStart = addDays(nextPayDate, -6);
  const daysUntil = differenceInCalendarDays(startOfDay(nextPayDate), startOfDay(now));
  return {
    frequency: "weekly",
    nextPayDate,
    periodStart,
    periodEnd,
    daysUntil
  };
}
function nextMonthlyPayDate(now, dayOfMonth) {
  const t0 = startOfDay(now);
  for(let i = 0; i < 24; i++){
    const d = addMonths(startOfMonth(t0), i);
    const y = d.getFullYear();
    const m = d.getMonth();
    const pay = dateInCalendarMonth(y, m, dayOfMonth);
    if (pay >= t0) return pay;
  }
  return dateInCalendarMonth(t0.getFullYear(), t0.getMonth(), dayOfMonth);
}
function monthlySnapshot(now, config) {
  const nextPayDate = nextMonthlyPayDate(now, config.monthlyDayOfMonth);
  const prevMonthStart = startOfMonth(addMonths(nextPayDate, -1));
  const periodStart = prevMonthStart;
  const periodEnd = endOfMonth(addMonths(nextPayDate, -1));
  const daysUntil = differenceInCalendarDays(startOfDay(nextPayDate), startOfDay(now));
  return {
    frequency: "monthly",
    nextPayDate,
    periodStart,
    periodEnd,
    daysUntil
  };
}
function semiSnapshot(now, config) {
  const L = Math.min(config.semiMonthlyDay1, config.semiMonthlyDay2);
  const H = Math.max(config.semiMonthlyDay1, config.semiMonthlyDay2);
  if (L === H) {
    return monthlySnapshot(now, {
      ...config,
      frequency: "monthly",
      monthlyDayOfMonth: L
    });
  }
  const todayYmd = now.toLocaleDateString("en-CA", {
    timeZone: "America/Chicago"
  });
  const payYmd = nextSemiMonthlyPayYmd(todayYmd, config.semiMonthlyDay1, config.semiMonthlyDay2);
  const { start: psYmd, end: peYmd } = semiPeriodYmds(payYmd, config.semiMonthlyDay1, config.semiMonthlyDay2);
  const nextPayDate = ymdToUtcNoonDate(payYmd);
  const periodStart = ymdToUtcNoonDate(psYmd);
  const periodEnd = ymdToUtcNoonDate(peYmd);
  const anchorDay = startOfDay(ymdToUtcNoonDate(todayYmd));
  const daysUntil = differenceInCalendarDays(startOfDay(nextPayDate), anchorDay);
  return {
    frequency: "semi_monthly",
    nextPayDate,
    periodStart,
    periodEnd,
    daysUntil
  };
}
function getNextPayrollSnapshot(now, config) {
  switch(config.frequency){
    case "weekly":
      return weeklySnapshot(now, config);
    case "monthly":
      return monthlySnapshot(now, config);
    case "semi_monthly":
      return semiSnapshot(now, config);
    default:
      return semiSnapshot(now, config);
  }
}
// --- Edge handler ---
const JOB_ID = "hr-pay-preparation-reminder";
const HR_PAY_PERIOD_CONFIG_KEY = "hr_pay_period_config";
const SETTING_KEYS = [
  "hr_head_name",
  "hr_head_email",
  "hr_head_phone",
  "hr_pay_prep_reminder_enabled",
  "hr_pay_prep_reminder_email_enabled",
  "hr_pay_prep_reminder_sms_enabled",
  "hr_pay_prep_reminder_last_sent_at",
  "hr_pay_prep_reminder_last_pay_date_ymd"
];
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type"
};
function todayYmdChicago() {
  return new Date().toLocaleDateString("en-CA", {
    timeZone: "America/Chicago"
  });
}
function dateToYmdPayrollCalendar(d) {
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}
function formatYmdLongChicago(ymd) {
  const [y, m, d] = ymd.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d, 12, 0, 0));
  return dt.toLocaleDateString("en-US", {
    timeZone: "America/Chicago",
    weekday: "long",
    year: "numeric",
    month: "long",
    day: "numeric"
  });
}
function addDaysYmdUtc(ymd, delta) {
  const [Y, M, D] = ymd.split("-").map(Number);
  const t = Date.UTC(Y, M - 1, D + delta);
  const x = new Date(t);
  const yy = x.getUTCFullYear();
  const mm = String(x.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(x.getUTCDate()).padStart(2, "0");
  return `${yy}-${mm}-${dd}`;
}
function normalizePhoneE164(raw) {
  if (!raw) return null;
  const d = String(raw).replace(/\D/g, "");
  if (d.length === 10) return `+1${d}`;
  if (d.length === 11 && d.startsWith("1")) return `+${d}`;
  if (d.length >= 10 && d.length <= 15) return `+${d}`;
  return null;
}
async function loadSettingsMap(supabase) {
  const keys = [
    ...SETTING_KEYS,
    HR_PAY_PERIOD_CONFIG_KEY
  ];
  const { data, error } = await supabase.from("system_settings").select("property_name, value").in("property_name", keys);
  if (error) throw error;
  const m = {};
  for (const r of data || []){
    m[String(r.property_name)] = String(r.value ?? "").trim();
  }
  return m;
}
async function upsertSetting(admin, property_name, value) {
  const { data: existing } = await admin.from("system_settings").select("id").eq("property_name", property_name).maybeSingle();
  if (existing?.id) {
    const { error } = await admin.from("system_settings").update({
      value,
      updated_at: new Date().toISOString()
    }).eq("id", existing.id);
    if (error) throw error;
  } else {
    const { error } = await admin.from("system_settings").insert({
      property_name,
      value,
      is_system: true,
      updated_at: new Date().toISOString()
    });
    if (error) throw error;
  }
}
async function sendDigestEmail(params) {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${params.resendKey}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      from: params.fromAddress,
      to: params.to,
      subject: params.subject,
      html: params.htmlBody
    })
  });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`Resend: ${t}`);
  }
}
async function isAuthorized(req, supabaseUrl, supabaseAnonKey, serviceRoleKey) {
  const authz = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  if (!authz) return {
    ok: false,
    reason: "missing_authorization"
  };
  if (authz === serviceRoleKey) return {
    ok: true
  };
  const userClient = createClient(supabaseUrl, supabaseAnonKey, {
    global: {
      headers: {
        Authorization: `Bearer ${authz}`
      }
    }
  });
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) return {
    ok: false,
    reason: "invalid_user"
  };
  const admin = createClient(supabaseUrl, serviceRoleKey);
  const { data: roleRow } = await admin.from("user_roles").select("role").eq("user_id", user.id).maybeSingle();
  const role = roleRow?.role;
  if (role === "hr" || role === "admin" || role === "super_admin") return {
    ok: true
  };
  return {
    ok: false,
    reason: "forbidden_role"
  };
}
Deno.serve(async (req)=>{
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: corsHeaders
    });
  }
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || "";
    const resendKey = Deno.env.get("RESEND_API_KEY");
    let reqBody = {};
    try {
      if (req.method === "POST" && req.headers.get("content-type")?.includes("application/json")) {
        reqBody = await req.json();
      }
    } catch  {
      reqBody = {};
    }
    const sendNow = reqBody.sendNow === true;
    const source = sendNow ? "manual" : "scheduled";
    if (!anonKey) {
      return new Response(JSON.stringify({
        error: "Server misconfiguration: SUPABASE_ANON_KEY"
      }), {
        status: 500,
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }
    const auth = await isAuthorized(req, supabaseUrl, anonKey, serviceRoleKey);
    if (!auth.ok) {
      return new Response(JSON.stringify({
        error: "Unauthorized",
        detail: auth.reason
      }), {
        status: 401,
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }
    const admin = createClient(supabaseUrl, serviceRoleKey);
    const settings = await loadSettingsMap(admin);
    const reminderEnabled = settings.hr_pay_prep_reminder_enabled !== "false";
    const emailDefault = settings.hr_pay_prep_reminder_email_enabled !== "false";
    const smsDefault = settings.hr_pay_prep_reminder_sms_enabled === "true";
    let emailOn;
    let smsOn;
    if (sendNow) {
      if (reqBody.email === undefined && reqBody.sms === undefined) {
        emailOn = true;
        smsOn = false;
      } else {
        emailOn = reqBody.email === true;
        smsOn = reqBody.sms === true;
      }
    } else {
      emailOn = emailDefault;
      smsOn = smsDefault;
    }
    if (source === "scheduled" && !reminderEnabled) {
      return new Response(JSON.stringify({
        ok: true,
        skipped: true,
        reason: "reminder_disabled"
      }), {
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }
    if (source === "scheduled") {
      const { data: cs } = await admin.from("cron_schedules").select("enabled").eq("job_id", JOB_ID).maybeSingle();
      if (cs && cs.enabled === false) {
        return new Response(JSON.stringify({
          ok: true,
          skipped: true,
          reason: "cron_row_paused"
        }), {
          headers: {
            "Content-Type": "application/json",
            ...corsHeaders
          }
        });
      }
    }
    const payConfig = parseHrPayPeriodConfigJson(settings[HR_PAY_PERIOD_CONFIG_KEY]);
    const todayYmd = todayYmdChicago();
    const [ty, tm, td] = todayYmd.split("-").map(Number);
    const nowAnchor = new Date(Date.UTC(ty, tm - 1, td, 12, 0, 0));
    const snap = getNextPayrollSnapshot(nowAnchor, payConfig);
    const payYmd = dateToYmdPayrollCalendar(snap.nextPayDate);
    const reminderYmd = addDaysYmdUtc(payYmd, -3);
    const cpaByYmd = addDaysYmdUtc(payYmd, -1);
    const periodStartYmd = dateToYmdPayrollCalendar(snap.periodStart);
    const periodEndYmd = dateToYmdPayrollCalendar(snap.periodEnd);
    const lastPayYmd = (settings.hr_pay_prep_reminder_last_pay_date_ymd || "").trim();
    if (!sendNow) {
      if (reminderYmd !== todayYmd) {
        return new Response(JSON.stringify({
          ok: true,
          skipped: true,
          reason: "not_reminder_day",
          todayYmd,
          reminderYmd,
          payYmd
        }), {
          headers: {
            "Content-Type": "application/json",
            ...corsHeaders
          }
        });
      }
      if (lastPayYmd === payYmd) {
        return new Response(JSON.stringify({
          ok: true,
          skipped: true,
          reason: "already_sent_for_pay_date",
          payYmd
        }), {
          headers: {
            "Content-Type": "application/json",
            ...corsHeaders
          }
        });
      }
    }
    const hrName = (settings.hr_head_name || "HR").trim() || "HR";
    const hrEmail = (settings.hr_head_email || "").trim();
    const hrPhone = normalizePhoneE164(settings.hr_head_phone);
    if (emailOn && !hrEmail) {
      return new Response(JSON.stringify({
        ok: false,
        error: "hr_head_email missing — add it in HR → Settings."
      }), {
        status: 400,
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }
    if (smsOn && !hrPhone) {
      return new Response(JSON.stringify({
        ok: false,
        error: "hr_head_phone missing — add it in HR → Settings."
      }), {
        status: 400,
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }
    if (!emailOn && !smsOn) {
      return new Response(JSON.stringify({
        ok: true,
        skipped: true,
        reason: "no_channels"
      }), {
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }
    const payLong = formatYmdLongChicago(payYmd);
    const cpaByLong = formatYmdLongChicago(cpaByYmd);
    const periodStartLong = formatYmdLongChicago(periodStartYmd);
    const periodEndLong = formatYmdLongChicago(periodEndYmd);
    const plain = `Payroll reminder: the next pay date is ${payLong}. ` + `This paycheck covers work from ${periodStartLong} through ${periodEndLong}. ` + `Please prepare payslips for your CPA by ${cpaByLong} (the day before pay day).`;
    const bodyHtml = `
    <h2 style="margin:0 0 12px;">Payroll — prepare CPA package</h2>
    <p style="font-size:16px;line-height:1.55;">Hello ${hrName},</p>
    <p style="font-size:16px;line-height:1.55;">${plain}</p>
    <p style="color:#64748b;font-size:13px;margin-top:16px;">This is an automated reminder (3 days before pay day). You can adjust HR Head contact and channels in HR → Settings.</p>
  `;
    const wrapShell = (inner)=>`<!DOCTYPE html><html><head><meta charset="utf-8"/></head><body style="margin:0;padding:24px;font-family:system-ui,sans-serif;background:#f4f7fa;"><div style="max-width:560px;margin:0 auto;background:#fff;border-radius:12px;padding:24px;box-shadow:0 2px 12px rgba(0,0,0,0.06);">${inner}</div></body></html>`;
    const subject = `Payroll: prepare CPA payslips by ${cpaByYmd} (pay day ${payYmd})`;
    let emailOk = false;
    let smsOk = false;
    const errors = [];
    if (emailOn && resendKey && hrEmail) {
      try {
        const { data: tmpl } = await admin.from("email_template_settings").select("from_name, from_email").eq("template_type", "default").order("is_active", {
          ascending: false,
          nullsFirst: false
        }).limit(1).maybeSingle();
        const fromName = tmpl?.from_name && String(tmpl.from_name).trim() || "KidNCode Online";
        const fromEmail = tmpl?.from_email && String(tmpl.from_email).trim() || "noreply@kidncode.com";
        const fromAddress = `${fromName} <${fromEmail}>`;
        await sendDigestEmail({
          resendKey,
          to: [
            hrEmail
          ],
          subject,
          htmlBody: wrapShell(bodyHtml),
          fromAddress
        });
        emailOk = true;
      } catch (e) {
        errors.push(`email: ${String(e?.message ?? e).slice(0, 200)}`);
      }
    } else if (emailOn && !resendKey) {
      errors.push("RESEND_API_KEY not configured");
    }
    if (smsOn && hrPhone) {
      const accountSid = Deno.env.get("TWILIO_ACCOUNT_SID");
      const authToken = Deno.env.get("TWILIO_AUTH_TOKEN");
      const platformPhone = (Deno.env.get("TWILIO_PHONE_NUMBER") || "").trim();
      if (accountSid && authToken && platformPhone) {
        const { data: smsTmpl } = await admin.from("sms_template_settings").select("header_message, footer_message").eq("template_type", "default").eq("is_active", true).order("updated_at", {
          ascending: false,
          nullsFirst: false
        }).limit(1).maybeSingle();
        const head = smsTmpl?.header_message != null ? String(smsTmpl.header_message).trim() : "";
        const foot = smsTmpl?.footer_message != null ? String(smsTmpl.footer_message).trim() : "";
        const core = `${plain}`;
        const wrapped = [
          head,
          core,
          foot
        ].filter(Boolean).join("\n\n").slice(0, 1500);
        let to = hrPhone.replace(/\D/g, "");
        if (!to.startsWith("1") && to.length === 10) to = "1" + to;
        if (!to.startsWith("+")) to = "+" + to;
        try {
          const tw = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`, {
            method: "POST",
            headers: {
              Authorization: "Basic " + btoa(`${accountSid}:${authToken}`),
              "Content-Type": "application/x-www-form-urlencoded"
            },
            body: new URLSearchParams({
              To: to,
              From: platformPhone,
              Body: wrapped
            })
          });
          const tj = await tw.json();
          if (!tw.ok) {
            errors.push(`sms: ${String(tj.message || tw.status)}`);
          } else {
            smsOk = true;
          }
        } catch (e) {
          errors.push(`sms: ${String(e?.message ?? e).slice(0, 120)}`);
        }
      } else {
        errors.push("Twilio not fully configured");
      }
    }
    const anyOk = emailOk || smsOk;
    if (!anyOk && errors.length > 0) {
      return new Response(JSON.stringify({
        ok: false,
        error: errors.join("; ")
      }), {
        status: 502,
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }
    if (anyOk) {
      const sentAt = new Date().toISOString();
      await upsertSetting(admin, "hr_pay_prep_reminder_last_sent_at", sentAt);
      if (!sendNow) {
        await upsertSetting(admin, "hr_pay_prep_reminder_last_pay_date_ymd", payYmd);
      }
    }
    return new Response(JSON.stringify({
      ok: true,
      source,
      payYmd,
      reminderYmd,
      cpaByYmd,
      periodStartYmd,
      periodEndYmd,
      emailSent: emailOk,
      smsSent: smsOk,
      errors: errors.length ? errors : undefined
    }), {
      headers: {
        "Content-Type": "application/json",
        ...corsHeaders
      }
    });
  } catch (e) {
    console.error("send-hr-pay-preparation-reminder:", e);
    return new Response(JSON.stringify({
      error: String(e?.message ?? e)
    }), {
      status: 500,
      headers: {
        "Content-Type": "application/json",
        ...corsHeaders
      }
    });
  }
});
