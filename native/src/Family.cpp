#include "Family.h"

#include "PCH.h"

#include "Marriage.h"

#include <cctype>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <vector>

namespace SNRom::Family {

    namespace {

        std::string Lower(std::string a_text) {
            for (auto& c : a_text) {
                c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            }
            return a_text;
        }

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
        // ONE CHILD, ONE LINE (2.6; seen in play, the author, 2026-11-04):
        // Erith, Daighre's daughter by the game's records, adopted by the
        // player in Kinship with Daighre as her mother, was listed twice. A
        // child Kinship lists is not listed again from the records: by base,
        // or by name when Kinship's child has no body to resolve.
        std::set<RE::FormID>  kinBases;
        std::set<std::string> kinNames;
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
                        const auto ref = static_cast<RE::FormID>(k.value("refId", std::uint64_t{ 0 }));
                        auto*      body = ref ? RE::TESForm::LookupByID<RE::Actor>(ref) : nullptr;
                        if (auto* npc = body ? body->GetActorBase() : nullptr) {
                            kinBases.insert(npc->GetFormID());
                        } else if (auto said = Lower(k.value("name", "")); !said.empty()) {
                            kinNames.insert(std::move(said));
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
                if (name.empty() || kinBases.contains(child) || kinNames.contains(Lower(name))) {
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
        // What the family is made of, when it changes (wpm47).
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

    std::vector<RE::Actor*> Relatives(RE::Actor* a_of, const std::string& a_relation) {
        std::vector<RE::Actor*> out;
        auto*                   base = a_of ? a_of->GetActorBase() : nullptr;
        if (!base) {
            return out;
        }
        // The relation, singular, and the sex it asks for: 1 female, 0 male,
        // -1 either.
        // THE PLAYER'S SPOUSES (wpm52; Olfina asked for her "sister-wives"):
        // "wives", "husbands", "spouses" of the player, and "sister-wives" or
        // "co-wives" of anyone married or engaged to them - the player's
        // other spouses. From Relationships' marriage record, married or
        // separated.
        std::string key;
        for (const char c : a_relation) {
            if (c != ' ' && c != '-') {
                key += c;
            }
        }
        int spouseSex = -2;   // -2 not a spouse word; -1 either; 1 female; 0 male
        bool coSpouse = false;
        if (key == "wife" || key == "wives") {
            spouseSex = 1;
        } else if (key == "husband" || key == "husbands") {
            spouseSex = 0;
        } else if (key == "spouse" || key == "spouses") {
            spouseSex = -1;
        } else if (key == "sisterwife" || key == "sisterwives" || key == "cowife" || key == "cowives") {
            spouseSex = 1, coSpouse = true;
        } else if (key == "brotherhusband" || key == "brotherhusbands" || key == "cohusband" || key == "cohusbands" ||
                   key == "cospouse" || key == "cospouses") {
            spouseSex = key.starts_with("brother") || key.starts_with("cohusband") ? 0 : -1, coSpouse = true;
        }
        if (spouseSex != -2) {
            const bool ofPlayer = a_of->IsPlayerRef();
            const auto ownState = Marriage::StateOf(static_cast<std::int32_t>(a_of->GetFormID()));
            const bool wedToPlayer = ownState == Marriage::State::kMarried || ownState == Marriage::State::kEngaged ||
                                     ownState == Marriage::State::kSeparated;
            if (!(ofPlayer && !coSpouse) && !(coSpouse && wedToPlayer)) {
                return out;
            }
            std::vector<std::int32_t> spouses = Marriage::WithState(Marriage::State::kMarried);
            for (const auto id : Marriage::WithState(Marriage::State::kSeparated)) {
                spouses.push_back(id);
            }
            for (const auto id : spouses) {
                auto* spouse = RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(id));
                auto* spouseBase = spouse ? spouse->GetActorBase() : nullptr;
                if (!spouse || spouse == a_of || spouse->IsDead() || !spouseBase) {
                    continue;
                }
                if (spouseSex >= 0 && (spouseBase->GetSex() == RE::SEX::kFemale) != (spouseSex == 1)) {
                    continue;
                }
                out.push_back(spouse);
            }
            return out;
        }
        std::string rel = a_relation;
        if (rel.ends_with("ren")) {
            rel.resize(rel.size() - 3);   // children
        } else if (rel.ends_with("s")) {
            rel.pop_back();               // brothers, parents, kids
        }
        int         sex = -1;
        std::string kind;
        if (rel == "mother" || rel == "mom" || rel == "mum" || rel == "ma") {
            kind = "parent", sex = 1;
        } else if (rel == "father" || rel == "dad" || rel == "pa" || rel == "da") {
            kind = "parent", sex = 0;
        } else if (rel == "parent") {
            kind = "parent";
        } else if (rel == "brother") {
            kind = "sibling", sex = 0;
        } else if (rel == "sister") {
            kind = "sibling", sex = 1;
        } else if (rel == "sibling") {
            kind = "sibling";
        } else if (rel == "son") {
            kind = "child", sex = 0;
        } else if (rel == "daughter") {
            kind = "child", sex = 1;
        } else if (rel == "child" || rel == "kid") {
            kind = "child";
        } else {
            return out;
        }
        const auto self = base->GetFormID();
        std::vector<RE::FormID> npcs;
        const auto add = [&](RE::FormID a_npc) {
            if (a_npc != self && std::ranges::find(npcs, a_npc) == npcs.end()) {
                npcs.push_back(a_npc);
            }
        };
        const auto parents = g_parentsOf.find(self);
        if (kind == "parent" && parents != g_parentsOf.end()) {
            for (const auto p : parents->second) {
                add(p);
            }
        } else if (kind == "sibling" && parents != g_parentsOf.end()) {
            for (const auto p : parents->second) {
                if (const auto kids = g_childrenOf.find(p); kids != g_childrenOf.end()) {
                    for (const auto k : kids->second) {
                        add(k);
                    }
                }
            }
        } else if (kind == "child") {
            if (const auto kids = g_childrenOf.find(self); kids != g_childrenOf.end()) {
                for (const auto k : kids->second) {
                    add(k);
                }
            }
        }
        for (const auto npcId : npcs) {
            if (sex >= 0 && Female(npcId) != (sex == 1)) {
                continue;
            }
            auto* npc = RE::TESForm::LookupByID<RE::TESNPC>(npcId);
            auto* actor = npc ? npc->GetUniqueActor() : nullptr;
            if (actor && !actor->IsDead()) {
                out.push_back(actor);
            }
        }
        // The player's own children: Kinship's, by reference.
        if (kind == "child" && a_of->IsPlayerRef()) {
            RefreshKin();
            for (const auto& [ref, kin] : g_kin) {
                auto* child = kin.generation == 1 ? RE::TESForm::LookupByID<RE::Actor>(ref) : nullptr;
                auto* childBase = child ? child->GetActorBase() : nullptr;
                if (!child || child->IsDead() || !childBase) {
                    continue;
                }
                if (sex >= 0 && (childBase->GetSex() == RE::SEX::kFemale) != (sex == 1)) {
                    continue;
                }
                if (std::ranges::find(out, child) == out.end()) {
                    out.push_back(child);
                }
            }
        }
        return out;
    }

    namespace {

        std::string SexWord(const RE::TESNPC* a_npc) {
            return !a_npc ? "" : a_npc->GetSex() == RE::SEX::kFemale ? "female" : "male";
        }

        // A person's children by the game's records, and theirs, as deep as
        // the records go. a_seen keeps anyone from being drawn twice, and a
        // record that loops from looping the tree.
        nlohmann::json Descendants(RE::FormID a_base, std::set<RE::FormID>& a_seen, int a_depth) {
            auto       out = nlohmann::json::array();
            const auto it = g_childrenOf.find(a_base);
            if (it == g_childrenOf.end() || a_depth > 12) {
                return out;
            }
            for (const auto child : it->second) {
                auto* npc = RE::TESForm::LookupByID<RE::TESNPC>(child);
                auto  name = NameOf(child);
                if (!npc || name.empty() || !a_seen.insert(child).second) {
                    continue;
                }
                auto* body = npc->GetUniqueActor();
                std::string with;
                if (const auto p = g_parentsOf.find(child); p != g_parentsOf.end()) {
                    for (const auto parent : p->second) {
                        if (parent != a_base) {
                            with = NameOf(parent);
                            break;
                        }
                    }
                }
                out.push_back({ { "formId", body ? body->GetFormID() : 0 },
                                { "name", std::move(name) },
                                { "sex", SexWord(npc) },
                                { "stage", Grown(child) ? 5 : 3 },
                                { "kind", "descendant" },
                                { "inWorld", body != nullptr },
                                { "dead", body && body->IsDead() },
                                { "with", std::move(with) },
                                { "children", Descendants(child, a_seen, a_depth + 1) } });
            }
            return out;
        }

        struct Partner {
            std::uint32_t  formId = 0;
            std::string    name;
            std::string    sex;
            std::string    status;
            float          day = 0.0f;
            bool           dead = false;
            nlohmann::json children = nlohmann::json::array();
            nlohmann::json theirs = nlohmann::json::array();
        };

        int GroupOf(const std::string& a_status) {
            return a_status == "married" || a_status == "separated" || a_status == "engaged" ? 0 :
                   a_status == "divorced" || a_status == "late"                               ? 1 :
                   a_status == "coparent"                                                     ? 2 :
                                                                                                3;
        }
    }

    nlohmann::json Tree() {
        auto*       player = RE::PlayerCharacter::GetSingleton();
        auto*       playerBase = player ? player->GetActorBase() : nullptr;
        const char* you = player ? player->GetName() : nullptr;
        const std::string me = you ? you : "";

        std::vector<Partner>                partners;
        std::map<std::uint32_t, std::size_t> byId;
        std::map<std::string, std::size_t>   byName;   // lowercased, known by name only
        const auto add = [&](Partner a_p) -> std::size_t {
            partners.push_back(std::move(a_p));
            const auto at = partners.size() - 1;
            if (partners[at].formId) {
                byId[partners[at].formId] = at;
            } else if (!partners[at].name.empty()) {
                byName[Lower(partners[at].name)] = at;
            }
            return at;
        };

        // Every spouse, former ones and the late included, from the record.
        using S = Marriage::State;
        for (const auto [state, word] : { std::pair{ S::kMarried, "married" }, std::pair{ S::kSeparated, "separated" },
                                          std::pair{ S::kEngaged, "engaged" }, std::pair{ S::kDivorced, "divorced" },
                                          std::pair{ S::kWidowed, "late" } }) {
            for (const auto id : Marriage::WithState(state)) {
                auto* actor = RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(id));
                auto* base = actor ? actor->GetActorBase() : nullptr;
                const char* name = actor ? actor->GetName() : nullptr;
                if (!base || !name || !*name) {
                    continue;
                }
                const auto record = Marriage::Of(id);
                float      day = record.is_object() ? record.value("weddingDay", 0.0f) : 0.0f;
                if (day <= 0.0f && record.is_object()) {
                    day = record.value("since", 0.0f);
                }
                Partner p;
                p.formId = static_cast<std::uint32_t>(id);
                p.name = name;
                p.sex = SexWord(base);
                p.dead = actor->IsDead();
                p.status = p.dead && (state == S::kMarried || state == S::kSeparated) ? "late" : word;
                p.day = day;
                add(std::move(p));
            }
        }

        // The player's children (Kinship), each under the parent they had
        // them with: a spouse's branch, a co-parent's, or the player's alone.
        std::set<RE::FormID>  seen;       // bases already drawn
        std::set<std::string> kinNames;   // record-only children, lowercased
        if (playerBase) {
            seen.insert(playerBase->GetFormID());
        }
        const auto kids = AllKinshipChildren();
        // Bases first, so a spouse's "theirs" never repeats one of them.
        for (const auto& k : kids) {
            const auto ref = static_cast<RE::FormID>(k.is_object() ? k.value("refId", std::uint64_t{ 0 }) : 0);
            auto*      body = ref ? RE::TESForm::LookupByID<RE::Actor>(ref) : nullptr;
            if (auto* npc = body ? body->GetActorBase() : nullptr) {
                seen.insert(npc->GetFormID());
            } else if (k.is_object()) {
                kinNames.insert(Lower(k.value("name", "")));
            }
        }
        for (const auto& k : kids) {
            if (!k.is_object()) {
                continue;
            }
            const auto motherId = static_cast<std::uint32_t>(k.value("motherId", std::uint64_t{ 0 }));
            const auto fatherId = static_cast<std::uint32_t>(k.value("fatherId", std::uint64_t{ 0 }));
            const auto mother = k.value("mother", std::string{});
            const auto father = k.value("father", std::string{});
            // The other parent: whichever is not the player, by id or by name.
            const bool playerIsMother = motherId == 0x14 || (motherId == 0 && !me.empty() && _stricmp(mother.c_str(), me.c_str()) == 0);
            const auto otherId = playerIsMother ? fatherId : motherId;
            const auto otherName = playerIsMother ? father : mother;
            std::size_t at = 0;
            if (otherId && otherId != 0x14 && byId.contains(otherId)) {
                at = byId[otherId];
            } else if (otherId && otherId != 0x14) {
                auto*       actor = RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(otherId));
                const char* name = actor ? actor->GetName() : nullptr;
                Partner     p;
                p.formId = otherId;
                p.name = name && *name ? name : otherName;
                p.sex = actor ? SexWord(actor->GetActorBase()) : "";
                p.dead = actor && actor->IsDead();
                p.status = "coparent";
                at = add(std::move(p));
            } else if (!otherName.empty() && byName.contains(Lower(otherName))) {
                at = byName[Lower(otherName)];
            } else if (!otherName.empty()) {
                Partner p;
                p.name = otherName;
                p.status = "coparent";
                at = add(std::move(p));
            } else if (byName.contains("")) {
                at = byName[""];
            } else {
                Partner p;
                p.status = "alone";
                at = add(std::move(p));
                byName[""] = at;
            }
            const auto ref = static_cast<RE::FormID>(k.value("refId", std::uint64_t{ 0 }));
            auto*      body = ref ? RE::TESForm::LookupByID<RE::Actor>(ref) : nullptr;
            auto*      npc = body ? body->GetActorBase() : nullptr;
            // IN THE WORLD IS KINSHIP'S WORD (2.6; seen in play, the author,
            // 2026-11-05): Linde and Nina, adopted and at home, were drawn
            // "not yet in the world" because their references did not resolve
            // from where the player stood. A reference in a cell that is not
            // loaded need not be in memory; Kinship recording one is what
            // having a body means, as the card's family list already says.
            // The reference is kept, so the card still opens.
            const bool inWorld = body != nullptr || k.value("inWorld", false);
            if (ref && !body) {
                SKSE::log::info("Family tree: {} has a body by Kinship ({:08X}) that is not loaded here",
                                k.value("name", ""), ref);
            }
            const auto gender = k.value("child", std::string{});
            const auto born = k.value("born", 0.0f);
            auto&      partner = partners[at];
            if (partner.status != "married" && partner.status != "separated" && partner.status != "engaged" &&
                partner.status != "divorced" && partner.status != "late" && born > 0.0f &&
                (partner.day <= 0.0f || born < partner.day)) {
                partner.day = born;
            }
            partner.children.push_back(
                { { "formId", body ? body->GetFormID() : inWorld ? ref : 0 },
                  { "name", k.value("name", "") },
                  { "sex", npc ? SexWord(npc) : gender == "daughter" ? "female" : gender == "son" ? "male" : "" },
                  { "stage", k.value("stage", -1) },
                  { "kind", k.value("adopted", false) ? "adopted" : "born" },
                  { "inWorld", inWorld },
                  { "dead", body && body->IsDead() },
                  { "with", "" },
                  { "children", npc ? Descendants(npc->GetFormID(), seen, 1) : nlohmann::json::array() } });
        }

