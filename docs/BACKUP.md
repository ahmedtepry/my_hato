# Backup & recovery

* **Supabase Pro**: enable Point-in-Time Recovery (restore to any second within the retention window). Free plan has no automatic backups.
* **Daily logical backup** (in addition, kept outside Supabase):
  ```bash
  pg_dump "$DATABASE_URL" --format=custom --no-owner --file="myhato-$(date +%F).dump"
  ```
  Store encrypted (e.g. `age`/GPG) in a separate cloud account; keep 30 daily + 12 monthly copies.
* **Storage**: product images are re-uploadable; `repair-photos` should be copied weekly with `supabase storage cp -r ss:///repair-photos ./backup/` (private data → encrypt).
* **Restore drill** (quarterly): create a fresh project, `pg_restore --no-owner -d "$NEW_DB_URL" file.dump`, redeploy functions, point a staging app at it.
* **Retention**: orders/invoices 5 years (accounting); support messages 2 years; guest lookup challenges and rate-limit rows can be purged after 7 days:
  ```sql
  delete from public.repair_lookup_challenges where created_at < now() - interval '7 days';
  delete from public.rate_limits where window_start < now() - interval '7 days';
  ```
* **Account deletion**: requests appear in Admin → Customers (`deletion_requested_at`). Anonymise the profile, delete addresses/avatars/repair photos, keep order snapshots required by law, then delete the auth user.

## Restore test (do it every month, and before trusting a backup)

1. In the app: Shifts & approvals → *Backup and restore test* → **Take a snapshot now**. Copy the numbers (row counts, units in stock, the audit-log head hash).
2. Restore the latest Supabase backup into a **separate** project (never over the live one): Dashboard → Database → Backups → Restore, or point-in-time recovery if it is enabled.
3. In the restored project run `select public.owner_data_snapshot();` (as the owner) and compare it with step 1. Rows added after the backup are the only difference allowed.
4. Run `select public.audit_verify();` in the restored project: `ok` must be `true`. A `false` means the log was changed after it was written.
5. Delete the test project when done. Write the date and the result somewhere the owner can see it.

What is protected where: invoices, shifts, refunds, approvals and stock movements can never be edited or deleted (database triggers); the audit log is append-only and hash-chained; money and stock only change inside the `pos_*` functions.
