// PixMirror native layer for Windows.
//
// Exported from the runner executable and loaded from Dart with
// DynamicLibrary.executable(). Provides:
//   * monitor enumeration
//   * screen capture: DXGI Desktop Duplication (GPU, change-driven), with a
//     GDI fallback for when duplication is unavailable (e.g. secure desktop)
//   * JPEG encoding (WIC)
//   * cursor position / shape
//   * mouse and keyboard injection (SendInput)
//
// All functions are safe to call from any thread; capture is serialized.

#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wincodec.h>
#include <objidl.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>

#define PM_API extern "C" __declspec(dllexport)

namespace {

template <typename T>
void SafeRelease(T*& p) {
  if (p) {
    p->Release();
    p = nullptr;
  }
}

// ---- Monitors (cached; cursor polling calls this 30x a second) -------------

struct Monitor {
  RECT rect;
  bool primary;
};

std::mutex g_monitor_mutex;
std::vector<Monitor> g_monitors;
ULONGLONG g_monitors_at = 0;

BOOL CALLBACK EnumMonitorProc(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
  auto* list = reinterpret_cast<std::vector<Monitor>*>(data);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (GetMonitorInfo(monitor, &info)) {
    list->push_back({info.rcMonitor, (info.dwFlags & MONITORINFOF_PRIMARY) != 0});
  }
  return TRUE;
}

// Primary monitor is always index 0.
std::vector<Monitor> Monitors() {
  std::lock_guard<std::mutex> lock(g_monitor_mutex);
  ULONGLONG now = GetTickCount64();
  if (g_monitors.empty() || now - g_monitors_at > 1000) {
    std::vector<Monitor> list;
    EnumDisplayMonitors(nullptr, nullptr, EnumMonitorProc,
                        reinterpret_cast<LPARAM>(&list));
    for (size_t i = 1; i < list.size(); i++) {
      if (list[i].primary) {
        std::swap(list[0], list[i]);
        break;
      }
    }
    g_monitors = list;
    g_monitors_at = now;
  }
  return g_monitors;
}

bool MonitorAt(int index, RECT* out) {
  auto list = Monitors();
  if (list.empty()) return false;
  if (index < 0 || index >= static_cast<int>(list.size())) index = 0;
  *out = list[index].rect;
  return true;
}

// ---- Shared capture state --------------------------------------------------

std::mutex g_capture_mutex;
IWICImagingFactory* g_wic = nullptr;

// Last scaled frame (BGRX, tightly packed). Re-encoded when a viewer asks
// for a forced frame while the screen is idle.
std::vector<uint8_t> g_frame;
int g_frame_w = 0;
int g_frame_h = 0;
bool g_force = true;

void EnsureCom() {
  // Dart isolates run on arbitrary threads; MTA init is idempotent per thread.
  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  (void)hr;  // S_FALSE / RPC_E_CHANGED_MODE are fine: COM is usable.
}

bool EnsureWic() {
  if (g_wic) return true;
  EnsureCom();
  return SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                    CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(&g_wic)));
}

void TargetSize(int src_w, int src_h, int max_width, int* w, int* h) {
  *w = src_w;
  *h = src_h;
  if (max_width > 0 && *w > max_width) {
    *w = max_width;
    *h = static_cast<int>(static_cast<int64_t>(src_h) * max_width / src_w);
  }
  *w &= ~1;
  *h &= ~1;
}

