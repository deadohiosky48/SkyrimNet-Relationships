#include "Painting.h"

#include "PCH.h"

#include "Dashboard.h"
#include "L10n.h"
#include "Model.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <format>
#include <fstream>
#include <functional>
#include <mutex>
#include <random>
#include <thread>
#include <vector>

#include <d3d11.h>
#include <dxgi.h>
#include <wincodec.h>
#include <wrl/client.h>

namespace SNRom::Painting {

    namespace {

        using Microsoft::WRL::ComPtr;
        using json = nlohmann::json;

        // ------------------------------------------------------------------
        // The frame. Caught in the swap chain's Present, before it is handed
        // on: the world, with whatever the game drew into it, and none of the
        // overlays that draw themselves in their own Present further along.
        // The hook is put in at the first sitting, not at startup: nobody who
        // never asks for a painting has it.
        // ------------------------------------------------------------------
        using PresentFn = HRESULT(STDMETHODCALLTYPE*)(IDXGISwapChain*, UINT, UINT);
        PresentFn         g_present = nullptr;
        std::atomic<bool> g_hooked{ false };
        std::atomic<bool> g_active{ false };      // a sitting is under way
        std::atomic<bool> g_stepQueued{ false };  // its next step is on the main thread's list
        std::atomic<bool> g_wantCopy{ false };    // copy the frame at the next Present
        std::atomic<int>  g_copied{ 0 };          // 0 not yet, 1 copied, 2 failed
        std::atomic<bool> g_busy{ false };        // a sitting or its painting

        struct Shot {
            UINT                      w = 0;
            UINT                      h = 0;
            std::vector<std::uint8_t> bgra;
            std::string               format;
        };
        Shot g_shot;  // written in Present while g_wantCopy, read after g_copied

        // The latest painting, while it is described: the card shows it from
        // here, and from its kept record (Keep) once a later session reads it.
        std::mutex   g_latestLock;
        std::string  g_latestName;     // file stem
        RE::FormID   g_latestPartner = 0;
        std::string  g_latestPlaythrough;
        bool         g_latestWedding = false;
        std::string  g_latestSrc;    // PNG data URL, small
        std::string  g_latestTitle;  // the vision model's, "" until it answers
        std::string  g_latestDescription;
        std::string  g_latestDescribing;  // "asked", "failed: why", or ""

        // SkyrimNet's custom prompt (CppAPI/PublicAPI.h, v8+), resolved at the
        // first description.
        using CustomPromptFn = bool (*)(const char*, const char*, const char*, std::function<void(const char*, int)>);

        void Step();

        float Half(std::uint16_t a_h) {
            const std::uint32_t sign = (a_h >> 15) & 1;
            const std::uint32_t exp = (a_h >> 10) & 0x1F;
            const std::uint32_t man = a_h & 0x3FF;
            float v;
            if (exp == 0) {
                v = std::ldexp(static_cast<float>(man), -24);
            } else if (exp == 31) {
                v = man ? 0.0f : 65504.0f;
            } else {
                v = std::ldexp(static_cast<float>(man | 0x400), static_cast<int>(exp) - 25);
            }
            return sign ? -v : v;
        }

        std::uint8_t ToByte(float a_v) {
            return static_cast<std::uint8_t>(std::clamp(a_v, 0.0f, 1.0f) * 255.0f + 0.5f);
        }

        // Linear HDR light, as a float buffer holds it, to an sRGB byte.
        std::uint8_t LinearToByte(float a_v) {
            a_v = std::clamp(a_v, 0.0f, 1.0f);
            const float s = a_v <= 0.0031308f ? a_v * 12.92f : 1.055f * std::pow(a_v, 1.0f / 2.4f) - 0.055f;
            return ToByte(s);
        }

        DXGI_FORMAT Concrete(DXGI_FORMAT a_f) {
            switch (a_f) {
            case DXGI_FORMAT_R8G8B8A8_TYPELESS:
                return DXGI_FORMAT_R8G8B8A8_UNORM;
            case DXGI_FORMAT_B8G8R8A8_TYPELESS:
                return DXGI_FORMAT_B8G8R8A8_UNORM;
            case DXGI_FORMAT_B8G8R8X8_TYPELESS:
                return DXGI_FORMAT_B8G8R8X8_UNORM;
            case DXGI_FORMAT_R10G10B10A2_TYPELESS:
                return DXGI_FORMAT_R10G10B10A2_UNORM;
            case DXGI_FORMAT_R16G16B16A16_TYPELESS:
                return DXGI_FORMAT_R16G16B16A16_FLOAT;
            default:
                return a_f;
            }
        }

        // The back buffer, read into g_shot as BGRA bytes. On the thread
        // that presents, with the immediate context, before the frame is
        // handed on; the Map waits for the copy, once.
        void Copy(IDXGISwapChain* a_chain) {
            const auto fail = [](const char* a_step, HRESULT a_hr) {
                SKSE::log::warn("Painting: the frame could not be copied at {} (0x{:08X})", a_step,
                                static_cast<std::uint32_t>(a_hr));
                g_copied = 2;
            };
            ComPtr<ID3D11Texture2D> back;
            auto hr = a_chain->GetBuffer(0, IID_PPV_ARGS(&back));
            if (FAILED(hr) || !back) {
                return fail("GetBuffer", hr);
            }
            D3D11_TEXTURE2D_DESC desc{};
            back->GetDesc(&desc);
            ComPtr<ID3D11Device> device;
            back->GetDevice(&device);
            ComPtr<ID3D11DeviceContext> context;
            device->GetImmediateContext(&context);
            const auto format = Concrete(desc.Format);

            ComPtr<ID3D11Texture2D> source = back;
            if (desc.SampleDesc.Count > 1) {
                auto resolved = desc;
                resolved.SampleDesc = { 1, 0 };
                resolved.Format = format;
                resolved.BindFlags = 0;
                resolved.MiscFlags = 0;
                ComPtr<ID3D11Texture2D> single;
                hr = device->CreateTexture2D(&resolved, nullptr, &single);
                if (FAILED(hr)) {
                    return fail("the resolve target", hr);
                }
                context->ResolveSubresource(single.Get(), 0, back.Get(), 0, format);
                source = single;
            }
            auto stagingDesc = desc;
            stagingDesc.Usage = D3D11_USAGE_STAGING;
            stagingDesc.BindFlags = 0;
            stagingDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            stagingDesc.MiscFlags = 0;
            stagingDesc.SampleDesc = { 1, 0 };
            stagingDesc.MipLevels = 1;
            stagingDesc.ArraySize = 1;
            ComPtr<ID3D11Texture2D> staging;
            hr = device->CreateTexture2D(&stagingDesc, nullptr, &staging);
            if (FAILED(hr)) {
                return fail("the staging copy", hr);
            }
            context->CopyResource(staging.Get(), source.Get());
            D3D11_MAPPED_SUBRESOURCE mapped{};
            hr = context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
            if (FAILED(hr)) {
                return fail("Map", hr);
            }
            g_shot.w = desc.Width;
            g_shot.h = desc.Height;
            g_shot.bgra.assign(static_cast<std::size_t>(desc.Width) * desc.Height * 4, 255);
            g_shot.format = std::format("DXGI format {}{}", static_cast<int>(desc.Format),
                                        desc.SampleDesc.Count > 1 ? std::format(", {}x MSAA", desc.SampleDesc.Count) : "");
            bool known = true;
            for (UINT y = 0; y < desc.Height && known; ++y) {
                const auto* row = static_cast<const std::uint8_t*>(mapped.pData) + static_cast<std::size_t>(y) * mapped.RowPitch;
                auto*       out = g_shot.bgra.data() + static_cast<std::size_t>(y) * desc.Width * 4;
                for (UINT x = 0; x < desc.Width; ++x, out += 4) {
                    switch (format) {
                    case DXGI_FORMAT_R8G8B8A8_UNORM:
                    case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
                        out[0] = row[x * 4 + 2];
                        out[1] = row[x * 4 + 1];
                        out[2] = row[x * 4 + 0];
                        break;
                    case DXGI_FORMAT_B8G8R8A8_UNORM:
                    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
                    case DXGI_FORMAT_B8G8R8X8_UNORM:
                    case DXGI_FORMAT_B8G8R8X8_UNORM_SRGB:
                        out[0] = row[x * 4 + 0];
                        out[1] = row[x * 4 + 1];
                        out[2] = row[x * 4 + 2];
                        break;
                    case DXGI_FORMAT_R10G10B10A2_UNORM: {
                        std::uint32_t v;
                        std::memcpy(&v, row + x * 4, 4);
                        out[2] = static_cast<std::uint8_t>((v & 0x3FF) >> 2);
                        out[1] = static_cast<std::uint8_t>(((v >> 10) & 0x3FF) >> 2);
                        out[0] = static_cast<std::uint8_t>(((v >> 20) & 0x3FF) >> 2);
                        break;
                    }
                    case DXGI_FORMAT_R16G16B16A16_FLOAT: {
                        std::uint16_t v[4];
                        std::memcpy(v, row + x * 8, 8);
                        out[2] = LinearToByte(Half(v[0]));
                        out[1] = LinearToByte(Half(v[1]));
                        out[0] = LinearToByte(Half(v[2]));
                        break;
                    }
                    default:
                        known = false;
                        break;
                    }
                    if (!known) {
                        break;
                    }
                }
            }
            context->Unmap(staging.Get(), 0);
            if (!known) {
                SKSE::log::warn("Painting: the frame is in a format this build cannot read ({})", g_shot.format);
                g_copied = 2;
                return;
            }
            g_copied = 1;
        }

