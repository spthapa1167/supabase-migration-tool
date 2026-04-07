import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { channelB2bConsultation, channelContactForm, channelFromTrialRequestType, mergeCrmTags, mergeInboundMetadata, nextLeadFieldsForInboundMerge } from "../_shared/crmInboundSync.ts";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type"
};
function ageYearsFromDateOfBirth(dobIso, refDateYmd) {
  if (!dobIso) return null;
  const dob = String(dobIso).slice(0, 10);
  const parts = dob.split("-").map((x)=>parseInt(x, 10));
  if (parts.length < 3 || parts.some((n)=>Number.isNaN(n))) return null;
  const [y, m, d] = parts;
  const rparts = refDateYmd.split("-").map((x)=>parseInt(x, 10));
  if (rparts.length < 3 || rparts.some((n)=>Number.isNaN(n))) return null;
  const [ry, rm, rd] = rparts;
  let age = ry - y;
  if (rm < m || rm === m && rd < d) age -= 1;
  return age;
}
/** Roster written to crm_customers.metadata.synced_children on each parent sync (CSR → CRM). */ function buildSyncedChildrenSummary(students, enrollmentsActive, enrollmentsAll, syncRunAtIso) {
  const refYmd = syncRunAtIso.slice(0, 10);
  return students.map((st)=>{
    const allForStudent = enrollmentsAll.filter((e)=>e.student_id === st.id);
    const activeForStudent = enrollmentsActive.filter((e)=>e.student_id === st.id);
    const withDates = allForStudent.map((e)=>e.enrollment_date).filter((x)=>Boolean(x)).sort();
    const firstEnrolled = withDates.length > 0 ? withDates[0] : null;
    const pickEnrollment = activeForStudent.find((e)=>e.subscription_status === "active" || e.status === "active") || activeForStudent.find((e)=>e.status === "trial") || activeForStudent[0] || null;
    return {
      student_id: st.id,
      first_name: st.first_name,
      last_name: st.last_name,
      display_name: `${st.first_name} ${st.last_name}`.trim(),
      date_of_birth: st.date_of_birth,
      age_years: ageYearsFromDateOfBirth(st.date_of_birth, refYmd),
      grade_level: st.grade_level,
      school_name: st.school_name,
      program_name: pickEnrollment?.programs?.name ?? null,
      center_name: pickEnrollment?.centers?.name ?? null,
      enrollment_status: pickEnrollment?.status ?? null,
      subscription_status: pickEnrollment?.subscription_status ?? null,
      first_enrolled_at: firstEnrolled,
      current_enrollment_date: pickEnrollment?.enrollment_date ?? null,
      monthly_price: pickEnrollment?.monthly_price ?? null
    };
  });
}
/** Load every active parent — never cap with .limit() or "deleted at source" will false-positive for parents outside the page. */ async function fetchAllActiveParents(supabase) {
  const pageSize = 1000;
  const all = [];
  let from = 0;
  for(;;){
    const { data, error } = await supabase.from("parents").select("id, email, phone, first_name, last_name, created_at").is("deleted_at", null).order("id", {
      ascending: true
    }).range(from, from + pageSize - 1);
    if (error) throw error;
    if (!data?.length) break;
    all.push(...data);
    if (data.length < pageSize) break;
    from += pageSize;
  }
  return all;
}
serve(async (req)=>{
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: corsHeaders
    });
  }
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const supabase = createClient(supabaseUrl, serviceKey);
    const rawBody = await req.json().catch(()=>({}));
    const syncType = rawBody.syncType ?? "full";
    const triggerSource = rawBody.triggerSource === "nightly_pg_cron" ? "nightly_pg_cron" : "manual";
    const startTime = Date.now();
    // Create sync log for customers
    const { data: logEntry } = await supabase.from("crm_sync_logs").insert({
      sync_type: "customers",
      status: "running",
      started_at: new Date().toISOString(),
      trigger_source: triggerSource
    }).select().single();
    let recordsProcessed = 0;
    let recordsCreated = 0;
    let recordsUpdated = 0;
    let recordsFailed = 0;
    // Full active parent list + iterate all — required so "deleted at source" never marks parents missing only due to .limit()
    const parents = await fetchAllActiveParents(supabase);
    const activeParentIds = new Set(parents.map((p)=>p.id));
    const syncRunAt = new Date().toISOString();
    for (const parent of parents){
      recordsProcessed++;
      try {
        // Get students for this parent
        const { data: students, count: studentCount } = await supabase.from("students").select("id, first_name, last_name, date_of_birth, grade_level, school_name", {
          count: "exact"
        }).eq("parent_id_new", parent.id).is("deleted_at", null);
        const studentRows = students || [];
        const studentIds = studentRows.map((s)=>s.id);
        // Get enrollment info: include soft-deleted so we can set "Soft Deleted" in CRM when all enrollments are soft-deleted
        let enrollmentsActive = [];
        let enrollmentsAll = [];
        if (studentIds.length > 0) {
          const { data: enrActive } = await supabase.from("enrollments").select("id, status, subscription_status, enrollment_date, monthly_price, student_id, program_id, center_id, programs(name), centers(name)").in("student_id", studentIds).is("deleted_at", null).neq("status", "deleted").order("enrollment_date", {
            ascending: false
          });
          enrollmentsActive = enrActive || [];
          const { data: enrAll } = await supabase.from("enrollments").select("id, deleted_at, status, subscription_status, enrollment_date, student_id, program_id, programs(name)").in("student_id", studentIds).order("enrollment_date", {
            ascending: false
          });
          enrollmentsAll = enrAll || [];
        }
        const isEnrollmentSoftDeleted = (e)=>!!e.deleted_at || e.status === "deleted" || e.subscription_status === "deleted";
        const hasSoftDeletedEnrollment = enrollmentsAll.some(isEnrollmentSoftDeleted);
        const hasNonSoftDeletedEnrollment = enrollmentsAll.some((e)=>!isEnrollmentSoftDeleted(e));
        const hasOnlySoftDeleted = hasSoftDeletedEnrollment && !hasNonSoftDeletedEnrollment;
        // Prefer the source enrollment's actual deleted_at timestamp for history/UI.
        // If enrollment(s) are marked deleted without a deleted_at value, fall back to sync time.
        const earliestSoftDeletedAt = (()=>{
          let minMs = null;
          for (const e of enrollmentsAll){
            const v = e?.deleted_at;
            if (!v) continue;
            const t = new Date(v).getTime();
            if (Number.isNaN(t)) continue;
            if (minMs === null || t < minMs) minMs = t;
          }
          return minMs ? new Date(minMs).toISOString() : null;
        })();
        // Determine customer status from active enrollments; if only soft-deleted enrollments remain, CRM shows "Soft Deleted at source"
        let customerStatus = "prospect";
        if (hasOnlySoftDeleted) {
          customerStatus = "source_soft_deleted";
        } else {
          const activeEnrollments = enrollmentsActive.filter((e)=>e.subscription_status === "active" || e.status === "active");
          const trialEnrollments = enrollmentsActive.filter((e)=>e.status === "trial");
          if (activeEnrollments.length > 0) customerStatus = "enrolled";
          else if (trialEnrollments.length > 0) customerStatus = "trial";
          else if (enrollmentsActive.length > 0) customerStatus = "churned";
        }
        const customerType = (studentCount || 0) > 1 ? "family" : "individual";
        // Find existing by parent_id first, then by email (canonical key) to avoid duplicates
        const { data: existingByParent } = await supabase.from("crm_customers").select("id, metadata").eq("parent_id", parent.id).maybeSingle();
        let existing = existingByParent;
        if (!existing && parent.email) {
          const normEmail = String(parent.email).trim().toLowerCase();
          const { data: existingByEmail } = await supabase.from("crm_customers").select("id, metadata").ilike("email", normEmail).limit(1).maybeSingle();
          existing = existingByEmail;
        }
        let prevSourceSoftDeletedAt = null;
        if (existing?.id) {
          const { data: prevRow } = await supabase.from("crm_customers").select("source_soft_deleted_at").eq("id", existing.id).maybeSingle();
          prevSourceSoftDeletedAt = prevRow?.source_soft_deleted_at ?? null;
        }
        const syncedChildren = buildSyncedChildrenSummary(studentRows, enrollmentsActive, enrollmentsAll, syncRunAt);
        const prevMeta = existing?.metadata && typeof existing.metadata === "object" && !Array.isArray(existing.metadata) ? {
          ...existing.metadata
        } : {};
        const mergedMetadata = {
          ...prevMeta,
          synced_children: syncedChildren,
          synced_children_at: syncRunAt
        };
        // Keep the first-detected timestamp for soft-deletes; do not bump every sync.
        // Prefer the enrollment's real deleted_at timestamp when available.
        const nextSourceSoftDeletedAt = hasOnlySoftDeleted ? prevSourceSoftDeletedAt ?? earliestSoftDeletedAt ?? syncRunAt : null;
        const payload = {
          email: parent.email,
          phone: parent.phone,
          first_name: parent.first_name,
          last_name: parent.last_name,
          customer_status: customerStatus,
          customer_type: customerType,
          total_students: studentCount || 0,
          last_synced_at: syncRunAt,
          parent_id: parent.id,
          deleted_from_source_at: null,
          source_soft_deleted_at: nextSourceSoftDeletedAt,
          metadata: mergedMetadata
        };
        let crmCustomerId;
        if (existing) {
          await supabase.from("crm_customers").update(payload).eq("id", existing.id);
          crmCustomerId = existing.id;
          recordsUpdated++;
          try {
            if (hasOnlySoftDeleted && !prevSourceSoftDeletedAt) {
              const at = nextSourceSoftDeletedAt ?? syncRunAt;
              await supabase.from("crm_customer_history").insert({
                customer_id: existing.id,
                event_type: "soft_deleted_at_source",
                event_at: at,
                metadata: {
                  message: `Customer enrollment(s) soft-deleted in the source system (source deleted_at: ${at}). First detected on sync: ${syncRunAt}.`,
                  enrollment_soft_deleted_at: at,
                  sync_run_at: syncRunAt
                }
              });
            } else if (!hasOnlySoftDeleted && prevSourceSoftDeletedAt) {
              await supabase.from("crm_customer_history").insert({
                customer_id: existing.id,
                event_type: "restored_at_source",
                event_at: syncRunAt,
                metadata: {
                  message: "Customer enrollment(s) active again in the source system (sync).",
                  sync_run_at: syncRunAt
                }
              });
            }
          } catch (histErr) {
            console.warn("crm_customer_history insert (soft delete):", histErr);
          }
        } else {
          const { data: newCustomer } = await supabase.from("crm_customers").insert({
            ...payload,
            first_contact_at: parent.created_at
          }).select("id").single();
          crmCustomerId = newCustomer?.id;
          recordsCreated++;
        }
        // --- Sync Transactions (payments) as interactions ---
        if (crmCustomerId) {
          const { data: payments } = await supabase.from("payments").select("id, amount, status, payment_date, payment_method, description, stripe_payment_intent_id, created_at").eq("parent_id", parent.id).order("payment_date", {
            ascending: false
          }).limit(100);
          for (const payment of payments || []){
            // Check if this payment is already logged
            const { data: existingInt } = await supabase.from("crm_interactions").select("id").eq("customer_id", crmCustomerId).eq("interaction_type", "note").eq("subject", `Payment #${payment.id.substring(0, 8)}`).maybeSingle();
            if (!existingInt) {
              await supabase.from("crm_interactions").insert({
                customer_id: crmCustomerId,
                interaction_type: "note",
                direction: "outbound",
                subject: `Payment #${payment.id.substring(0, 8)}`,
                content: `Amount: $${(Number(payment.amount) / 100).toFixed(2)} | Status: ${payment.status} | Method: ${payment.payment_method || "N/A"} | ${payment.description || ""}`.trim(),
                channel: "system",
                metadata: {
                  source: "payment_sync",
                  payment_id: payment.id,
                  amount: payment.amount,
                  status: payment.status,
                  payment_method: payment.payment_method,
                  stripe_pi: payment.stripe_payment_intent_id
                },
                created_at: payment.payment_date || payment.created_at
              });
            }
          }
          // --- Sync Enrollment details as interactions ---
          for (const enr of enrollmentsActive){
            const studentName = studentRows.find((s)=>s.id === enr.student_id);
            const sName = studentName ? `${studentName.first_name} ${studentName.last_name}` : "Student";
            const { data: existingEnrInt } = await supabase.from("crm_interactions").select("id").eq("customer_id", crmCustomerId).eq("interaction_type", "note").eq("subject", `Enrollment #${enr.id.substring(0, 8)}`).maybeSingle();
            if (!existingEnrInt) {
              await supabase.from("crm_interactions").insert({
                customer_id: crmCustomerId,
                interaction_type: "note",
                direction: "inbound",
                subject: `Enrollment #${enr.id.substring(0, 8)}`,
                content: `${sName} → ${enr.programs?.name || "Program"} | Status: ${enr.subscription_status || enr.status || "active"} | Center: ${enr.centers?.name || "N/A"} | Monthly: $${Number(enr.monthly_price || 0).toFixed(2)} | Date: ${enr.enrollment_date || "N/A"}`,
                channel: "system",
                metadata: {
                  source: "enrollment_sync",
                  enrollment_id: enr.id,
                  student_id: enr.student_id,
                  student_name: sName,
                  program: enr.programs?.name,
                  center: enr.centers?.name,
                  status: enr.subscription_status || enr.status,
                  monthly_price: enr.monthly_price,
                  enrollment_date: enr.enrollment_date
                },
                created_at: enr.enrollment_date ? `${enr.enrollment_date}T00:00:00Z` : undefined
              });
            }
          }
        }
      } catch (err) {
        console.error(`Failed to sync parent ${parent.id}:`, err);
        recordsFailed++;
      }
    }
    // Mark warehouse customers as "deleted from source" when their source (parent) no longer exists in main system
    try {
      // 1) CRM customers with parent_id that is not in active parents (parent was deleted or removed)
      const { data: crmWithParent, error: selError } = await supabase.from("crm_customers").select("id, parent_id, deleted_from_source_at").not("parent_id", "is", null);
      if (selError) {
        console.warn("Mark deleted-from-source: select failed (run crm_customer_deleted_from_source.sql if needed):", selError.message);
        throw selError;
      }
      // Mark when parent_id is not in current active parents (parent hard/permanently deleted or removed from source)
      const toMarkByParentId = (crmWithParent || []).filter((c)=>c.parent_id && !activeParentIds.has(c.parent_id));
      // 2) CRM customers with no parent_id but email matches a deleted (inactive) parent
      let toMarkByEmail = [];
      const deletedParentEmails = new Set();
      {
        const pageSize = 1000;
        let from = 0;
        for(;;){
          const { data: deletedPage } = await supabase.from("parents").select("id, email").not("deleted_at", "is", null).order("id", {
            ascending: true
          }).range(from, from + pageSize - 1);
          if (!deletedPage?.length) break;
          for (const p of deletedPage){
            const e = (p.email || "").trim().toLowerCase();
            if (e) deletedParentEmails.add(e);
          }
          if (deletedPage.length < pageSize) break;
          from += pageSize;
        }
      }
      if (deletedParentEmails.size > 0) {
        const deletedEmails = deletedParentEmails;
        const { data: crmNoParent } = await supabase.from("crm_customers").select("id, email, deleted_from_source_at").is("parent_id", null).is("internal_profile_id", null);
        toMarkByEmail = (crmNoParent || []).filter((c)=>!c.deleted_from_source_at && deletedEmails.has((c.email || "").trim().toLowerCase()));
      }
      const seen = new Set();
      const uniqueToMark = [];
      for (const r of toMarkByParentId){
        if (!seen.has(r.id)) {
          seen.add(r.id);
          uniqueToMark.push({
            id: r.id,
            deleted_from_source_at: r.deleted_from_source_at
          });
        }
      }
      for (const r of toMarkByEmail){
        if (!seen.has(r.id)) {
          seen.add(r.id);
          uniqueToMark.push({
            id: r.id,
            deleted_from_source_at: null
          });
        }
      }
      for (const row of uniqueToMark){
        const isNewlyMarked = !row.deleted_from_source_at;
        await supabase.from("crm_customers").update({
          deleted_from_source_at: syncRunAt,
          source_soft_deleted_at: null,
          customer_status: "deleted_at_source",
          last_synced_at: syncRunAt
        }).eq("id", row.id);
        if (isNewlyMarked) {
          try {
            await supabase.from("crm_customer_history").insert({
              customer_id: row.id,
              event_type: "deleted_from_source",
              event_at: syncRunAt,
              metadata: {
                message: `Customer removed or no longer present/active in the source system as of this sync. Marked "Deleted at source" on or before ${syncRunAt} (sync detection time).`,
                deleted_from_source_detected_at: syncRunAt,
                sync_run_at: syncRunAt
              }
            });
          } catch (histDelErr) {
            console.warn("crm_customer_history insert (deleted_from_source):", histDelErr);
          }
        }
      }
      if (uniqueToMark.length > 0) {
        console.log(`Mark deleted-at-source: updated ${uniqueToMark.length} customer(s) (status → deleted_at_source)`);
      }
    } catch (e) {
      console.warn("Mark deleted-from-source step failed (table/column may not exist yet):", e);
    }
    // Align customer_status with sync flags (fixes stale "enrolled" when deleted_from_source_at is set)
    try {
      await supabase.from("crm_customers").update({
        customer_status: "deleted_at_source",
        source_soft_deleted_at: null
      }).not("deleted_from_source_at", "is", null);
      await supabase.from("crm_customers").update({
        customer_status: "source_soft_deleted"
      }).not("source_soft_deleted_at", "is", null).is("deleted_from_source_at", null);
    } catch (e) {
      console.warn("CRM customer_status backfill skipped:", e);
    }
    // Teachers & staff: internal CRM customers from user_roles AND active employees (HR) matched to profiles by email.
    const internalSyncedProfileIds = new Set();
    const internalSyncErrors = [];
    try {
      const collectUserIdsForRole = async (role)=>{
        const pageSize = 1000;
        const ids = [];
        let from = 0;
        for(;;){
          const { data, error } = await supabase.from("user_roles").select("user_id").eq("role", role).order("id", {
            ascending: true
          }).range(from, from + pageSize - 1);
          if (error) throw error;
          if (!data?.length) break;
          for (const row of data)ids.push(row.user_id);
          if (data.length < pageSize) break;
          from += pageSize;
        }
        return [
          ...new Set(ids)
        ];
      };
      /** Active teachers/staff in HR may not have user_roles until portal access exists — still sync to CRM when a profile matches email. */ const profileIdFromEmployeeEmail = async (emailRaw)=>{
        const e = String(emailRaw || "").trim().toLowerCase();
        if (!e || !e.includes("@")) return null;
        const esc = e.replace(/\\/g, "\\\\").replace(/%/g, "\\%").replace(/_/g, "\\_");
        const { data: rows, error } = await supabase.from("profiles").select("id, deleted_at").ilike("email", esc).is("deleted_at", null).limit(1);
        if (error) {
          console.warn("profile lookup by employee email:", error.message);
          return null;
        }
        const id = rows?.[0]?.id;
        return id ?? null;
      };
      const mergeEmployeeTeacherStaffProfileIds = async (teacherIds, staffIds)=>{
        const pageSize = 500;
        let from = 0;
        for(;;){
          const { data, error } = await supabase.from("employees").select("email, employee_type").in("employee_type", [
            "teacher",
            "staff"
          ]).or("is_active.eq.true,is_active.is.null").is("deleted_at", null).order("id", {
            ascending: true
          }).range(from, from + pageSize - 1);
          if (error) {
            console.warn("employees fetch for CRM internal sync skipped:", error.message);
            break;
          }
          if (!data?.length) break;
          for (const row of data){
            const et = String(row.employee_type || "").toLowerCase();
            if (et !== "teacher" && et !== "staff") continue;
            const pid = await profileIdFromEmployeeEmail(row.email || "");
            if (!pid) continue;
            if (et === "teacher") teacherIds.add(pid);
            else staffIds.add(pid);
          }
          if (data.length < pageSize) break;
          from += pageSize;
        }
      };
      const teacherProfileIds = new Set(await collectUserIdsForRole("teacher"));
      const staffFromRoles = new Set(await collectUserIdsForRole("staff"));
      await mergeEmployeeTeacherStaffProfileIds(teacherProfileIds, staffFromRoles);
      const staffOnlyProfileIds = [
        ...staffFromRoles
      ].filter((id)=>!teacherProfileIds.has(id));
      const syntheticInternalEmail = (profileId)=>`internal+${String(profileId).replace(/-/g, "")}@crm-sync.local`;
      const formatPgErr = (err)=>{
        const e = err;
        return [
          e?.code,
          e?.message,
          e?.details
        ].filter(Boolean).join(" | ") || String(err);
      };
      const upsertInternalCrm = async (profileId, customerType)=>{
        const { data: prof, error: pe } = await supabase.from("profiles").select("id, email, first_name, last_name, phone, created_at, deleted_at").eq("id", profileId).maybeSingle();
        if (pe || !prof) return;
        if (prof.deleted_at) return;
        recordsProcessed++;
        const { data: existing, error: exErr } = await supabase.from("crm_customers").select("id, metadata").eq("internal_profile_id", prof.id).maybeSingle();
        if (exErr) {
          internalSyncErrors.push(`${customerType} ${prof.id} lookup: ${formatPgErr(exErr)}`);
          console.error("crm internal existing row:", exErr);
          recordsFailed++;
          return;
        }
        const prevMeta = existing?.metadata && typeof existing.metadata === "object" && !Array.isArray(existing.metadata) ? {
          ...existing.metadata
        } : {};
        const portalEmail = (prof.email || "").trim().toLowerCase();
        const metaFull = {
          ...prevMeta,
          internal_team: true,
          ...portalEmail ? {
            portal_email: portalEmail
          } : {}
        };
        const metaMinimal = {
          internal_team: true
        };
        // Always use synthetic crm_customers.email — avoids unique(email) clashes with parent/prospect rows.
        const rowEmail = syntheticInternalEmail(prof.id);
        const buildPayload = (customerStatus, meta)=>({
            email: rowEmail,
            phone: prof.phone ?? null,
            first_name: (prof.first_name || "").trim() || "Team",
            last_name: (prof.last_name || "").trim() || "Member",
            customer_status: customerStatus,
            customer_type: customerType,
            total_students: 0,
            total_revenue: 0,
            last_synced_at: syncRunAt,
            parent_id: null,
            internal_profile_id: prof.id,
            deleted_from_source_at: null,
            source_soft_deleted_at: null,
            source: "csr_roles_employees_sync",
            metadata: meta
          });
        if (existing?.id) {
          const tryStatuses = [
            "internal",
            "enrolled"
          ];
          let upErr = null;
          for (const st of tryStatuses){
            const { error } = await supabase.from("crm_customers").update(buildPayload(st, metaFull)).eq("id", existing.id);
            if (!error) {
              recordsUpdated++;
              internalSyncedProfileIds.add(prof.id);
              return;
            }
            upErr = error;
            const { error: e2 } = await supabase.from("crm_customers").update(buildPayload(st, metaMinimal)).eq("id", existing.id);
            if (!e2) {
              recordsUpdated++;
              internalSyncedProfileIds.add(prof.id);
              return;
            }
            upErr = e2;
          }
          internalSyncErrors.push(`update ${customerType} ${prof.id}: ${formatPgErr(upErr)}`);
          console.error(`crm internal update ${prof.id}:`, upErr);
          recordsFailed++;
          return;
        }
        const insertAttempts = [
          {
            status: "internal",
            meta: metaFull
          },
          {
            status: "enrolled",
            meta: metaFull
          },
          {
            status: "internal",
            meta: metaMinimal
          },
          {
            status: "enrolled",
            meta: metaMinimal
          },
          {
            status: "prospect",
            meta: metaMinimal
          }
        ];
        let lastIns = null;
        for (const a of insertAttempts){
          const { error: insErr } = await supabase.from("crm_customers").insert({
            ...buildPayload(a.status, a.meta),
            first_contact_at: prof.created_at || syncRunAt
          });
          if (!insErr) {
            recordsCreated++;
            internalSyncedProfileIds.add(prof.id);
            return;
          }
          lastIns = insErr;
        }
        internalSyncErrors.push(`insert ${customerType} ${prof.id}: ${formatPgErr(lastIns)}`);
        console.error(`crm internal insert ${prof.id}:`, lastIns);
        recordsFailed++;
      };
      for (const uid of teacherProfileIds){
        await upsertInternalCrm(uid, "teacher");
      }
      for (const uid of staffOnlyProfileIds){
        await upsertInternalCrm(uid, "staff");
      }
      console.log(`CRM internal sync: ${internalSyncedProfileIds.size} active teacher/staff profile(s) (${teacherProfileIds.size} teacher keys, ${staffOnlyProfileIds.length} staff-only).`);
      const { data: crmInternal } = await supabase.from("crm_customers").select("id, internal_profile_id, deleted_from_source_at").not("internal_profile_id", "is", null);
      for (const row of crmInternal || []){
        const pid = row.internal_profile_id;
        if (!pid || internalSyncedProfileIds.has(pid)) continue;
        if (row.deleted_from_source_at) continue;
        await supabase.from("crm_customers").update({
          deleted_from_source_at: syncRunAt,
          source_soft_deleted_at: null,
          customer_status: "deleted_at_source",
          last_synced_at: syncRunAt
        }).eq("id", row.id);
        try {
          await supabase.from("crm_customer_history").insert({
            customer_id: row.id,
            event_type: "deleted_from_source",
            event_at: syncRunAt,
            metadata: {
              message: "Teacher/staff internal customer: role removed or profile inactive in the main system (CSR sync).",
              sync_run_at: syncRunAt
            }
          });
        } catch (histErr) {
          console.warn("crm_customer_history insert (internal removed):", histErr);
        }
        recordsUpdated++;
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      internalSyncErrors.push(`internal sync block: ${msg}`);
      console.warn("Internal teacher/staff CRM sync skipped (column or table missing?):", e);
    }
    const findCrmCustomerRowByEmailForInbound = async (email)=>{
      const raw = email?.trim();
      if (!raw) return null;
      const pattern = raw.replace(/\\/g, "\\\\").replace(/%/g, "\\%").replace(/_/g, "\\_");
      const { data } = await supabase.from("crm_customers").select("id, parent_id, customer_status, tags, metadata, lead_sub_status").ilike("email", pattern).limit(1).maybeSingle();
      return data;
    };
    // Sync contact submissions → CRM leads (tagged Form submission, New until reviewed)
    const { data: contacts } = await supabase.from("contact_submissions").select("*").order("created_at", {
      ascending: false
    }).limit(500);
    const chForm = channelContactForm();
    for (const contact of contacts || []){
      recordsProcessed++;
      try {
        const row = await findCrmCustomerRowByEmailForInbound(contact.email);
        const metaExtras = {
          contact_submission_id: contact.id,
          submission_type: contact.submission_type,
          interested_program: contact.interested_program,
          age_group: contact.age_group
        };
        let custId = null;
        if (!row) {
          const nameParts = (contact.name || "").split(" ");
          const { data: ins } = await supabase.from("crm_customers").insert({
            email: contact.email,
            phone: contact.phone || null,
            first_name: nameParts[0] || contact.name || "Contact",
            last_name: nameParts.slice(1).join(" ") || "",
            customer_status: "lead",
            lead_sub_status: "new",
            customer_type: "individual",
            source: chForm.sourceSlug,
            first_contact_at: contact.created_at,
            last_synced_at: syncRunAt,
            tags: [
              chForm.tag
            ],
            metadata: mergeInboundMetadata(null, chForm.key, metaExtras)
          }).select("id").single();
          custId = ins?.id ?? null;
          if (custId) recordsCreated++;
        } else {
          custId = row.id;
          await supabase.from("crm_customers").update({
            last_synced_at: syncRunAt,
            tags: mergeCrmTags(row.tags, [
              chForm.tag
            ]),
            metadata: mergeInboundMetadata(row.metadata, chForm.key, metaExtras),
            ...nextLeadFieldsForInboundMerge(row)
          }).eq("id", row.id);
          recordsUpdated++;
        }
        if (custId) {
          const { data: existingInt } = await supabase.from("crm_interactions").select("id").eq("customer_id", custId).eq("interaction_type", "note").eq("subject", `Contact submission #${contact.id.substring(0, 8)}`).maybeSingle();
          if (!existingInt) {
            await supabase.from("crm_interactions").insert({
              customer_id: custId,
              interaction_type: "note",
              direction: "inbound",
              subject: `Contact submission #${contact.id.substring(0, 8)}`,
              content: (contact.message || "").slice(0, 2000),
              channel: "system",
              metadata: {
                source: "contact_form_sync",
                contact_submission_id: contact.id,
                submission_type: contact.submission_type
              },
              created_at: contact.created_at
            });
          }
        }
      } catch (err) {
        console.error(`Failed to sync contact ${contact.id}:`, err);
        recordsFailed++;
      }
    }
    // Sync trial / consultation / evaluation requests → tagged CRM leads + interaction
    try {
      const { data: trials } = await supabase.from("trial_requests").select("id, parent_email, parent_first_name, parent_last_name, parent_phone, child_first_name, child_last_name, created_at, page_slug, preferred_mode, program_id, request_type").order("created_at", {
        ascending: false
      }).limit(500);
      for (const tr of trials || []){
        recordsProcessed++;
        try {
          const ch = channelFromTrialRequestType(tr.request_type);
          const metaExtras = {
            trial_request_id: tr.id,
            page_slug: tr.page_slug,
            csr_request_type: tr.request_type
          };
          const row = await findCrmCustomerRowByEmailForInbound(tr.parent_email);
          let custId = null;
          if (!row) {
            const { data: newC } = await supabase.from("crm_customers").insert({
              email: tr.parent_email,
              phone: tr.parent_phone || null,
              first_name: tr.parent_first_name || "Parent",
              last_name: tr.parent_last_name || "",
              customer_status: "lead",
              lead_sub_status: "new",
              customer_type: "individual",
              source: ch.sourceSlug,
              first_contact_at: tr.created_at,
              last_synced_at: syncRunAt,
              tags: [
                ch.tag
              ],
              metadata: mergeInboundMetadata(null, ch.key, metaExtras)
            }).select("id").single();
            custId = newC?.id ?? null;
            if (custId) recordsCreated++;
          } else {
            custId = row.id;
            await supabase.from("crm_customers").update({
              last_synced_at: syncRunAt,
              tags: mergeCrmTags(row.tags, [
                ch.tag
              ]),
              metadata: mergeInboundMetadata(row.metadata, ch.key, metaExtras),
              ...nextLeadFieldsForInboundMerge(row)
            }).eq("id", row.id);
            recordsUpdated++;
          }
          if (custId) {
            const { data: existingInt } = await supabase.from("crm_interactions").select("id").eq("customer_id", custId).eq("interaction_type", "note").eq("subject", `Trial request #${tr.id.substring(0, 8)}`).maybeSingle();
            if (!existingInt) {
              const typeLabel = ch.key === "consultation" ? "Consultation" : ch.key === "evaluation" ? "Evaluation" : "Trial class";
              await supabase.from("crm_interactions").insert({
                customer_id: custId,
                interaction_type: "note",
                direction: "inbound",
                subject: `Trial request #${tr.id.substring(0, 8)}`,
                content: `${typeLabel}: ${tr.child_first_name} ${tr.child_last_name} | Page: ${tr.page_slug || "N/A"} | Mode: ${tr.preferred_mode || "N/A"}`,
                channel: "system",
                metadata: {
                  source: "trial_sync",
                  trial_request_id: tr.id,
                  request_type: tr.request_type
                },
                created_at: tr.created_at
              });
            }
          }
        } catch (err) {
          console.error(`Failed to sync trial ${tr.id}:`, err);
          recordsFailed++;
        }
      }
    } catch (e) {
      console.warn("trial_requests sync skipped:", e);
    }
    // Sync B2B consultation requests → tagged CRM leads + interaction
    try {
      const { data: b2b } = await supabase.from("b2b_consultation_requests").select("id, email, contact_name, phone, institution_name, message, created_at, program_interest").order("created_at", {
        ascending: false
      }).limit(300);
      const chB2b = channelB2bConsultation();
      for (const req of b2b || []){
        recordsProcessed++;
        try {
          const metaExtras = {
            institution_name: req.institution_name,
            b2b_consultation_id: req.id
          };
          const row = await findCrmCustomerRowByEmailForInbound(req.email);
          let custId = null;
          if (!row) {
            const nameParts = (req.contact_name || "").split(" ");
            const { data: newC } = await supabase.from("crm_customers").insert({
              email: req.email,
              phone: req.phone || null,
              first_name: nameParts[0] || req.contact_name || "Contact",
              last_name: nameParts.slice(1).join(" ") || "",
              customer_status: "lead",
              lead_sub_status: "new",
              customer_type: "individual",
              source: chB2b.sourceSlug,
              first_contact_at: req.created_at,
              last_synced_at: syncRunAt,
              tags: [
                chB2b.tag
              ],
              metadata: mergeInboundMetadata(null, chB2b.key, metaExtras)
            }).select("id").single();
            custId = newC?.id ?? null;
            if (custId) recordsCreated++;
          } else {
            custId = row.id;
            await supabase.from("crm_customers").update({
              last_synced_at: syncRunAt,
              tags: mergeCrmTags(row.tags, [
                chB2b.tag
              ]),
              metadata: mergeInboundMetadata(row.metadata, chB2b.key, metaExtras),
              ...nextLeadFieldsForInboundMerge(row)
            }).eq("id", row.id);
            recordsUpdated++;
          }
          if (custId) {
            const { data: existingInt } = await supabase.from("crm_interactions").select("id").eq("customer_id", custId).eq("interaction_type", "note").eq("subject", `B2B consultation #${req.id.substring(0, 8)}`).maybeSingle();
            if (!existingInt) {
              await supabase.from("crm_interactions").insert({
                customer_id: custId,
                interaction_type: "note",
                direction: "inbound",
                subject: `B2B consultation #${req.id.substring(0, 8)}`,
                content: `${req.institution_name || "N/A"} | ${req.program_interest || "N/A"} | ${(req.message || "").slice(0, 200)}`,
                channel: "system",
                metadata: {
                  source: "b2b_consultation_sync",
                  consultation_id: req.id
                },
                created_at: req.created_at
              });
            }
          }
        } catch (err) {
          console.error(`Failed to sync B2B consultation ${req.id}:`, err);
          recordsFailed++;
        }
      }
    } catch (e) {
      console.warn("b2b_consultation_requests sync skipped:", e);
    }
    // Helper: case-insensitive email match (CRM may store lowercase, log may have mixed case)
    const findCrmCustomerByEmail = async (email)=>{
      const raw = email?.trim();
      if (!raw) return null;
      const pattern = raw.replace(/\\/g, "\\\\").replace(/%/g, "\\%").replace(/_/g, "\\_");
      const { data } = await supabase.from("crm_customers").select("id").ilike("email", pattern).limit(1).maybeSingle();
      return data;
    };
    // Helper: find customer by phone (try exact then digits-only; log may have +1, CRM may not)
    const findCrmCustomerByPhone = async (phone)=>{
      if (!phone?.trim()) return null;
      let { data } = await supabase.from("crm_customers").select("id").eq("phone", phone.trim()).maybeSingle();
      if (data) return data;
      const digits = phone.replace(/\D/g, "");
      if (digits.length >= 10) {
        const withPlus = digits.length === 11 && digits.startsWith("1") ? `+${digits}` : digits.length === 10 ? `+1${digits}` : `+${digits}`;
        const withoutPlus = digits.length === 11 && digits.startsWith("1") ? digits.slice(1) : digits;
        const { data: d2 } = await supabase.from("crm_customers").select("id").eq("phone", withPlus).maybeSingle();
        if (d2) return d2;
        const { data: d3 } = await supabase.from("crm_customers").select("id").eq("phone", withoutPlus).maybeSingle();
        if (d3) return d3;
        const { data: d4 } = await supabase.from("crm_customers").select("id").eq("phone", digits).maybeSingle();
        if (d4) return d4;
      }
      return null;
    };
    // Sync outbound email log into CRM interactions (by recipient_email → crm_customers)
    try {
      const { data: emailLogs } = await supabase.from("outbound_email_log").select("id, sent_at, recipient_email, recipient_name, subject, body_preview, source, provider_message_id").order("sent_at", {
        ascending: false
      }).limit(500);
      for (const row of emailLogs || []){
        recordsProcessed++;
        try {
          const cust = await findCrmCustomerByEmail(row.recipient_email);
          if (!cust) continue;
          const pid = row.provider_message_id || row.id;
          const { data: existingList } = await supabase.from("crm_interactions").select("id, metadata").eq("customer_id", cust.id).eq("channel", "email").limit(500);
          const hasExisting = pid && (existingList || []).some((i)=>i?.metadata?.provider_message_id === pid);
          if (!hasExisting) {
            await supabase.from("crm_interactions").insert({
              customer_id: cust.id,
              interaction_type: "email",
              direction: "outbound",
              subject: row.subject || "(No subject)",
              content: row.body_preview || null,
              channel: "email",
              metadata: {
                source: "email_log_sync",
                provider_message_id: row.provider_message_id || row.id,
                log_source: row.source
              },
              created_at: row.sent_at
            });
          }
        } catch (err) {
          console.error(`Failed to sync email log ${row.id}:`, err);
          recordsFailed++;
        }
      }
    } catch (e) {
      console.warn("outbound_email_log sync skipped (table may not exist):", e);
    }
    // Sync outbound SMS log into CRM interactions (by recipient_phone → crm_customers)
    try {
      const { data: smsLogs } = await supabase.from("outbound_sms_log").select("id, sent_at, recipient_phone, body_preview, source, provider_message_sid").order("sent_at", {
        ascending: false
      }).limit(500);
      for (const row of smsLogs || []){
        recordsProcessed++;
        try {
          const cust = await findCrmCustomerByPhone(row.recipient_phone);
          if (!cust) continue;
          const sid = row.provider_message_sid || row.id;
          const { data: smsList } = await supabase.from("crm_interactions").select("id, metadata").eq("customer_id", cust.id).eq("channel", "sms").limit(500);
          const hasExistingSms = sid && (smsList || []).some((i)=>i?.metadata?.provider_message_sid === sid);
          if (!hasExistingSms) {
            await supabase.from("crm_interactions").insert({
              customer_id: cust.id,
              interaction_type: "sms",
              direction: "outbound",
              subject: "SMS",
              content: row.body_preview || null,
              channel: "sms",
              metadata: {
                source: "sms_log_sync",
                provider_message_sid: row.provider_message_sid || row.id,
                log_source: row.source
              },
              created_at: row.sent_at
            });
          }
        } catch (err) {
          console.error(`Failed to sync SMS log ${row.id}:`, err);
          recordsFailed++;
        }
      }
    } catch (e) {
      console.warn("outbound_sms_log sync skipped (table may not exist):", e);
    }
    // Sync refunds (outgoing) to CRM customer history - from local refunds table
    try {
      const { data: refundRows } = await supabase.from("refunds").select("id, customer_email, customer_name, amount, processed_at, reason, status, stripe_refund_id").order("processed_at", {
        ascending: false
      }).limit(500);
      for (const row of refundRows || []){
        recordsProcessed++;
        try {
          const cust = await findCrmCustomerByEmail(row.customer_email);
          if (!cust) continue;
          const refId = row.stripe_refund_id || row.id;
          const { data: existingList } = await supabase.from("crm_interactions").select("id, metadata").eq("customer_id", cust.id).eq("interaction_type", "note").eq("subject", `Refund #${row.id.substring(0, 8)}`).limit(1);
          const hasExisting = existingList && existingList.length > 0;
          if (!hasExisting) {
            await supabase.from("crm_interactions").insert({
              customer_id: cust.id,
              interaction_type: "note",
              direction: "outbound",
              subject: `Refund #${row.id.substring(0, 8)}`,
              content: `Refund $${(Number(row.amount) / 100).toFixed(2)} | Reason: ${row.reason || "N/A"} | Status: ${row.status || "N/A"}`,
              channel: "system",
              metadata: {
                source: "refund_sync",
                refund_id: row.id,
                stripe_refund_id: row.stripe_refund_id
              },
              created_at: row.processed_at
            });
          }
        } catch (err) {
          console.error(`Failed to sync refund ${row.id}:`, err);
          recordsFailed++;
        }
      }
    } catch (e) {
      console.warn("refunds sync skipped:", e);
    }
    const duration = Date.now() - startTime;
    // Update sync log
    if (logEntry) {
      await supabase.from("crm_sync_logs").update({
        status: recordsFailed > 0 ? "partial" : "success",
        records_processed: recordsProcessed,
        records_created: recordsCreated,
        records_updated: recordsUpdated,
        records_failed: recordsFailed,
        completed_at: new Date().toISOString(),
        duration_ms: duration
      }).eq("id", logEntry.id);
    }
    // Update sync settings for customers
    await supabase.from("crm_sync_settings").update({
      last_sync_at: new Date().toISOString(),
      last_sync_status: recordsFailed > 0 ? "partial" : "success",
      last_sync_count: recordsProcessed
    }).eq("sync_type", "customers");
    // Also update transactions sync setting
    await supabase.from("crm_sync_settings").update({
      last_sync_at: new Date().toISOString(),
      last_sync_status: recordsFailed > 0 ? "partial" : "success",
      last_sync_count: recordsProcessed
    }).eq("sync_type", "transactions");
    return new Response(JSON.stringify({
      success: true,
      syncType,
      triggerSource,
      records_processed: recordsProcessed,
      records_created: recordsCreated,
      records_updated: recordsUpdated,
      records_failed: recordsFailed,
      duration_ms: duration,
      internal_sync_errors: internalSyncErrors.length ? internalSyncErrors.slice(0, 15) : undefined,
      hint: internalSyncErrors.some((s)=>/internal_profile_id|column/i.test(s)) ? "Apply DB migrations 20260329240000_crm_customers_internal_profile.sql and 20260329250000_crm_customers_relax_internal_checks.sql (e.g. supabase db push), redeploy crm-sync-data, then sync again." : internalSyncErrors.length ? "See internal_sync_errors above; fix DB constraints or redeploy the latest crm-sync-data function." : undefined
    }), {
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  } catch (error) {
    console.error("CRM sync error:", error);
    return new Response(JSON.stringify({
      success: false,
      error: error.message
    }), {
      status: 500,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  }
});