// Bilinear downscale of a BGRA surface into g_frame.
void ScaleInto(const uint8_t* src, int src_pitch, int src_w, int src_h, int w, int h) {
  g_frame.resize(static_cast<size_t>(w) * h * 4);
  g_frame_w = w;
  g_frame_h = h;
  uint8_t* dst = g_frame.data();
  if (w == src_w && h == src_h) {
    for (int y = 0; y < h; y++) {
      memcpy(dst + static_cast<size_t>(y) * w * 4, src + static_cast<size_t>(y) * src_pitch, static_cast<size_t>(w) * 4);
    }
    return;
  }
  // 16.16 fixed point; sample at pixel centers.
  const int64_t sx = (static_cast<int64_t>(src_w) << 16) / w;
  const int64_t sy = (static_cast<int64_t>(src_h) << 16) / h;
  std::vector<int> x0(w), fx(w);
  for (int x = 0; x < w; x++) {
    int64_t fxp = (x * sx) + (sx >> 1) - (1 << 15);
    if (fxp < 0) fxp = 0;
    x0[x] = static_cast<int>(fxp >> 16);
    if (x0[x] >= src_w - 1) {
      x0[x] = src_w - 2;
      fx[x] = 0xFFFF;
    } else {
      fx[x] = static_cast<int>(fxp & 0xFFFF);
    }
  }
  for (int y = 0; y < h; y++) {
    int64_t fyp = (y * sy) + (sy >> 1) - (1 << 15);
    if (fyp < 0) fyp = 0;
    int y0 = static_cast<int>(fyp >> 16);
    int fy = static_cast<int>(fyp & 0xFFFF);
    if (y0 >= src_h - 1) {
      y0 = src_h - 2;
      fy = 0xFFFF;
    }
    const uint8_t* r0 = src + static_cast<size_t>(y0) * src_pitch;
    const uint8_t* r1 = r0 + src_pitch;
    uint8_t* out = dst + static_cast<size_t>(y) * w * 4;
    for (int x = 0; x < w; x++) {
      const uint8_t* a = r0 + x0[x] * 4;
      const uint8_t* b = r1 + x0[x] * 4;
      const int wx = fx[x] >> 8, wy = fy >> 8;  // 0..255
      for (int c = 0; c < 3; c++) {
        int top = a[c] * (256 - wx) + a[c + 4] * wx;
        int bot = b[c] * (256 - wx) + b[c + 4] * wx;
        out[x * 4 + c] = static_cast<uint8_t>((top * (256 - wy) + bot * wy) >> 16);
      }
      out[x * 4 + 3] = 255;
    }
  }
}

bool EncodeJpeg(int quality, uint8_t** out, int* out_len) {
  if (!EnsureWic() || g_frame.empty()) return false;
  const int w = g_frame_w, h = g_frame_h;
  bool ok = false;
  IStream* stream = nullptr;
  IWICBitmapEncoder* encoder = nullptr;
  IWICBitmapFrameEncode* frame = nullptr;
  IPropertyBag2* props = nullptr;
  IWICBitmap* source = nullptr;

  do {
    if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) break;
    if (FAILED(g_wic->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder))) break;
    if (FAILED(encoder->Initialize(stream, WICBitmapEncoderNoCache))) break;
    if (FAILED(encoder->CreateNewFrame(&frame, &props))) break;

    PROPBAG2 option{};
    option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_R4;
    value.fltVal = static_cast<float>(quality) / 100.0f;
    props->Write(1, &option, &value);

    if (FAILED(frame->Initialize(props))) break;
    if (FAILED(frame->SetSize(w, h))) break;
    WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
    if (FAILED(frame->SetPixelFormat(&format))) break;
    if (FAILED(g_wic->CreateBitmapFromMemory(
            w, h, GUID_WICPixelFormat32bppBGR, w * 4, w * h * 4,
            g_frame.data(), &source)))
      break;
    // WriteSource converts 32bpp BGRX -> 24bpp BGR for us.
    if (FAILED(frame->WriteSource(source, nullptr))) break;
    if (FAILED(frame->Commit())) break;
    if (FAILED(encoder->Commit())) break;

    HGLOBAL global = nullptr;
    if (FAILED(GetHGlobalFromStream(stream, &global))) break;
    STATSTG stat{};
    if (FAILED(stream->Stat(&stat, STATFLAG_NONAME))) break;
    int len = static_cast<int>(stat.cbSize.QuadPart);
    void* src = GlobalLock(global);
    if (!src) break;
    *out = static_cast<uint8_t*>(malloc(len));
    if (*out) {
      memcpy(*out, src, len);
      *out_len = len;
      ok = true;
    }
    GlobalUnlock(global);
  } while (false);

  SafeRelease(source);
  SafeRelease(props);
  SafeRelease(frame);
  SafeRelease(encoder);
  SafeRelease(stream);
  return ok;
}