        HRESULT STDMETHODCALLTYPE OnPresent(IDXGISwapChain* a_chain, UINT a_sync, UINT a_flags) {
            if (g_wantCopy.exchange(false)) {
                Copy(a_chain);
            }
            if (g_active && !g_stepQueued.exchange(true)) {
                SKSE::GetTaskInterface()->AddTask([]() {
                    g_stepQueued = false;
                    Step();
                });
            }
            return g_present(a_chain, a_sync, a_flags);
        }

        bool Hook() {
            if (g_hooked) {
                return true;
            }
            auto* window = RE::BSGraphics::Renderer::GetCurrentRenderWindow();
            auto* chain = window ? reinterpret_cast<IDXGISwapChain*>(window->swapChain) : nullptr;
            if (!chain) {
                SKSE::log::warn("Painting: no swap chain to watch");
                return false;
            }
            auto** table = *reinterpret_cast<void***>(chain);
            DWORD  old = 0;
            if (!VirtualProtect(&table[8], sizeof(void*), PAGE_EXECUTE_READWRITE, &old)) {
                SKSE::log::warn("Painting: the swap chain's table could not be written");
                return false;
            }
            g_present = reinterpret_cast<PresentFn>(table[8]);
            table[8] = reinterpret_cast<void*>(&OnPresent);
            VirtualProtect(&table[8], sizeof(void*), old, &old);
            g_hooked = true;
            SKSE::log::info("Painting: watching the frame");
            return true;
        }

        // ------------------------------------------------------------------
        // The sitting. Main thread only, a step a frame.
        // ------------------------------------------------------------------
        enum class Phase { kIdle, kWaiting, kThirdPerson, kPosing, kSettling, kCopying };

        struct Sitting {
            RE::FormID   partner = 0;
            Phase        phase = Phase::kIdle;
            int          frames = 0;
            int          total = 0;
            int          candidate = 0;
            int          widened = 0;
            bool         firstPerson = false;
            bool         freeCamera = false;
            bool         menusHidden = false;
            bool         heldStill = false;  // we stopped the world (Main::freezeTime)
            bool         wedding = false;    // the ceremony's kiss (Ceremony.cpp), not the card
            bool         kissSeen = false;   // a wedding's: their heads met before the world stopped
            int          waited = 0;         // frames a wedding's sitting has waited for the kiss
            bool         kiss = false;       // painted as they kissed, for the description
            std::string  playthrough;        // whose paintings it joins (Model's id at the asking)
            bool         facing = false;  // facing each other: left as they stand
            RE::NiPoint3 mid;
            RE::NiPoint3 side;  // from the couple toward the camera, level
            float        distance = 0.0f;
            RE::NiPoint3 eye;
            RE::NiPoint3 look;
            // Where they are on the screen at the copy, 0..1, y down: each
            // one's head and feet, the player first.
            float points[2][4]{};
            std::chrono::steady_clock::time_point began;
        };
        Sitting g_sit;
        // The free camera's rotation, as found: which of its two numbers is
        // the pitch, and which way the yaw runs. Found at the first sitting.
        int g_convention = -1;

        constexpr float kPi = 3.14159265f;
        constexpr int   kConventions = 4;
        constexpr int   kMaxFrames = 900;  // ~15 s at 60
        // Heads closer than this are a kiss (seen in play, wpm106: an OStim
        // kiss, 17 apart, head bone to head bone).
        constexpr float kKissHeads = 24.0f;
        // A wedding's sitting waits this long for the kiss to reach them,
        // then paints the two of them as they are.
        constexpr int   kKissWaitFrames = 600;  // ~10 s at 60

        RE::Actor* Partner() {
            return RE::TESForm::LookupByID<RE::Actor>(g_sit.partner);
        }

        RE::NiPoint3 HeadOf(RE::Actor* a_who) {
            if (auto* root = a_who->Get3D(false)) {
                if (auto* head = root->GetObjectByName("NPC Head [Head]")) {
                    return head->world.translate;
                }
            }
            auto at = a_who->GetPosition();
            at.z += 120.0f * a_who->GetScale();
            return at;
        }

        // Where a_at is on the screen now, 0..1 each way as the camera
        // reports it. False when behind the camera or there is none.
        bool Project(const RE::NiPoint3& a_at, float& a_x, float& a_y) {
            auto* camera = RE::Main::WorldRootCamera();
            if (!camera) {
                return false;
            }
            float z = -1.0f;
            camera->WorldPtToScreenPt3(a_at, a_x, a_y, z, 1e-5f);
            return z > 0.0f;
        }

        RE::FreeCameraState* FreeState() {
            auto* camera = RE::PlayerCamera::GetSingleton();
            if (!camera || !camera->IsInFreeCameraMode()) {
                return nullptr;
            }
            return skyrim_cast<RE::FreeCameraState*>(camera->currentState.get());
        }

        void Aim() {
            auto* state = FreeState();
            if (!state) {
                return;
            }
            g_sit.eye = { g_sit.mid.x + g_sit.side.x * g_sit.distance, g_sit.mid.y + g_sit.side.y * g_sit.distance,
                          g_sit.mid.z + 108.0f };
            g_sit.look = { g_sit.mid.x, g_sit.mid.y, g_sit.mid.z + 92.0f };
            const float dx = g_sit.look.x - g_sit.eye.x;
            const float dy = g_sit.look.y - g_sit.eye.y;
            const float yaw = std::atan2(dx, dy);  // the game's heading: 0 north, clockwise
            const float down = std::atan2(g_sit.eye.z - g_sit.look.z, std::sqrt(dx * dx + dy * dy));
            state->translation = g_sit.eye;
            switch (g_convention >= 0 ? g_convention : g_sit.candidate) {
            case 0:
                state->rotation = { down, yaw };
                break;
            case 1:
                state->rotation = { -down, yaw };
                break;
            case 2:
                state->rotation = { yaw, down };
                break;
            default:
                state->rotation = { down, kPi / 2.0f - yaw };
                break;
            }
        }

        // NOTHING IN THE WAY (seen in play, wpm98: in the Tundra Homestead the
        // camera stepped back through the wall and painted the planks). A
        // ray from a_from to a_to through the camera's own collision, which
        // walls, floors and furniture stop and people do not. True when
        // there is no world to ask.
        bool Clear(const RE::NiPoint3& a_from, const RE::NiPoint3& a_to) {
            auto* player = RE::PlayerCharacter::GetSingleton();
            auto* cell = player ? player->GetParentCell() : nullptr;
            auto* world = cell ? cell->GetbhkWorld() : nullptr;
            if (!world) {
                return true;
            }
            const float     s = RE::bhkWorld::GetWorldScale();
            RE::bhkPickData pick{};
            pick.rayInput.from = RE::hkVector4(a_from.x * s, a_from.y * s, a_from.z * s, 0.0f);
            pick.rayInput.to = RE::hkVector4(a_to.x * s, a_to.y * s, a_to.z * s, 0.0f);
            pick.rayInput.filterInfo.SetCollisionLayer(RE::COL_LAYER::kCameraSphere);
            {
                RE::BSReadLockGuard lock(world->worldLock);
                world->PickObject(pick);
            }
            return !pick.rayOutput.HasHit();
        }

        // a_at short of a_to by a_short, along the line from a_from.
        RE::NiPoint3 Short(const RE::NiPoint3& a_from, const RE::NiPoint3& a_to, float a_short) {
            const auto  d = a_to - a_from;
            const float len = d.Length();
            return len <= a_short ? a_from : a_from + d * ((len - a_short) / len);
        }

        // The camera at a_distance on a_side, as Aim places it.
        RE::NiPoint3 EyeAt(const RE::NiPoint3& a_side, float a_distance) {
            return { g_sit.mid.x + a_side.x * a_distance, g_sit.mid.y + a_side.y * a_distance, g_sit.mid.z + 108.0f };
        }

        // From a_eye the couple's middle and both heads can be seen.
        bool Sees(const RE::NiPoint3& a_eye) {
            auto*              player = RE::PlayerCharacter::GetSingleton();
            auto*              partner = Partner();
            const RE::NiPoint3 look{ g_sit.mid.x, g_sit.mid.y, g_sit.mid.z + 92.0f };
            if (!Clear(a_eye, Short(a_eye, look, 40.0f))) {
                return false;
            }
            for (auto* who : { static_cast<RE::Actor*>(player), partner }) {
                if (who && !Clear(a_eye, Short(a_eye, HeadOf(who), 25.0f))) {
                    return false;
                }
            }
            return true;
        }

        // The furthest of a few distances up to a_want on a_side with the
        // couple in sight; -1 when none is.
        float SeenFrom(const RE::NiPoint3& a_side, float a_want) {
            for (const float f : { 1.0f, 0.85f, 0.7f, 0.58f, 0.48f }) {
                const float d = a_want * f;
                if (d < 110.0f) {
                    break;
                }
                if (Sees(EyeAt(a_side, d))) {
                    return d;
                }
            }
            return -1.0f;
        }

