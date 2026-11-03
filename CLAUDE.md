
## Two apps (standing rule from the owner)
- Windows team exe (TEAM_ONLY=true): everything for staff, owner, permissions, cashier, assistant. Any team/owner/permission request goes here only.
- Android APK (customerOnly): customers only. Only customer requests are built here. Never add staff features to the APK.
- Both share the same Supabase database.
- MyHato Owner (separate Android app, package com.myhato.owner, entry app/lib/owner_main.dart, built by build-owner-apk.yml via branch `owner-apk-build`, release `owner-N`): the owner's AI chat only. Added at the owner's explicit request; it is NOT the customer APK and the customer APK must still never get staff features.
