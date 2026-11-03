#include "Officiant.h"

#include "PCH.h"

#include "OurPlugin.h"

#include "Marriage.h"

#include <cctype>
#include <cstring>
#include <array>

namespace SNRom::Officiant {

    namespace {

        RE::TESFaction* Faction(RE::FormID a_id, const char* a_plugin) {
            auto* data = RE::TESDataHandler::GetSingleton();
            return data ? data->LookupForm<RE::TESFaction>(a_id, a_plugin) : nullptr;
        }

        // Verified against Skyrim.esm's FACT records: JobPriestFaction and
        // JobJarlFaction. Ours is FACT SNRom_Officiant.
        RE::TESFaction* Priests() {
            static auto* f = Faction(0x0005159A, "Skyrim.esm");
            return f;
        }
        RE::TESFaction* Jarls() {
            static auto* f = Faction(0x00050920, "Skyrim.esm");
            return f;
        }
        RE::TESFaction* Ours() {
            static auto* f = Faction(0xD71, OurPlugin());
            return f;
        }
        RE::TESFaction* PlannerFaction() {
            static auto* f = Faction(0xD87, OurPlugin());
            return f;
        }
        // Who governs (verified against Skyrim.esm's FACT records, wpm48):
        // GovRuling and GovExiled. In the plugin a hold's jarl has GovRuling
        // at rank 0 and the jarl the civil war would put in their place rank
        // -1; the war's scripts move the ranks as it goes. Rank -1 reads as
        // not a member, so IsInFaction is "rules now". A jarl's court can be
        // in GovRuling too (Hrongar is), so it is only ever asked of a hold's
        // own jarls (kHolds).
        RE::TESFaction* GovRuling() {
            static auto* f = Faction(0x0003662A, "Skyrim.esm");
            return f;
        }
        RE::TESFaction* GovExiled() {
            static auto* f = Faction(0x00036629, "Skyrim.esm");
            return f;
        }

        // THE JARLS BY HOLD (wpm48; the author, 2026-10-26: name the hold,
        // "and it will be whomever occupies that position on the day of the
        // wedding"). The words a player may use for each hold, and the jarls
        // it can have, its own first. Solitude's carry no GovRuling in the
        // plugin; Elisif is its jarl unless the war marks another.
        struct Hold {
            const char*                 name;
            std::array<const char*, 3>  words;
            std::array<const char*, 3>  jarls;
        };
        constexpr Hold kHolds[] = {
            { "Whiterun", { "whiterun" }, { "Balgruuf the Greater", "Vignar Gray-Mane" } },
            { "Solitude", { "solitude", "haafingar" }, { "Elisif the Fair", "Erikur", "Bryling" } },
            { "Windhelm", { "windhelm", "eastmarch" }, { "Ulfric Stormcloak", "Brunwulf Free-Winter" } },
            { "Riften", { "riften", "rift" }, { "Laila Law-Giver", "Maven Black-Briar" } },
            { "Markarth", { "markarth", "reach" }, { "Igmund", "Thongvor Silver-Blood" } },
            { "Falkreath", { "falkreath" }, { "Siddgeir", "Dengeir of Stuhn" } },
            { "Morthal", { "morthal", "hjaalmarch" }, { "Idgrod Ravencrone", "Sorli the Builder" } },
            { "Dawnstar", { "dawnstar", "pale" }, { "Skald", "Brina Merilis" } },
            { "Winterhold", { "winterhold" }, { "Korir", "Kraldar" } },
        };
        // Their records, by kHolds index, found at kDataLoaded (MarkAll).
        std::vector<std::vector<RE::TESNPC*>> g_holdJarls;