        void Face() {
            if (g_sit.facing) {
                return;   // in each other's arms: turned, they would let go
            }
            auto* player = RE::PlayerCharacter::GetSingleton();
            auto* partner = Partner();
            for (auto* who : { static_cast<RE::Actor*>(player), partner }) {
                if (who) {
                    const auto at = who->GetPosition();
                    who->SetHeading(std::atan2(g_sit.eye.x - at.x, g_sit.eye.y - at.y));
                }
            }
        }

        void Restore(const char* a_why) {
            auto* camera = RE::PlayerCamera::GetSingleton();
            if (g_sit.freeCamera && camera && camera->IsInFreeCameraMode()) {
                camera->ToggleFreeCameraMode(false);
            }
            if (g_sit.firstPerson && camera) {
                camera->ForceFirstPerson();
            }
            if (g_sit.menusHidden) {
                if (auto* ui = RE::UI::GetSingleton()) {
                    ui->ShowMenus(true);
                }
            }
            if (g_sit.heldStill) {
                if (auto* main = RE::Main::GetSingleton()) {
                    main->GetRuntimeData().freezeTime = false;
                }
                g_sit.heldStill = false;
            }
            const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - g_sit.began).count();
            SKSE::log::info("Painting: the sitting ends ({}), {} frames, {} ms", a_why, g_sit.total, ms);
            g_sit.phase = Phase::kIdle;
            g_active = false;
        }

        void Abort(const std::string& a_why) {
            SKSE::log::warn("Painting: the sitting is given up: {}", a_why);
            Restore("given up");
            g_busy = false;
            RE::SendHUDMessage::ShowHUDMessage(
                L10n::Text("paint.hud.givenUp", "[Relationships] The painting could not be made: {0}", a_why).c_str());
        }

        // Each one's head and feet on the screen, y down, into g_sit.points.
        // False if either is behind the camera.
        bool Measure() {
            auto*      player = RE::PlayerCharacter::GetSingleton();
            auto*      partner = Partner();
            RE::Actor* who[2] = { player, partner };
            float      raw[2][4]{};
            for (int i = 0; i < 2; ++i) {
                if (!who[i] || !Project(HeadOf(who[i]), raw[i][0], raw[i][1]) ||
                    !Project(who[i]->GetPosition(), raw[i][2], raw[i][3])) {
                    return false;
                }
            }
            // Which way the camera's y runs: a head is above its feet.
            const bool up = raw[0][1] > raw[0][3];
            for (int i = 0; i < 2; ++i) {
                g_sit.points[i][0] = raw[i][0];
                g_sit.points[i][1] = up ? 1.0f - raw[i][1] : raw[i][1];
                g_sit.points[i][2] = raw[i][2];
                g_sit.points[i][3] = up ? 1.0f - raw[i][3] : raw[i][3];
            }
            return true;
        }

        struct Rect {
            float x0, y0, x1, y1;
        };

        // The portrait's frame in pixels, 4 wide to 5 high: heads near the
        // top, down to about the thigh, a shoulder's width either side.
        Rect CropFor(const float a_points[2][4], float a_w, float a_h) {
            float body = 0.0f, top = 1e9f, headLow = -1e9f, left = 1e9f, right = -1e9f;
            for (int i = 0; i < 2; ++i) {
                const float hx = a_points[i][0] * a_w, hy = a_points[i][1] * a_h;
                const float fy = a_points[i][3] * a_h;
                body = (std::max)(body, fy - hy);
                top = (std::min)(top, hy);
                headLow = (std::max)(headLow, hy);
                left = (std::min)(left, hx);
                right = (std::max)(right, hx);
            }
            Rect r{ left - 0.30f * body, top - 0.28f * body, right + 0.30f * body, headLow + 0.62f * body };
            const float w = r.x1 - r.x0, h = r.y1 - r.y0;
            if (w / h < 0.8f) {
                const float grow = (0.8f * h - w) / 2.0f;
                r.x0 -= grow;
                r.x1 += grow;
            } else {
                r.y1 = r.y0 + w / 0.8f;
            }
            return r;
        }

        void Paint(Shot a_shot, Sitting a_sit);
        void Describe(std::string a_name, std::string a_jpeg, Sitting a_sit);

