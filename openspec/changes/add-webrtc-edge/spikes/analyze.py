#!/usr/bin/env python3
"""Decode a recorded broadcast and check its content, not the decoder's exit code.

  analyze.py <left-hex> <right-hex> <tone-hz> <file.mkv>...   (segments of one recording)

Video: every decoded frame is reduced to the mean colour of its left and right halves and
compared with the fixture's two colours (tolerance 45 per channel, codec and YUV round trip).
Audio: the dominant frequency of the decoded PCM (FFT) and its RMS level.
Prints one JSON line; exit 0 only if most frames match and the tone is within 3%.
"""
import json, subprocess, sys
import numpy as np

lhex, rhex, tone, paths = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4:]
rgb = lambda h: np.array([int(h[i:i + 2], 16) for i in (2, 4, 6)] if h.startswith('0x') else [int(h[i:i + 2], 16) for i in (0, 2, 4)])
want_l, want_r = rgb(lhex), rgb(rhex)
out = {'files': [p.rsplit('/', 1)[-1] for p in paths], 'streams': [], 'video_frames': 0, 'video_frames_matching': 0, 'video_decode_errors': 0}
frames, pcm_all = [], []
for path in paths:
    probe = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'stream=codec_type,codec_name,width,height', '-of', 'json', path], capture_output=True, text=True)
    for st in json.loads(probe.stdout or '{"streams":[]}').get('streams', []):
        st = {k: v for k, v in st.items() if k in ('codec_type', 'codec_name', 'width', 'height')}
        if st not in out['streams']:
            out['streams'].append(st)
    v = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-map', '0:v:0?', '-vf', 'format=rgb24,scale=2:1:flags=area', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], capture_output=True)
    frames.append(np.frombuffer(v.stdout, dtype=np.uint8).reshape(-1, 2, 3).astype(int))
    out['video_decode_errors'] += v.stderr.decode(errors='replace').count('\n')
    a = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-map', '0:a:0?', '-ac', '1', '-ar', '48000', '-f', 's16le', '-'], capture_output=True)
    pcm_all.append(np.frombuffer(a.stdout, dtype=np.int16).astype(float) / 32768)
px = np.concatenate(frames) if frames else np.zeros((0, 2, 3), int)
ok = [(np.abs(f[0] - want_l).max() <= 45 and np.abs(f[1] - want_r).max() <= 45) for f in px]
out['video_frames'] = len(px)
out['video_frames_matching'] = int(sum(ok))
if len(px):
    out['video_mean_left'] = px[:, 0].mean(0).round().astype(int).tolist()
    out['video_mean_right'] = px[:, 1].mean(0).round().astype(int).tolist()
pcm = np.concatenate(pcm_all) if pcm_all else np.zeros(0)
out['audio_seconds'] = round(len(pcm) / 48000, 2)
if len(pcm) > 4800:
    seg = pcm[len(pcm) // 4:]
    spec = np.abs(np.fft.rfft(seg * np.hanning(len(seg))))
    out['audio_peak_hz'] = round(float(np.argmax(spec[1:]) + 1) * 48000 / len(seg), 1)
    out['audio_rms'] = round(float(np.sqrt((seg ** 2).mean())), 4)
good_v = len(px) > 0 and sum(ok) >= 0.8 * len(px)
good_a = 'audio_peak_hz' in out and abs(out['audio_peak_hz'] - tone) <= 0.03 * tone and out['audio_rms'] > 0.01
out['verdict'] = 'content-ok' if good_v and good_a else ('video-ok-audio-bad' if good_v else ('audio-ok-video-bad' if good_a else 'content-bad'))
print(json.dumps(out))
sys.exit(0 if out['verdict'] == 'content-ok' else 1)
