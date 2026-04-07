import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { canSendOutbound, fetchNotificationPreferences } from "../_shared/notificationPreferences.ts";
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
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type"
};
// Input validation schema
const validateSMSInput = (data)=>{
  if (!data.to || typeof data.to !== 'string') {
    return {
      valid: false,
      error: 'Phone number is required and must be a string'
    };
  }
  if (!data.message || typeof data.message !== 'string') {
    return {
      valid: false,
      error: 'Message is required and must be a string'
    };
  }
  // Limit message to 1600 characters (10 SMS segments)
  if (data.message.length > 1600) {
    return {
      valid: false,
      error: 'Message must be 1600 characters or less'
    };
  }
  // Validate phone number format (E.164)
  const phoneDigits = data.to.replace(/\D/g, '');
  if (phoneDigits.length < 10 || phoneDigits.length > 15) {
    return {
      valid: false,
      error: 'Invalid phone number format'
    };
  }
  return {
    valid: true
  };
};
const handler = async (req)=>{
  console.log("SMS function invoked - Method:", req.method);
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: corsHeaders
    });
  }
  try {
    // Verify authentication
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      console.error("Missing authorization header");
      return new Response(JSON.stringify({
        error: 'Unauthorized: Missing authorization header'
      }), {
        status: 401,
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !supabaseServiceKey) {
      throw new Error("Missing Supabase environment variables");
    }
    const supabase = createClient(supabaseUrl, supabaseServiceKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false
      },
      global: {
        headers: {
          Authorization: authHeader
        }
      }
    });
    // Verify user is authenticated
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) {
      console.error("Authentication failed:", authError);
      return new Response(JSON.stringify({
        error: 'Unauthorized: Invalid token'
      }), {
        status: 401,
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }
    console.log("Authenticated user:", user.id);
    const body = await req.json();
    console.log("Request body received:", {
      to: body.to,
      messageLength: body.message?.length,
      channel: body.channel,
      userId: user.id
    });
    // Validate input
    const validation = validateSMSInput(body);
    if (!validation.valid) {
      console.error("Input validation failed:", validation.error);
      return new Response(JSON.stringify({
        error: validation.error
      }), {
        status: 400,
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders
        }
      });
    }
    const { to, message, channel, recipientUserIdForPreferences, notificationPreferenceKind = "reminder" } = body;
    const serviceSupabase = createClient(supabaseUrl, supabaseServiceKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false
      }
    });
    if (recipientUserIdForPreferences && typeof recipientUserIdForPreferences === "string") {
      const prefs = await fetchNotificationPreferences(serviceSupabase, recipientUserIdForPreferences);
      if (!canSendOutbound(prefs, "sms", notificationPreferenceKind)) {
        return new Response(JSON.stringify({
          error: "Recipient has opted out of SMS notifications"
        }), {
          status: 403,
          headers: {
            "Content-Type": "application/json",
            ...corsHeaders
          }
        });
      }
    }
    const accountSid = Deno.env.get("TWILIO_ACCOUNT_SID");
    const authToken = Deno.env.get("TWILIO_AUTH_TOKEN");
    const platformPhoneNumber = (Deno.env.get("TWILIO_PHONE_NUMBER") || "").trim();
    const receivePhoneNumber = (Deno.env.get("TWILIO_RECEIVE_PHONE_NUMBER") || "").trim();
    const preferReceiveNumber = channel === "csr_inbox";
    const twilioPhoneNumber = preferReceiveNumber && receivePhoneNumber ? receivePhoneNumber : platformPhoneNumber;
    console.log("Twilio credentials check:", {
      hasAccountSid: !!accountSid,
      hasAuthToken: !!authToken,
      hasPhoneNumber: !!twilioPhoneNumber,
      twilioPhoneNumber: twilioPhoneNumber,
      preferReceiveNumber
    });
    if (!accountSid || !authToken || !twilioPhoneNumber) {
      throw new Error("Twilio credentials not configured - please check TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER, and TWILIO_RECEIVE_PHONE_NUMBER secrets");
    }
    // Format phone number to E.164 format if not already
    let formattedPhone = to.replace(/\D/g, ''); // Remove non-digits
    console.log("Phone after removing non-digits:", formattedPhone);
    if (!formattedPhone.startsWith('1') && formattedPhone.length === 10) {
      formattedPhone = '1' + formattedPhone; // Add US country code
    }
    if (!formattedPhone.startsWith('+')) {
      formattedPhone = '+' + formattedPhone;
    }
    console.log("Formatted phone number:", formattedPhone);
    console.log("Sending SMS from:", twilioPhoneNumber, "to:", formattedPhone);
    const smsTemplate = await getSmsTemplate(serviceSupabase);
    const wrappedMessage = wrapSmsBody(smsTemplate, message);
    const response = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`, {
      method: "POST",
      headers: {
        "Authorization": "Basic " + btoa(`${accountSid}:${authToken}`),
        "Content-Type": "application/x-www-form-urlencoded"
      },
      body: new URLSearchParams({
        To: formattedPhone,
        From: twilioPhoneNumber,
        Body: wrappedMessage
      })
    });
    const data = await response.json();
    console.log("Twilio API response status:", response.status);
    console.log("Twilio API response data:", data);
    if (!response.ok) {
      console.error("Twilio API error:", data);
      throw new Error(data.message || `Twilio API error: ${response.status}`);
    }
    console.log("SMS sent successfully! SID:", data.sid, "User:", user.id);
    // Log SMS activity for audit trail
    await supabase.from('csr_activities').insert({
      performed_by: user.id,
      performed_by_email: user.email || 'unknown',
      action_type: 'SMS_SENT',
      entity_type: 'sms',
      entity_id: data.sid,
      notes: `SMS sent to ${formattedPhone}`,
      details: {
        recipient: formattedPhone,
        message_sid: data.sid,
        message_length: wrappedMessage.length
      }
    });
    // Platform-wide outbound SMS log for Communication Center history and CRM
    const { error: logErr } = await serviceSupabase.from("outbound_sms_log").insert({
      recipient_phone: formattedPhone,
      body_preview: message.slice(0, 500),
      source: "manual_csr",
      metadata: {
        twilio_sid: data.sid
      },
      created_by: user.id,
      provider_message_sid: data.sid,
      status: "sent"
    });
    if (logErr) {
      console.error("outbound_sms_log insert error:", logErr.message, logErr.code, logErr.details);
    }
    return new Response(JSON.stringify({
      success: true,
      messageSid: data.sid,
      ...logErr && {
        logWarning: "SMS sent but history log failed. Ensure outbound_sms_log table exists (run outbound_sms_log_create_table.sql)."
      }
    }), {
      status: 200,
      headers: {
        "Content-Type": "application/json",
        ...corsHeaders
      }
    });
  } catch (error) {
    console.error("Error in send-sms function:", error);
    console.error("Error stack:", error.stack);
    return new Response(JSON.stringify({
      error: error.message,
      details: error.stack
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