        void Step() {
            if (g_sit.phase == Phase::kIdle) {
                g_active = false;
                return;
            }
            ++g_sit.total;
            if (g_sit.total > kMaxFrames && g_sit.phase != Phase::kWaiting) {
                return Abort("it took too long");
            }
            auto* ui = RE::UI::GetSingleton();
            auto* camera = RE::PlayerCamera::GetSingleton();
            auto* player = RE::PlayerCharacter::GetSingleton();
            auto* partner = Partner();
            if (!ui || !camera || !player) {
                return Abort("the game is not ready");
            }
            switch (g_sit.phase) {
            case Phase::kWaiting: {
                // Until the dashboard is gone and the game has run a moment.
                if (ui->GameIsPaused()) {
                    g_sit.frames = 0;
                    return;
                }
                if (!partner || partner->IsDead() || !partner->Is3DLoaded()) {
                    return Abort("they are not here");
                }
                // THE WEDDING KISS (the author, 2026-11-21: "make the painting
                // happen during the wedding ceremony kiss"). Asked for as the
                // kiss becomes a scene, which may open with them apart: the
                // world is stopped once their heads meet, or after a while
                // without, as they are.
                if (g_sit.wedding && !g_sit.heldStill && g_sit.frames == 0) {
                    const float heads = HeadOf(player).GetDistance(HeadOf(partner));
                    if (heads > kKissHeads && ++g_sit.waited < kKissWaitFrames) {
                        return;
                    }
                    g_sit.kissSeen = heads <= kKissHeads;
                    SKSE::log::info("Painting: the wedding kiss {} after {} frames (heads {:.0f} apart)",
                                    g_sit.kissSeen ? "reached" : "never reached", g_sit.waited, heads);
                }
                // HELD STILL (seen in play, wpm101: an OStim kiss had let go
                // by the time the frame was caught, 2.6 s after the dashboard
                // closed). In a scene - the camera free already, or the two
                // at one spot - the world stops the moment the game runs
                // again, as a photo mode stops it: the camera still moves and
                // the frame is still drawn, and the kiss waits for the
                // picture. Restore lets it go on every way out.
                if (g_sit.frames == 0 && !g_sit.heldStill) {
                    auto*       main = RE::Main::GetSingleton();
                    const float apart = player->GetPosition().GetDistance(partner->GetPosition());
                    if (main && !main->GetRuntimeData().freezeTime &&
                        (g_sit.kissSeen || camera->IsInFreeCameraMode() || apart < 20.0f)) {
                        main->GetRuntimeData().freezeTime = true;
                        g_sit.heldStill = true;
                        SKSE::log::info("Painting: in a scene ({:.0f} apart{}); the world is held still for the sitting",
                                        apart, camera->IsInFreeCameraMode() ? ", the camera free" : "");
                    }
                }
                // Until the dashboard has gone; a wedding has none.
                if (++g_sit.frames < (g_sit.wedding ? 2 : 20)) {
                    return;
                }
                const auto p = player->GetPosition();
                const auto s = partner->GetPosition();
                if (p.GetDistance(s) > 600.0f || partner->GetParentCell() != player->GetParentCell()) {
                    return Abort("stand beside them first");
                }
                g_sit.began = std::chrono::steady_clock::now();
                g_sit.total = 0;
                g_sit.firstPerson = camera->IsInFirstPerson();
                if (g_sit.firstPerson) {
                    camera->ForceThirdPerson();
                }
                g_sit.phase = Phase::kThirdPerson;
                g_sit.frames = 0;
                SKSE::log::info("Painting: the sitting begins with {} at {:.0f} apart{}", partner->GetDisplayFullName(),
                                p.GetDistance(s), g_sit.firstPerson ? ", from first person" : "");
                return;
            }
            case Phase::kThirdPerson: {
                if (++g_sit.frames < 15) {
                    return;
                }
                // The camera stands off to the side the player faces, square
                // to the line between them, far enough for both.
                const auto p = player->GetPosition();
                const auto s = partner->GetPosition();
                g_sit.mid = { (p.x + s.x) / 2.0f, (p.y + s.y) / 2.0f, (std::min)(p.z, s.z) };
                float ax = s.x - p.x, ay = s.y - p.y;
                const float apart = std::sqrt(ax * ax + ay * ay);
                const float heading = player->GetAngleZ();
                // IN EACH OTHER'S ARMS (seen in play, wpm97: a Baka kiss): a
                // paired animation stands both at one spot, facing each
                // other, and square-to-the-line-on-the-player's-facing-side
                // put the camera in front of the player, with the partner's
                // back to it. Facing each other, the picture is the side
                // view: the camera off the player's right, both in profile.
                // AT ONE SPOT (seen in play, wpm98: an OStim kiss, 0 apart):
                // the scene sets both headings alike and the animation turns
                // them, so their headings say nothing. Their heads do: the
                // camera stands square to the line between the two heads.
                const float pfx = std::sin(heading), pfy = std::cos(heading);
                const float sh = partner->GetAngleZ();
                const auto  ph = HeadOf(player), sp = HeadOf(partner);
                const float hx = sp.x - ph.x, hy = sp.y - ph.y, heads = std::hypot(hx, hy);
                const bool  oneSpot = apart < 20.0f;
                const bool  facing = oneSpot || (pfx * std::sin(sh) + pfy * std::cos(sh) < -0.7f &&
                                                 (ax * pfx + ay * pfy) / apart > 0.7f);
                if (oneSpot && heads > 4.0f) {
                    g_sit.side = { -hy / heads, hx / heads, 0.0f };
                    if (g_sit.side.x * pfy - g_sit.side.y * pfx < 0.0f) {   // the player's right of the two
                        g_sit.side = { hy / heads, -hx / heads, 0.0f };
                    }
                } else if (facing) {
                    g_sit.side = { pfy, -pfx, 0.0f };   // the player's right
                } else {
                    if (apart < 20.0f) {
                        ax = std::cos(heading);  // the player's right
                        ay = -std::sin(heading);
                    } else {
                        ax /= apart;
                        ay /= apart;
                    }
                    g_sit.side = { -ay, ax, 0.0f };
                    if (g_sit.side.x * pfx + g_sit.side.y * pfy < 0.0f) {
                        g_sit.side = { ay, -ax, 0.0f };
                    }
                }
                g_sit.kiss = g_sit.kissSeen || (g_sit.heldStill && heads <= kKissHeads);
                SKSE::log::info("Painting: posed {} ({:.0f} apart, heads {:.0f} apart{})",
                                facing ? "from the side, facing each other" : "from the front, side by side", apart, heads,
                                g_sit.kiss ? ", a kiss" : "");
                g_sit.facing = facing;
                g_sit.distance = 190.0f + apart * 0.6f;
                // A side the camera can see them from: this one, nearer if a
                // wall is in the way, else the other.
                {
                    const RE::NiPoint3 other{ -g_sit.side.x, -g_sit.side.y, 0.0f };
                    const float        here = SeenFrom(g_sit.side, g_sit.distance);
                    if (here < g_sit.distance) {
                        const float there = SeenFrom(other, g_sit.distance);
                        if (there > here) {
                            g_sit.side = other;
                        }
                        const float best = (std::max)(here, there);
                        if (best > 0.0f) {
                            g_sit.distance = best;
                        }
                        SKSE::log::info("Painting: in the way at {:.0f}: seen from {:.0f} on this side, {:.0f} on the other; "
                                        "the camera stands at {:.0f}{}",
                                        190.0f + apart * 0.6f, here, there, g_sit.distance,
                                        best > 0.0f ? "" : " (nowhere clear; it may not see them)");
                    }
                }
                g_sit.candidate = 0;
                g_sit.widened = 0;
                // ONLY OURS TURNED OFF (suspected in play, wpm99: after an
                // OStim scene the player could not move). Free already - a
                // scene's own camera - it was turned off at the end all the
                // same, and the scene's own ending then turned it back on.
                // Now it is left as it was found.
                const bool alreadyFree = camera->IsInFreeCameraMode();
                if (!alreadyFree) {
                    camera->ToggleFreeCameraMode(false);
                }
                if (!camera->IsInFreeCameraMode()) {
                    return Abort("the camera could not be moved");
                }
                g_sit.freeCamera = !alreadyFree;
                if (alreadyFree) {
                    SKSE::log::info("Painting: the camera was free already (a scene's own); it is left free after");
                }
                ui->ShowMenus(false);
                g_sit.menusHidden = true;
                Aim();
                Face();
                g_sit.phase = Phase::kPosing;
                g_sit.frames = 0;
                return;
            }
            case Phase::kPosing: {
                Aim();
                Face();
                if (++g_sit.frames < 5) {
                    return;
                }
                float x = -1.0f, y = -1.0f;
                const bool seen = Project(g_sit.look, x, y);
                if (seen && std::abs(x - 0.5f) < 0.06f && std::abs(y - 0.5f) < 0.06f) {
                    if (g_convention < 0) {
                        g_convention = g_sit.candidate;
                        SKSE::log::info("Painting: the free camera's rotation is convention {}", g_convention);
                    }
                    g_sit.phase = Phase::kSettling;
                    g_sit.frames = 0;
                    return;
                }
                {
                    // Missed: the camera's own axes, for working the
                    // convention out from the log if none of the four is right.
                    const int   tried = g_convention >= 0 ? g_convention : g_sit.candidate;
                    const auto* cam = RE::Main::WorldRootCamera();
                    const auto& m = cam ? cam->world.rotate : RE::NiMatrix3{};
                    const float wx = g_sit.look.x - g_sit.eye.x, wy = g_sit.look.y - g_sit.eye.y,
                                wz = g_sit.look.z - g_sit.eye.z;
                    const float wl = std::sqrt(wx * wx + wy * wy + wz * wz);
                    SKSE::log::info("Painting: rotation convention {} missed: the couple's middle at {:.2f}, {:.2f}{}; "
                                    "wanted {:.2f} {:.2f} {:.2f}; camera column0 {:.2f} {:.2f} {:.2f}, row0 {:.2f} {:.2f} {:.2f}",
                                    tried, x, y, seen ? "" : " (behind)", wx / wl, wy / wl, wz / wl, m.entry[0][0],
                                    m.entry[1][0], m.entry[2][0], m.entry[0][0], m.entry[0][1], m.entry[0][2]);
                }
                if (g_convention >= 0) {
                    g_convention = -1;  // it was wrong this time; look again
                    g_sit.candidate = 0;
                } else if (++g_sit.candidate >= kConventions) {
                    return Abort("the camera could not be aimed");
                }
                g_sit.frames = 0;
                Aim();
                return;
            }
            case Phase::kSettling: {
                Aim();
                Face();
                if (++g_sit.frames < 8) {
                    return;
                }
                if (!Measure()) {
                    return Abort("they could not be seen");
                }
                auto*       window = RE::BSGraphics::Renderer::GetCurrentRenderWindow();
                const float w = window ? static_cast<float>(window->windowWidth) : 1920.0f;
                const float h = window ? static_cast<float>(window->windowHeight) : 1080.0f;
                const auto  r = CropFor(g_sit.points, w, h);
                const bool  fits = r.x0 >= 0.0f && r.y0 >= 0.0f && r.x1 <= w && r.y1 <= h;
                if (!fits && g_sit.widened < 4 && !Sees(EyeAt(g_sit.side, g_sit.distance * 1.25f))) {
                    // A step back would put a wall between: as they are,
                    // the frame slid and cut to fit.
                    SKSE::log::info("Painting: they do not fit, and a step back to {:.0f} is through a wall; painted as they are",
                                    g_sit.distance * 1.25f);
                    g_sit.widened = 4;
                }
                if (!fits && g_sit.widened < 4) {
                    ++g_sit.widened;
                    g_sit.distance *= 1.25f;
                    SKSE::log::info("Painting: they do not fit ({:.0f},{:.0f} to {:.0f},{:.0f} of {:.0f}x{:.0f}); "
                                    "the camera steps back to {:.0f}",
                                    r.x0, r.y0, r.x1, r.y1, w, h, g_sit.distance);
                    g_sit.frames = 0;
                    Aim();
                    return;
                }
                // A moment more, for the turn to finish and the scene to settle.
                if (g_sit.frames < 40) {
                    return;
                }
                g_copied = 0;
                g_wantCopy = true;
                g_sit.phase = Phase::kCopying;
                g_sit.frames = 0;
                return;
            }
            case Phase::kCopying: {
                Aim();
                if (g_copied == 0) {
                    if (++g_sit.frames > 60) {
                        g_wantCopy = false;
                        return Abort("the frame never came");
                    }
                    return;
                }
                if (g_copied == 2) {
                    return Abort("the frame could not be read");
                }
                Measure();
                const auto sit = g_sit;
                Restore("caught");
                SKSE::log::info("Painting: caught {}x{} ({}), distance {:.0f}", g_shot.w, g_shot.h, g_shot.format,
                                sit.distance);
                std::thread([shot = std::move(g_shot), sit]() mutable { Paint(std::move(shot), sit); }).detach();
                g_shot = {};
                return;
            }
            default:
                return;
            }
        }

        // ------------------------------------------------------------------
        // The painting. On a thread of its own.
        // ------------------------------------------------------------------
        struct Image {
            int                       w = 0;
            int                       h = 0;
            std::vector<std::uint8_t> bgra;  // alpha 255
            std::uint8_t*             at(int a_x, int a_y) { return bgra.data() + (static_cast<std::size_t>(a_y) * w + a_x) * 4; }
            const std::uint8_t*       at(int a_x, int a_y) const { return bgra.data() + (static_cast<std::size_t>(a_y) * w + a_x) * 4; }
        };