        // Lowercased, trimmed, a leading "the " and "jarl " taken off.
        std::string Plain(std::string_view a_text) {
            std::string out;
            for (const char c : a_text) {
                if (!std::isspace(static_cast<unsigned char>(c)) || !out.empty()) {
                    out += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
                }
            }
            while (!out.empty() && std::isspace(static_cast<unsigned char>(out.back()))) {
                out.pop_back();
            }
            for (const auto* prefix : { "the ", "jarl " }) {
                if (out.starts_with(prefix)) {
                    out.erase(0, std::strlen(prefix));
                }
            }
            return out;
        }

        // Who rules a hold now, of its own jarls: the one the war marks as
        // ruling, else its own jarl, else whoever of them still lives.
        RE::Actor* Ruler(std::size_t a_hold, const char*& a_how) {
            RE::Actor* own = nullptr;
            RE::Actor* living = nullptr;
            if (a_hold >= g_holdJarls.size()) {
                return nullptr;
            }
            for (auto* npc : g_holdJarls[a_hold]) {
                auto* actor = npc ? npc->GetUniqueActor() : nullptr;
                if (!actor || actor->IsDead()) {
                    continue;
                }
                const bool exiled = GovExiled() && actor->IsInFaction(GovExiled());
                if (!exiled && GovRuling() && actor->IsInFaction(GovRuling())) {
                    a_how = "marked ruling";
                    return actor;
                }
                if (!exiled && !own) {
                    own = actor;
                }
                if (!living) {
                    living = actor;
                }
            }
            a_how = own ? "the hold's own, none marked ruling" : "the only one living";
            return own ? own : living;
        }

        // "the Jarl of Whiterun", "jarl of the Reach", "Eastmarch's jarl":
        // the hold, or -1. Asked only when "jarl" is said.
        int HoldIn(const std::string& a_lower) {
            if (a_lower.find("jarl") == std::string::npos) {
                return -1;
            }
            for (std::size_t i = 0; i < std::size(kHolds); ++i) {
                for (const auto* word : kHolds[i].words) {
                    if (word && a_lower.find(word) != std::string::npos) {
                        return static_cast<int>(i);
                    }
                }
            }
            return -1;
        }

        // Every officiant's record, found at kDataLoaded from the plugins.
        std::vector<RE::TESNPC*> g_officiants;

        // THE WEDDING PLANNERS (Build B, M4p; the author, 2026-10-20: "a
        // handful of base-game NPCs"). A priestess in each of five temples,
        // so there is one in every major city's reach: Mara's in Riften, the
        // Divines' in Solitude, Kynareth's in Whiterun, Dibella's in Markarth,
        // Talos's in Windhelm. Found by name among the unique NPCs.
        constexpr const char* kPlannerNames[] = { "Dinya Balu", "Silana Petreia", "Danica Pure-Spring", "Senna",
                                                  "Jora" };
        std::vector<RE::TESNPC*> g_planners;

        // THE PLANNER'S BOOK lists these by hand (tools/rings/
        // add_ring_records.py, BOOK_TEXT): checked once at kDataLoaded, so a
        // name the book gets wrong is in the log, not discovered in play.
        constexpr const char* kBookOfficiants[] = {
            "Maramal", "Dinya Balu", "Rorlund", "Silana Petreia", "Freir", "Danica Pure-Spring", "Hamal", "Senna",
            "Jora", "Lortheim", "Andurs", "Styrr", "Brother Verulus", "Helgird", "Runil"
        };

        void Mark(RE::TESNPC* a_npc, RE::TESFaction* a_ours);

        // The record lists a_faction, at any rank.
        bool Lists(const RE::TESNPC* a_npc, const RE::TESFaction* a_faction) {
            if (!a_npc || !a_faction) {
                return false;
            }
            for (const auto& entry : a_npc->factions) {
                if (entry.faction == a_faction) {
                    return true;
                }
            }
            return false;
        }
    }