// ---- DXGI Desktop Duplication ---------------------------------------------

struct Duplication {
  ID3D11Device* device = nullptr;
  ID3D11DeviceContext* context = nullptr;
  IDXGIOutputDuplication* dup = nullptr;
  ID3D11Texture2D* staging = nullptr;
  int monitor = -1;
  RECT rect{};
  ULONGLONG retry_after = 0;  // back off after failures (e.g. secure desktop)

  void Reset() {
    SafeRelease(staging);
    SafeRelease(dup);
    SafeRelease(context);
    SafeRelease(device);
    monitor = -1;
  }

  bool Init(int index, const RECT& want) {
    Reset();
    IDXGIFactory1* factory = nullptr;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return false;
    bool ok = false;
    IDXGIAdapter1* adapter = nullptr;
    for (UINT a = 0; !ok && factory->EnumAdapters1(a, &adapter) != DXGI_ERROR_NOT_FOUND; a++) {
      IDXGIOutput* output = nullptr;
      for (UINT o = 0; !ok && adapter->EnumOutputs(o, &output) != DXGI_ERROR_NOT_FOUND; o++) {
        DXGI_OUTPUT_DESC desc{};
        output->GetDesc(&desc);
        if (EqualRect(&desc.DesktopCoordinates, &want) && desc.Rotation <= DXGI_MODE_ROTATION_IDENTITY) {
          IDXGIOutput1* output1 = nullptr;
          D3D_FEATURE_LEVEL level;
          if (SUCCEEDED(output->QueryInterface(IID_PPV_ARGS(&output1))) &&
              SUCCEEDED(D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0, nullptr, 0,
                                          D3D11_SDK_VERSION, &device, &level, &context)) &&
              SUCCEEDED(output1->DuplicateOutput(device, &dup))) {
            ok = true;
            monitor = index;
            rect = want;
          }
          SafeRelease(output1);
        }
        SafeRelease(output);
      }
      SafeRelease(adapter);
    }
    SafeRelease(factory);
    if (!ok) Reset();
    return ok;
  }

  // 1 new frame in g_frame, 0 no change, -1 failure (caller falls back).
  int Capture(int index, int max_width) {
    RECT r;
    if (!MonitorAt(index, &r)) return -1;
    if (dup == nullptr || monitor != index || !EqualRect(&rect, &r)) {
      if (GetTickCount64() < retry_after) return -1;
      if (!Init(index, r)) {
        retry_after = GetTickCount64() + 2000;
        return -1;
      }
    }

    DXGI_OUTDUPL_FRAME_INFO info{};
    IDXGIResource* resource = nullptr;
    HRESULT hr = dup->AcquireNextFrame(0, &info, &resource);
    if (hr == DXGI_ERROR_WAIT_TIMEOUT) return 0;
    if (FAILED(hr)) {
      // ACCESS_LOST on mode changes / desktop switches: rebuild next time.
      Reset();
      return -1;
    }

    int result = 0;
    // Mouse-only updates carry no new image.
    if (info.LastPresentTime.QuadPart != 0) {
      ID3D11Texture2D* texture = nullptr;
      if (SUCCEEDED(resource->QueryInterface(IID_PPV_ARGS(&texture)))) {
        D3D11_TEXTURE2D_DESC desc;
        texture->GetDesc(&desc);
        if (staging) {
          D3D11_TEXTURE2D_DESC sd;
          staging->GetDesc(&sd);
          if (sd.Width != desc.Width || sd.Height != desc.Height || sd.Format != desc.Format) {
            SafeRelease(staging);
          }
        }
        if (!staging) {
          D3D11_TEXTURE2D_DESC sd = desc;
          sd.Usage = D3D11_USAGE_STAGING;
          sd.BindFlags = 0;
          sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
          sd.MiscFlags = 0;
          sd.MipLevels = 1;
          sd.ArraySize = 1;
          device->CreateTexture2D(&sd, nullptr, &staging);
        }
        if (staging) {
          context->CopyResource(staging, texture);
          result = 1;
        } else {
          result = -1;
        }
        SafeRelease(texture);
      }
    }
    resource->Release();
    dup->ReleaseFrame();
    if (result != 1) return result;

    D3D11_MAPPED_SUBRESOURCE map;
    if (FAILED(context->Map(staging, 0, D3D11_MAP_READ, 0, &map))) return -1;
    D3D11_TEXTURE2D_DESC sd;
    staging->GetDesc(&sd);
    int w, h;
    TargetSize(static_cast<int>(sd.Width), static_cast<int>(sd.Height), max_width, &w, &h);
    ScaleInto(static_cast<const uint8_t*>(map.pData), static_cast<int>(map.RowPitch),
              static_cast<int>(sd.Width), static_cast<int>(sd.Height), w, h);
    context->Unmap(staging, 0);
    return 1;
  }
};

