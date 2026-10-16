#include "Decorators.h"

#include "PCH.h"

#include "Dashboard.h"
#include "Display.h"
#include "Model.h"

#include <atomic>
#include <cctype>
#include <cmath>
#include <functional>

namespace SNRom::Decorators {

    namespace {

        using json = nlohmann::json;

        // SkyrimNet's PublicAPI.h: PublicRegisterDecorator (v5+). The callback
        // must be thread-safe; it runs on SkyrimNet's prompt threads.
        using RegisterFn = bool (*)(const char*, const char*, std::function<std::string(RE::Actor*)>);
        using VersionFn = int (*)();

        std::atomic<bool>         g_active{ false };
        std::atomic<std::int32_t> g_partners{ 0 };
        std::atomic<float>        g_bypassRatio{ 1.5F };

        // SNRom_Bridge.TierName: the ladder the prompts and the log use.
        const char* TierName(std::int32_t a_tier) {
            if (a_tier >= 5) {
                return "Spouse";
            }
            switch (a_tier) {
            case 4:
                return "Lover";
            case 3:
                return "Confidant";
            case 2:
                return "Friend";
            case 1:
                return "Acquaintance";
            case -1:
                return "Disliked";
            case -2:
                return "Resentful";
            default:
                return a_tier <= -3 ? "Enemy" : "Stranger";
            }
        }

        // SNRom_Decorators.IntimacyRank: 0 casual, 1 romantic, 2 guarded, 3 never.
        std::int32_t IntimacyRank(std::int32_t a_minTier) {
            if (a_minTier < 0) {
                return 3;
            }
            if (a_minTier >= 5) {
                return 2;
            }
            return a_minTier == 4 ? 1 : 0;
        }

        // SNRom_Decorators.OrientationWord: stated only when KNOWN.
        const char* OrientationWord(const Model::Numbers& a_n) {
            if (a_n[Model::kOrientationBasis] < 2) {
                return "";
            }
            switch (a_n[Model::kOrientation]) {
            case 1:
                return "men";
            case 2:
                return "women";
            case 0:
                return "no one";
            default:
                return "both men and women";
            }
        }

        struct Row {
            Model::Numbers       n{};
            Model::Texts         text{};
            Display::EngineFacts engine;
            Display::BatchFacts  batch;
            std::int32_t         playerSex = 0;
        };

        // Enrolled and pushed, or nothing: someone the model does not hold is
        // answered exactly as Papyrus answers someone not enrolled.
        std::optional<Row> Load(std::int32_t a_formId) {
            auto numbers = Model::Get().NumbersOf(a_formId);
            if (!numbers || (*numbers)[Model::kEnrolledFlag] != 1) {
                return std::nullopt;
            }
            Row row;
            row.n = *numbers;
            if (auto text = Model::Get().TextsOf(a_formId)) {
                row.text = std::move(*text);
            }
            row.engine = Dashboard::EngineFactsOf(a_formId);
            row.batch = Model::Get().Facts();
            row.playerSex = Dashboard::PlayerSexNow();
            return row;
        }

        // SNRom_Decorators.RomanceOk.
        bool RomanceOk(std::int32_t a_formId, const Row& a_row) {
            if (a_row.batch.kinGuard && a_row.n[Model::kPlayerKin] == 1) {
                return false;
            }
            if (Display::MarriedToPlayer(a_formId, a_row.engine, a_row.batch)) {
                return true;
            }
            if (a_row.n[Model::kOrientationBasis] < 2) {
                return true;
            }
            const auto orient = a_row.n[Model::kOrientation];
            if (orient == 0) {
                return false;
            }
            if (orient == 1 && a_row.playerSex != 0) {
                return false;
            }
            if (orient == 2 && a_row.playerSex != 1) {
                return false;
            }
            return true;
        }

        std::int32_t Applicability(std::int32_t a_formId, const Row& a_row) {
            Display::StoredFacts stored;
            stored.orientation = a_row.n[Model::kOrientation];
            stored.orientationKnown = a_row.n[Model::kOrientationBasis];
            stored.playerKin = a_row.n[Model::kPlayerKin] == 1;
            return Display::Applicability(a_formId, a_row.engine, a_row.batch, stored, a_row.playerSex);
        }