        // a_r of the shot, into a_w by a_h: averaged over each pixel's
        // footprint when shrinking, blended between neighbours when growing.
        Image Resample(const Shot& a_shot, Rect a_r, int a_w, int a_h) {
            Image out{ a_w, a_h, std::vector<std::uint8_t>(static_cast<std::size_t>(a_w) * a_h * 4, 255) };
            const float sx = (a_r.x1 - a_r.x0) / a_w;
            const float sy = (a_r.y1 - a_r.y0) / a_h;
            const int   W = static_cast<int>(a_shot.w), H = static_cast<int>(a_shot.h);
            const auto  px = [&](int a_x, int a_y, int a_c) -> float {
                a_x = std::clamp(a_x, 0, W - 1);
                a_y = std::clamp(a_y, 0, H - 1);
                return a_shot.bgra[(static_cast<std::size_t>(a_y) * W + a_x) * 4 + a_c];
            };
            const int n = (std::max)(1, static_cast<int>(std::ceil((std::max)(sx, sy))));
            for (int y = 0; y < a_h; ++y) {
                for (int x = 0; x < a_w; ++x) {
                    float sum[3]{};
                    for (int j = 0; j < n; ++j) {
                        for (int i = 0; i < n; ++i) {
                            const float fx = a_r.x0 + (x + (i + 0.5f) / n) * sx - 0.5f;
                            const float fy = a_r.y0 + (y + (j + 0.5f) / n) * sy - 0.5f;
                            const int   x0 = static_cast<int>(std::floor(fx)), y0 = static_cast<int>(std::floor(fy));
                            const float tx = fx - x0, ty = fy - y0;
                            for (int c = 0; c < 3; ++c) {
                                const float top = px(x0, y0, c) * (1 - tx) + px(x0 + 1, y0, c) * tx;
                                const float bot = px(x0, y0 + 1, c) * (1 - tx) + px(x0 + 1, y0 + 1, c) * tx;
                                sum[c] += top * (1 - ty) + bot * ty;
                            }
                        }
                    }
                    auto* o = out.at(x, y);
                    for (int c = 0; c < 3; ++c) {
                        o[c] = static_cast<std::uint8_t>(std::clamp(sum[c] / (n * n) + 0.5f, 0.0f, 255.0f));
                    }
                }
            }
            return out;
        }

        // ------------------------------------------------------------------
        // OIL ON CANVAS (the author, 2026-11-18: the Kuwahara filter "makes
        // it look like a watercolor painting. I was hoping for something more
        // like an oil painting"). Painted as a painter would, after Hertzmann
        // (1998): a brown ground, then curved strokes in passes from a broad
        // brush to a fine one, each laid where the canvas is still furthest
        // from the sitting and drawn along the forms (the smoothed structure
        // tensor), each carrying one load of paint. The strokes leave relief -
        // a ridge with bristle marks - lit from the upper left, so they catch
        // the light like thick paint; then the weave and a varnished edge.
        // ------------------------------------------------------------------

        // One channel of floats.
        struct Plane {
            int                w = 0;
            int                h = 0;
            std::vector<float> v;
            Plane() = default;
            Plane(int a_w, int a_h, float a_fill = 0.0f) : w(a_w), h(a_h), v(static_cast<std::size_t>(a_w) * a_h, a_fill) {}
            float& at(int a_x, int a_y) { return v[static_cast<std::size_t>(a_y) * w + a_x]; }
            float  at(int a_x, int a_y) const { return v[static_cast<std::size_t>(a_y) * w + a_x]; }
            float  clamped(int a_x, int a_y) const { return at(std::clamp(a_x, 0, w - 1), std::clamp(a_y, 0, h - 1)); }
        };

        // A box of radius a_r, edges repeated, along each axis in turn.
        Plane Box(const Plane& a_in, int a_r) {
            const int   w = a_in.w, h = a_in.h;
            const float k = 1.0f / (2 * a_r + 1);
            Plane       mid(w, h), out(w, h);
            for (int y = 0; y < h; ++y) {
                float sum = 0.0f;
                for (int i = -a_r; i <= a_r; ++i) {
                    sum += a_in.clamped(i, y);
                }
                for (int x = 0; x < w; ++x) {
                    mid.at(x, y) = sum * k;
                    sum += a_in.clamped(x + a_r + 1, y) - a_in.clamped(x - a_r, y);
                }
            }
            for (int x = 0; x < w; ++x) {
                float sum = 0.0f;
                for (int i = -a_r; i <= a_r; ++i) {
                    sum += mid.clamped(x, i);
                }
                for (int y = 0; y < h; ++y) {
                    out.at(x, y) = sum * k;
                    sum += mid.clamped(x, y + a_r + 1) - mid.clamped(x, y - a_r);
                }
            }
            return out;
        }

        // Three boxes, near enough a Gaussian.
        Plane Blur(const Plane& a_in, int a_r) {
            const int r = (std::max)(1, a_r / 2);
            return Box(Box(Box(a_in, r), r), r);
        }

        struct Rgb {
            Plane c[3];  // r g b, 0..1
        };

        Rgb Blur(const Rgb& a_in, int a_r) {
            return { { Blur(a_in.c[0], a_r), Blur(a_in.c[1], a_r), Blur(a_in.c[2], a_r) } };
        }

        Plane Luma(const Rgb& a_in) {
            Plane out(a_in.c[0].w, a_in.c[0].h);
            for (std::size_t i = 0; i < out.v.size(); ++i) {
                out.v[i] = 0.299f * a_in.c[0].v[i] + 0.587f * a_in.c[1].v[i] + 0.114f * a_in.c[2].v[i];
            }
            return out;
        }