Duplication g_dup;

// ---- GDI fallback ------------------------------------------------------------

HDC g_mem_dc = nullptr;
HBITMAP g_dib = nullptr;
void* g_dib_bits = nullptr;
int g_dib_w = 0;
int g_dib_h = 0;

bool CaptureGdi(int monitor, int max_width) {
  RECT r;
  if (!MonitorAt(monitor, &r)) return false;
  int src_w = r.right - r.left;
  int src_h = r.bottom - r.top;
  if (!g_mem_dc) g_mem_dc = CreateCompatibleDC(nullptr);
  if (!g_dib || g_dib_w != src_w || g_dib_h != src_h) {
    if (g_dib) DeleteObject(g_dib);
    BITMAPINFO bmi{};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = src_w;
    bmi.bmiHeader.biHeight = -src_h;  // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    g_dib = CreateDIBSection(g_mem_dc, &bmi, DIB_RGB_COLORS, &g_dib_bits, nullptr, 0);
    if (!g_dib) return false;
    SelectObject(g_mem_dc, g_dib);
    g_dib_w = src_w;
    g_dib_h = src_h;
  }
  HDC screen = GetDC(nullptr);
  BitBlt(g_mem_dc, 0, 0, src_w, src_h, screen, r.left, r.top, SRCCOPY);
  ReleaseDC(nullptr, screen);
  GdiFlush();
  int w, h;
  TargetSize(src_w, src_h, max_width, &w, &h);
  ScaleInto(static_cast<uint8_t*>(g_dib_bits), src_w * 4, src_w, src_h, w, h);
  return true;
}

uint64_t HashFrame() {
  uint64_t h = 1469598103934665603ULL;
  const uint64_t* words = reinterpret_cast<const uint64_t*>(g_frame.data());
  size_t count = g_frame.size() / 8;
  for (size_t i = 0; i < count; i += 7) {
    h ^= words[i];
    h *= 1099511628211ULL;
  }
  return h;
}

uint64_t g_gdi_hash = 0;

void SendMouse(DWORD flags, LONG dx = 0, LONG dy = 0, DWORD data = 0) {
  INPUT input{};
  input.type = INPUT_MOUSE;
  input.mi.dx = dx;
  input.mi.dy = dy;
  input.mi.mouseData = data;
  input.mi.dwFlags = flags;
  SendInput(1, &input, sizeof(INPUT));
}

