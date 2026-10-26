#include "Family.h"

#include "PCH.h"

#include <map>
#include <mutex>
#include <vector>

namespace SNRom::Family {

    namespace {

        // Base records (TESNPC form ids): a child's parents, a parent's
        // children, as the plugins declare them. Written once at kDataLoaded.
        std::map<RE::FormID, std::vector<RE::FormID>> g_parentsOf;
        std::map<RE::FormID, std::vector<RE::FormID>> g_childrenOf;

        // SkyrimNet Kinship's read API (include/SNKinship_API.h in Kinship;
        // the one call it has is copied here, as its header asks).
        struct KinshipApiV1 {
            std::uint32_t version;
            std::uint32_t (*ChildrenWith)(std::uint32_t a_parentFormId, char* a_out, std::uint32_t a_size);
        };
        // Version 2 (Kinship 1.10): every child of the player's, with the day
        // each was born, for the calendar's birthdays.
        struct KinshipApiV2 {
            std::uint32_t version;
            std::uint32_t (*ChildrenWith)(std::uint32_t a_parentFormId, char* a_out, std::uint32_t a_size);
            std::uint32_t (*AllChildren)(char* a_out, std::uint32_t a_size);
        };
        std::once_flag      g_kinshipOnce;
        const KinshipApiV1* g_kinship = nullptr;
        const KinshipApiV2* g_kinship2 = nullptr;

        const KinshipApiV1* Kinship() {
            std::call_once(g_kinshipOnce, []() {
                using Request = const void* (*)(std::uint32_t);
                const auto dll = GetModuleHandleW(L"SkyrimNetKinship.dll");
                const auto fn = dll ? reinterpret_cast<Request>(GetProcAddress(dll, "SNKinship_RequestApi")) : nullptr;
                g_kinship = fn ? static_cast<const KinshipApiV1*>(fn(1)) : nullptr;
                g_kinship2 = fn ? static_cast<const KinshipApiV2*>(fn(2)) : nullptr;
                SKSE::log::info("Family: {}", g_kinship ? "children with the player read from SkyrimNet Kinship" :
                                                          "SkyrimNet Kinship 1.10 or later is not installed; no "
                                                          "children with the player are shown");
            });
            return g_kinship;
        }

        // ParentChild, and not Siblings: a family association whose parent
        // and child titles differ ("Father" and "Son", where Siblings is
        // "Brother" on both sides).
        bool IsParentChild(const RE::BGSAssociationType* a_type) {
            if (!a_type || !a_type->flags.all(RE::BGSAssociationType::FLAGS::kFamily)) {
                return false;
            }
            using M = RE::BGSAssociationType::Members;
            using S = RE::BGSAssociationType::Sexes;
            const auto& l = a_type->associationLabels;
            return l[M::kParent][S::kMale] != l[M::kChild][S::kMale] ||
                   l[M::kParent][S::kFemale] != l[M::kChild][S::kFemale];
        }

        RE::TESNPC* BaseOf(std::int32_t a_formId) {
            auto* actor = a_formId ? RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(a_formId)) : nullptr;
            return actor ? actor->GetActorBase() : nullptr;
        }

        std::string NameOf(RE::FormID a_npc) {
            auto*       npc = RE::TESForm::LookupByID<RE::TESNPC>(a_npc);
            const char* name = npc ? npc->GetName() : nullptr;
            return name && *name ? name : "";
        }

        bool Grown(RE::FormID a_npc) {
            auto* npc = RE::TESForm::LookupByID<RE::TESNPC>(a_npc);
            auto* race = npc ? npc->GetRace() : nullptr;
            return !race || !race->data.flags.all(RE::RACE_DATA::Flag::kChild);
        }

        bool Female(RE::FormID a_npc) {
            auto* npc = RE::TESForm::LookupByID<RE::TESNPC>(a_npc);
            return npc && npc->GetSex() == RE::SEX::kFemale;
        }

        // The player's descendants by reference form id (RefreshKin).
        struct Kin {
            int  generation = 0;
            bool adopted = false;
        };
        std::map<std::uint32_t, Kin> g_kin;
        std::size_t                  g_kinLogged = static_cast<std::size_t>(-1);

