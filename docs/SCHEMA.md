# Database schema

Money: integer **piasters** (`*_minor`, 1 EGP = 100), currency column fixed to `EGP`. Timestamps: `timestamptz` (UTC), shown in Africa/Cairo.
All primary keys are UUID except append-only logs (identity bigint). RLS is enabled on **every** table.

## Tables

| Area | Table | Purpose / key constraints | Client access (RLS) |
|---|---|---|---|
| Security | `profiles` | 1:1 with `auth.users`; created by trigger; `phone`/`phone_verified`/`email` synced from Auth only | own row (update limited to name, avatar, locale, notification prefs) · staff `customers.view` |
| | `customer_addresses` | one default per user (partial unique index) | own rows |
| | `user_roles` | staff roles (`owner, manager, sales, technician, support`) | read own · write only via `staff_set_role()` |
| | `role_permissions` | permission matrix | read |
| | `staff_assignments` | staff ↔ branch | `staff.manage` |
| | `application_settings` | emails, fees, `used_devices_enabled`, approval policy | public keys readable; emails staff-only; `settings.manage` writes |
| | `audit_logs` | append-only (trigger blocks update/delete) | `audit.view` read only |
| Catalog | `categories` (kind: phones/accessories/used), `brands` | admin-editable, bilingual | public read active · `products.manage` |
| | `products` | unique `sku`, `slug`; `compare_at_price_minor > price_minor`; `stock_quantity >= 0` | public read published · `products.manage` (no delete → archive) |
| | `product_variants`, `product_images`, `product_360_assets` (unique frame index), `product_specifications` | | public read if product published |
| | `product_favorites`, `recently_viewed` | | own rows |
| | `banners` | scheduled with starts/ends | public read active · `banners.manage` |
| | view `catalog_products` | published only + discount % + in_stock + thumb | public |
| Commerce | `branches`, `delivery_zones` | fee per governorate | public read active · `settings.manage` |
| | `carts`, `cart_items` | qty 1–20, unique per product/variant | read own · write via RPC |
| | `orders` | unique `reference`, unique `(customer_id, idempotency_key)`, snapshots of name/phone/address, `total = subtotal + fee` check | read own / `orders.view` · write via RPC only |
| | `order_items` | immutable price/name/SKU snapshot, `line_total = unit × qty` check | via parent |
| | `order_status_history`, `order_transitions` | allowed state machine (fulfilment-aware) | via parent |
| | `inventory_movements` | every stock change (order, cancel, manual, restock) | `inventory.manage` |
| Repairs | `repair_requests` | unique `reference` (MY-HATO###), idempotency key, `internal_notes` **column not granted** to API roles | own / assigned technician / manager+ / support |
| | `repair_status_history`, `repair_transitions`, `repair_status_labels` (AR/EN messages) | | via `can_read_repair()` |
| | `repair_quotes` (one pending per repair), `repair_approvals` (one per quote, `via` customer_app/staff_recorded + mandatory note) | | via `can_read_repair()` |
| | `repair_attachments` (`is_internal`), `repair_assignments`, `repair_parts` | | staff / owner of repair (non-internal) |
| | `repair_lookup_challenges` | hashed guest-lookup codes, attempts, expiry | service role only |
| Comms | `notifications` (bilingual, deep link, read_at) | | own (update `read_at` only) |
| | `notification_delivery_logs` | per channel: in_app/push/sms/email + status | staff |
| | `email_outbox` | unique `(kind, related_id)` → never duplicate mails | staff read |
| | `customer_support_requests` | | own insert/read · `support.manage` |
| | `device_tokens` | FCM tokens | own |
| | `rate_limits` | fixed-window counters | service role only |

## Server functions (all `SECURITY DEFINER`, `search_path` pinned)
| Function | Who | What |
|---|---|---|
| `place_order(idempotency_key, fulfillment, payment, branch, address, notes)` | customer | locks rows, server prices, validates stock, writes order + items + history + inventory, clears cart, queues sales email, notifies — one transaction; replay returns same order |
| `customer_cancel_order` | customer | only while pending; restocks |
| `staff_update_order_status` | `orders.manage` | validated transition, restock on cancel, notification, audit |
| `staff_adjust_stock` | `inventory.manage` | atomic delta + movement + audit |
| `cart_set_item`, `cart_merge`, `get_cart`, `quote_delivery_fee` | customer | server-validated cart |
| `request_repair(...)` | customer | creates MY-HATO reference, history, queues **service** email, notification |
| `add_repair_attachment` | owner / staff | path must be `repair-photos/{customer}/{repair}/…` |
| `staff_update_repair_status` | manager+ or assigned technician | transition table, blocks chargeable repair without approval, cancel needs reason |
| `staff_update_repair_details` | same | whitelisted fields only |
| `staff_create_repair_quote` | same | supersedes pending quote, moves to awaiting approval (re-approval if price changes) |
| `customer_respond_to_quote` | repair owner | approve/reject, stores amount + timestamp, emails service mailbox |
| `staff_record_quote_decision` | `repairs.manage` | phone approval with mandatory note, audited |
| `staff_assign_technician`, `staff_get_repair`, `staff_list_technicians` | staff | |
| `staff_set_role`, `staff_list_staff` | owner (`staff.manage`) | |
| `guest_repair_public_view`, `repair_contact_for_lookup`, `hit_rate_limit`, `claim_*`, `complete_*` | service role only | used by Edge Functions |

## Storage buckets
| Bucket | Public | Limit | Path | Policy |
|---|---|---|---|---|
| `product-images` | yes | 5 MB jpeg/png/webp | `{product_id}/…` | read all · write `products.manage` |
| `product-360` | yes | 3 MB | `{product_id}/fNNN_…` | same |
| `banners` | yes | 5 MB | | write `banners.manage` |
| `avatars` | **no** | 2 MB | `{uid}/…` | owner only (signed URLs) |
| `repair-photos` | **no** | 8 MB incl. heic | `{customer_uid}/{repair_id}/…` | customer uploads to own repair; read by owner/authorised staff via 5-min signed URLs; internal staff photos hidden from customers |