bool IsExtendedKey(WORD vk) {
  switch (vk) {
    case VK_INSERT: case VK_DELETE: case VK_HOME: case VK_END:
    case VK_PRIOR: case VK_NEXT: case VK_LEFT: case VK_RIGHT:
    case VK_UP: case VK_DOWN: case VK_LWIN: case VK_RWIN:
    case VK_APPS: case VK_RCONTROL: case VK_RMENU: case VK_DIVIDE:
    case VK_NUMLOCK: case VK_SNAPSHOT:
      return true;
    default:
      return false;
  }
}

}  // namespace

// ---- Monitors --------------------------------------------------------------

PM_API int pm_monitor_count() { return static_cast<int>(Monitors().size()); }

PM_API int pm_monitor_rect(int index, int* left, int* top, int* width,
                           int* height) {
  RECT r;
  if (!MonitorAt(index, &r)) return 0;
  *left = r.left;
  *top = r.top;
  *width = r.right - r.left;
  *height = r.bottom - r.top;
  return 1;
}

// ---- Capture ---------------------------------------------------------------

// Returns 1 with a new JPEG in *out (free with pm_free), 0 when the screen is
// unchanged since the previous call (only if skip_unchanged), -1 on error.
PM_API int pm_capture_jpeg(int monitor, int max_width, int quality,
                           int skip_unchanged, uint8_t** out, int* out_len,
                           int* out_w, int* out_h) {
  std::lock_guard<std::mutex> lock(g_capture_mutex);
  EnsureCom();
  int rc = g_dup.Capture(monitor, max_width);
  if (rc < 0) {
    // GDI path: always grabs, so detect "unchanged" by hashing.
    if (!CaptureGdi(monitor, max_width)) return -1;
    uint64_t hash = HashFrame();
    rc = (hash == g_gdi_hash) ? 0 : 1;
    g_gdi_hash = hash;
  }
  // A size change (quality preset switched) needs a fresh frame.
  if (rc == 0 && g_frame_w > 0) {
    int w, h;
    RECT r;
    if (MonitorAt(monitor, &r)) {
      TargetSize(r.right - r.left, r.bottom - r.top, max_width, &w, &h);
      if (w != g_frame_w && !g_frame.empty() && g_dup.staging) {
        D3D11_MAPPED_SUBRESOURCE map;
        if (SUCCEEDED(g_dup.context->Map(g_dup.staging, 0, D3D11_MAP_READ, 0, &map))) {
          D3D11_TEXTURE2D_DESC sd;
          g_dup.staging->GetDesc(&sd);
          ScaleInto(static_cast<const uint8_t*>(map.pData), static_cast<int>(map.RowPitch),
                    static_cast<int>(sd.Width), static_cast<int>(sd.Height), w, h);
          g_dup.context->Unmap(g_dup.staging, 0);
          rc = 1;
        }
      }
    }
  }
  if (rc == 0 && (g_force || !skip_unchanged) && !g_frame.empty()) rc = 1;
  if (rc != 1) return rc;
  if (!EncodeJpeg(quality, out, out_len)) return -1;
  g_force = false;
  *out_w = g_frame_w;
  *out_h = g_frame_h;
  return 1;
}

// Forces the next capture to be sent even if the screen did not change.
PM_API void pm_capture_invalidate() {
  std::lock_guard<std::mutex> lock(g_capture_mutex);
  g_force = true;
}

PM_API void pm_free(uint8_t* p) { free(p); }

// ---- Cursor ----------------------------------------------------------------

