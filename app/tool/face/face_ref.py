# Reference face pipeline (plain numpy), the twin of lib/features/admin/face/face_core.dart.
# Usage: python face_ref.py <folder with models/ and images/>  -> writes <folder>/ref/*.png and ref.json for test/face/face_core_test.dart
import sys, numpy as np, onnxruntime as ort, cv2
D = sys.argv[1] if len(sys.argv) > 1 else '.'
det = ort.InferenceSession(f'{D}/models/face_detection_yunet_2023mar.onnx', providers=['CPUExecutionProvider'])
rec = ort.InferenceSession(f'{D}/models/face_recognition_sface_2021dec.onnx', providers=['CPUExecutionProvider'])
DST = np.array([[38.2946,51.6963],[73.5318,51.5014],[56.0252,71.7366],[41.5493,92.3655],[70.7299,92.2041]])

def letterbox(rgb):  # scale the longer side to 640, pad right/bottom with black; returns BGR float CHW
    h, w, _ = rgb.shape; s = 640 / max(w, h)
    nw, nh = round(w * s), round(h * s)
    out = np.zeros((640, 640, 3), np.float32)
    # bilinear resize, same formula as the Dart code (pixel centers)
    ys = (np.arange(nh) + 0.5) / s - 0.5; xs = (np.arange(nw) + 0.5) / s - 0.5
    out[:nh, :nw] = bilinear(rgb.astype(np.float32), xs[None, :].repeat(nh, 0), ys[:, None].repeat(nw, 1))
    return out[:, :, ::-1].transpose(2, 0, 1)[None].copy(), s

def bilinear(img, X, Y):
    h, w, _ = img.shape
    x0 = np.floor(X).astype(int); y0 = np.floor(Y).astype(int); fx = X - x0; fy = Y - y0
    def px(yy, xx):
        inside = (xx >= 0) & (xx < w) & (yy >= 0) & (yy < h)
        v = img[np.clip(yy, 0, h - 1), np.clip(xx, 0, w - 1)]
        return v * inside[..., None]
    return (px(y0, x0) * ((1 - fx) * (1 - fy))[..., None] + px(y0, x0 + 1) * (fx * (1 - fy))[..., None]
            + px(y0 + 1, x0) * ((1 - fx) * fy)[..., None] + px(y0 + 1, x0 + 1) * (fx * fy)[..., None])

def detect(rgb, thr=0.8):
    blob, s = letterbox(rgb)
    o = dict(zip([x.name for x in det.get_outputs()], det.run(None, {'input': blob})))
    faces = []
    for st in (8, 16, 32):
        cols = 640 // st
        cls = np.clip(o[f'cls_{st}'][0, :, 0], 0, 1); obj = np.clip(o[f'obj_{st}'][0, :, 0], 0, 1)
        sc = np.sqrt(cls * obj); bb = o[f'bbox_{st}'][0]; kp = o[f'kps_{st}'][0]
        for i in np.nonzero(sc > thr)[0]:
            r, c = divmod(i, cols)
            cx = (c + bb[i, 0]) * st; cy = (r + bb[i, 1]) * st; w = np.exp(bb[i, 2]) * st; h = np.exp(bb[i, 3]) * st
            k = [((kp[i, 2*n] + c) * st / s, (kp[i, 2*n+1] + r) * st / s) for n in range(5)]
            faces.append([sc[i], (cx - w/2) / s, (cy - h/2) / s, w / s, h / s, k])
    faces.sort(key=lambda f: -f[0]); keep = []
    for f in faces:  # NMS 0.3
        if all(iou(f, g) < 0.3 for g in keep): keep.append(f)
    return keep

def iou(a, b):
    x1, y1 = max(a[1], b[1]), max(a[2], b[2]); x2, y2 = min(a[1]+a[3], b[1]+b[3]), min(a[2]+a[4], b[2]+b[4])
    inter = max(0, x2-x1) * max(0, y2-y1); return inter / (a[3]*a[4] + b[3]*b[4] - inter)

def similarity(src, dst):  # Umeyama, 2D, no reflection; returns 2x3 matrix src->dst
    n = len(src); ms, md = src.mean(0), dst.mean(0); s0, d0 = src - ms, dst - md
    cov = d0.T @ s0 / n; U, S, Vt = np.linalg.svd(cov); d = np.ones(2)
    if np.linalg.det(cov) < 0: d[1] = -1
    R = U @ np.diag(d) @ Vt; var = (s0 ** 2).sum() / n; scale = (S * d).sum() / var
    t = md - scale * R @ ms; return np.hstack([scale * R, t[:, None]])

def align(rgb, kps):
    M = similarity(np.array(kps), DST); A = M[:, :2]; t = M[:, 2]; Ai = np.linalg.inv(A)
    yy, xx = np.mgrid[0:112, 0:112].astype(np.float64)
    sx = Ai[0, 0] * (xx - t[0]) + Ai[0, 1] * (yy - t[1]); sy = Ai[1, 0] * (xx - t[0]) + Ai[1, 1] * (yy - t[1])
    return bilinear(rgb.astype(np.float32), sx, sy)  # 112x112x3 RGB

def embed(rgb, face):
    crop = align(rgb, face[5])
    blob = crop.transpose(2, 0, 1)[None].astype(np.float32)  # RGB, 0..255
    v = rec.run(None, {'data': blob})[0][0]; return v / np.linalg.norm(v)

def load(p):
    return cv2.cvtColor(cv2.imread(p), cv2.COLOR_BGR2RGB)


if __name__ == '__main__':
    import json, os
    os.makedirs(f'{D}/ref', exist_ok=True); out = {}
    for n in ['t1.jpg', 'lena.jpg', 'messi5.jpg', 'Tom_Hanks_54745.png']:
        im = load(f'{D}/images/{n}'); base = n.rsplit('.', 1)[0]
        for tag, v in [('', im), ('_flip', im[:, ::-1].copy()), ('_dark', (im * 0.6).astype(np.uint8))]:
            name = base + tag + '.png'
            cv2.imwrite(f'{D}/ref/{name}', cv2.cvtColor(v, cv2.COLOR_RGB2BGR))
            fs = detect(v)
            if not fs: continue
            f = max(fs, key=lambda f: f[3] * f[4])
            out[name] = {'faces': len(fs), 'box': [float(x) for x in f[1:5]], 'print': [float(x) for x in embed(v, f)]}
    json.dump(out, open(f'{D}/ref/ref.json', 'w'))
    print('reference written for', len(out), 'pictures')