        // SNRom_Decorators.OtherPartners: the count less themselves.
        std::int32_t OtherPartners(const Row& a_row) {
            auto total = g_partners.load();
            if (a_row.n[Model::kSparked] == 1 && a_row.n[Model::kStance] == 1) {
                --total;
            }
            return total < 0 ? 0 : total;
        }

        json RomanceObject(std::int32_t a_formId, const Row& a_row) {
            const auto& n = a_row.n;
            const auto  pts = n[Model::kPoints];
            const auto  tier = n[Model::kTier];
            auto        toNext = ((tier + 1) * 500) - pts;
            if (tier < 0) {
                toNext = ((tier + 1) * 500) - 499 - pts;
            }
            if (toNext < 0) {
                toNext = 0;
            }
            auto peak = n[Model::kPeakTier] == -9 ? tier : n[Model::kPeakTier];
            if (peak < tier) {
                peak = tier;
            }
            const auto married = tier <= 0 && Display::MarriedToPlayer(a_formId, a_row.engine, a_row.batch);
            const auto bio = n[Model::kBioHasBits];
            // INTS, NOT JSON BOOLEANS, as the Papyrus original: the prompts
            // test == 1. "enrolled" alone is a boolean, as it always was.
            return json{
                { "enrolled", true },
                { "points", pts },
                { "level", tier },
                { "peak", peak },
                { "ended", n[Model::kEndedAt] >= 0 ? 1 : 0 },
                { "married", married ? 1 : 0 },
                { "levelName", TierName(tier) },
                { "toNext", toNext },
                { "ardor", n[Model::kArdor] },
                { "exclusivity", n[Model::kExclusivity] },
                { "sparked", n[Model::kSparked] == 1 ? 1 : 0 },
                { "romanceOk", RomanceOk(a_formId, a_row) ? 1 : 0 },
                { "orientation", OrientationWord(n) },
                { "orientationKnown", n[Model::kOrientationBasis] },
                { "why", a_row.text[Model::kWhy] },
                { "limit", a_row.text[Model::kLimit] },
                { "address", a_row.text[Model::kAddress] },
                { "history", a_row.text[Model::kPlayerSays] },
                { "addressDropped", a_row.text[Model::kAddressDropped] },
                { "romanceNA", Applicability(a_formId, a_row) },
                { "physMinTier", n[Model::kPhysMinTier] },
                { "otherPartners", OtherPartners(a_row) },
                { "stance", n[Model::kStance] },
                { "blkDrawn", bio & 1 },
                { "blkAttach", (bio & 4) >> 2 },
            };
        }

        // SNRom_Decorators.PhysicalOk: SEXUAL intimacy only.
        bool Physical(std::int32_t a_formId, const Row& a_row) {
            const auto& n = a_row.n;
            if (Applicability(a_formId, a_row) != 0) {
                return false;
            }
            auto minTier = n[Model::kPhysMinTier];
            if (minTier < 0) {
                return false;
            }
            const auto rank = IntimacyRank(minTier);
            if (rank >= 1) {
                if (n[Model::kSparked] != 1 && Display::Commitment(a_formId, a_row.engine, a_row.batch) < 2) {
                    return false;
                }
                if (rank == 1) {
                    minTier = 3;  // Confidant
                }
            }
            const auto tier = n[Model::kTier];
            if (tier < 0) {
                return false;  // closed below Stranger, whatever the disposition
            }
            if (tier >= minTier) {
                return true;
            }
            const auto banked = n[Model::kBanked];
            if (banked > 0 && (n[Model::kPoints] + banked) / 500 >= minTier) {
                return true;
            }
            if (n[Model::kAttrBypass] == 1) {
                const auto ratio = static_cast<double>(n[Model::kAttractionMilli]) / 1000.0;
                if (ratio > 0.0 && ratio >= static_cast<double>(g_bypassRatio.load())) {
                    return true;
                }
            }
            return false;
        }

        // What the check forgives, measured on the first run (2026-10-16, 146
        // bonds): Papyrus strings pass through one case-insensitive string
        // table, so "false" can come back "False" depending on what entered it
        // first; and Papyrus's JsonEscape turns a double quote in authored text
        // into a single one, where the native JSON escapes it. Neither is a
        // difference a prompt sees.
        std::string Lower(std::string a_text) {
            for (auto& c : a_text) {
                c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            }
            return a_text;
        }