// Writes the cursor position normalized to the monitor (0..1). Returns the
// cursor kind: 0 hidden/off-monitor, 1 arrow, 2 text beam, 3 hand, 4 other.
PM_API int pm_cursor(int monitor, double* nx, double* ny) {
  RECT r;
  if (!MonitorAt(monitor, &r)) return 0;
  CURSORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetCursorInfo(&info) || !(info.flags & CURSOR_SHOWING)) return 0;
  POINT p = info.ptScreenPos;
  if (p.x < r.left || p.x >= r.right || p.y < r.top || p.y >= r.bottom) {
    return 0;
  }
  *nx = static_cast<double>(p.x - r.left) / (r.right - r.left);
  *ny = static_cast<double>(p.y - r.top) / (r.bottom - r.top);
  static HCURSOR arrow = LoadCursor(nullptr, IDC_ARROW);
  static HCURSOR beam = LoadCursor(nullptr, IDC_IBEAM);
  static HCURSOR hand = LoadCursor(nullptr, IDC_HAND);
  if (info.hCursor == arrow) return 1;
  if (info.hCursor == beam) return 2;
  if (info.hCursor == hand) return 3;
  return 4;
}

// ---- Input -----------------------------------------------------------------

PM_API void pm_mouse_abs(int monitor, double nx, double ny) {
  RECT r;
  if (!MonitorAt(monitor, &r)) return;
  if (nx < 0) nx = 0;
  if (nx > 1) nx = 1;
  if (ny < 0) ny = 0;
  if (ny > 1) ny = 1;
  int px = r.left + static_cast<int>(nx * (r.right - r.left - 1));
  int py = r.top + static_cast<int>(ny * (r.bottom - r.top - 1));
  int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
  int vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
  int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  int vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  LONG ax = static_cast<LONG>((static_cast<int64_t>(px - vx) * 65535) / (vw - 1));
  LONG ay = static_cast<LONG>((static_cast<int64_t>(py - vy) * 65535) / (vh - 1));
  SendMouse(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
            ax, ay);
}

PM_API void pm_mouse_rel(int dx, int dy) {
  // Relative SendInput is subject to pointer acceleration; move the cursor
  // directly so trackpad deltas map 1:1 to pixels.
  POINT p;
  if (!GetCursorPos(&p)) return;
  SetCursorPos(p.x + dx, p.y + dy);
}

// button: 0 left, 1 right, 2 middle.
PM_API void pm_mouse_button(int button, int down) {
  DWORD flags;
  switch (button) {
    case 1: flags = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP; break;
    case 2: flags = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP; break;
    default: flags = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP; break;
  }
  SendMouse(flags);
}

// Wheel deltas in WHEEL_DELTA (120) units per notch; positive dy scrolls up.
PM_API void pm_mouse_wheel(int dx, int dy) {
  if (dy) SendMouse(MOUSEEVENTF_WHEEL, 0, 0, static_cast<DWORD>(dy));
  if (dx) SendMouse(MOUSEEVENTF_HWHEEL, 0, 0, static_cast<DWORD>(dx));
}

PM_API void pm_key(int vk, int down) {
  INPUT input{};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = static_cast<WORD>(vk);
  input.ki.wScan = static_cast<WORD>(MapVirtualKey(vk, MAPVK_VK_TO_VSC));
  input.ki.dwFlags = (down ? 0 : KEYEVENTF_KEYUP) |
                     (IsExtendedKey(static_cast<WORD>(vk)) ? KEYEVENTF_EXTENDEDKEY : 0);
  SendInput(1, &input, sizeof(INPUT));
}

PM_API void pm_type(const uint16_t* text, int length) {
  std::vector<INPUT> inputs;
  inputs.reserve(length * 2);
  for (int i = 0; i < length; i++) {
    uint16_t c = text[i];
    if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < length && text[i + 1] == '\n') continue;
      for (int up = 0; up < 2; up++) {
        INPUT in{};
        in.type = INPUT_KEYBOARD;
        in.ki.wVk = VK_RETURN;
        in.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
        inputs.push_back(in);
      }
      continue;
    }
    for (int up = 0; up < 2; up++) {
      INPUT in{};
      in.type = INPUT_KEYBOARD;
      in.ki.wScan = c;
      in.ki.dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0);
      inputs.push_back(in);
    }
  }
  if (!inputs.empty()) {
    SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
  }
}