        // Each partner's children by someone else, as the plugins record them.
        for (auto& p : partners) {
            auto* actor = p.formId ? RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(p.formId)) : nullptr;
            auto* base = actor ? actor->GetActorBase() : nullptr;
            const auto it = base ? g_childrenOf.find(base->GetFormID()) : g_childrenOf.end();
            if (it == g_childrenOf.end()) {
                continue;
            }
            for (const auto child : it->second) {
                auto* npc = RE::TESForm::LookupByID<RE::TESNPC>(child);
                auto  name = NameOf(child);
                if (!npc || name.empty() || kinNames.contains(Lower(name)) || !seen.insert(child).second) {
                    continue;
                }
                auto*       body = npc->GetUniqueActor();
                std::string with;
                if (const auto pa = g_parentsOf.find(child); pa != g_parentsOf.end()) {
                    for (const auto parent : pa->second) {
                        if (parent != base->GetFormID()) {
                            with = NameOf(parent);
                            break;
                        }
                    }
                }
                p.theirs.push_back({ { "formId", body ? body->GetFormID() : 0 },
                                     { "name", std::move(name) },
                                     { "sex", SexWord(npc) },
                                     { "stage", Grown(child) ? 5 : 3 },
                                     { "kind", "theirs" },
                                     { "inWorld", body != nullptr },
                                     { "dead", body && body->IsDead() },
                                     { "with", std::move(with) },
                                     { "children", Descendants(child, seen, 1) } });
            }
        }