        Image Oil(const Image& a_in) {
            const int  w = a_in.w, h = a_in.h;
            const auto n = static_cast<std::size_t>(w) * h;
            std::mt19937                          rng{ 7u };
            std::normal_distribution<float>       jitter(0.0f, 0.012f);
            std::uniform_real_distribution<float> unit(0.0f, 1.0f);

            // 1. Graded like an oil: highlights held back so white cloth
            //    keeps its folds, more contrast and colour, a warm varnish,
            //    and the small detail lifted so it survives the brush.
            Rgb x{ { Plane(w, h), Plane(w, h), Plane(w, h) } };
            for (int y = 0; y < h; ++y) {
                for (int i = 0; i < w; ++i) {
                    const auto* p = a_in.at(i, y);
                    float       c[3] = { p[2] / 255.0f, p[1] / 255.0f, p[0] / 255.0f };
                    for (auto& v : c) {
                        v = v > 0.6f ? 0.6f + (v - 0.6f) * 0.55f : v;
                        v = 0.5f + (v - 0.5f) * 1.12f;
                    }
                    const float     l = 0.299f * c[0] + 0.587f * c[1] + 0.114f * c[2];
                    constexpr float kWarm[3] = { 1.04f, 0.99f, 0.88f };
                    for (int k = 0; k < 3; ++k) {
                        x.c[k].at(i, y) = std::clamp((l + (c[k] - l) * 1.25f) * kWarm[k], 0.0f, 1.0f);
                    }
                }
            }
            {
                const Plane l = Luma(x), soft = Luma(Blur(x, 4));
                for (std::size_t i = 0; i < n; ++i) {
                    const float d = (l.v[i] - soft.v[i]) * 0.9f;
                    for (auto& c : x.c) {
                        c.v[i] = std::clamp(c.v[i] + d, 0.0f, 1.0f);
                    }
                }
            }

            // 2. Which way the forms run at each point: across the gradient,
            //    from the smoothed structure tensor.
            Plane tdx(w, h), tdy(w, h);
            {
                const Plane ly = Blur(Luma(x), 3);
                Plane       jxx(w, h), jxy(w, h), jyy(w, h);
                for (int y = 0; y < h; ++y) {
                    for (int i = 0; i < w; ++i) {
                        const float gx = (ly.clamped(i + 1, y) - ly.clamped(i - 1, y)) * 0.5f;
                        const float gy = (ly.clamped(i, y + 1) - ly.clamped(i, y - 1)) * 0.5f;
                        jxx.at(i, y) = gx * gx;
                        jxy.at(i, y) = gx * gy;
                        jyy.at(i, y) = gy * gy;
                    }
                }
                jxx = Blur(jxx, 8);
                jxy = Blur(jxy, 8);
                jyy = Blur(jyy, 8);
                for (std::size_t i = 0; i < n; ++i) {
                    const float theta = 0.5f * std::atan2(2.0f * jxy.v[i], jxx.v[i] - jyy.v[i]);
                    tdx.v[i] = -std::sin(theta);
                    tdy.v[i] = std::cos(theta);
                }
            }

            // 3. Painted, broad brush to fine.
            Rgb               canvas{ { Plane(w, h, 0.36f), Plane(w, h, 0.28f), Plane(w, h, 0.20f) } };
            Plane             height(w, h);
            std::vector<char> painted(n, 0);
            std::size_t       strokes = 0;
            for (const int r : { 14, 8, 4, 2 }) {
                const Rgb ref = Blur(x, r);
                const int d = 2 * r + 1;
                // The brush: a soft-edged disc of paint, domed.
                std::vector<float> alpha(static_cast<std::size_t>(d) * d), dome(alpha.size());
                for (int j = -r; j <= r; ++j) {
                    for (int i = -r; i <= r; ++i) {
                        const float q = std::sqrt(static_cast<float>(i * i + j * j)) / (r + 0.5f);
                        alpha[static_cast<std::size_t>(j + r) * d + (i + r)] = std::clamp((1.0f - q) * 3.0f, 0.0f, 1.0f);
                        dome[static_cast<std::size_t>(j + r) * d + (i + r)] = std::sqrt(std::clamp(1.0f - q * q, 0.0f, 1.0f));
                    }
                }
                const auto offBy = [&](int a_x, int a_y) {
                    const auto i = static_cast<std::size_t>(a_y) * w + a_x;
                    if (!painted[i]) {
                        return 9.0f;
                    }
                    float s = 0.0f;
                    for (int k = 0; k < 3; ++k) {
                        const float e = canvas.c[k].v[i] - ref.c[k].v[i];
                        s += e * e;
                    }
                    return std::sqrt(s);
                };
                // Where to begin a stroke: in each cell of the grid that is
                // still too far from the sitting, its furthest point.
                const float                      threshold = r > 4 ? 0.10f : 0.07f;
                std::vector<std::pair<int, int>> starts;
                for (int gy = 0; gy < h; gy += r) {
                    for (int gx = 0; gx < w; gx += r) {
                        float sum = 0.0f, worst = -1.0f;
                        int   wx = gx, wy = gy, cells = 0;
                        for (int y = gy; y < (std::min)(h, gy + r); ++y) {
                            for (int i = gx; i < (std::min)(w, gx + r); ++i) {
                                const float e = offBy(i, y);
                                sum += e;
                                ++cells;
                                if (e > worst) {
                                    worst = e;
                                    wx = i;
                                    wy = y;
                                }
                            }
                        }
                        if (cells && sum / cells > threshold) {
                            starts.emplace_back(wx, wy);
                        }
                    }
                }
                std::shuffle(starts.begin(), starts.end(), rng);
                const int                            maxLength = r > 4 ? 16 : 8;
                std::vector<float>                   streak(static_cast<std::size_t>(2 * d + 4));
                std::vector<float>                   bristle(alpha.size());
                std::vector<std::pair<float, float>> points, dense;
                for (const auto& [sx, sy] : starts) {
                    const float load = 1.0f + jitter(rng);
                    float       col[3];
                    for (int k = 0; k < 3; ++k) {
                        col[k] = ref.c[k].at(sx, sy) * load;
                    }
                    points.assign(1, { sx + 0.5f, sy + 0.5f });
                    float px = static_cast<float>(sx), py = static_cast<float>(sy), lx = 0.0f, ly = 0.0f;
                    for (int s = 0; s < maxLength; ++s) {
                        const int ix = static_cast<int>(px), iy = static_cast<int>(py);
                        if (ix < 0 || iy < 0 || ix >= w || iy >= h) {
                            break;
                        }
                        if (s > 1) {
                            // Ended where the paint already there is nearer
                            // the sitting than this stroke's colour.
                            float own = 0.0f, there = 0.0f;
                            for (int k = 0; k < 3; ++k) {
                                own += std::abs(ref.c[k].at(ix, iy) - col[k]);
                                there += std::abs(ref.c[k].at(ix, iy) - canvas.c[k].at(ix, iy));
                            }
                            if (own > there) {
                                break;
                            }
                        }
                        float dx = tdx.at(ix, iy), dy = tdy.at(ix, iy);
                        if (dx * lx + dy * ly < 0.0f) {
                            dx = -dx;
                            dy = -dy;
                        }
                        dx = 0.6f * dx + 0.4f * lx;  // the hand's own curve
                        dy = 0.6f * dy + 0.4f * ly;
                        const float len = std::hypot(dx, dy);
                        if (len > 0.0f) {
                            dx /= len;
                            dy /= len;
                        }
                        lx = dx;
                        ly = dy;
                        px += dx * r;
                        py += dy * r;
                        points.emplace_back(px, py);
                    }
                    dense.clear();
                    for (std::size_t p = 0; p < points.size(); ++p) {
                        const auto [ax, ay] = points[p];
                        const auto [bx, by] = points[(std::min)(p + 1, points.size() - 1)];
                        const int steps = (std::max)(1, static_cast<int>(std::hypot(bx - ax, by - ay) / (std::max)(1.0f, r * 0.35f)));
                        for (int t = 0; t < steps; ++t) {
                            dense.emplace_back(ax + (bx - ax) * t / steps, ay + (by - ay) * t / steps);
                        }
                    }
                    // Bristles: streaks across the brush, along its travel.
                    const float angle = std::atan2(ly != 0.0f ? ly : 1e-3f, lx != 0.0f ? lx : 1e-3f);
                    const float sa = std::sin(angle), ca = std::cos(angle);
                    for (auto& v : streak) {
                        v = unit(rng);
                    }
                    for (int j = -r; j <= r; ++j) {
                        for (int i = -r; i <= r; ++i) {
                            const int at = std::clamp(static_cast<int>(-i * sa + j * ca + r + 2), 0, static_cast<int>(streak.size()) - 1);
                            bristle[static_cast<std::size_t>(j + r) * d + (i + r)] = 0.55f + 0.45f * streak[at];
                        }
                    }
                    const float relief = (std::min)(r, 8) * 0.22f;
                    for (const auto& [fx, fy] : dense) {
                        const int x0 = static_cast<int>(fx) - r, y0 = static_cast<int>(fy) - r;
                        for (int j = (std::max)(0, -y0); j < d && y0 + j < h; ++j) {
                            for (int i = (std::max)(0, -x0); i < d && x0 + i < w; ++i) {
                                const auto  m = static_cast<std::size_t>(j) * d + i;
                                const float a = alpha[m];
                                if (a <= 0.0f) {
                                    continue;
                                }
                                const auto at = static_cast<std::size_t>(y0 + j) * w + (x0 + i);
                                for (int k = 0; k < 3; ++k) {
                                    canvas.c[k].v[at] = canvas.c[k].v[at] * (1.0f - a) + col[k] * a;
                                }
                                const float hm = (0.35f * dome[m] + 0.65f) * bristle[m] * relief;
                                height.v[at] = (std::max)(height.v[at] * (1.0f - a * 0.85f), hm);
                                if (a > 0.5f) {
                                    painted[at] = 1;
                                }
                            }
                        }
                    }
                    ++strokes;
                }
            }

            // 4. The relief lit from the upper left; the weave; a varnished
            //    edge.
            const Plane hb = Box(Box(Box(height, 1), 1), 1);
            float       lightDir[3] = { -0.5f, -0.6f, 0.62f };
            {
                const float len = std::sqrt(lightDir[0] * lightDir[0] + lightDir[1] * lightDir[1] + lightDir[2] * lightDir[2]);
                for (auto& v : lightDir) {
                    v /= len;
                }
            }
            Image out{ w, h, std::vector<std::uint8_t>(n * 4, 255) };
            for (int y = 0; y < h; ++y) {
                for (int i = 0; i < w; ++i) {
                    const float nx = -(hb.clamped(i + 1, y) - hb.clamped(i - 1, y)) * 0.5f * 0.9f;
                    const float ny = -(hb.clamped(i, y + 1) - hb.clamped(i, y - 1)) * 0.5f * 0.9f;
                    const float shade = (nx * lightDir[0] + ny * lightDir[1] + lightDir[2]) / std::sqrt(nx * nx + ny * ny + 1.0f);
                    const float spec = std::pow(std::clamp(shade, 0.0f, 1.0f), 24.0f) * 0.18f * 0.6f;
                    const float weave = std::sin(i * 1.7f) * std::sin(y * 1.7f) * 0.018f;
                    const float cx = (i - w / 2.0f) / (w / 2.0f), cy = (y - h / 2.0f) / (h / 2.0f);
                    const float vignette = std::clamp(1.0f - 0.22f * std::pow(cx * cx + cy * cy, 1.2f), 0.0f, 1.0f);
                    auto*       p = out.at(i, y);
                    for (int k = 0; k < 3; ++k) {
                        p[2 - k] = ToByte((canvas.c[k].at(i, y) * (0.72f + 0.32f * shade) + spec + weave) * vignette);
                    }
                    p[3] = 255;
                }
            }
            return out;
        }

