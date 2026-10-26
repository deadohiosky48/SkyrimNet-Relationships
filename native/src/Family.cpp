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

    std::string SexOf(std::int32_t a_formId) {
        auto* base = BaseOf(a_formId);
        if (!base) {
            return "";
        }
        return base->GetSex() == RE::SEX::kFemale ? "female" : "male";
    }
}