    void MarkAll() {
        auto* data = RE::TESDataHandler::GetSingleton();
        auto* ours = Ours();
        if (!data || !ours) {
            SKSE::log::warn("Officiants: SNRom_Officiant not found; no one can marry the player");
            return;
        }
        g_officiants.clear();
        for (auto* npc : data->GetFormArray<RE::TESNPC>()) {
            if (npc && (Lists(npc, Priests()) || Lists(npc, Jarls()))) {
                g_officiants.push_back(npc);
                Mark(npc, ours);
            }
        }
        SKSE::log::info("Officiants: {} priests, priestesses and jarls can marry the player", g_officiants.size());

        g_planners.clear();
        if (auto* planners = PlannerFaction()) {
            for (auto* npc : data->GetFormArray<RE::TESNPC>()) {
                const char* name = npc && npc->IsUnique() ? npc->GetFullName() : nullptr;
                if (!name || !*name) {
                    continue;
                }
                for (const auto* wanted : kPlannerNames) {
                    if (_stricmp(name, wanted) == 0) {
                        g_planners.push_back(npc);
                        Mark(npc, planners);
                        break;
                    }
                }
            }
        }
        SKSE::log::info("Officiants: {} wedding planners", g_planners.size());

        // THE BOOK'S OFFICIANTS ARE OFFICIANTS (2026-10-25). Thirteen of those
        // it names - Rorlund, Silana Petreia, Senna, Jora, the priests of
        // Arkay, Skald the Elder - are in neither vanilla job faction, so the
        // planner could not choose them. Each unique NPC by that name is
        // marked as well; a name with no NPC at all is logged.
        std::size_t added = 0;
        std::string missing;
        for (const auto* name : kBookOfficiants) {
            bool found = false;
            for (auto* npc : data->GetFormArray<RE::TESNPC>()) {
                const char* full = npc && npc->IsUnique() ? npc->GetFullName() : nullptr;
                if (!full || _stricmp(full, name) != 0) {
                    continue;
                }
                found = true;
                if (std::find(g_officiants.begin(), g_officiants.end(), npc) == g_officiants.end()) {
                    g_officiants.push_back(npc);
                    Mark(npc, ours);
                    ++added;
                }
            }
            if (!found) {
                missing += (missing.empty() ? "" : ", ") + std::string(name);
            }
        }
        SKSE::log::info("Officiants: {} more from the planner's book, outside the job factions", added);
        if (!missing.empty()) {
            SKSE::log::warn("Officiants: the planner's book names some no NPC here has: {}", missing);
        }

        // The jarls by hold (kHolds), as the book now names them.
        g_holdJarls.assign(std::size(kHolds), {});
        std::string noJarl;
        for (std::size_t i = 0; i < std::size(kHolds); ++i) {
            for (const auto* name : kHolds[i].jarls) {
                if (!name) {
                    continue;
                }
                RE::TESNPC* found = nullptr;
                for (auto* npc : data->GetFormArray<RE::TESNPC>()) {
                    const char* full = npc && npc->IsUnique() ? npc->GetFullName() : nullptr;
                    if (full && Plain(full) == Plain(name)) {
                        found = npc;
                        break;
                    }
                }
                if (found) {
                    g_holdJarls[i].push_back(found);
                    if (std::find(g_officiants.begin(), g_officiants.end(), found) == g_officiants.end()) {
                        g_officiants.push_back(found);
                        Mark(found, ours);
                    }
                } else {
                    noJarl += (noJarl.empty() ? "" : ", ") + std::string(name);
                }
            }
        }
        if (!noJarl.empty()) {
            SKSE::log::warn("Officiants: no NPC here is the jarl {}", noJarl);
        }
    }

    void Remark() {
        auto* ours = Ours();
        if (!ours) {
            return;
        }
        std::size_t again = 0;
        for (auto* npc : g_officiants) {
            if (!Lists(npc, ours)) {
                Mark(npc, ours);
                ++again;
            }
        }
        if (auto* planners = PlannerFaction()) {
            for (auto* npc : g_planners) {
                if (!Lists(npc, planners)) {
                    Mark(npc, planners);
                    ++again;
                }
            }
        }
        SKSE::log::info("Officiants: {} marked again after the load (their factions came from the save)", again);
    }

