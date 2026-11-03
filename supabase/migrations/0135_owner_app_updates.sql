-- 0135: the MyHato Owner Android app gets its own update channel ('android_owner'), separate from the customer app.
alter table public.app_releases drop constraint if exists app_releases_platform_check;
alter table public.app_releases add constraint app_releases_platform_check check (platform in ('windows', 'android', 'android_owner'));