        std::string Base64(const std::vector<std::uint8_t>& a_bytes) {
            static constexpr char kTable[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            std::string out;
            out.reserve((a_bytes.size() + 2) / 3 * 4);
            std::size_t i = 0;
            for (; i + 2 < a_bytes.size(); i += 3) {
                const auto n = (a_bytes[i] << 16) | (a_bytes[i + 1] << 8) | a_bytes[i + 2];
                out += kTable[(n >> 18) & 63];
                out += kTable[(n >> 12) & 63];
                out += kTable[(n >> 6) & 63];
                out += kTable[n & 63];
            }
            if (const auto rest = a_bytes.size() - i; rest > 0) {
                auto n = a_bytes[i] << 16;
                if (rest == 2) {
                    n |= a_bytes[i + 1] << 8;
                }
                out += kTable[(n >> 18) & 63];
                out += kTable[(n >> 12) & 63];
                out += rest == 2 ? kTable[(n >> 6) & 63] : '=';
                out += '=';
            }
            return out;
        }

        // A PNG of a_img, scaled to a_w by a_h (its own size when 0). Empty
        // on failure (logged). COM is the caller's.
        std::vector<std::uint8_t> Encode(const Image& a_img, UINT a_w, UINT a_h, const GUID& a_container);

        std::vector<std::uint8_t> Png(const Image& a_img, UINT a_w = 0, UINT a_h = 0) {
            return Encode(a_img, a_w, a_h, GUID_ContainerFormatPng);
        }

        // A JPEG, for the vision model: a tenth of a PNG's size.
        std::vector<std::uint8_t> Jpeg(const Image& a_img, UINT a_w, UINT a_h) {
            return Encode(a_img, a_w, a_h, GUID_ContainerFormatJpeg);
        }

        std::vector<std::uint8_t> Encode(const Image& a_img, UINT a_w, UINT a_h, const GUID& a_container) {
            std::vector<std::uint8_t> out;
            const auto fail = [](const char* a_step, HRESULT a_hr) {
                SKSE::log::warn("Painting: encoding failed at {} (0x{:08X})", a_step, static_cast<std::uint32_t>(a_hr));
                return std::vector<std::uint8_t>{};
            };
            const UINT w = a_w ? a_w : a_img.w, h = a_h ? a_h : a_img.h;
            ComPtr<IWICImagingFactory> factory;
            auto hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
            if (FAILED(hr)) {
                return fail("the imaging factory", hr);
            }
            ComPtr<IWICBitmap> bitmap;
            hr = factory->CreateBitmapFromMemory(a_img.w, a_img.h, GUID_WICPixelFormat32bppBGRA, a_img.w * 4,
                                                 static_cast<UINT>(a_img.bgra.size()), const_cast<BYTE*>(a_img.bgra.data()), &bitmap);
            if (FAILED(hr)) {
                return fail("the bitmap", hr);
            }
            ComPtr<IWICBitmapSource> source = bitmap;
            ComPtr<IWICBitmapScaler> scaler;
            if (w != static_cast<UINT>(a_img.w) || h != static_cast<UINT>(a_img.h)) {
                hr = factory->CreateBitmapScaler(&scaler);
                if (SUCCEEDED(hr)) {
                    hr = scaler->Initialize(bitmap.Get(), w, h, WICBitmapInterpolationModeHighQualityCubic);
                }
                if (FAILED(hr)) {
                    return fail("scaling", hr);
                }
                source = scaler;
            }
            ComPtr<IStream>               stream;
            ComPtr<IWICBitmapEncoder>     encoder;
            ComPtr<IWICBitmapFrameEncode> frame;
            hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
            if (SUCCEEDED(hr)) {
                hr = factory->CreateEncoder(a_container, nullptr, &encoder);
            }
            if (SUCCEEDED(hr)) {
                hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
            }
            if (SUCCEEDED(hr)) {
                hr = encoder->CreateNewFrame(&frame, nullptr);
            }
            if (SUCCEEDED(hr)) {
                hr = frame->Initialize(nullptr);
            }
            if (SUCCEEDED(hr)) {
                hr = frame->SetSize(w, h);
            }
            WICPixelFormatGUID format = a_container == GUID_ContainerFormatJpeg ? GUID_WICPixelFormat24bppBGR
                                                                                   : GUID_WICPixelFormat32bppBGRA;
            if (SUCCEEDED(hr)) {
                hr = frame->SetPixelFormat(&format);
            }
            // Whatever the encoder settled on, the source is converted to it.
            ComPtr<IWICFormatConverter> converter;
            if (SUCCEEDED(hr) && format != GUID_WICPixelFormat32bppBGRA) {
                hr = factory->CreateFormatConverter(&converter);
                if (SUCCEEDED(hr)) {
                    hr = converter->Initialize(source.Get(), format, WICBitmapDitherTypeNone, nullptr, 0.0,
                                               WICBitmapPaletteTypeCustom);
                }
                if (SUCCEEDED(hr)) {
                    source = converter;
                }
            }
            if (SUCCEEDED(hr)) {
                hr = frame->WriteSource(source.Get(), nullptr);
            }
            if (SUCCEEDED(hr)) {
                hr = frame->Commit();
            }
            if (SUCCEEDED(hr)) {
                hr = encoder->Commit();
            }
            STATSTG stat{};
            if (SUCCEEDED(hr)) {
                hr = stream->Stat(&stat, STATFLAG_NONAME);
            }
            HGLOBAL global = nullptr;
            if (SUCCEEDED(hr)) {
                hr = GetHGlobalFromStream(stream.Get(), &global);
            }
            if (FAILED(hr)) {
                return fail("encoding", hr);
            }
            if (const auto* bytes = static_cast<const std::uint8_t*>(GlobalLock(global))) {
                out.assign(bytes, bytes + static_cast<std::size_t>(stat.cbSize.QuadPart));
                GlobalUnlock(global);
            }
            return out;
        }

        bool WriteFile(const std::filesystem::path& a_path, const void* a_data, std::size_t a_size) {
            std::error_code ec;
            std::filesystem::create_directories(a_path.parent_path(), ec);
            std::ofstream file(a_path, std::ios::binary | std::ios::trunc);
            file.write(static_cast<const char*>(a_data), static_cast<std::streamsize>(a_size));
            return file.good();
        }

        std::filesystem::path PreviewFolder() {
            const auto logs = SKSE::log::log_directory();
            return logs ? *logs / "Relationships" / "Paintings" : std::filesystem::path{};
        }

        // THE KEPT RECORD (2.6): beside each painting's PNGs, <name>.json says
        // whose it is - the partner, the playthrough, a wedding's or not - and
        // what the vision model made of it, so the card finds the couple's
        // painting in any later session. <name>_card.png is the card's copy.
        void Keep(const std::string& a_name, const json& a_record) {
            const auto folder = PreviewFolder();
            if (folder.empty()) {
                return;
            }
            const auto text = a_record.dump(2, ' ', false, json::error_handler_t::replace);
            if (!WriteFile(folder / (a_name + ".json"), text.data(), text.size())) {
                SKSE::log::warn("Painting: {}'s record could not be kept", a_name);
            }
        }

        json KeptRecord(const std::string& a_name) {
            const auto    folder = PreviewFolder();
            std::ifstream file(folder / (a_name + ".json"), std::ios::binary);
            auto          record = file ? json::parse(file, nullptr, false) : json(nullptr);
            return record.is_object() ? record : json::object();
        }

        void Paint(Shot a_shot, Sitting a_sit) {
            const auto start = std::chrono::steady_clock::now();
            const auto com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
            const auto now = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
            std::tm    local{};
            localtime_s(&local, &now);
            const auto name = std::format("Painting_{:04}{:02}{:02}_{:02}{:02}{:02}", local.tm_year + 1900, local.tm_mon + 1,
                                          local.tm_mday, local.tm_hour, local.tm_min, local.tm_sec);
            const float W = static_cast<float>(a_shot.w), H = static_cast<float>(a_shot.h);
            auto r = CropFor(a_sit.points, W, H);
            // Kept inside the frame: slid, then cut, never stretched.
            if (r.x1 - r.x0 > W || r.y1 - r.y0 > H) {
                const float scale = (std::min)(W / (r.x1 - r.x0), H / (r.y1 - r.y0));
                const float cx = (r.x0 + r.x1) / 2, cy = (r.y0 + r.y1) / 2;
                const float hw = (r.x1 - r.x0) * scale / 2, hh = (r.y1 - r.y0) * scale / 2;
                r = { cx - hw, cy - hh, cx + hw, cy + hh };
            }
            if (r.x0 < 0) { r.x1 -= r.x0; r.x0 = 0; }
            if (r.y0 < 0) { r.y1 -= r.y0; r.y0 = 0; }
            if (r.x1 > W) { r.x0 -= r.x1 - W; r.x1 = W; }
            if (r.y1 > H) { r.y0 -= r.y1 - H; r.y1 = H; }

            constexpr int kW = 1024, kH = 1280;
            const auto    shot = Resample(a_shot, r, kW, kH);
            const auto    painted = Oil(shot);

            const auto previews = PreviewFolder();
            const auto shotPng = Png(shot);
            const auto paintedPng = Png(painted);
            const auto cardPng = Png(painted, 384, 480);
            const auto visionJpeg = Jpeg(painted, 512, 640);
            bool       ok = !previews.empty() && !shotPng.empty() && !paintedPng.empty();
            ok = ok && WriteFile(previews / (name + "_shot.png"), shotPng.data(), shotPng.size());
            ok = ok && WriteFile(previews / (name + "_painted.png"), paintedPng.data(), paintedPng.size());
            ok = ok && !cardPng.empty() && WriteFile(previews / (name + "_card.png"), cardPng.data(), cardPng.size());
            if (SUCCEEDED(com)) {
                CoUninitialize();
            }
            const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
            SKSE::log::info("Painting: {} painted in {} ms{}", name, ms, ok ? "" : "; it could NOT be saved");
            if (ok) {
                Keep(name, { { "partner", a_sit.partner },
                             { "playthrough", a_sit.playthrough },
                             { "wedding", a_sit.wedding },
                             { "kiss", a_sit.kiss },
                             { "title", "" },
                             { "description", "" } });
                std::scoped_lock lock(g_latestLock);
                g_latestName = name;
                g_latestPartner = a_sit.partner;
                g_latestPlaythrough = a_sit.playthrough;
                g_latestWedding = a_sit.wedding;
                g_latestSrc = "data:image/png;base64," + Base64(cardPng);
                g_latestTitle.clear();
                g_latestDescription.clear();
                g_latestDescribing.clear();
            }
            g_busy = false;
            if (ok && !visionJpeg.empty()) {
                SKSE::GetTaskInterface()->AddTask(
                    [name, jpeg = "data:image/jpeg;base64," + Base64(visionJpeg), a_sit]() { Describe(name, jpeg, a_sit); });
            }
            SKSE::GetTaskInterface()->AddTask([ok, partner = a_sit.partner]() {
                auto*       who = RE::TESForm::LookupByID<RE::Actor>(partner);
                const char* them = who ? who->GetDisplayFullName() : "";
                RE::SendHUDMessage::ShowHUDMessage(
                    ok ? L10n::Text("paint.hud.done", "[Relationships] The painting is finished. It hangs on {0}'s card.", them).c_str()
                       : L10n::Text("paint.hud.unsaved", "[Relationships] The painting could not be saved. See the log.").c_str());
            });
        }

        // Latest() as JSON text, for a push.
        std::string LatestText();

        // THE DESCRIPTION (the author, 2026-11-04: "so NPCs have that info and
        // can talk about it"). The painting goes to SkyrimNet's vision model -
        // the "vision" variant OmniSight's own captures use - in our own
        // template, snrom_painting_describe, which an [image] block carries.
        // Told who stands on which side, so the description names them; an
        // OmniSight capture of the canvas could not know who is who. Main
        // thread.
        void Describe(std::string a_name, std::string a_jpeg, Sitting a_sit) {
            static CustomPromptFn prompt = []() -> CustomPromptFn {
                const auto mod = GetModuleHandleW(L"SkyrimNet.dll");
                using VersionFn = int (*)();
                const auto version = mod ? reinterpret_cast<VersionFn>(GetProcAddress(mod, "PublicGetVersion")) : nullptr;
                if (!version || version() < 8) {
                    return nullptr;
                }
                return reinterpret_cast<CustomPromptFn>(GetProcAddress(mod, "PublicSendCustomPromptToLLM"));
            }();
            const auto fail = [&](const std::string& a_why) {
                SKSE::log::warn("Painting: {} is not described: {}", a_name, a_why);
                {
                    std::scoped_lock lock(g_latestLock);
                    if (g_latestName == a_name) {
                        g_latestDescribing = "failed: " + a_why;
                    }
                }
                Dashboard::Push("painting", LatestText());
            };
            if (!prompt) {
                return fail("SkyrimNet has no custom prompts");
            }
            auto*       player = RE::PlayerCharacter::GetSingleton();
            auto*       partner = RE::TESForm::LookupByID<RE::Actor>(a_sit.partner);
            std::string you = player ? player->GetDisplayFullName() : "";
            std::string them = partner ? partner->GetDisplayFullName() : "";
            // As the viewer sees it: whose head is further left.
            const bool youLeft = a_sit.points[0][0] <= a_sit.points[1][0];
            json       ctx = { { "painting_image", a_jpeg },
                               { "painting_player", you },
                               { "painting_partner", them },
                               { "painting_left", youLeft ? you : them },
                               { "painting_right", youLeft ? them : you },
                               { "painting_place", "" },
                               { "painting_kiss", a_sit.kiss },
                               { "painting_wedding", a_sit.wedding } };
            if (auto* where = player ? player->GetCurrentLocation() : nullptr) {
                ctx["painting_place"] = where->GetFullName() ? where->GetFullName() : "";
            }
            {
                std::scoped_lock lock(g_latestLock);
                if (g_latestName == a_name) {
                    g_latestDescribing = "asked";
                }
            }
            Dashboard::Push("painting", LatestText());
            const auto started = std::chrono::steady_clock::now();
            const bool queued = prompt(
                "snrom_painting_describe", "vision", ctx.dump(-1, ' ', false, json::error_handler_t::replace).c_str(),
                [a_name, started](const char* a_response, int a_success) {
                    std::string text = a_response ? a_response : "";
                    const auto  ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
                    SKSE::GetTaskInterface()->AddTask([a_name, text, ok = a_success != 0, ms]() {
                        SKSE::log::info("Painting: the vision model answered for {} in {} ms ({}): {}", a_name, ms,
                                        ok ? "ok" : "FAILED", text.substr(0, 800));
                        {
                            std::scoped_lock lock(g_latestLock);
                            if (g_latestName == a_name) {
                                if (!ok) {
                                    g_latestDescribing = "failed: " + text.substr(0, 200);
                                } else {
                                    // JSON, perhaps fenced or with words around
                                    // it: the outermost braces.
                                    const auto open = text.find('{');
                                    const auto close = text.rfind('}');
                                    auto       answer = open != std::string::npos && close != std::string::npos && close > open
                                                            ? json::parse(text.substr(open, close - open + 1), nullptr, false)
                                                            : json(nullptr);
                                    if (answer.is_object() && answer.contains("description")) {
                                        g_latestTitle = answer.value("title", std::string{});
                                        g_latestDescription = answer.value("description", std::string{});
                                        g_latestDescribing.clear();
                                        auto record = KeptRecord(a_name);
                                        if (!record.empty()) {
                                            record["title"] = g_latestTitle;
                                            record["description"] = g_latestDescription;
                                            Keep(a_name, record);
                                        }
                                    } else {
                                        g_latestDescription = text;  // shown as it came, to judge
                                        g_latestDescribing = "failed: the answer was not the JSON asked for";
                                    }
                                }
                            }
                        }
                        Dashboard::Push("painting", LatestText());
                    });
                });
            SKSE::log::info("Painting: {} sent to the vision model ({} KB){}", a_name, a_jpeg.size() / 1024,
                            queued ? "" : " - REFUSED");
            if (!queued) {
                fail("SkyrimNet would not send it");
            }
        }

    }  // namespace