    // Named, as it was said.
    static RE::Actor* AsSaid(const std::string& a_name) {
        // "Jarl Elisif the Fair" asks for Elisif the Fair: the title is not
        // part of her record's name.
        const std::string wanted = Plain(a_name);
        if (wanted.empty()) {
            return nullptr;
        }
        // A name exactly first, so "Jarl Siddgeir of Falkreath" is Siddgeir;
        // then a hold ("the Jarl of Whiterun"), whoever rules it now; then
        // part of a name.
        for (auto* npc : g_officiants) {
            const char* name = npc ? npc->GetFullName() : nullptr;
            auto*       actor = name && *name ? npc->GetUniqueActor() : nullptr;
            if (actor && !actor->IsDead() && Plain(name) == wanted) {
                return actor;
            }
        }
        std::string said;
        for (const char c : a_name) {
            said += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        }
        if (const auto hold = HoldIn(said); hold >= 0) {
            const char* how = "";
            auto*       ruler = Ruler(static_cast<std::size_t>(hold), how);
            // TEST LOG (wpm48): who a hold's jarl turned out to be, and why;
            // remove once validated.
            SKSE::log::info("Officiants: '{}' is the Jarl of {}: {} ({})", a_name, kHolds[hold].name,
                            ruler ? ruler->GetDisplayFullName() : "nobody living", how);
            if (ruler) {
                return ruler;
            }
        }
        RE::Actor* partial = nullptr;
        for (auto* npc : g_officiants) {
            const char* name = npc ? npc->GetFullName() : nullptr;
            if (!name || !*name) {
                continue;
            }
            std::string lower;
            for (const char* c = name; *c; ++c) {
                lower += static_cast<char>(std::tolower(static_cast<unsigned char>(*c)));
            }
            auto* actor = npc->GetUniqueActor();
            if (!actor || actor->IsDead()) {
                continue;
            }
            if (lower == wanted) {
                return actor;
            }
            // "Skald the Elder" asked of a record named "Skald": the record's
            // name, then a space, begins what was asked.
            if (!partial && (lower.starts_with(wanted) || lower.find(wanted) != std::string::npos ||
                             wanted.starts_with(lower + " "))) {
                partial = actor;
            }
        }
        return partial;
    }

    // TITLES OFF (seen in play, wpm88): "Mother Hamal" found no one, since
    // her record is "Hamal"; the plan judge, reading "Hamal", rescued it.
    std::string TitleOff(std::string_view a_said) {
        static constexpr std::array kTitles{ "high priestess ", "high priest ", "priestess ", "priest ", "mother ",
                                             "father ", "sister ", "brother ", "lady ", "lord ", "thane ",
                                             "master ", "mistress ", "madam ", "sir ", "dame ", "elder ",
                                             "auntie ", "uncle " };
        std::string lower;
        std::size_t start = 0;
        while (start < a_said.size() && std::isspace(static_cast<unsigned char>(a_said[start]))) {
            ++start;
        }
        for (std::size_t i = start; i < a_said.size(); ++i) {
            lower += static_cast<char>(std::tolower(static_cast<unsigned char>(a_said[i])));
        }
        std::size_t skip = lower.starts_with("the ") ? 4 : 0;
        for (const auto* title : kTitles) {
            if (lower.compare(skip, std::strlen(title), title) == 0) {
                std::string rest(a_said.substr(start + skip + std::strlen(title)));
                while (!rest.empty() && std::isspace(static_cast<unsigned char>(rest.front()))) {
                    rest.erase(0, 1);
                }
                return rest;
            }
        }
        return {};
    }