        std::stable_sort(partners.begin(), partners.end(), [](const Partner& a, const Partner& b) {
            const auto ga = GroupOf(a.status);
            const auto gb = GroupOf(b.status);
            if (ga != gb) {
                return ga < gb;
            }
            // Unknown days last within a group.
            const auto da = a.day > 0.0f ? a.day : 1e9f;
            const auto db = b.day > 0.0f ? b.day : 1e9f;
            return da < db;
        });
        auto out = nlohmann::json::array();
        std::size_t children = 0;
        for (auto& p : partners) {
            children += p.children.size();
            out.push_back({ { "formId", p.formId },
                            { "name", p.name },
                            { "sex", p.sex },
                            { "status", p.status },
                            { "day", p.day },
                            { "dead", p.dead },
                            { "children", std::move(p.children) },
                            { "theirs", std::move(p.theirs) } });
        }
        SKSE::log::info("Family tree: {} branches, {} of the player's children, {} people in all", out.size(),
                        children, seen.size() - (playerBase ? 1 : 0) + kinNames.size());
        return { { "you", { { "formId", 0x14 }, { "name", me }, { "sex", SexWord(playerBase) } } },
                 { "partners", std::move(out) } };
    }

    std::string SexOf(std::int32_t a_formId) {
        auto* base = BaseOf(a_formId);
        if (!base) {
            return "";
        }
        return base->GetSex() == RE::SEX::kFemale ? "female" : "male";
    }
}