    std::string Sit(RE::FormID a_partner, bool a_wedding) {
        if (g_busy) {
            return L10n::Text("paint.busy", "The painter is still at work on the last one.");
        }
        auto* partner = RE::TESForm::LookupByID<RE::Actor>(a_partner);
        auto* player = RE::PlayerCharacter::GetSingleton();
        if (!partner || !player) {
            return L10n::Text("paint.nobody", "There is nobody to paint.");
        }
        if (!partner->Is3DLoaded() || partner->GetParentCell() != player->GetParentCell() ||
            partner->GetPosition().GetDistance(player->GetPosition()) > 600.0f) {
            return L10n::Text("paint.standBeside", "Stand beside {0} first.", partner->GetDisplayFullName());
        }
        if (!Hook()) {
            return L10n::Text("paint.noFrame", "The painter cannot see the game. See the log.");
        }
        g_busy = true;
        g_sit = {};
        g_sit.partner = a_partner;
        g_sit.wedding = a_wedding;
        g_sit.playthrough = Model::Get().PlaythroughId();
        g_sit.phase = Phase::kWaiting;
        g_sit.began = std::chrono::steady_clock::now();
        g_active = true;
        SKSE::log::info("Painting: a sitting with {} ({:08X}) is asked for{}", partner->GetDisplayFullName(), a_partner,
                        a_wedding ? ", at their wedding" : "");
        return "";
    }

    json Latest(RE::FormID a_partner) {
        // As the card knows them: Papyrus pushes form ids signed.
        json out = { { "formId", static_cast<std::int32_t>(a_partner) }, { "name", "" },        { "src", "" },        { "title", "" },
                     { "description", "" },   { "describing", "" }, { "wedding", false } };
        const auto playthrough = Model::Get().PlaythroughId();
        {
            std::scoped_lock lock(g_latestLock);
            if (!g_latestName.empty() && g_latestPartner == a_partner && g_latestPlaythrough == playthrough) {
                out["name"] = g_latestName;
                out["src"] = g_latestSrc;
                out["title"] = g_latestTitle;
                out["description"] = g_latestDescription;
                out["describing"] = g_latestDescribing;
                out["wedding"] = g_latestWedding;
                return out;
            }
        }
        // The newest kept for this couple in this playthrough: the names are
        // the time they were painted, so the greatest is the newest.
        const auto      folder = PreviewFolder();
        std::error_code ec;
        std::string     newest;
        json            found;
        if (!folder.empty() && std::filesystem::is_directory(folder, ec)) {
            for (const auto& entry : std::filesystem::directory_iterator(folder, ec)) {
                const auto path = entry.path();
                const auto stem = path.stem().string();
                if (path.extension() != ".json" || !stem.starts_with("Painting_") || stem <= newest) {
                    continue;
                }
                auto record = KeptRecord(stem);
                if (record.value("partner", RE::FormID{ 0 }) == a_partner &&
                    record.value("playthrough", std::string{}) == playthrough) {
                    newest = stem;
                    found = std::move(record);
                }
            }
        }
        if (newest.empty()) {
            return out;
        }
        std::ifstream             png(folder / (newest + "_card.png"), std::ios::binary);
        std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(png)), std::istreambuf_iterator<char>());
        if (bytes.empty()) {
            return out;
        }
        out["name"] = newest;
        out["src"] = "data:image/png;base64," + Base64(bytes);
        out["title"] = found.value("title", std::string{});
        out["description"] = found.value("description", std::string{});
        out["wedding"] = found.value("wedding", false);
        return out;
    }

    namespace {
        std::string LatestText() {
            RE::FormID partner = 0;
            {
                std::scoped_lock lock(g_latestLock);
                partner = g_latestPartner;
            }
            return Latest(partner).dump(-1, ' ', false, json::error_handler_t::replace);
        }
    }

}  // namespace SNRom::Painting
