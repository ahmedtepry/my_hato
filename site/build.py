# Builds the myhato.com page from src.html: inlines the icon and the catalogue snapshot.
#   index.html      -> the page body (used for the Claude preview)
#   www/index.html  -> the full page to upload to the myhato.com host (with icons)
import base64, json, os, pathlib
here = pathlib.Path(__file__).parent
src = (here/'src.html').read_text(encoding='utf-8')
snap = json.loads((here/'snapshot.json').read_text(encoding='utf-8'))
icon = 'data:image/png;base64,' + base64.b64encode((here/'icon-96.png').read_bytes()).decode()
body = src.replace('__SNAPSHOT__', json.dumps(snap, ensure_ascii=False, separators=(',', ':'))).replace('__ICON96__', icon)
(here/'index.html').write_text(body, encoding='utf-8')
os.makedirs(here/'www', exist_ok=True)
head, rest = body.split('</style>', 1)
full = ('<!doctype html>\n<html lang="ar" dir="rtl">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
        '<link rel="apple-touch-icon" href="icon-192.png">\n'
        + head + '</style>\n</head>\n<body>\n' + rest + '\n</body>\n</html>\n')
(here/'www'/'index.html').write_text(full, encoding='utf-8')
for f in ('icon-192.png', 'icon-96.png'):
    (here/'www'/f).write_bytes((here/f).read_bytes())
print('ok', len(body)//1024, 'KB')
