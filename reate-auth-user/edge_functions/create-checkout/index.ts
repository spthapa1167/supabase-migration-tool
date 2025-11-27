import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.21.0?target=deno";
import { createClient } from "npm:@supabase/supabase-js@2";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type"
};
const logStep = (step, details)=>{
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : '';
  console.log(`[CREATE-CHECKOUT] ${step}${detailsStr}`);
};
serve(async (req)=>{
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: corsHeaders
    });
  }
  const supabaseClient = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_ANON_KEY") ?? "");
  try {
    logStep("Function started");
    const authHeader = req.headers.get("Authorization");
    const token = authHeader.replace("Bearer ", "");
    const { data } = await supabaseClient.auth.getUser(token);
    const user = data.user;
    if (!user?.email) throw new Error("User not authenticated or email not available");
    logStep("User authenticated", {
      email: user.email
    });
    const { price_id, enrollment_data } = await req.json();
    logStep("Request data received", {
      price_id,
      has_enrollment_data: !!enrollment_data,
      has_promo: !!enrollment_data.promoCode
    });
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") || "", {
      apiVersion: "2024-04-10"
    });
    // Check for existing customer
    const customers = await stripe.customers.list({
      email: user.email,
      limit: 1
    });
    let customerId;
    if (customers.data.length > 0) {
      customerId = customers.data[0].id;
      logStep("Existing customer found", {
        customerId
      });
    } else {
      logStep("No existing customer, will create new");
    }
    // Create coupons based on promo code and tier discount
    const coupons = [];
    // First, add tier discount if exists
    if (enrollment_data.discountPercentage && enrollment_data.discountPercentage > 0) {
      const tierCoupon = await stripe.coupons.create({
        percent_off: enrollment_data.discountPercentage,
        duration: "once",
        name: `${enrollment_data.discountPercentage}% off first month (tier discount)`
      });
      coupons.push(tierCoupon.id);
      logStep("Tier coupon created", {
        couponId: tierCoupon.id,
        percent_off: tierCoupon.percent_off
      });
    }
    // Then, add promo code discount if provided
    if (enrollment_data.promoCode) {
      const promo = enrollment_data.promoCode;
      let duration = "once";
      let duration_in_months;
      // Map application_timing to Stripe coupon duration
      switch(promo.application_timing){
        case 'recurring':
          duration = "forever";
          break;
        case 'first_3_months':
          duration = "repeating";
          duration_in_months = 3;
          break;
        case 'first_6_months':
          duration = "repeating";
          duration_in_months = 6;
          break;
        default:
          // one_time, first_month, etc.
          duration = "once";
          break;
      }
      const promoCouponParams = {
        duration,
        name: `${promo.code} - ${promo.discount_type === 'percentage' ? promo.discount_value + '%' : '$' + promo.discount_value} off`
      };
      if (duration === "repeating" && duration_in_months) {
        promoCouponParams.duration_in_months = duration_in_months;
      }
      if (promo.discount_type === 'percentage') {
        promoCouponParams.percent_off = promo.discount_value;
      } else {
        promoCouponParams.amount_off = Math.floor(promo.discount_value) * 100; // Convert to cents
        promoCouponParams.currency = 'usd';
      }
      const promoCoupon = await stripe.coupons.create(promoCouponParams);
      coupons.push(promoCoupon.id);
      logStep("Promo coupon created", {
        couponId: promoCoupon.id,
        type: promo.discount_type,
        value: promo.discount_value,
        duration,
        duration_in_months
      });
    }
    const originalPrice = typeof enrollment_data.monthlyPrice === 'number' ? Number(enrollment_data.monthlyPrice.toFixed(2)) : 0;
    const firstMonthAmount = typeof enrollment_data.paymentAmount === 'number' ? Number(enrollment_data.paymentAmount.toFixed(2)) : originalPrice;
    const monthlyAmount = originalPrice;
    const totalDiscount = Number((monthlyAmount - firstMonthAmount).toFixed(2));
    // Build comprehensive pricing messages for Stripe checkout (same structure as public checkout)
    const pricingMessages = [];
    // Subscription-only flow for this function
    pricingMessages.push(`Original monthly program price: $${monthlyAmount.toFixed(2)}`);
    if (totalDiscount > 0) {
      pricingMessages.push(`Combined discount on first month: -$${totalDiscount.toFixed(2)}`);
      pricingMessages.push(`Discounted first-month price: $${firstMonthAmount.toFixed(2)}`);
    }
    pricingMessages.push(`Price due today: $${firstMonthAmount.toFixed(2)}`);
    if (firstMonthAmount !== monthlyAmount) {
      pricingMessages.push(`From second month onward: $${monthlyAmount.toFixed(2)}/month (charged ~30 days after class start date)`);
    } else {
      pricingMessages.push(`Ongoing monthly payment: $${monthlyAmount.toFixed(2)}/month (charged ~30 days after class start date)`);
    }
    const session = await stripe.checkout.sessions.create({
      customer: customerId,
      customer_email: customerId ? undefined : user.email,
      payment_method_types: [
        "card"
      ],
      line_items: [
        {
          price: price_id,
          quantity: 1
        }
      ],
      mode: "subscription",
      discounts: coupons.length > 0 ? coupons.map((c)=>({
          coupon: c
        })) : undefined,
      success_url: `${req.headers.get("origin")}/portal?session_id={CHECKOUT_SESSION_ID}&enrollment_success=true`,
      cancel_url: `${req.headers.get("origin")}/#enroll`,
      custom_text: {
        submit: {
          message: pricingMessages.join("  |  ")
        }
      },
      metadata: {
        // Parent information
        parent_email: user.email,
        parent_first_name: enrollment_data.parentFirstName || '',
        parent_last_name: enrollment_data.parentLastName || '',
        phone: enrollment_data.phone || '',
        // Student information
        student_name: enrollment_data.studentName,
        students_data: enrollment_data.students ? JSON.stringify(enrollment_data.students) : JSON.stringify([
          {
            name: enrollment_data.studentName,
            grade: enrollment_data.grade,
            medicalNotes: enrollment_data.medicalNotes || ''
          }
        ]),
        student_count: enrollment_data.students ? enrollment_data.students.length.toString() : '1',
        grade: enrollment_data.grade || '',
        medical_notes: enrollment_data.medicalNotes || '',
        // Program information
        program_id: enrollment_data.programId || '',
        program_name: enrollment_data.programName,
        program_type: enrollment_data.programType || '',
        tier_name: enrollment_data.tierName,
        pricing_tier_id: enrollment_data.pricingTierId || '',
        // Pricing information
        original_price: originalPrice.toString(),
        monthly_price: monthlyAmount.toString(),
        final_price: firstMonthAmount.toString(),
        payment_amount: firstMonthAmount.toString(),
        total_first_month: enrollment_data.totalFirstMonth ? enrollment_data.totalFirstMonth.toString() : firstMonthAmount.toString(),
        students_pricing: enrollment_data.studentsPricing ? JSON.stringify(enrollment_data.studentsPricing) : '',
        // Promo code information
        promo_code: enrollment_data.promoCode ? enrollment_data.promoCode.code : '',
        promo_discount_type: enrollment_data.promoCode ? enrollment_data.promoCode.discount_type : '',
        promo_discount_value: enrollment_data.promoCode ? enrollment_data.promoCode.discount_value.toString() : '',
        promo_application_timing: enrollment_data.promoCode ? enrollment_data.promoCode.application_timing : '',
        promotion_enabled: enrollment_data.promotionEnabled ? 'true' : 'false',
        promotion_name: enrollment_data.promotionName || '',
        promotion_discount: enrollment_data.promotionDiscount ? enrollment_data.promotionDiscount.toString() : '',
        promotion_discount_type: enrollment_data.promotionDiscountType || '',
        // Schedule information
        center_id: enrollment_data.centerId || '',
        requested_start_date: enrollment_data.requestedStartDate || '',
        selected_days: enrollment_data.selectedDays ? JSON.stringify(enrollment_data.selectedDays) : '',
        time_slots_array: enrollment_data.timeSlotsArray ? JSON.stringify(enrollment_data.timeSlotsArray) : '',
        days_per_week: enrollment_data.daysPerWeek ? enrollment_data.daysPerWeek.toString() : '',
        timezone: enrollment_data.timezone || '',
        // Camp-specific information
        is_seasonal_camp: enrollment_data.isSeasonalCamp ? 'true' : 'false',
        camp_start_date: enrollment_data.campStartDate || '',
        camp_end_date: enrollment_data.campEndDate || '',
        camp_daily_start_time: enrollment_data.campDailyStartTime || '',
        camp_daily_end_time: enrollment_data.campDailyEndTime || '',
        closing_ceremony_date: enrollment_data.closingCeremonyDate || '',
        closing_ceremony_start_time: enrollment_data.closingCeremonyStartTime || '',
        closing_ceremony_end_time: enrollment_data.closingCeremonyEndTime || '',
        // Additional information
        notes: enrollment_data.notes || '',
        stripe_price_id: price_id,
        created_by: enrollment_data.createdBy || user.id,
        user_id: user.id
      },
      subscription_data: {
        description: `Enrollment Summary: ${enrollment_data.programName} - ${enrollment_data.tierName}`,
        metadata: {
          original_price: originalPrice.toString(),
          first_month_discount: totalDiscount.toString(),
          first_month_amount: firstMonthAmount.toString(),
          monthly_recurring_amount: monthlyAmount.toString(),
          total_first_month_savings: totalDiscount.toString()
        }
      }
    });
    logStep("Checkout session created", {
      sessionId: session.id,
      url: session.url
    });
    // Record promo code usage if a promo code was applied
    if (enrollment_data.promoCode) {
      try {
        // Find the promo code record
        const { data: promoCodeRecord } = await supabaseClient.from('promotion_codes').select('id').eq('code', enrollment_data.promoCode.code).single();
        if (promoCodeRecord) {
          const discountAmount = enrollment_data.monthlyPrice - enrollment_data.paymentAmount;
          await supabaseClient.from('promo_code_usage').insert({
            promo_code_id: promoCodeRecord.id,
            customer_email: user.email,
            customer_name: enrollment_data.parentName || `${enrollment_data.parentFirstName} ${enrollment_data.parentLastName}`,
            stripe_customer_id: customerId || session.customer,
            stripe_subscription_id: null,
            enrollment_id: null,
            discount_amount: discountAmount,
            original_price: enrollment_data.monthlyPrice,
            final_price: enrollment_data.paymentAmount
          });
          logStep("Promo code usage recorded", {
            code: enrollment_data.promoCode.code,
            discount_amount: discountAmount
          });
        }
      } catch (usageError) {
        // Log but don't fail the checkout
        logStep("ERROR recording promo usage", {
          error: usageError
        });
      }
    }
    return new Response(JSON.stringify({
      url: session.url,
      session_id: session.id
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
