#include "Portraits.h"

#include "PCH.h"

#include "SkyrimNetLink.h"

#include <filesystem>
#include <format>
#include <fstream>
#include <vector>

namespace SNRom::Portraits {

    namespace {

        // A cutout is about 150 KB; anything far bigger is not one of them.
        constexpr std::uintmax_t kMaxBytes = 4u * 1024u * 1024u;

        std::filesystem::path Folder() {
            const auto logs = SKSE::log::log_directory();
            return logs ? *logs / "SeverActions" / "Portraits" : std::filesystem::path{};
        }

        std::string Base64(const std::vector<char>& a_bytes) {
            static constexpr char kTable[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            std::string out;
            out.reserve((a_bytes.size() + 2) / 3 * 4);
            std::size_t i = 0;
            for (; i + 2 < a_bytes.size(); i += 3) {
                const auto n = (static_cast<std::uint8_t>(a_bytes[i]) << 16) |
                               (static_cast<std::uint8_t>(a_bytes[i + 1]) << 8) | static_cast<std::uint8_t>(a_bytes[i + 2]);
                out += kTable[(n >> 18) & 63];
                out += kTable[(n >> 12) & 63];
                out += kTable[(n >> 6) & 63];
                out += kTable[n & 63];
            }
            if (const auto rest = a_bytes.size() - i; rest > 0) {
                auto n = static_cast<std::uint8_t>(a_bytes[i]) << 16;
                if (rest == 2) {
                    n |= static_cast<std::uint8_t>(a_bytes[i + 1]) << 8;
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
            const auto add = [&](const RE::TESForm* a_form) {
                const auto* files = a_form ? a_form->sourceFiles.array : nullptr;
                if (!files) {
                    return;
                }
                for (auto i = files->size(); i-- > 0;) {
                    const auto* file = (*files)[i];
                    if (file && !file->GetFilename().empty()) {
                        auto key = std::format("{}_{:06X}", file->GetFilename(), local);
                        if (std::ranges::find(keys, key) == keys.end()) {
                            keys.push_back(std::move(key));
                        }
                    }
                }
            };
            add(RE::TESForm::LookupByID(a_formId));
            return keys;
        }
    }

    std::string DataUrlOf(std::uint32_t a_formId) {
        const auto folder = Folder();
        if (folder.empty()) {
            return {};
        }
        std::error_code ec;
        for (const auto& key : Keys(a_formId)) {
            const auto file = folder / (key + ".cut.png");
            const auto size = std::filesystem::file_size(file, ec);
            if (ec || size == 0 || size > kMaxBytes) {
                ec.clear();
                continue;
            }
            std::ifstream in(file, std::ios::binary);
            std::vector<char> bytes(static_cast<std::size_t>(size));
            if (!in.read(bytes.data(), static_cast<std::streamsize>(bytes.size()))) {
                continue;
            }
            return "data:image/png;base64," + Base64(bytes);
        }
        return {};
    }
}
