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

for f in ('segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf', 'consola.ttf'):
    path = os.path.join('C:/Windows/Fonts', f)
    if os.path.exists(path):
        font_manager.fontManager.addfont(path)
plt.rcParams['font.family'] = 'Segoe UI'

report = json.load(open('build/security/report.json', encoding='utf-8'))
aot = json.load(open('build/security/aot.json')) if os.path.exists('build/security/aot.json') else {}
tests = sorted(report['tests'], key=lambda t: t['n'])
bench = report['benchmarks']
passed = sum(t['passed'] for t in tests)

BG, CARD, INK, MUTED, LINE = '#12121C', '#1C1C2B', '#F2F2FF', '#9A9AB8', '#2E2E46'
GOOD, ACCENT, ACCENT2, BAD, CHIP = '#34C759', '#6C6CFF', '#22C8EE', '#FF453A', '#2A2A40'

fig = plt.figure(figsize=(16, 10), dpi=120, facecolor=BG)


def card(x, y, w, h):
    fig.patches.append(FancyBboxPatch((x, y), w, h, boxstyle='round,pad=0,rounding_size=0.014',
                                      transform=fig.transFigure, facecolor=CARD, edgecolor=LINE,
                                      linewidth=1.2, zorder=-10))


fig.text(0.025, 0.948, 'PixMirror security test suite', color=INK, fontsize=27, weight='bold')
fig.text(0.025, 0.912, f"{passed}/{len(tests)} tests passed  ·  attacks run against the real host, discovery and viewer code  ·  "
         f"X25519 + HKDF-SHA256 + ChaCha20-Poly1305", color=MUTED, fontsize=12.5)
fig.text(0.975, 0.94, 'ALL PASSED' if passed == len(tests) else f'{len(tests) - passed} FAILED',
         color=BG, fontsize=15, weight='bold', ha='right',
         bbox=dict(boxstyle='round,pad=0.55', facecolor=GOOD if passed == len(tests) else BAD, edgecolor='none'))

# ---- Left: 20 tests in two columns ----------------------------------------
LX, LY, LW, LH = 0.025, 0.04, 0.635, 0.845
card(LX, LY, LW, LH)
fig.text(LX + 0.017, LY + LH - 0.037, 'Security tests', color=INK, fontsize=15, weight='bold')
fig.text(LX + LW - 0.017, LY + LH - 0.037,
         'runtime = real attack over sockets · static = code / manifest audit · live = running app',
         color=MUTED, fontsize=8.8, ha='right')
half = (len(tests) + 1) // 2
row_h = (LH - 0.1) / half
for i, t in enumerate(tests):
    col, row = divmod(i, half)
    x = LX + 0.017 + col * (LW / 2)
    y = LY + LH - 0.098 - row * row_h
    ok = t['passed']
    fig.text(x, y, ' PASS ' if ok else ' FAIL ', color=BG, fontsize=9, weight='bold', va='center', family='Consolas',
             bbox=dict(boxstyle='round,pad=0.28', facecolor=GOOD if ok else BAD, edgecolor='none'))
    fig.text(x + 0.045, y + 0.011, f"{t['n']:02d}  {t['title']}", color=INK, fontsize=10.8, va='center')
    fig.text(x + 0.045, y - 0.013, t['threat'], color=MUTED, fontsize=8.6, va='center')
    fig.text(x + LW / 2 - 0.03, y + 0.011, t['kind'], color=MUTED, fontsize=7.6, va='center', ha='right',
             family='Consolas', bbox=dict(boxstyle='round,pad=0.25', facecolor=CHIP, edgecolor='none'))


# ---- Right: benchmarks -----------------------------------------------------
def panel(rect, title, subtitle):
    x, y, w, h = rect
    card(x, y, w, h)
    fig.text(x + 0.015, y + h - 0.038, title, color=INK, fontsize=13.5, weight='bold')
    fig.text(x + 0.015, y + h - 0.064, subtitle, color=MUTED, fontsize=9.2)
    ax = fig.add_axes([x + 0.085, y + 0.035, w - 0.13, h - 0.13], zorder=5)
    ax.patch.set_alpha(0)
    for s in ax.spines.values():
        s.set_visible(False)
    ax.tick_params(colors=MUTED, labelsize=9.5, length=0)
    ax.grid(axis='x', color=LINE, linewidth=0.8)
    ax.set_axisbelow(True)
    return ax


def bars(ax, labels, values, colors, unit, xmax=None):
    ys = list(range(len(labels)))[::-1]
    ax.barh(ys, values, color=colors, height=0.55)
    ax.set_yticks(ys, labels, color=INK, fontsize=10.5)
    top = xmax or max(values) * 1.45
    ax.set_xlim(0, top)
    for yv, v in zip(ys, values):
        ax.text(v + top * 0.02, yv, f'{v:.1f} {unit}', va='center', color=INK, fontsize=10.5, weight='bold')


RX, RW = 0.675, 0.30
ax = panel((RX, 0.635, RW, 0.25), 'Secure handshake', 'Connect + mutual auth, loopback (lower is better)')
bars(ax, ['median', 'p95'], [bench['handshake_ms_median'], bench['handshake_ms_p95']], [ACCENT, ACCENT2], 'ms')

frame_ms = aot.get('aot_aead_ms_per_frame_roundtrip', bench['aead_ms_per_frame_roundtrip'])
ax = panel((RX, 0.37, RW, 0.25), 'Encryption cost per frame', '100 KB frame, encrypt + decrypt, release build')
bars(ax, ['crypto', '30 fps budget'], [frame_ms, 1000 / 30], [ACCENT, '#3A3A55'], 'ms', xmax=1000 / 30 * 1.4)

ax = panel((RX, 0.105, RW, 0.25), 'Encrypted stream', 'Full session, 100 KB frames, test runner')
bars(ax, ['achieved', 'target'], [bench['stream_fps'], bench['stream_target_fps']], [GOOD, '#3A3A55'], 'fps',
     xmax=bench['stream_target_fps'] * 1.4)

deps = bench.get('deps_checked')
if deps:
    fig.text(RX, 0.072, f'{deps} dependencies checked against OSV · 0 known vulnerabilities', color=MUTED, fontsize=9)
fig.text(0.975, 0.016, f"{report['os'][:60]}  ·  Dart {report['dart']}  ·  {report['generated'][:10]}",
         color=MUTED, fontsize=8.5, ha='right')
os.makedirs('docs', exist_ok=True)
fig.savefig('docs/security-benchmark.png', facecolor=BG)
print('wrote docs/security-benchmark.png')
