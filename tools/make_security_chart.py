"""Renders docs/security-benchmark.png from the security test run.

    flutter test test/security_test.dart
    dart compile exe tools/bench_crypto.dart -o build/bench_crypto.exe && build/bench_crypto.exe
    python tools/make_security_chart.py
"""
import json
import os

import matplotlib

matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager
from matplotlib.patches import FancyBboxPatch

for f in ('segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf'):
    path = os.path.join('C:/Windows/Fonts', f)
    if os.path.exists(path):
        font_manager.fontManager.addfont(path)
plt.rcParams['font.family'] = 'Segoe UI'

report = json.load(open('build/security/report.json', encoding='utf-8'))
aot = json.load(open('build/security/aot.json')) if os.path.exists('build/security/aot.json') else {}
tests, bench = report['tests'], report['benchmarks']
passed = sum(t['passed'] for t in tests)

BG, CARD, INK, MUTED = '#12121C', '#1C1C2B', '#F2F2FF', '#9A9AB8'
GOOD, ACCENT, ACCENT2, BAD = '#34C759', '#6C6CFF', '#22C8EE', '#FF453A'

fig = plt.figure(figsize=(16, 9), dpi=120, facecolor=BG)


def card(x, y, w, h):
    fig.patches.append(FancyBboxPatch((x, y), w, h, boxstyle='round,pad=0,rounding_size=0.018',
                                      transform=fig.transFigure, facecolor=CARD, edgecolor='#2E2E46',
                                      linewidth=1.2, zorder=-10))


fig.text(0.035, 0.935, 'PixMirror security test', color=INK, fontsize=28, weight='bold')
fig.text(0.035, 0.895, f"{passed}/{len(tests)} attack scenarios blocked  ·  real HostServer over sockets  ·  "
         f"X25519 + HKDF-SHA256 + ChaCha20-Poly1305", color=MUTED, fontsize=13)
badge_color = GOOD if passed == len(tests) else BAD
fig.text(0.965, 0.925, 'ALL PASSED' if passed == len(tests) else f'{len(tests) - passed} FAILED',
         color=BG, fontsize=15, weight='bold', ha='right',
         bbox=dict(boxstyle='round,pad=0.55', facecolor=badge_color, edgecolor='none'))

# ---- Left: attack scenarios ------------------------------------------------
card(0.03, 0.05, 0.50, 0.80)
fig.text(0.05, 0.805, 'Attack scenarios', color=INK, fontsize=16, weight='bold')
row_h = 0.70 / len(tests)
for i, t in enumerate(tests):
    y = 0.765 - i * row_h
    ok = t['passed']
    fig.text(0.05, y, ' PASS ' if ok else ' FAIL ', color=BG, fontsize=10.5, weight='bold', va='center',
             bbox=dict(boxstyle='round,pad=0.3', facecolor=GOOD if ok else BAD, edgecolor='none'))
    fig.text(0.095, y + 0.009, t['title'], color=INK, fontsize=12.5, va='center')
    fig.text(0.095, y - 0.016, t['threat'], color=MUTED, fontsize=10, va='center')

# ---- Right: benchmarks -----------------------------------------------------
def panel(rect, title, subtitle):
    x, y, w, h = rect
    card(x, y, w, h)
    fig.text(x + 0.02, y + h - 0.045, title, color=INK, fontsize=15, weight='bold')
    fig.text(x + 0.02, y + h - 0.075, subtitle, color=MUTED, fontsize=10.5)
    ax = fig.add_axes([x + 0.105, y + 0.04, w - 0.15, h - 0.15], zorder=5)
    ax.patch.set_alpha(0)
    for s in ax.spines.values():
        s.set_visible(False)
    ax.tick_params(colors=MUTED, labelsize=10.5, length=0)
    ax.grid(axis='x', color='#2E2E46', linewidth=0.8)
    ax.set_axisbelow(True)
    return ax


def bars(ax, labels, values, colors, unit, xmax=None):
    ys = list(range(len(labels)))[::-1]
    ax.barh(ys, values, color=colors, height=0.55)
    ax.set_yticks(ys, labels, color=INK, fontsize=11.5)
    top = xmax or max(values) * 1.35
    ax.set_xlim(0, top)
    for yv, v in zip(ys, values):
        ax.text(v + top * 0.015, yv, f'{v:.1f} {unit}', va='center', color=INK, fontsize=11.5, weight='bold')


ax = panel((0.55, 0.585, 0.42, 0.265), 'Secure handshake',
           'Connect + mutual authentication, loopback (lower is better)')
bars(ax, ['median', 'p95'], [bench['handshake_ms_median'], bench['handshake_ms_p95']], [ACCENT, ACCENT2], 'ms')

frame_ms = aot.get('aot_aead_ms_per_frame_roundtrip', bench['aead_ms_per_frame_roundtrip'])
ax = panel((0.55, 0.305, 0.42, 0.265), 'Encryption cost per frame',
           '100 KB frame, encrypt + decrypt (release/AOT) vs. the 30 fps frame budget')
bars(ax, ['crypto', '30 fps budget'], [frame_ms, 1000 / 30], [ACCENT, '#3A3A55'], 'ms', xmax=1000 / 30 * 1.3)

ax = panel((0.55, 0.05, 0.42, 0.24), 'Encrypted stream',
           'Full session over loopback, 100 KB frames, in the debug-mode test runner')
bars(ax, ['achieved', 'target'], [bench['stream_fps'], bench['stream_target_fps']], [GOOD, '#3A3A55'], 'fps',
     xmax=bench['stream_target_fps'] * 1.3)

fig.text(0.965, 0.018, f"{report['os'][:60]}  ·  Dart {report['dart']}  ·  {report['generated'][:10]}",
         color=MUTED, fontsize=9, ha='right')
os.makedirs('docs', exist_ok=True)
fig.savefig('docs/security-benchmark.png', facecolor=BG)
print('wrote docs/security-benchmark.png')
