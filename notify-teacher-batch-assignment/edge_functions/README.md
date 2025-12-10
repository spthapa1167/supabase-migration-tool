# Edge Functions Backup

This folder contains edge functions downloaded from source project for migration to target.

## Migration Summary
- Source: htqfxkbuuqgwthwxqnxf
- Target: ekwvmluwiyjsmmucchce
- Functions migrated: 0
- Functions skipped: 0
- Functions failed: 87
- Functions incompatible: 0
- Date: 2025-11-27T15:19:00.034Z

## Manual Deployment

If automatic deployment failed, you can deploy functions manually:

```bash
# Navigate to function directory
cd edge_functions/<function-name>

# Deploy to target project
supabase functions deploy <function-name> --project-ref ekwvmluwiyjsmmucchce
```

## Functions List

- check-subscription (id: d9bf7205-2f5d-4d70-a43a-24af07b81721)
- create-checkout (id: 2bba5272-ef81-4ba4-82e4-a006e8a833ea)
- customer-portal (id: e6c3b488-7b97-4c4f-aaae-47565f905a8b)
- create-checkout-public (id: abb7d74e-85bc-4f4c-a01d-96a9bb467862)
- get-customers-subscriptions (id: 163fb830-2875-40f2-bb6f-db01585c675c)
- stripe-webhook (id: 7de45b7c-a6e4-472d-9506-057fcf41f2bd)
- verify-payment (id: c98a1363-f418-4719-b326-eb390eaf86ac)
- save-enrollment (id: 0910d51a-ddf7-4221-a8e6-9c98efa04fd8)
- cancel-subscription (id: 04461a41-cf7b-41a9-bb99-452229876fb0)
- get-subscription-details (id: 9d645bf4-cd7b-4c81-960e-37c95c058def)
- manage-payment-method (id: b81885cd-046e-4f4d-ae10-bb9ce4a0bdf4)
- apply-credit-discount (id: 525512e0-4c78-43ed-815f-f419c013b6f3)
- create-one-time-invoice (id: 9c883d8a-4554-4b57-bdb4-5bad62b92042)
- pause-resume-subscription (id: 21df92b0-2b09-43e7-9123-1d7474ba62c3)
- process-refund (id: e3746535-76b0-4950-b9f7-216bf929fc5e)
- update-billing-cycle (id: 43094376-9946-4551-b309-46868ad830a2)
- send-contact-email (id: 88d17eff-8d50-48f5-ab0c-a50c2f352843)
- send-sms (id: 2765eed5-2857-4a10-946a-f4878599c487)
- send-custom-email (id: 3d44c9f5-ea69-4e1e-9c38-bb6296708946)
- get-payment-invoice (id: 2c3f708c-d003-47dc-a3d0-68180c64a901)
- get-customer-invoices (id: 4932b47c-f5ed-4d2e-88b3-2bd5457f7827)
- get-stripe-mode (id: 8ac68957-83ab-4e12-87a4-a48d0f1e9107)
- get-user-count (id: f051364d-4782-4d89-b2a7-3c974f181f53)
- pay-adhoc-invoice (id: 002004c6-6011-4014-bf33-c7a6e28f5adb)
- validate-promo-code (id: 9ec23b7c-aed9-41bb-b51f-9920c4ba4999)
- finalize-adhoc-invoice (id: fe35ef44-5241-4597-b31c-929c75badc9b)
- delete-stripe-invoice (id: 23cb0dd4-934d-421c-8663-f5d41c50caf5)
- pay-adhoc-invoice-existing (id: 642d0377-8bd6-4526-b3f0-a3018bbee941)
- get-customer-payment-intents (id: e2d74eb4-04ce-4033-91e6-75d8a8fff665)
- delete-user (id: 8597be44-2a66-41aa-8fb2-4d1ac91b850e)
- update-user-profile (id: 426220b5-a0bf-43a2-89b0-3755b866c346)
- update-parent-email (id: c9f69d1e-ddfa-4071-b0b3-78d64742c387)
- permanent-delete-enrollment (id: 4b682b90-400b-442b-9651-7293a71ff6ef)
- switch-parent-primary-email (id: ef10cfef-e52f-40f9-875a-79aa2bede41a)
- track-login (id: 22f63793-f233-4ff6-b824-90e483ac5755)
- get-system-setting (id: c7260137-04f7-44cd-965f-a2dabd1c5495)
- verify-otp-change-password (id: cb41d2a9-5ef4-48ca-b4b7-2998a19d19ca)
- update-subscription-price (id: efb876c4-68b8-477f-a11a-088dac29bfb2)
- preview-subscription-price-change (id: 70dc0974-9305-4f54-b8e0-c01b504482a6)
- restore-user (id: 99854246-28d6-4058-a712-43c9b4c50a0d)
- send-trial-request-email (id: 7710b93e-d42f-4adb-909e-e07209c98edb)
- send-teacher-assignment-email (id: 41ec520c-e28a-422a-9614-0cd79c16c31f)
- send-trial-status-notification (id: 43caa485-fc07-43ea-899b-98179616996d)
- send-b2b-consultation-email (id: 353abda9-c62f-438c-b701-6cd09bf15085)
- chatbot-add-knowledge (id: 668e4c0b-ed00-4b8c-bd26-df85a87371a8)
- chatbot-chat (id: 8e8f77df-8a46-4cff-b0b7-5c0cf4395b06)
- grant-portal-access-with-auth (id: 4f8537c3-0167-4617-890d-7dd930eeb66c)
- process-existing-enrollments (id: 73c486b6-0f7a-4c90-a920-7d520ea0b779)
- send-password-reset-csr (id: 54da6950-5520-46da-aa1c-16bb5333c575)
- bulk-delete-users (id: 71389a18-225c-4150-8abc-38ed300c3967)
- update-user-role (id: 668001fe-3968-4374-9eeb-6a8bd5ef2deb)
- chatbot-delete-knowledge (id: 88b73da1-767e-4cf1-97ff-bd2dd1d936f6)
- restore-enrollment (id: 408519ec-fe0f-4e70-b7dc-00184c90ba00)
- fix-batch-schedule-types (id: 30401326-d94b-46b5-98c5-25a2a98e3e51)
- balance-batches (id: 6d096d4e-682e-4c86-a4d4-03060ee0fdd0)
- merge-batches (id: 2c38193c-24b0-4089-9301-5dfee65b5b15)
- get-app-environment (id: 4df50bde-e286-40e0-9fc3-a2d0a78da545)
- assign-student-to-batch (id: 95fc26d1-1ab8-4775-85af-880fb3bafcbd)
- set-system-setting (id: 246f5793-2d46-422b-b9c0-3020aee2b2bc)
- get-app-env (id: c920070a-0a36-4bac-9262-595f74694218)
- get-user-roles (id: 8a8b1e09-cfb1-436a-8c48-be07dceee9a7)
- create-missing-profiles (id: 1fb0eb94-f3b8-4459-bef8-016b11d3121b)
- get-missing-profiles (id: 7c6d6e94-c2cc-46d9-86e4-fa2103974345)
- fix-batch-counts (id: db268ac0-60ff-4360-bf1c-deca96c00974)
- manual-cleanup (id: c7be413a-f395-44b5-8275-1a93a2a13ac1)
- diagnose-stripe (id: 02f4ccc4-7060-48bb-963e-e089f3bbb013)
- delete-users-no-profiles (id: d9db869d-f0b4-43ba-9a2a-192d48a0b944)
- assign-unassigned-enrollments (id: 449a7139-64e1-4c14-ab77-fae6ca3c903f)
- send-package-email (id: beb52d70-7d0f-433d-b51a-e28e82c42397)
- send-trial-rejection-email (id: ebd49265-b7ff-40f6-855b-1afd7ad6854e)
- track-package-view (id: e5890b99-567a-4caf-817f-2b02b9cf6348)
- send-employee-unique-id (id: a1bb80bf-295c-4bed-b497-0ff08c702088)
- send-employee-welcome (id: 7878f60b-2930-42fc-98a9-927168c7fa3c)
- send-pickup-code (id: 5a9347bd-14a4-4fd1-a247-1918b7484c43)
- send-password-change-otp (id: 69a73f9a-f11b-4ccb-93bb-3df443fe8f78)
- send-chat-notification (id: 87404be4-7d4c-4a22-8dec-246cf6e676ec)
- create-auth-user (id: d07788d9-8c50-4a74-b4c1-a20c7f245f22)
- notify-teacher-batch-assignment (id: 29a5c5ae-7736-49b1-a57a-5fd3031b85c3)
- resend-enrollment-confirmation (id: f8362965-0d1c-4e2a-9754-586eb19f40d8)
- send-enrollment-confirmation (id: e1bacde8-ee6b-4340-91f4-5819abaf64d7)
- send-enrollment-email (id: 90b12a08-4c1e-456b-b6e3-4337a4c5f933)
- send-password-confirmation (id: 1b15e5b3-6f0c-4daa-a4d4-c99f4b8981fa)
- send-password-reset (id: b3d3557e-6f97-4c77-81dc-fdd25e3a2651)
- setup-portal-users (id: a8d44772-bdd7-474d-a95d-bb13eb129e9e)
- update-consent-content (id: e17492a1-2749-4c75-83f4-f9b1536a6607)
- cleanup-pricing-discounts (id: 3c5267b8-6425-416e-bbf7-0b1a7ec815f0)
- auto-mark-missing-class-status (id: 94937d10-27fe-4bdb-8175-73da09836e30)