        json Forgiving(const json& a_value) {
            if (!a_value.is_string()) {
                return a_value;
            }
            auto text = a_value.get<std::string>();
            for (auto& c : text) {
                if (c == '"') {
                    c = '\'';
                }
            }
            return text;
        }

        std::int32_t FormIdOf(RE::Actor* a_actor) {
            return a_actor ? static_cast<std::int32_t>(a_actor->GetFormID()) : 0;
        }
    }

    std::string Romance(std::int32_t a_formId) {
        const auto row = a_formId ? Load(a_formId) : std::nullopt;
        if (!row) {
            return R"({"enrolled":false})";
        }
        return RomanceObject(a_formId, *row).dump(-1, ' ', false, json::error_handler_t::replace);
    }

    std::string PhysicalOk(std::int32_t a_formId) {
        const auto row = a_formId ? Load(a_formId) : std::nullopt;
        return row && Physical(a_formId, *row) ? "true" : "false";
    }

    bool Register() {
        const auto mod = GetModuleHandleW(L"SkyrimNet.dll");
        const auto version = mod ? reinterpret_cast<VersionFn>(GetProcAddress(mod, "PublicGetVersion")) : nullptr;
        const auto api = version ? version() : 0;
        const auto reg = api >= 5 ? reinterpret_cast<RegisterFn>(GetProcAddress(mod, "PublicRegisterDecorator"))
                                  : nullptr;
        if (!reg) {
            SKSE::log::warn("Decorators: SkyrimNet API v{} has no native decorators; Papyrus registers its own", api);
            return false;
        }
        const auto romance = reg("get_romance", "Relationships: this person's bond with the player, as JSON",
                                 [](RE::Actor* a_actor) { return Romance(FormIdOf(a_actor)); });
        const auto physical = reg("romance_physical_ok",
                                  "Relationships: whether sexual intimacy with the player is open to them",
                                  [](RE::Actor* a_actor) { return PhysicalOk(FormIdOf(a_actor)); });
        g_active = romance && physical;
        SKSE::log::info("Decorators: native get_romance {}, romance_physical_ok {} (SkyrimNet API v{})",
                        romance ? "registered" : "REFUSED", physical ? "registered" : "REFUSED", api);
        return g_active;
    }

    bool Active() {
        return g_active.load();
    }

    void SetFacts(std::int32_t a_partnerCount, float a_bypassRatio) {
        g_partners = a_partnerCount;
        g_bypassRatio = a_bypassRatio;
    }

    std::int32_t Check(std::int32_t a_formId, const std::string& a_papyrusRomance,
                       const std::string& a_papyrusPhysical) {
        std::int32_t disagreements = 0;
        const auto   name = Dashboard::EngineFactsOf(a_formId).name;
        const auto   mine = json::parse(Romance(a_formId), nullptr, false);
        const auto   theirs = json::parse(a_papyrusRomance, nullptr, false);
        if (!theirs.is_object()) {
            ++disagreements;
            SKSE::log::warn("Decorator check: {} ({:08X}) Papyrus get_romance is not valid JSON: {}", name,
                            static_cast<std::uint32_t>(a_formId), a_papyrusRomance);
        } else if (mine.is_object()) {
            for (const auto& [key, value] : theirs.items()) {
                // levelName is case-folded by the Papyrus compiler; no template reads it.
                if (key == "levelName") {
                    continue;
                }
                const auto it = mine.find(key);
                if (it == mine.end() || Forgiving(*it) != Forgiving(value)) {
                    ++disagreements;
                    SKSE::log::warn("Decorator check: {} ({:08X}) get_romance.{}: Papyrus says {}, native says {}",
                                    name, static_cast<std::uint32_t>(a_formId), key, value.dump(),
                                    it == mine.end() ? "(missing)" : it->dump());
                }
            }
        }
        const auto physical = PhysicalOk(a_formId);
        if (physical != Lower(a_papyrusPhysical)) {
            ++disagreements;
            SKSE::log::warn("Decorator check: {} ({:08X}) romance_physical_ok: Papyrus says {}, native says {}", name,
                            static_cast<std::uint32_t>(a_formId), a_papyrusPhysical, physical);
        }
        return disagreements;
    }
}
