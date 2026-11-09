#include "Portraits.h"

#include "PCH.h"

#include "SkyrimNetLink.h"

#include <format>
#include <fstream>
#include <map>
#include <mutex>
#include <tuple>

#include <wincodec.h>
#include <wrl/client.h>

namespace SNRom::Portraits {

    namespace {

        using Microsoft::WRL::ComPtr;

        // A cutout is about 150 KB; anything far bigger is not one of them.
        constexpr std::uintmax_t kMaxBytes = 4u * 1024u * 1024u;

        std::filesystem::path Folder() {
            const auto logs = SKSE::log::log_directory();
            return logs ? *logs / "SeverActions" / "Portraits" : std::filesystem::path{};
        }

        std::string Base64(const std::uint8_t* a_bytes, std::size_t a_size) {
            static constexpr char kTable[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            std::string out;
            out.reserve((a_size + 2) / 3 * 4);
            std::size_t i = 0;
            for (; i + 2 < a_size; i += 3) {
                const auto n = (a_bytes[i] << 16) | (a_bytes[i + 1] << 8) | a_bytes[i + 2];
                out += kTable[(n >> 18) & 63];
                out += kTable[(n >> 12) & 63];
                out += kTable[(n >> 6) & 63];
                out += kTable[n & 63];
            }
            if (const auto rest = a_size - i; rest > 0) {
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

        // The file keys SeverActions could have used for this actor, most
        // likely first.
        std::vector<std::string> Keys(std::uint32_t a_formId) {
            std::vector<std::string> keys;
            if (a_formId == 0x14 || (a_formId >> 24) == 0xFF) {
                const auto save = SkyrimNetLink::SaveId();
                if (!save.empty()) {
                    keys.push_back(a_formId == 0x14 ? std::format("player_{}", save)
                                                    : std::format("runtime_{}_{:08X}", save, a_formId));
                }
                return keys;
            }
            const auto local = (a_formId >> 24) == 0xFE ? (a_formId & 0xFFF) : (a_formId & 0xFFFFFF);
            const auto* form = RE::TESForm::LookupByID(a_formId);
            const auto* files = form ? form->sourceFiles.array : nullptr;
            if (!files) {
                return keys;
            }
            // THE PLUGIN'S NAME AS SEVERACTIONS WRITES IT (2.6; a player's
            // report, 2026-11-08): "new follower.esp" found nothing. Its
            // files hold only A-Z a-z 0-9 . _ - ("CC Farming - Tweaks and
            // Enhancements.esp" is saved as CC_Farming_-_Tweaks_and_...), so
            // anything else became "_". Inferred from the files, not
            // documented: the name as given is still tried after it.
            const auto asSaved = [](std::string_view a_name) {
                std::string out{ a_name };
                for (auto& c : out) {
                    const auto u = static_cast<unsigned char>(c);
                    if (!std::isalnum(u) || u >= 0x80) {
                        if (c != '.' && c != '_' && c != '-') {
                            c = '_';
                        }
                    }
                }
                return out;
            };
            const auto add = [&](std::string a_key) {
                if (std::ranges::find(keys, a_key) == keys.end()) {
                    keys.push_back(std::move(a_key));
                }
            };
            for (auto i = files->size(); i-- > 0;) {
                const auto* file = (*files)[i];
                if (file && !file->GetFilename().empty()) {
                    add(std::format("{}_{:06X}", asSaved(file->GetFilename()), local));
                    add(std::format("{}_{:06X}", file->GetFilename(), local));
                }
            }
            return keys;
        }

        // The first candidate that is a readable cutout of a sane size.
        std::filesystem::path FirstExisting(const std::vector<std::filesystem::path>& a_candidates,
                                            std::uintmax_t& a_size) {
            std::error_code ec;
            for (const auto& file : a_candidates) {
                a_size = std::filesystem::file_size(file, ec);
                if (!ec && a_size > 0 && a_size <= kMaxBytes) {
                    return file;
                }
                ec.clear();
            }
            return {};
        }

        // The PNG bytes of a thumbnail: a square from the top of the cutout,
        // where the head is, scaled to a_px. Empty on any failure (logged).
        std::vector<std::uint8_t> Cut(const std::filesystem::path& a_file, std::uint32_t a_px) {
            std::vector<std::uint8_t> out;
            const auto fail = [&](const char* a_step, HRESULT a_hr) {
                SKSE::log::warn("Portraits: thumbnail of {} failed at {} (0x{:08X})", a_file.filename().string(), a_step,
                                static_cast<std::uint32_t>(a_hr));
                return std::vector<std::uint8_t>{};
            };
            ComPtr<IWICImagingFactory> factory;
            auto hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
            if (FAILED(hr)) {
                return fail("the imaging factory", hr);
            }
            ComPtr<IWICBitmapDecoder> decoder;
            hr = factory->CreateDecoderFromFilename(a_file.c_str(), nullptr, GENERIC_READ,
                                                    WICDecodeMetadataCacheOnDemand, &decoder);
            ComPtr<IWICBitmapFrameDecode> frame;
            if (SUCCEEDED(hr)) {
                hr = decoder->GetFrame(0, &frame);
            }
            UINT w = 0, h = 0;
            if (SUCCEEDED(hr)) {
                hr = frame->GetSize(&w, &h);
            }
            if (FAILED(hr) || w == 0 || h == 0) {
                return fail("decoding", hr);
            }
            // SeverActions frames head and shoulders, 384 by 480: the head is
            // in a square three quarters of the width, centred, from the top.
            const auto side = (std::min)(w * 3 / 4, h);
            const WICRect square{ static_cast<INT>((w - side) / 2), 0, static_cast<INT>(side), static_cast<INT>(side) };
            ComPtr<IWICBitmapClipper> clipper;
            ComPtr<IWICBitmapScaler>  scaler;
            ComPtr<IWICFormatConverter> converter;
            hr = factory->CreateBitmapClipper(&clipper);
            if (SUCCEEDED(hr)) {
                hr = clipper->Initialize(frame.Get(), &square);
            }
            if (SUCCEEDED(hr)) {
                hr = factory->CreateBitmapScaler(&scaler);
            }
            if (SUCCEEDED(hr)) {
                hr = scaler->Initialize(clipper.Get(), a_px, a_px, WICBitmapInterpolationModeHighQualityCubic);
            }
            if (SUCCEEDED(hr)) {
                hr = factory->CreateFormatConverter(&converter);
            }
            if (SUCCEEDED(hr)) {
                hr = converter->Initialize(scaler.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr,
                                           0.0, WICBitmapPaletteTypeCustom);
            }
            if (FAILED(hr)) {
                return fail("scaling", hr);
            }
            ComPtr<IStream>               stream;
            ComPtr<IWICBitmapEncoder>     encoder;
            ComPtr<IWICBitmapFrameEncode> target;
            hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
            if (SUCCEEDED(hr)) {
                hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
            }
            if (SUCCEEDED(hr)) {
                hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
            }
            if (SUCCEEDED(hr)) {
                hr = encoder->CreateNewFrame(&target, nullptr);
            }
            if (SUCCEEDED(hr)) {
                hr = target->Initialize(nullptr);
            }
            if (SUCCEEDED(hr)) {
                hr = target->SetSize(a_px, a_px);
            }
            WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
            if (SUCCEEDED(hr)) {
                hr = target->SetPixelFormat(&format);
            }
            if (SUCCEEDED(hr)) {
                hr = target->WriteSource(converter.Get(), nullptr);
            }
            if (SUCCEEDED(hr)) {
                hr = target->Commit();
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

        // SEVERACTIONS' OWN ANSWER (4.8.0, its native API v2, asked for by
        // us): SAAPI_GetPortraitPath gives the picture its pages show, picked
        // or taken, by reference id, so its file naming (which 4.8.0 changed:
        // a portrait is now named after the plugin that ADDS the character)
        // is no longer ours to guess. Its header is not published, so the
        // call is made to hold whatever the documented shape is built from:
        // the kind is written into eight zeroed bytes, so a byte or an int
        // reads back the same, and a cap or length of 32 or 64 bits passes
        // the same in a register. Empty when SeverActions is older or has
        // no picture of them; the folder search below then still runs.
        std::filesystem::path FromSeverActions(std::uint32_t a_formId) {
            using VersionFn = std::uint32_t (*)();
            using PathFn = std::uint32_t (*)(std::uint32_t, char*, std::uint32_t, std::int32_t*);
            static const PathFn getPath = [] {
                const HMODULE sa = GetModuleHandleW(L"SeverActionsNative.dll");
                const auto    version = sa ? reinterpret_cast<VersionFn>(GetProcAddress(sa, "SAAPI_GetVersion")) : nullptr;
                const auto    v = version ? version() : 0u;
                const auto    fn = v >= 2 ? reinterpret_cast<PathFn>(GetProcAddress(sa, "SAAPI_GetPortraitPath")) : nullptr;
                SKSE::log::info("Portraits: SeverActions native API {} - {}", v,
                                fn ? "asking it for each picture" : "searching its folder ourselves");
                return fn;
            }();
            if (!getPath || a_formId == 0) {
                return {};
            }
            std::string   text(512, '\0');
            std::int64_t  kind = 0;
            auto          length = getPath(a_formId, text.data(), static_cast<std::uint32_t>(text.size()),
                                           reinterpret_cast<std::int32_t*>(&kind));
            if (length >= text.size() && length < 32768) {
                text.assign(static_cast<std::size_t>(length) + 1, '\0');
                kind = 0;
                length = getPath(a_formId, text.data(), static_cast<std::uint32_t>(text.size()),
                                 reinterpret_cast<std::int32_t*>(&kind));
            }
            if (length == 0 || length >= text.size()) {
                return {};
            }
            text.resize(length);
            return std::filesystem::path{ std::u8string{ text.begin(), text.end() } };
        }

        // Thumbnails made this session: by file, size and last write.
        using ThumbKey = std::tuple<std::wstring, std::uint32_t, std::int64_t>;
        std::mutex                          g_thumbLock;
        std::map<ThumbKey, std::string>     g_thumbs;
    }

    bool Available() {
        const auto folder = Folder();
        std::error_code ec;
        if (folder.empty() || !std::filesystem::is_directory(folder, ec)) {
            return false;
        }
        for (const auto& entry : std::filesystem::directory_iterator(folder, ec)) {
            if (entry.path().extension() == ".png" || entry.path().extension() == ".jpg") {
                return true;
            }
        }
        return false;
    }

    std::vector<std::filesystem::path> Candidates(std::uint32_t a_formId) {
        std::vector<std::filesystem::path> out;
        if (auto asked = FromSeverActions(a_formId); !asked.empty()) {
            out.push_back(std::move(asked));
        }
        const auto folder = Folder();
        if (folder.empty()) {
            return out;
        }
        // A PICKED PORTRAIT FIRST (SeverActions 4.6.0: anyone can be given a
        // picture, which then shows wherever they appear): SetFromFile keeps
        // it as a JPEG beside the automatic cutout, under the same key. The
        // naming is read from its DLL, not documented; the log names each
        // file tried, so a miss shows what it looked for.
        for (const auto& key : Keys(a_formId)) {
            out.push_back(folder / (key + ".jpg"));
            out.push_back(folder / (key + ".cut.png"));
        }
        return out;
    }

    std::string DataUrlOf(std::uint32_t a_formId) {
        const auto candidates = Candidates(a_formId);
        std::uintmax_t size = 0;
        const auto     file = FirstExisting(candidates, size);
        if (!file.empty()) {
            std::ifstream             in(file, std::ios::binary);
            std::vector<std::uint8_t> bytes(static_cast<std::size_t>(size));
            if (in.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()))) {
                const char* type = file.extension() == ".jpg" ? "image/jpeg" : "image/png";
                return std::format("data:{};base64,", type) + Base64(bytes.data(), bytes.size());
            }
            SKSE::log::warn("Portraits: {} exists but could not be read", file.filename().string());
        }
        return {};
    }

    std::string ThumbnailOf(const std::vector<std::filesystem::path>& a_candidates, std::uint32_t a_px) {
        std::uintmax_t size = 0;
        const auto     file = FirstExisting(a_candidates, size);
        if (file.empty()) {
            return {};
        }
        std::error_code ec;
        const auto      written = std::filesystem::last_write_time(file, ec).time_since_epoch().count();
        const ThumbKey  key{ file.wstring(), a_px, ec ? 0 : written };
        {
            const std::scoped_lock lock{ g_thumbLock };
            if (const auto it = g_thumbs.find(key); it != g_thumbs.end()) {
                return it->second;
            }
        }
        const auto bytes = Cut(file, a_px);
        auto       url = bytes.empty() ? std::string{} : "data:image/png;base64," + Base64(bytes.data(), bytes.size());
        const std::scoped_lock lock{ g_thumbLock };
        g_thumbs[key] = url;
        return url;
    }
}