    RE::Actor* Named(const std::string& a_name) {
        if (auto* actor = AsSaid(a_name)) {
            return actor;
        }
        const auto bare = TitleOff(a_name);
        auto*      actor = bare.empty() ? nullptr : AsSaid(bare);
        // TEST LOG (wpm89): a name found only without its title; remove once
        // validated.
        if (!bare.empty()) {
            SKSE::log::info("Officiants: '{}' without its title is '{}': {}", a_name, bare,
                            actor ? actor->GetDisplayFullName() : "still no one");
        }
        return actor;
    }

    RE::Actor* InPlaceOf(std::uint32_t a_officiant) {
        auto* actor = a_officiant ? RE::TESForm::LookupByID<RE::Actor>(a_officiant) : nullptr;
        auto* base = actor ? actor->GetActorBase() : nullptr;
        if (!base) {
            return actor;
        }
        for (std::size_t i = 0; i < g_holdJarls.size(); ++i) {
            const auto& jarls = g_holdJarls[i];
            if (std::find(jarls.begin(), jarls.end(), base) == jarls.end()) {
                continue;
            }
            const bool gone = actor->IsDead() || (GovExiled() && actor->IsInFaction(GovExiled()));
            if (!gone) {
                return actor;
            }
            const char* how = "";
            auto*       ruler = Ruler(i, how);
            SKSE::log::info("Officiants: {} no longer holds {}; {} comes in their place ({})",
                            actor->GetDisplayFullName(), kHolds[i].name,
                            ruler ? ruler->GetDisplayFullName() : "nobody", how);
            return ruler ? ruler : actor;
        }
        return actor;
    }

    bool IsPlanner(RE::Actor* a_actor) {
        if (!a_actor || a_actor->IsDead()) {
            return false;
        }
        auto* base = a_actor->GetActorBase();
        return base && std::find(g_planners.begin(), g_planners.end(), base) != g_planners.end();
    }

    bool Is(RE::Actor* a_actor) {
        if (!a_actor || a_actor->IsDead() || a_actor->IsChild() || a_actor->IsPlayerRef()) {
            return false;
        }
        // The plugins' officiants; the factions catch someone a mod makes a
        // priest or jarl while the game runs.
        auto* base = a_actor->GetActorBase();
        if (base && std::find(g_officiants.begin(), g_officiants.end(), base) != g_officiants.end()) {
            return true;
        }
        const auto in = [&](RE::TESFaction* a_faction) { return a_faction && a_actor->IsInFaction(a_faction); };
        return in(Ours()) || in(Priests()) || in(Jarls());
    }

    namespace {
        void Mark(RE::TESNPC* a_npc, RE::TESFaction* a_ours) {
            if (Lists(a_npc, a_ours)) {
                return;
            }
            RE::FACTION_RANK entry{};
            entry.faction = a_ours;
            entry.rank = 0;
            a_npc->factions.push_back(entry);
        }
    }

    std::vector<RE::Actor*> BetrothedNear(float a_range) {
        std::vector<RE::Actor*> out;
        auto*                   player = RE::PlayerCharacter::GetSingleton();
        if (!player) {
            return out;
        }
        const auto here = player->GetPosition();
        for (const auto id : Marriage::AllEngaged()) {
            auto* actor = RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(id));
            if (!actor || actor->IsDead() || !actor->Is3DLoaded()) {
                continue;
            }
            // Indoors, the same cell; outdoors, the same worldspace (a
            // neighbouring exterior cell is still across the square).
            auto*      cell = player->GetParentCell();
            const bool indoors = cell && cell->IsInteriorCell();
            if (indoors ? actor->GetParentCell() != cell : actor->GetWorldspace() != player->GetWorldspace()) {
                continue;
            }
            if (actor->GetPosition().GetDistance(here) <= a_range) {
                out.push_back(actor);
            }
        }
        return out;
    }

    bool CanBless(RE::Actor* a_actor) {
        if (!Is(a_actor) || !Marriage::MayMarryAnother()) {
            return false;
        }
        for (auto* betrothed : BetrothedNear(kPresentRange)) {
            if (betrothed != a_actor) {
                return true;
            }
        }
        return false;
    }
}