        // Every child Kinship records, parsed; empty without Kinship 1.10.
        nlohmann::json AllKinshipChildren() {
            Kinship();
            if (!g_kinship2) {
                return nlohmann::json::array();
            }
            const auto  need = g_kinship2->AllChildren(nullptr, 0);
            std::string text(need, '\0');
            if (need == 0 || g_kinship2->AllChildren(text.data(), need) != need) {
                return nlohmann::json::array();
            }
            text.resize(need - 1);
            auto kids = nlohmann::json::parse(text, nullptr, false);
            return kids.is_array() ? kids : nlohmann::json::array();
        }
    }

    void Index() {
        auto* data = RE::TESDataHandler::GetSingleton();
        if (!data) {
            return;
        }
        std::size_t pairs = 0;
        for (auto* rel : data->GetFormArray<RE::BGSRelationship>()) {
            if (!rel || !rel->npc1 || !rel->npc2 || !IsParentChild(rel->assocType)) {
                continue;
            }
            // Parent first, as the record's DATA lists them.
            g_childrenOf[rel->npc1->GetFormID()].push_back(rel->npc2->GetFormID());
            g_parentsOf[rel->npc2->GetFormID()].push_back(rel->npc1->GetFormID());
            ++pairs;
        }
        SKSE::log::info("Family: {} parent and child records read from the plugins", pairs);
    }

    nlohmann::json Of(std::int32_t a_formId) {
        nlohmann::json out{ { "parents", nlohmann::json::array() }, { "children", nlohmann::json::array() } };
        auto*          base = BaseOf(a_formId);
        if (!base) {
            return out;
        }
        const auto self = base->GetFormID();
        if (const auto it = g_parentsOf.find(self); it != g_parentsOf.end()) {
            for (const auto parent : it->second) {
                if (auto name = NameOf(parent); !name.empty()) {
                    out["parents"].push_back({ { "name", std::move(name) } });
                }
            }
        }
        // Theirs with the player first: Kinship's.
        if (const auto* kin = Kinship()) {
            const auto id = static_cast<std::uint32_t>(a_formId);
            const auto need = kin->ChildrenWith(id, nullptr, 0);
            std::string text(need, '\0');
            if (need > 0 && kin->ChildrenWith(id, text.data(), need) == need) {
                text.resize(need - 1);
                const auto kids = nlohmann::json::parse(text, nullptr, false);
                auto*      player = RE::PlayerCharacter::GetSingleton();
                const char* you = player ? player->GetName() : nullptr;
                if (kids.is_array()) {
                    for (const auto& k : kids) {
                        if (!k.is_object()) {
                            continue;
                        }
                        out["children"].push_back({ { "name", k.value("name", "") },
                                                    { "child", k.value("child", "") },
                                                    { "withPlayer", true },
                                                    { "otherParent", you ? you : "" },
                                                    { "stage", k.value("stage", -1) },
                                                    { "adopted", k.value("adopted", false) },
                                                    { "inWorld", k.value("inWorld", false) } });
                    }
                }
            }
        }
        // Theirs by anyone else, as the plugins record them.
        if (const auto it = g_childrenOf.find(self); it != g_childrenOf.end()) {
            for (const auto child : it->second) {
                auto name = NameOf(child);
                if (name.empty()) {
                    continue;
                }
                std::string other;
                if (const auto p = g_parentsOf.find(child); p != g_parentsOf.end()) {
                    for (const auto parent : p->second) {
                        if (parent != self) {
                            other = NameOf(parent);
                            break;
                        }
                    }
                }
                out["children"].push_back({ { "name", std::move(name) },
                                            { "child", Female(child) ? "daughter" : "son" },
                                            { "withPlayer", false },
                                            { "otherParent", std::move(other) },
                                            { "stage", Grown(child) ? 5 : 3 },
                                            { "adopted", false },
                                            { "inWorld", true } });
            }
        }
        return out;
    }

    nlohmann::json PlayerChildren() {
        auto out = nlohmann::json::array();
        Kinship();
        if (!g_kinship2) {
            return out;
        }
        const auto  need = g_kinship2->AllChildren(nullptr, 0);
        std::string text(need, '\0');
        if (need == 0 || g_kinship2->AllChildren(text.data(), need) != need) {
            return out;
        }
        text.resize(need - 1);
        const auto kids = nlohmann::json::parse(text, nullptr, false);
        if (!kids.is_array()) {
            return out;
        }
        auto*       player = RE::PlayerCharacter::GetSingleton();
        const char* you = player ? player->GetName() : nullptr;
        const std::string me = you ? you : "";
        for (const auto& k : kids) {
            if (!k.is_object()) {
                continue;
            }
            // The other parent: whichever of the two is not the player.
            const auto mother = k.value("mother", std::string{});
            const auto father = k.value("father", std::string{});
            const auto other = _stricmp(mother.c_str(), me.c_str()) == 0 ? father : mother;
            out.push_back({ { "name", k.value("name", "") },
                            { "child", k.value("child", "") },
                            { "born", k.value("born", 0.0) },
                            { "bornKnown", k.value("bornKnown", false) },
                            { "otherParent", other },
                            { "adopted", k.value("adopted", false) },
                            { "stage", k.value("stage", -1) } });
        }
        return out;
    }

    void RefreshKin() {
        g_kin.clear();
        std::size_t byReference = 0;
        std::size_t recordsOnly = 0;
        for (const auto& k : AllKinshipChildren()) {
            if (!k.is_object()) {
                continue;
            }
            const auto ref = static_cast<std::uint32_t>(k.value("refId", std::uint64_t{ 0 }));
            if (ref == 0) {
                ++recordsOnly;
                continue;
            }
            g_kin[ref] = { 1, k.value("adopted", false) };
            ++byReference;
        }
        // Grandchildren and on: the game's own records, a generation at a
        // time, from each descendant's base. Kinship records only the
        // player's own children.
        std::vector<std::uint32_t> frontier;
        for (const auto& [ref, kin] : g_kin) {
            frontier.push_back(ref);
        }
        std::size_t further = 0;
        for (int generation = 2; generation <= 8 && !frontier.empty(); ++generation) {
            std::vector<std::uint32_t> next;
            for (const auto ref : frontier) {
                auto* actor = RE::TESForm::LookupByID<RE::Actor>(ref);
                auto* base = actor ? actor->GetActorBase() : nullptr;
                const auto it = base ? g_childrenOf.find(base->GetFormID()) : g_childrenOf.end();
                if (it == g_childrenOf.end()) {
                    continue;
                }
                for (const auto npcId : it->second) {
                    auto* npc = RE::TESForm::LookupByID<RE::TESNPC>(npcId);
                    auto* child = npc ? npc->GetUniqueActor() : nullptr;
                    const auto id = child ? child->GetFormID() : 0;
                    if (id == 0 || id == 0x14 || g_kin.contains(id)) {
                        continue;
                    }
                    g_kin[id] = { generation, false };
                    next.push_back(id);
                    ++further;
                }
            }
            frontier = std::move(next);
        }
        // TEST LOG (wpm47): what the family is made of, when it changes;
        // remove once validated.
        if (g_kin.size() != g_kinLogged) {
            g_kinLogged = g_kin.size();
            SKSE::log::info("Family: {} of the player's children by reference from Kinship ({} records only, "
                            "not counted), {} further descendants from the plugins' records",
                            byReference, recordsOnly, further);
        }
    }

    nlohmann::json KinOf(std::int32_t a_formId) {
        const auto it = g_kin.find(static_cast<std::uint32_t>(a_formId));
        if (it == g_kin.end()) {
            return nullptr;
        }
        return { { "generation", it->second.generation }, { "adopted", it->second.adopted } };
    }

    std::string SexOf(std::int32_t a_formId) {
        auto* base = BaseOf(a_formId);
        if (!base) {
            return "";
        }
        return base->GetSex() == RE::SEX::kFemale ? "female" : "male";
    }
}
