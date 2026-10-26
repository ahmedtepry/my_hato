from PIL import Image
im = Image.open('assets/brand/app_icon.png').convert('RGBA')
im.save('windows/runner/resources/app_icon.ico', sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)])
