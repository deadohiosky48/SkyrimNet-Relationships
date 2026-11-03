#include "Natives.h"

#include "PCH.h"

#include "OurPlugin.h"

#include "Api.h"
#include "L10n.h"
#include "BioPlan.h"
#include "Dashboard.h"
#include "Ceremony.h"
#include "Decorators.h"
#include "Marriage.h"
#include "History.h"
#include "Hotkey.h"
#include "Notices.h"
#include "Officiant.h"
#include "PlanJudge.h"
#include "WeddingPlan.h"
#include "RingCatalog.h"
#include "Settings.h"
#include "SkyrimNetLink.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <map>
#include <filesystem>
#include <format>
#include <fstream>
#include <mutex>
#include <unordered_set>

namespace SNRom::Natives {

    namespace {

        // src/scripts/SNRom_Native.psc declares these. Papyrus calls them only
        // after SKSE.GetPluginVersion("SkyrimNetRelationships") > 0: an unbound
        // native logs an error and returns 0, which reads exactly like a real
        // "no" (brief 5, Papyrus).
        constexpr auto kScript = "SNRom_Native";

        std::int32_t Version(RE::StaticFunctionTag*) {
            return kVersion;
        }

        // Both are virtual keys; SNRom_Bridge.DashboardModifierVK maps the
        // modifier's option name. Version 1 took the key alone, and a script
        // and DLL that disagree on the arguments cannot call it, so Papyrus
        // checks Version() >= 2 first.
        bool SetDashboardHotkey(RE::StaticFunctionTag*, std::int32_t a_virtualKey, std::int32_t a_modifier) {
            return Hotkey::Bind(a_virtualKey, a_modifier);
        }

        void SetDeveloperView(RE::StaticFunctionTag*, bool a_on) {
            Dashboard::SetDeveloperView(a_on);
        }

        // VERSION 4. The two display selects, by their options' names, which
        // the DLL reads with the same table as its settings watcher. False
        // when either is not an option; that one stays as it was, and the
        // other still applies.
        bool SetDisplaySettings(RE::StaticFunctionTag*, std::string a_scale, std::string a_textSize) {
            const auto scale = Settings::ScaleFromName(a_scale);
            const auto textSize = Settings::TextSizeFromName(a_textSize);
            if (!scale) {
                SKSE::log::warn("dashboardScale '{}' is not one of the options, so the dashboard's scale stays as it is",
                                a_scale);
            }
            if (!textSize) {
                SKSE::log::warn(
                    "dashboardTextSize '{}' is not one of the options, so the dashboard's text size stays as it is",
                    a_textSize);
            }
            Dashboard::SetDisplay(scale, textSize);
            return scale && textSize;
        }

        // ------------------------------------------------------------------
        // VERSION 3: THE READ MODEL (design 7.3, the WP2 transport).
        //
        // ONE CALL PER ACTOR PER PUSH, never one per field: each is a whole
        // positional array, in the order Model.h defines and
        // SNRom_Bridge.DashboardNumbers / DashboardText build. No JSON is built
        // in Papyrus, where string concatenation is slow.
        //
        // REGISTERED CALLABLE FROM TASKLETS (below). They touch nothing of the
        // game's - only the model, under its own lock, and SKSE's task queue -
        // so they may run on the VM thread at once instead of each waiting for
        // the next frame on the main thread. A roster of 120 would otherwise
        // cost 120 frames just in the calls.
        // ------------------------------------------------------------------
        std::int32_t FormIdOf(const RE::Actor* a_actor) {
            return a_actor ? static_cast<std::int32_t>(a_actor->GetFormID()) : 0;
        }

        void PutBondNumbers(RE::StaticFunctionTag*, std::int32_t a_generation, RE::Actor* a_actor,
                            std::vector<std::int32_t> a_numbers) {
            if (const auto formId = FormIdOf(a_actor); formId != 0) {
                Dashboard::PushNumbers(a_generation, formId, a_numbers);
            }
        }

        void PutBondText(RE::StaticFunctionTag*, std::int32_t a_generation, RE::Actor* a_actor,
                         std::vector<std::string> a_text) {
            if (const auto formId = FormIdOf(a_actor); formId != 0) {
                Dashboard::PushText(a_generation, formId, a_text);
            }
        }

        void DropBond(RE::StaticFunctionTag*, RE::Actor* a_actor) {
            if (const auto formId = FormIdOf(a_actor); formId != 0) {
                Dashboard::DropBond(formId);
            }
        }

        void PutPlaythrough(RE::StaticFunctionTag*, std::int32_t a_generation, std::string a_id, std::string a_store,
                            std::int32_t a_decision) {
            Dashboard::PushPlaythrough(a_generation, std::move(a_id), std::move(a_store), a_decision);
        }

        // ONCE PER REFRESH, not per bond: what Papyrus fetched with the batch
        // APIs, for the display copies (Display.h). MARAS's three status lists
        // when TT_MARAS.esp is installed; SeverActions' active roster and its
        // dead tracked followers when SeverActions.esp is; and the kin guard.
        std::unordered_set<std::int32_t> FormIds(const std::vector<RE::Actor*>& a_actors) {
            std::unordered_set<std::int32_t> ids;
            for (const auto* actor : a_actors) {
                if (actor) {
                    ids.insert(static_cast<std::int32_t>(actor->GetFormID()));
                }
            }
            return ids;
        }

        // Form.GetFormID() without the wait for the main thread: the refresh
        // builds each actor's store keys from it (SNRom_Bridge.DashboardText).
        // A form's id does not change while the VM holds a reference to it.
        std::int32_t ActorFormId(RE::StaticFunctionTag*, RE::Actor* a_actor) {
            return FormIdOf(a_actor);
        }

        void PutRefreshFacts(RE::StaticFunctionTag*, std::int32_t a_generation, bool a_kinGuard, bool a_maras,
                             std::vector<RE::Actor*> a_married, std::vector<RE::Actor*> a_engaged,
                             std::vector<RE::Actor*> a_candidates, bool a_sever, std::vector<RE::Actor*> a_severActive,
                             std::vector<RE::Actor*> a_severDead) {
            Display::BatchFacts facts;
            facts.kinGuard = a_kinGuard;
            facts.maras = a_maras;
            facts.married = FormIds(a_married);
            facts.engaged = FormIds(a_engaged);
            facts.candidates = FormIds(a_candidates);
            facts.sever = a_sever;
            facts.severFollowers = FormIds(a_severActive);
            facts.severFollowers.merge(FormIds(a_severDead));
            Dashboard::PushFacts(a_generation, std::move(facts));
        }

        void RefreshDone(RE::StaticFunctionTag*, std::int32_t a_generation, std::int32_t a_count,
                         std::string a_status) {
            Dashboard::RefreshDone(a_generation, a_count, std::move(a_status));
        }

        // VERSION 3: PAGE ACTIONS. SNRom_Bridge.OnDashboardAction gets the op
        // and the actor from the SNRom_DashboardAction event, asks here for the
        // Int arguments (never parsed from a string), does it, pushes the
        // actor's row, and answers.
        std::vector<std::int32_t> ActionArgs(RE::StaticFunctionTag*, std::int32_t a_requestId) {
            return Dashboard::ActionArgs(a_requestId);
        }

        // VERSION 12. The one String an op takes (2.4: SetPlayerHistory).
        std::string ActionText(RE::StaticFunctionTag*, std::int32_t a_requestId) {
            return Dashboard::ActionText(a_requestId);
        }

        // VERSION 15 (2.5, marriage phase 1). The marriage record (Marriage.h).
        std::int32_t MarriageState(RE::StaticFunctionTag*, RE::Actor* a_actor) {
            return a_actor ? static_cast<std::int32_t>(
                                 Marriage::StateOf(static_cast<std::int32_t>(a_actor->GetFormID())))
                           : 0;
        }

        bool SetMarriageState(RE::StaticFunctionTag*, RE::Actor* a_actor, std::int32_t a_state, std::string a_why,
                              bool a_force, RE::Actor* a_officiant, bool a_eloped) {
            if (!a_actor) {
                return false;
            }
            return Marriage::Set(static_cast<std::int32_t>(a_actor->GetFormID()),
                                 static_cast<Marriage::State>(a_state), std::move(a_why), a_force,
                                 a_officiant ? static_cast<std::int32_t>(a_officiant->GetFormID()) : 0, a_eloped);
        }

        std::vector<RE::Actor*> MarriageWithState(RE::StaticFunctionTag*, std::int32_t a_state) {
            std::vector<RE::Actor*> out;
            for (const auto id : Marriage::WithState(static_cast<Marriage::State>(a_state))) {
                if (auto* actor = RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(id))) {
                    out.push_back(actor);
                }
            }
            return out;
        }

        bool MaraException(RE::StaticFunctionTag*) {
            return Marriage::Exception();
        }

        void SetMaraException(RE::StaticFunctionTag*, bool a_granted) {
            Marriage::SetException(a_granted);
        }

        // VERSION 16 (2.5, Build A). Proposals, rings and eloping.
        std::int32_t FormIdOfActor(RE::Actor* a_actor) {
            return a_actor ? static_cast<std::int32_t>(a_actor->GetFormID()) : 0;
        }

        bool CanAcceptProposal(RE::StaticFunctionTag*, RE::Actor* a_actor) {
            return Decorators::CanAcceptProposal(FormIdOfActor(a_actor)) == "true";
        }

        bool CanDeclineProposal(RE::StaticFunctionTag*, RE::Actor* a_actor) {
            return Decorators::CanDeclineProposal(FormIdOfActor(a_actor)) == "true";
        }

        // VERSION 24: a deeper bond lifts a no; and how long ago it was.
        void ClearProposalDeclined(RE::StaticFunctionTag*, RE::Actor* a_actor) {
            if (const auto id = FormIdOfActor(a_actor)) {
                Marriage::ClearDeclined(id);
            }
        }
        float ProposalDaysSinceDeclined(RE::StaticFunctionTag*, RE::Actor* a_actor) {
            const auto id = FormIdOfActor(a_actor);
            return id ? Marriage::DaysSinceDeclined(id) : -1.0f;
        }

        // VERSION 25: the no keeps its tier.
        void NoteProposalDeclinedAt(RE::StaticFunctionTag*, RE::Actor* a_actor, std::int32_t a_tier) {
            if (const auto id = FormIdOfActor(a_actor)) {
                Marriage::NoteDeclined(id, a_tier);
            }
        }

        void NoteProposalDeclined(RE::StaticFunctionTag*, RE::Actor* a_actor) {
            if (const auto id = FormIdOfActor(a_actor)) {
                Marriage::NoteDeclined(id);
            }
        }

        void SetMarriageFacts(RE::StaticFunctionTag*, std::int32_t a_spouses, float a_cooldownDays) {
            Marriage::SetFacts(a_spouses, a_cooldownDays);
        }

        RE::TESForm* MarriageRing(RE::StaticFunctionTag*, RE::Actor* a_actor, bool a_fromPlayer) {
            const auto item = Marriage::Ring(FormIdOfActor(a_actor), a_fromPlayer);
            return item ? RE::TESForm::LookupByID(static_cast<RE::FormID>(item)) : nullptr;
        }

        bool SetMarriageRing(RE::StaticFunctionTag*, RE::Actor* a_actor, bool a_fromPlayer, RE::TESForm* a_item) {
            const auto id = FormIdOfActor(a_actor);
            return id && Marriage::SetRing(id, a_fromPlayer, a_item ? static_cast<std::int32_t>(a_item->GetFormID()) : 0);
        }

        // RINGS. Armour on the ring slot or with ClothingRing, never a quest
        // item; worn ones included, and the caller says so when it asks.
        RE::BGSKeyword* RingKeyword() {
            static auto* keyword = [] {
                auto* data = RE::TESDataHandler::GetSingleton();
                return data ? data->LookupForm<RE::BGSKeyword>(0x0010CD09, "Skyrim.esm") : nullptr;  // ClothingRing
            }();
            return keyword;
        }

        // Every ring a_actor carries and the count of each.
        std::map<RE::FormID, std::int32_t> Rings(RE::Actor* a_actor) {
            std::map<RE::FormID, std::int32_t> out;
            if (!a_actor) {
                return out;
            }
            auto* keyword = RingKeyword();
            for (const auto& [object, entry] : a_actor->GetInventory()) {
                auto* armor = object ? object->As<RE::TESObjectARMO>() : nullptr;
                if (!armor || entry.first <= 0 || (entry.second && entry.second->IsQuestObject())) {
                    continue;
                }
                if (armor->HasPartOf(RE::BGSBipedObjectForm::BipedObjectSlot::kRing) ||
                    (keyword && armor->HasKeyword(keyword))) {
                    out[armor->GetFormID()] = entry.first;
                }
            }
            return out;
        }

        // At most 128, Papyrus's array limit: a player can carry more rings
        // than that, which is why the player chooses in the gift menu
        // (RingGiftFilter) and not from this list.
        std::vector<RE::TESForm*> RingsCarried(RE::StaticFunctionTag*, RE::Actor* a_actor) {
            std::vector<RE::TESForm*> out;
            for (const auto& [id, count] : Rings(a_actor)) {
                if (out.size() >= 128) {
                    break;
                }
                if (auto* form = RE::TESForm::LookupByID(id)) {
                    out.push_back(form);
                }
            }
            return out;
        }

        // THE RING THE PLAYER MEANT, from the words the model passed. Hroki was
        // offered vanilla's Gold Ring for an engagement (2026-10-18): the old
        // match took the first ring whose name held the words, and vanilla's
        // come first.
        //
        // SCORED, NOT FILTERED: requiring every word sent "gold engagement
        // ring with a diamond solitaire" to the gift menu, and the model then
        // took the action again. Each ring scores the words asked for that its
        // name holds; our rings also answer to what they look like ("diamond",
        // "solitaire", "band"). The highest score wins, and our marriage ring
        // wins a tie, since this is an engagement; nothing particular asked
        // for ("a ring", "it") means ours if the player carries it. Among
        // others, fewer words beyond those asked for breaks a tie, and a tie
        // left after that is no answer: the player chooses in the gift menu.
        std::vector<std::string> Words(const char* a_text) {
            static const std::unordered_set<std::string> filler{ "a", "an", "the", "my", "your", "this", "that",
                                                                  "it", "one", "of", "for", "you", "to" };
            std::vector<std::string> out;
            std::string              word;
            for (const char* p = a_text ? a_text : ""; ; ++p) {
                const auto c = static_cast<unsigned char>(*p);
                if (std::isalnum(c) || c == '\'') {
                    word += static_cast<char>(std::tolower(c));
                } else {
                    if (!word.empty() && !filler.contains(word)) {
                        out.push_back(word);
                    }
                    word.clear();
                    if (!c) {
                        break;
                    }
                }
            }
            return out;
        }

        bool IsOurMarriageRing(const RE::TESForm* a_form) {
            return RingCatalog::IsOurs(a_form);   // any of the twelve
        }

        RE::TESForm* RingNamed(RE::StaticFunctionTag*, RE::Actor* a_owner, std::string a_name) {
            static const std::vector<std::string> ourWords{ "engagement", "wedding", "marriage", "diamond", "solitaire",
                                                            "band", "promise" };
            const auto   wanted = Words(a_name.c_str());
            RE::TESForm* best = nullptr;
            int          bestScore = 0;
            std::size_t  bestExtra = SIZE_MAX;
            bool         bestOurs = false;
            bool         tie = false;
            for (const auto& [id, count] : Rings(a_owner)) {
                auto* form = RE::TESForm::LookupByID(id);
                if (!form) {
                    continue;
                }
                auto       have = Words(form->GetName());
                const bool ours = IsOurMarriageRing(form);
                if (ours) {
                    have.insert(have.end(), ourWords.begin(), ourWords.end());
                }
                int score = 0;
                for (const auto& w : wanted) {
                    score += std::find(have.begin(), have.end(), w) != have.end() ? 1 : 0;
                }
                if (wanted.empty() && ours) {
                    return form;   // nothing particular asked for: the ring of ours
                }
                if (score == 0) {
                    continue;
                }
                const auto extra = Words(form->GetName()).size() > static_cast<std::size_t>(score)
                                       ? Words(form->GetName()).size() - score
                                       : 0;
                const bool better = score > bestScore || (score == bestScore && ours && !bestOurs) ||
                                    (score == bestScore && ours == bestOurs && extra < bestExtra);
                const bool same = score == bestScore && ours == bestOurs && extra == bestExtra;
                if (better) {
                    best = form;
                    bestScore = score;
                    bestExtra = extra;
                    bestOurs = ours;
                    tie = false;
                } else if (same) {
                    tie = true;
                }
            }
            return tie && !bestOurs ? nullptr : best;
        }

        // THE GIFT MENU, FILTERED TO RINGS: the player's whole inventory of
        // them, scrolling, however many. Vanilla has no list of the ring
        // keyword alone, so one is made at run time and remade if a load ever
        // drops it.
        RE::BGSListForm* RingGiftFilter(RE::StaticFunctionTag*) {
            static RE::FormID made = 0;
            if (made) {
                if (auto* list = RE::TESForm::LookupByID<RE::BGSListForm>(made)) {
                    return list;
                }
            }
            auto* factory = RE::IFormFactory::GetConcreteFormFactoryByType<RE::BGSListForm>();
            auto* list = factory ? factory->Create() : nullptr;
            auto* keyword = RingKeyword();
            if (!list || !keyword) {
                SKSE::log::error("Rings: could not make the gift menu's ring filter");
                return nullptr;
            }
            list->AddForm(keyword);
            made = list->GetFormID();
            return list;
        }

        // Which ring left a_owner's inventory between a snapshot and now: how
        // the gift menu's choice is read, since the menu moves the item
        // itself. The first whose count fell.
        std::map<RE::FormID, std::int32_t> g_ringSnapshot;

        void SnapshotRings(RE::StaticFunctionTag*, RE::Actor* a_owner) {
            g_ringSnapshot = Rings(a_owner);
        }

        RE::TESForm* RingGivenSince(RE::StaticFunctionTag*, RE::Actor* a_owner) {
            const auto now = Rings(a_owner);
            for (const auto& [id, before] : g_ringSnapshot) {
                const auto it = now.find(id);
                if (it == now.end() || it->second < before) {
                    return RE::TESForm::LookupByID(id);
                }
            }
            return nullptr;
        }

        // SEVERACTIONS' OUTFIT LOCK SETTING, read from its script: the
        // OutfitLockEnabled property of SeverActions_Outfit on its quest
        // SeverActions (0xD62, SeverActions.esp). Every enforcement path there
        // returns early without it. Read here so our scripts never name
        // SeverActions_Outfit, which drags its outfit scripts into our compile.
        // 1 on, 0 off, -1 unread (no SeverActions, or no such property).
        // VERSION 19: the wedding, spoken and directed (Ceremony.h).
        bool CeremonyBegin(RE::StaticFunctionTag*, RE::Actor* a_officiant, RE::Actor* a_betrothed,
                           std::string a_variant) {
            return Ceremony::Begin(a_officiant, a_betrothed, std::move(a_variant));
        }
        std::int32_t CeremonyStage(RE::StaticFunctionTag*) {
            return Ceremony::Now();
        }

        // VERSION 28 (Build B, M4p and M4w): the wedding plan (WeddingPlan.h).
        bool CeremonyBeginPlanned(RE::StaticFunctionTag*, RE::Actor* a_officiant, RE::Actor* a_betrothed,
                                  std::string a_variant, std::int32_t a_parts) {
            const bool begun = Ceremony::Begin(a_officiant, a_betrothed, std::move(a_variant),
                                               static_cast<std::uint32_t>(a_parts), true);
            if (begun) {
                WeddingPlan::BegunAgain(FormIdOfActor(a_betrothed));
            }
            return begun;
        }
        void SetMarasOwns(RE::StaticFunctionTag*, bool a_owns) {
            Marriage::SetMarasOwns(a_owns);
        }
        bool MarasInstalled(RE::StaticFunctionTag*) {
            return Marriage::MarasInstalled();
        }
        // VERSION 37: the planner heard (PlanJudge.h).
        void PlanJudgeStart(RE::StaticFunctionTag*, std::string a_variant) {
            PlanJudge::SetVariant(std::move(a_variant));
        }
        std::string PlanHeardField(RE::StaticFunctionTag*, std::int32_t a_token, std::string a_key) {
            return PlanJudge::Field(a_token, a_key);
        }
        void PlanHeardDone(RE::StaticFunctionTag*, std::int32_t a_token) {
            PlanJudge::Forget(a_token);
        }
        // VERSION 37: the day by hand, from the dashboard: days from today and
        // the hour, each -1 left as it is.
        bool PlanSetDayAt(RE::StaticFunctionTag*, RE::Actor* a_betrothed, std::int32_t a_days, std::int32_t a_hour) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && WeddingPlan::SetDay(id, a_days, a_hour);
        }
        // VERSION 38: a place right where they stand, and the spot a judgment
        // was said at (WeddingPlan::SetPlaceHere, PlanJudge::UseSpotOf).
        std::int32_t PlanPlaceHere(RE::StaticFunctionTag*, RE::Actor* a_betrothed, std::string a_said, bool a_always) {
            const auto id = FormIdOfActor(a_betrothed);
            return id ? WeddingPlan::SetPlaceHere(id, a_said, a_always) : -1;
        }
        bool PlanHeardSpot(RE::StaticFunctionTag*, std::int32_t a_token) {
            return PlanJudge::UseSpotOf(a_token);
        }
        bool CeremonyPlanned(RE::StaticFunctionTag*) {
            return Ceremony::Planned();
        }
        bool IsWeddingPlanner(RE::StaticFunctionTag*, RE::Actor* a_actor) {
            return Officiant::IsPlanner(a_actor);
        }
        RE::Actor* OfficiantNamed(RE::StaticFunctionTag*, std::string a_name) {
            return Officiant::Named(a_name);
        }
        RE::Actor* PersonNamed(RE::StaticFunctionTag*, std::string a_name) {
            return WeddingPlan::PersonNamed(a_name);
        }
        // v30: guests as they are said (WeddingPlan::GuestsNamed).
        std::vector<RE::Actor*> GuestsNamed(RE::StaticFunctionTag*, RE::Actor* a_speaker, std::string a_list) {
            return WeddingPlan::GuestsNamed(a_speaker, a_list);
        }
        // The one engaged to the player named a_name; with no name, or no
        // match, the only one engaged, or the nearest of several loaded.
        RE::Actor* BetrothedNamed(RE::StaticFunctionTag*, std::string a_name) {
            const auto engaged = Marriage::AllEngaged();
            std::vector<RE::Actor*> actors;
            for (const auto id : engaged) {
                if (auto* actor = RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(id));
                    actor && !actor->IsDead()) {
                    actors.push_back(actor);
                }
            }
            if (!a_name.empty()) {
                auto* named = WeddingPlan::PersonNamed(a_name);
                if (named && std::find(actors.begin(), actors.end(), named) != actors.end()) {
                    return named;
                }
            }
            if (actors.size() == 1) {
                return actors.front();
            }
            auto*      player = RE::PlayerCharacter::GetSingleton();
            RE::Actor* nearest = nullptr;
            float      best = 0.0f;
            for (auto* actor : actors) {
                if (!player || !actor->Is3DLoaded()) {
                    continue;
                }
                const float d = actor->GetPosition().GetDistance(player->GetPosition());
                if (!nearest || d < best) {
                    nearest = actor;
                    best = d;
                }
            }
            return nearest;
        }
        bool PlanExists(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            return WeddingPlan::Get(FormIdOfActor(a_betrothed)).has_value();
        }
        bool PlanHire(RE::StaticFunctionTag*, RE::Actor* a_betrothed, RE::Actor* a_planner) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && a_planner && WeddingPlan::Hire(id, a_planner->GetFormID());
        }
        // v29: the day as said, read here (WeddingPlan::SetDayFromWords).
        // Nothing unread becomes today or noon.
        bool PlanSetDay(RE::StaticFunctionTag*, RE::Actor* a_betrothed, std::string a_day, std::string a_timeOfDay) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && WeddingPlan::SetDayFromWords(id, a_day, a_timeOfDay);
        }
        // v31: and what the place is by (a_near), for a place no one can find
        // by its own name.
        bool PlanSetPlace(RE::StaticFunctionTag*, RE::Actor* a_betrothed, std::string a_place, std::string a_near) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && WeddingPlan::SetPlace(id, std::move(a_place), std::move(a_near));
        }
        bool PlanSetFindable(RE::StaticFunctionTag*, RE::Actor* a_betrothed, std::string a_travelTo) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && WeddingPlan::SetFindable(id, std::move(a_travelTo));
        }
        std::string PlanNear(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto plan = WeddingPlan::Get(FormIdOfActor(a_betrothed));
            return plan ? plan->nearTo : "";
        }
        // -1 not yet looked for, 0 not found, 1 found as PlanTravelTo.
        std::int32_t PlanFindable(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto plan = WeddingPlan::Get(FormIdOfActor(a_betrothed));
            return plan ? plan->findable : -1;
        }
        std::string PlanTravelTo(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto plan = WeddingPlan::Get(FormIdOfActor(a_betrothed));
            return plan ? plan->travelTo : "";
        }
        bool BringToWedding(RE::StaticFunctionTag*, RE::Actor* a_who, RE::Actor* a_near) {
            return WeddingPlan::BringBeside(a_who, a_near);
        }
        // v32: where everyone stands (WeddingPlan::SetMark), and whose guests
        // they are.
        bool PlanMark(RE::StaticFunctionTag*, RE::Actor* a_betrothed, std::int32_t a_role) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && WeddingPlan::SetMark(id, a_role);
        }
        bool PlanSettleLayout(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && WeddingPlan::SettleLayout(id);
        }
        std::int32_t PlanMarked(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto id = FormIdOfActor(a_betrothed);
            const auto plan = WeddingPlan::Get(id);
            return plan ? static_cast<std::int32_t>(WeddingPlan::Marked(id) | (plan->anchor ? 32u : 0u)) : 0;
        }
        bool PlanGuestSide(RE::StaticFunctionTag*, RE::Actor* a_betrothed, RE::Actor* a_guest, std::int32_t a_side) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && a_guest && WeddingPlan::SetSide(id, a_guest->GetFormID(), a_side);
        }
        std::int32_t PlanSideOf(RE::StaticFunctionTag*, RE::Actor* a_betrothed, RE::Actor* a_guest) {
            const auto plan = WeddingPlan::Get(FormIdOfActor(a_betrothed));
            if (!plan || !a_guest || !plan->sides.contains(a_guest->GetFormID())) {
                return WeddingPlan::kSideUnknown;
            }
            return plan->sides.at(a_guest->GetFormID());
        }
        std::int32_t PlanSideNamed(RE::StaticFunctionTag*, RE::Actor* a_betrothed, RE::Actor* a_speaker,
                                   std::string a_words) {
            return WeddingPlan::SideNamed(a_betrothed, a_speaker, a_words);
        }
        std::int32_t GuestSideOf(RE::StaticFunctionTag*, RE::Actor* a_betrothed, RE::Actor* a_guest) {
            return WeddingPlan::SideOf(a_betrothed, a_guest);
        }
        bool PlanSetAnchor(RE::StaticFunctionTag*, RE::Actor* a_betrothed, RE::TESObjectREFR* a_found) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && WeddingPlan::SetAnchor(id, a_found);
        }
        void WeddingLetGo(RE::StaticFunctionTag*, RE::Actor* a_who) {
            WeddingPlan::LetGo(a_who);
        }
        // v33: each to their place when it begins, and let go when it ends.
        std::vector<RE::Actor*> WeddingPlaces(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto id = FormIdOfActor(a_betrothed);
            return id ? WeddingPlan::TakePlaces(id) : std::vector<RE::Actor*>{};
        }
        void WeddingPlacesClear(RE::StaticFunctionTag*) {
            WeddingPlan::ClearPlaces();
        }
        // v34: the planned day has begun, so the officiant begins the planned
        // wedding, not one of their own.
        bool PlanToday(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && WeddingPlan::Today(id);
        }
        // v35: married, everyone stays a while.
        std::int32_t WeddingReception(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto id = FormIdOfActor(a_betrothed);
            return id ? WeddingPlan::BeginReception(id) : 0;
        }
        bool PlanSetOfficiant(RE::StaticFunctionTag*, RE::Actor* a_betrothed, RE::Actor* a_officiant) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && a_officiant && WeddingPlan::SetOfficiant(id, a_officiant->GetFormID());
        }
        bool PlanGuest(RE::StaticFunctionTag*, RE::Actor* a_betrothed, RE::Actor* a_guest, bool a_add) {
            const auto id = FormIdOfActor(a_betrothed);
            if (!id || !a_guest) {
                return false;
            }
            return a_add ? WeddingPlan::AddGuest(id, a_guest->GetFormID())
                         : WeddingPlan::RemoveGuest(id, a_guest->GetFormID());
        }
        bool PlanSetParts(RE::StaticFunctionTag*, RE::Actor* a_betrothed, std::int32_t a_parts) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && WeddingPlan::SetParts(id, static_cast<std::uint32_t>(a_parts));
        }
        // v29: the rings per person, each -1 left as it is.
        bool PlanSetRings(RE::StaticFunctionTag*, RE::Actor* a_betrothed, std::int32_t a_yourStyle,
                          std::int32_t a_yourMetal, std::int32_t a_theirStyle, std::int32_t a_theirMetal) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && WeddingPlan::SetRings(id, a_yourStyle, a_yourMetal, a_theirStyle, a_theirMetal);
        }
        bool PlanSettleGuests(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && WeddingPlan::SettleGuests(id);
        }
        bool PlanSetOutfit(RE::StaticFunctionTag*, RE::Actor* a_betrothed, bool a_saved) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && WeddingPlan::SetOutfit(id, a_saved);
        }
        bool PlanPostpone(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto id = FormIdOfActor(a_betrothed);
            return id && WeddingPlan::Postpone(id);
        }
        void PlanClear(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            if (const auto id = FormIdOfActor(a_betrothed)) {
                WeddingPlan::Clear(id);
            }
        }
        std::string PlanOpen(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto plan = WeddingPlan::Get(FormIdOfActor(a_betrothed));
            if (!plan) {
                return "day,place,officiant";
            }
            std::string out;
            for (const auto& item : WeddingPlan::Open(*plan)) {
                out += (out.empty() ? "" : ",") + item;
            }
            return out;
        }
        RE::Actor* PlanPlanner(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto plan = WeddingPlan::Get(FormIdOfActor(a_betrothed));
            return plan && plan->planner ? RE::TESForm::LookupByID<RE::Actor>(plan->planner) : nullptr;
        }
        RE::Actor* PlanOfficiant(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto plan = WeddingPlan::Get(FormIdOfActor(a_betrothed));
            return plan && plan->officiant ? RE::TESForm::LookupByID<RE::Actor>(plan->officiant) : nullptr;
        }
        std::vector<RE::Actor*> PlanGuests(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            std::vector<RE::Actor*> out;
            if (const auto plan = WeddingPlan::Get(FormIdOfActor(a_betrothed))) {
                for (const auto guest : plan->guests) {
                    if (auto* actor = RE::TESForm::LookupByID<RE::Actor>(guest); actor && !actor->IsDead()) {
                        out.push_back(actor);
                    }
                }
            }
            return out;
        }
        std::string PlanPlace(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto plan = WeddingPlan::Get(FormIdOfActor(a_betrothed));
            return plan ? plan->place : "";
        }
        bool PlanOutfit(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto plan = WeddingPlan::Get(FormIdOfActor(a_betrothed));
            return plan && plan->outfit;
        }
        std::int32_t PlanParts(RE::StaticFunctionTag*, RE::Actor* a_betrothed) {
            const auto plan = WeddingPlan::Get(FormIdOfActor(a_betrothed));
            return plan ? static_cast<std::int32_t>(plan->parts) : 0;
        }
        // 0 the betrothed's wedding ring's metal, 1 the player's band's, 2
        // whether that band is wide; -1 when the plan leaves it.
        std::int32_t PlanRing(RE::StaticFunctionTag*, RE::Actor* a_betrothed, std::int32_t a_which) {
            const auto plan = WeddingPlan::Get(FormIdOfActor(a_betrothed));
            if (!plan) {
                return -1;
            }
            // 0 their metal, 1 your metal, 2 your style, 3 their style. A style
            // nobody chose is the usual one for the wearer (v37, 2026-11-03).
            const auto id = FormIdOfActor(a_betrothed);
            return a_which == 0 ? plan->theirMetal : a_which == 1 ? plan->yourMetal :
                   a_which == 2 ? WeddingPlan::RingStyle(id, false) : WeddingPlan::RingStyle(id, true);
        }
        RE::Actor* CeremonyOfficiant(RE::StaticFunctionTag*) {
            return Ceremony::Officiant();
        }
        RE::Actor* CeremonyBetrothed(RE::StaticFunctionTag*) {
            return Ceremony::Betrothed();
        }
        RE::Actor* CeremonyLastOfficiant(RE::StaticFunctionTag*) {
            return Ceremony::LastOfficiant();
        }
        RE::Actor* CeremonyCueTarget(RE::StaticFunctionTag*, std::int32_t a_token) {
            return Ceremony::CueTarget(a_token);
        }
        bool CeremonyCueWanted(RE::StaticFunctionTag*, std::int32_t a_token) {
            return Ceremony::CueWanted(a_token);
        }
        float CeremonyCueDelay(RE::StaticFunctionTag*, std::int32_t a_token) {
            return Ceremony::CueDelay(a_token);
        }
        void CeremonyCueSent(RE::StaticFunctionTag*, std::int32_t a_token) {
            Ceremony::CueSent(a_token);
        }
        // VERSION 27: one change taken out of a bond's history (History.h).
        bool RemoveChange(RE::StaticFunctionTag*, RE::Actor* a_actor, std::int32_t a_index, std::int32_t a_delta,
                          std::int32_t a_total) {
            const auto id = FormIdOfActor(a_actor);
            return id && History::Remove(id, a_index, a_delta, a_total);
        }

        // VERSION 26: CeremonySetReplyWait (20), CeremonySetSpeechBudget (21)
        // and CeremonySetChainDepth (23) are gone. On SkyrimNet beta 28 a cue
        // is sent at once (Ceremony.cpp), so nothing waits on them.

        // VERSION 22: the ring catalogue (RingCatalog.h).
        RE::TESForm* RingWeddingFor(RE::StaticFunctionTag*, RE::TESForm* a_engagement) {
            if (RingCatalog::KindOf(a_engagement) != static_cast<std::int32_t>(RingCatalog::Kind::kEngagement)) {
                return nullptr;
            }
            return RingCatalog::Find(RingCatalog::Kind::kWedding,
                                     static_cast<RingCatalog::Metal>(RingCatalog::MetalOf(a_engagement)));
        }
        // VERSION 28 (Build B): a wedding ring by metal, as a planner chose it.
        RE::TESForm* RingWeddingOfMetal(RE::StaticFunctionTag*, std::int32_t a_metal) {
            if (a_metal < 0 || a_metal > 2) {
                return nullptr;
            }
            return RingCatalog::Find(RingCatalog::Kind::kWedding, static_cast<RingCatalog::Metal>(a_metal));
        }
        RE::TESForm* RingBand(RE::StaticFunctionTag*, std::int32_t a_metal, bool a_wide) {
            const auto metal = a_metal >= 0 && a_metal <= 2 ? static_cast<RingCatalog::Metal>(a_metal)
                                                            : RingCatalog::Metal::kGold;
            return RingCatalog::Find(a_wide ? RingCatalog::Kind::kWideBand : RingCatalog::Kind::kBand, metal);
        }
        std::int32_t RingKindOf(RE::StaticFunctionTag*, RE::TESForm* a_ring) {
            return RingCatalog::KindOf(a_ring);
        }
        std::int32_t RingMetalOf(RE::StaticFunctionTag*, RE::TESForm* a_ring) {
            return RingCatalog::MetalOf(a_ring);
        }
        std::vector<RE::TESForm*> RingAllOurs(RE::StaticFunctionTag*) {
            return RingCatalog::All();
        }

        void CeremonyStop(RE::StaticFunctionTag*, std::string a_why) {
            Ceremony::Stop(std::move(a_why));
        }

        // VERSION 17: a question in our own UI (Dashboard::Ask).
        std::int32_t AskOpen(RE::StaticFunctionTag*, std::string a_title, std::string a_body,
                             std::vector<std::string> a_buttons) {
            return Dashboard::Ask(std::move(a_title), std::move(a_body), std::move(a_buttons));
        }

        std::int32_t AskAnswer(RE::StaticFunctionTag*, std::int32_t a_id) {
            return Dashboard::AskAnswer(a_id);
        }

        // VERSION 28 (Build B, M8c): a question with a default and a timer,
        // floating over the game; looked at without taking; withdrawn.
        std::int32_t AskOpenEx(RE::StaticFunctionTag*, std::string a_title, std::string a_body,
                               std::vector<std::string> a_buttons, std::int32_t a_default, float a_seconds) {
            return Dashboard::Ask(std::move(a_title), std::move(a_body), std::move(a_buttons), a_default, a_seconds);
        }
        std::int32_t AskPeek(RE::StaticFunctionTag*, std::int32_t a_id) {
            return Dashboard::AskPeek(a_id);
        }
        void AskCancel(RE::StaticFunctionTag*, std::int32_t a_id) {
            Dashboard::AskCancel(a_id);
        }

        std::int32_t SeverOutfitLockSetting(RE::StaticFunctionTag*) {
            auto* data = RE::TESDataHandler::GetSingleton();
            auto* quest = data ? data->LookupForm<RE::TESQuest>(0xD62, "SeverActions.esp") : nullptr;
            auto* vm = RE::BSScript::Internal::VirtualMachine::GetSingleton();
            if (!quest || !vm) {
                return -1;
            }
            const auto handle = vm->GetObjectHandlePolicy()->GetHandleForObject(RE::FormType::Quest, quest);
            RE::BSTSmartPointer<RE::BSScript::Object> object;
            if (!vm->FindBoundObject(handle, "SeverActions_Outfit", object) || !object) {
                return -1;
            }
            const auto* property = object->GetProperty("OutfitLockEnabled");
            return property ? (property->GetBool() ? 1 : 0) : -1;
        }

        bool IsOfficiant(RE::StaticFunctionTag*, RE::Actor* a_actor) {
            return Officiant::Is(a_actor);
        }

        bool CanBless(RE::StaticFunctionTag*, RE::Actor* a_actor) {
            return Officiant::CanBless(a_actor);
        }

        std::vector<RE::Actor*> BetrothedNear(RE::StaticFunctionTag*) {
            return Officiant::BetrothedNear(Officiant::kPresentRange);
        }

        // VERSION 14 (2.4). The native get_romance and romance_physical_ok
        // (Decorators.h): whether they are live, the two facts they cannot
        // read from the model, and the developer check against Papyrus.
        bool DecoratorsNative(RE::StaticFunctionTag*) {
            return Decorators::Active();
        }

        void SetDecoratorFacts(RE::StaticFunctionTag*, std::int32_t a_partnerCount, float a_bypassRatio) {
            Decorators::SetFacts(a_partnerCount, a_bypassRatio);
        }

        std::int32_t CheckDecorators(RE::StaticFunctionTag*, RE::Actor* a_actor, std::string a_romance,
                                     std::string a_physical) {
            return a_actor ? Decorators::Check(static_cast<std::int32_t>(a_actor->GetFormID()), a_romance, a_physical)
                           : 0;
        }

        // VERSION 13. How long the player and someone have known each other,
        // from SkyrimNet's database rather than its live feed (SkyrimNetLink.h).
        std::string KnownProof(RE::StaticFunctionTag*, RE::Actor* a_actor) {
            return a_actor ? SkyrimNetLink::KnownProof(a_actor->GetFormID()) : std::string{};
        }

        void ActionDone(RE::StaticFunctionTag*, std::int32_t a_requestId, bool a_ok, std::string a_message) {
            Dashboard::ActionDone(a_requestId, a_ok, std::move(a_message));
        }

        // VERSION 5. One change to a bond's depth, from SNRom_Bridge.ApplyDepth
        // and the import: kept in the co-save, newest first (History.h).
        // Callable from tasklets like the read model's natives: it touches only
        // the history, under its own lock, and reads the calendar.
        void RecordChange(RE::StaticFunctionTag*, RE::Actor* a_actor, std::string a_kind, std::int32_t a_delta,
                          std::int32_t a_total, std::string a_reason) {
            if (const auto formId = FormIdOf(a_actor); formId != 0) {
                History::Record(formId, std::move(a_kind), a_delta, a_total, std::move(a_reason));
            }
        }

        // VERSION 5. A tier change's notice, worded by SNRom_Bridge.AnnounceTier:
        // held until the player is out of combat, out of a scene and not
        // paused, then shown (Notices.h). Callable from tasklets: it only
        // queues.
        void Announce(RE::StaticFunctionTag*, std::string a_text) {
            Notices::Post(std::move(a_text));
        }

        // VERSION 12 (2.4, WP-N). A notice worded when shown, not when posted.
        void AnnounceKey(RE::StaticFunctionTag*, std::string a_key, std::string a_english, std::string a_arg0,
                         std::string a_arg1Key, std::string a_arg1) {
            Notices::PostKeyed(std::move(a_key), std::move(a_english), std::move(a_arg0), std::move(a_arg1Key),
                               std::move(a_arg1));
        }

        // v11 (2.3, WP-L): the player's words in the player's language
        // (L10n.h). a_english is the text when this language has none; {0}
        // and {1} are filled from the two arguments either way.
        std::string Text(RE::StaticFunctionTag*, std::string a_key, std::string a_english, std::string a_arg0,
                         std::string a_arg1) {
            return L10n::Text(a_key, a_english, a_arg0, a_arg1);
        }

        // The display check, one bond at a time (SNRom_Bridge.CheckDashboardDisplay).
        // NOT callable from tasklets: it reads the engine, so it waits for the
        // main thread. That costs a frame per bond, which this tool pays on
        // purpose.
        std::int32_t CheckBond(RE::StaticFunctionTag*, RE::Actor* a_actor, bool a_following, std::int32_t a_commitment,
                               std::int32_t a_applicability) {
            const auto formId = FormIdOf(a_actor);
            return formId ? Dashboard::CheckBond(formId, a_following, a_commitment, a_applicability) : 0;
        }

        // VERSION 7. Appends a_text to a_file in the mod's logs folder, at once
        // and in the order called: snrom.log (SNRom_Bridge.Diag), ledger.jsonl
        // and dispositions.jsonl. MiscUtil.WriteToFile, which this replaces,
        // delivered lines in blocks grouped by call site and minutes late, and
        // twice that cost a wrong diagnosis (design 6.7, WP8). snrom.log lines
        // also get the wall clock, so they line up with SkyrimNet's own logs;
        // the .jsonl files stay one JSON object a line. A bare file name only:
        // nothing outside that folder can be named. Callable from tasklets: it
        // touches no game state.
        bool AppendLog(RE::StaticFunctionTag*, std::string a_file, std::string a_text) {
            if (a_file.empty() || a_file.find_first_of("/\\:") != std::string::npos || a_file.find("..") != std::string::npos) {
                return false;
            }
            static std::mutex lock;
            const std::scoped_lock guard{ lock };
            static const std::filesystem::path folder{ "Data/SKSE/Plugins/SkyrimNet Relationships/logs" };
            std::error_code error;
            std::filesystem::create_directories(folder, error);
            std::ofstream out{ folder / a_file, std::ios::binary | std::ios::app };
            if (!out) {
                return false;
            }
            if (a_file == "snrom.log") {
                const auto now = std::chrono::zoned_time{ std::chrono::current_zone(),
                                                          std::chrono::floor<std::chrono::milliseconds>(
                                                              std::chrono::system_clock::now()) };
                out << std::format("{:%H:%M:%S} ", now);
            }
            out << a_text;
            return static_cast<bool>(out);
        }

        // VERSION 6. Who can observe the player now (SNRom_Bridge.Observers):
        // every enrolled character - in SNRom_Bond - whom the game keeps loaded
        // near the player, alive and within a_range units. The assessors pick
        // from these instead of walking the roster, where every IsFollowing,
        // Is3DLoaded and GetDistance waited for a frame: some hundreds of
        // frames a tick at 122 enrolled, one here. NOT callable from tasklets:
        // it reads the engine.
        // VERSION 8. WP-B: one person's Relationships bio blocks, decided here
        // rather than in Papyrus string handling (BioPlan.h). Pure, so callable
        // from a tasklet.
        std::vector<std::int32_t> BioPlan(RE::StaticFunctionTag*, RE::Actor* a_actor, std::vector<std::string> a_titles,
                                          std::vector<std::int32_t> a_state) {
            return BioPlan::Plan(a_actor, a_titles, a_state);
        }

        // VERSION 9. WP-B2: SkyrimNet's event record prints an actor's UUID as a
        // decimal 64-bit number, while SkyrimNetApi.GetActorByUUID wants it in
        // uppercase hex - given the decimal it logs "stoull argument out of range"
        // and returns None. Papyrus has no 64-bit integers, so the conversion is
        // here. "" for anything that is not a decimal number.
        std::string UuidHex(RE::StaticFunctionTag*, std::string a_decimal) {
            if (a_decimal.empty() || a_decimal.find_first_not_of("0123456789") != std::string::npos) {
                return {};
            }
            try {
                return std::format("{:X}", std::stoull(a_decimal));
            } catch (const std::exception&) {
                return {};
            }
        }

        // VERSION 10. WP-A: Papyrus has published everyone after a load (the
        // read API, Api.h). Only posts a task.
        void ApiLoaded(RE::StaticFunctionTag*, std::int32_t a_count) {
            Api::Loaded(a_count);
        }

        void ApiSelfTest(RE::StaticFunctionTag*) {
            Api::SelfTest();
        }

        std::vector<RE::Actor*> ObserversNear(RE::StaticFunctionTag*, float a_range) {
            std::vector<RE::Actor*> out;
            static RE::TESFaction* bond = nullptr;
            if (!bond) {
                if (auto* data = RE::TESDataHandler::GetSingleton()) {
                    bond = data->LookupForm<RE::TESFaction>(0xD63, OurPlugin());
                }
            }
            auto* player = RE::PlayerCharacter::GetSingleton();
            auto* lists = RE::ProcessLists::GetSingleton();
            if (!bond || !player || !lists) {
                return out;
            }
            const auto  here = player->GetPosition();
            const auto* cell = player->GetParentCell();
            const auto* world = player->GetWorldspace();
            const bool  inside = cell && cell->IsInteriorCell();
            for (auto& handle : lists->highActorHandles) {
                const auto ptr = handle.get();
                auto*      actor = ptr.get();
                if (!actor || actor == player || actor->IsDead() || !actor->Is3DLoaded() ||
                    !actor->IsInFaction(bond)) {
                    continue;
                }
                // Positions compare only within one space: the same interior
                // cell, or the same worldspace outside.
                if (inside ? actor->GetParentCell() != cell : actor->GetWorldspace() != world) {
                    continue;
                }
                if (actor->GetPosition().GetDistance(here) <= a_range) {
                    out.push_back(actor);
                }
            }
            return out;
        }
    }

    void Register(const SKSE::PapyrusInterface* a_papyrus) {
        if (!a_papyrus) {
            return;
        }
        a_papyrus->Register(+[](RE::BSScript::IVirtualMachine* a_vm) {
            a_vm->RegisterFunction("Version", kScript, Version);
            a_vm->RegisterFunction("SetDashboardHotkey", kScript, SetDashboardHotkey);
            a_vm->RegisterFunction("SetDeveloperView", kScript, SetDeveloperView);
            a_vm->RegisterFunction("SetDisplaySettings", kScript, SetDisplaySettings);
            // true: callable from tasklets, see above.
            a_vm->RegisterFunction("PutBondNumbers", kScript, PutBondNumbers, true);
            a_vm->RegisterFunction("PutBondText", kScript, PutBondText, true);
            a_vm->RegisterFunction("DropBond", kScript, DropBond, true);
            a_vm->RegisterFunction("FormIdOf", kScript, ActorFormId, true);
            a_vm->RegisterFunction("PutPlaythrough", kScript, PutPlaythrough, true);
            a_vm->RegisterFunction("PutRefreshFacts", kScript, PutRefreshFacts, true);
            a_vm->RegisterFunction("RefreshDone", kScript, RefreshDone, true);
            a_vm->RegisterFunction("ActionArgs", kScript, ActionArgs, true);
            a_vm->RegisterFunction("ActionText", kScript, ActionText, true);
            a_vm->RegisterFunction("ActionDone", kScript, ActionDone, true);
            a_vm->RegisterFunction("CheckBond", kScript, CheckBond);  // main thread: see above
            a_vm->RegisterFunction("RecordChange", kScript, RecordChange, true);
            a_vm->RegisterFunction("Announce", kScript, Announce, true);
            a_vm->RegisterFunction("AnnounceKey", kScript, AnnounceKey, true);
            a_vm->RegisterFunction("Text", kScript, Text, true);
            a_vm->RegisterFunction("ObserversNear", kScript, ObserversNear);  // main thread: see above
            a_vm->RegisterFunction("AppendLog", kScript, AppendLog, true);
            a_vm->RegisterFunction("BioPlan", kScript, BioPlan, true);
            a_vm->RegisterFunction("UuidHex", kScript, UuidHex, true);
            a_vm->RegisterFunction("ApiLoaded", kScript, ApiLoaded, true);
            a_vm->RegisterFunction("ApiSelfTest", kScript, ApiSelfTest, true);
            a_vm->RegisterFunction("KnownProof", kScript, KnownProof, true);
            a_vm->RegisterFunction("DecoratorsNative", kScript, DecoratorsNative, true);
            a_vm->RegisterFunction("SetDecoratorFacts", kScript, SetDecoratorFacts, true);
            a_vm->RegisterFunction("CheckDecorators", kScript, CheckDecorators);  // main thread: engine facts
            a_vm->RegisterFunction("MarriageState", kScript, MarriageState, true);
            a_vm->RegisterFunction("SetMarriageState", kScript, SetMarriageState, true);
            a_vm->RegisterFunction("MarriageWithState", kScript, MarriageWithState, true);
            a_vm->RegisterFunction("MaraException", kScript, MaraException, true);
            a_vm->RegisterFunction("SetMaraException", kScript, SetMaraException, true);
            a_vm->RegisterFunction("CanAcceptProposal", kScript, CanAcceptProposal, true);
            a_vm->RegisterFunction("CanDeclineProposal", kScript, CanDeclineProposal, true);
            a_vm->RegisterFunction("NoteProposalDeclined", kScript, NoteProposalDeclined, true);
            a_vm->RegisterFunction("ClearProposalDeclined", kScript, ClearProposalDeclined, true);
            a_vm->RegisterFunction("NoteProposalDeclinedAt", kScript, NoteProposalDeclinedAt, true);
            a_vm->RegisterFunction("RemoveChange", kScript, RemoveChange, true);
            a_vm->RegisterFunction("ProposalDaysSinceDeclined", kScript, ProposalDaysSinceDeclined, true);
            a_vm->RegisterFunction("SetMarriageFacts", kScript, SetMarriageFacts, true);
            a_vm->RegisterFunction("MarriageRing", kScript, MarriageRing, true);
            a_vm->RegisterFunction("SetMarriageRing", kScript, SetMarriageRing, true);
            a_vm->RegisterFunction("RingsCarried", kScript, RingsCarried);    // main thread: inventory
            a_vm->RegisterFunction("RingNamed", kScript, RingNamed);          // main thread: inventory
            a_vm->RegisterFunction("RingGiftFilter", kScript, RingGiftFilter);  // main thread: makes a form
            a_vm->RegisterFunction("SnapshotRings", kScript, SnapshotRings);    // main thread: inventory
            a_vm->RegisterFunction("RingGivenSince", kScript, RingGivenSince);  // main thread: inventory
            a_vm->RegisterFunction("IsOfficiant", kScript, IsOfficiant);      // main thread: factions
            a_vm->RegisterFunction("SeverOutfitLockSetting", kScript, SeverOutfitLockSetting, true);
            a_vm->RegisterFunction("CanBless", kScript, CanBless);            // main thread: positions
            a_vm->RegisterFunction("BetrothedNear", kScript, BetrothedNear);  // main thread: positions
            // Main thread, all: the ceremony is the main thread's.
            a_vm->RegisterFunction("CeremonyBegin", kScript, CeremonyBegin);
            a_vm->RegisterFunction("CeremonyStage", kScript, CeremonyStage);
            a_vm->RegisterFunction("CeremonyBeginPlanned", kScript, CeremonyBeginPlanned);
            a_vm->RegisterFunction("CeremonyPlanned", kScript, CeremonyPlanned, true);
            a_vm->RegisterFunction("SetMarasOwns", kScript, SetMarasOwns, true);
            a_vm->RegisterFunction("MarasInstalled", kScript, MarasInstalled, true);
            a_vm->RegisterFunction("PlanJudgeStart", kScript, PlanJudgeStart, true);
            a_vm->RegisterFunction("PlanHeardField", kScript, PlanHeardField, true);
            a_vm->RegisterFunction("PlanHeardDone", kScript, PlanHeardDone, true);
            a_vm->RegisterFunction("PlanSetDayAt", kScript, PlanSetDayAt, true);
            a_vm->RegisterFunction("PlanPlaceHere", kScript, PlanPlaceHere);
            a_vm->RegisterFunction("PlanHeardSpot", kScript, PlanHeardSpot, true);
            a_vm->RegisterFunction("IsWeddingPlanner", kScript, IsWeddingPlanner, true);
            a_vm->RegisterFunction("PersonNamed", kScript, PersonNamed);
            a_vm->RegisterFunction("GuestsNamed", kScript, GuestsNamed);
            a_vm->RegisterFunction("OfficiantNamed", kScript, OfficiantNamed);
            a_vm->RegisterFunction("BetrothedNamed", kScript, BetrothedNamed);
            a_vm->RegisterFunction("PlanExists", kScript, PlanExists, true);
            a_vm->RegisterFunction("PlanHire", kScript, PlanHire, true);
            a_vm->RegisterFunction("PlanSetDay", kScript, PlanSetDay, true);
            a_vm->RegisterFunction("PlanSetPlace", kScript, PlanSetPlace, true);
            a_vm->RegisterFunction("PlanSetOfficiant", kScript, PlanSetOfficiant, true);
            a_vm->RegisterFunction("PlanGuest", kScript, PlanGuest, true);
            a_vm->RegisterFunction("PlanSetParts", kScript, PlanSetParts, true);
            a_vm->RegisterFunction("PlanSetRings", kScript, PlanSetRings, true);
            a_vm->RegisterFunction("PlanSettleGuests", kScript, PlanSettleGuests, true);
            a_vm->RegisterFunction("PlanSetOutfit", kScript, PlanSetOutfit, true);
            a_vm->RegisterFunction("PlanPostpone", kScript, PlanPostpone, true);
            a_vm->RegisterFunction("PlanClear", kScript, PlanClear, true);
            a_vm->RegisterFunction("PlanOpen", kScript, PlanOpen, true);
            a_vm->RegisterFunction("PlanOfficiant", kScript, PlanOfficiant, true);
            a_vm->RegisterFunction("PlanPlanner", kScript, PlanPlanner, true);
            a_vm->RegisterFunction("PlanGuests", kScript, PlanGuests, true);
            a_vm->RegisterFunction("PlanPlace", kScript, PlanPlace, true);
            a_vm->RegisterFunction("PlanSetFindable", kScript, PlanSetFindable, true);
            a_vm->RegisterFunction("PlanNear", kScript, PlanNear, true);
            a_vm->RegisterFunction("PlanFindable", kScript, PlanFindable, true);
            a_vm->RegisterFunction("PlanTravelTo", kScript, PlanTravelTo, true);
            a_vm->RegisterFunction("BringToWedding", kScript, BringToWedding);
            // v32. Main thread: a marker placed, the game's family records,
            // names, a door's other side, a link to a mark.
            a_vm->RegisterFunction("PlanMark", kScript, PlanMark);
            a_vm->RegisterFunction("PlanSettleLayout", kScript, PlanSettleLayout, true);
            a_vm->RegisterFunction("PlanMarked", kScript, PlanMarked, true);
            a_vm->RegisterFunction("PlanGuestSide", kScript, PlanGuestSide, true);
            a_vm->RegisterFunction("PlanSideOf", kScript, PlanSideOf, true);
            a_vm->RegisterFunction("PlanSideNamed", kScript, PlanSideNamed);
            a_vm->RegisterFunction("GuestSideOf", kScript, GuestSideOf);
            a_vm->RegisterFunction("PlanSetAnchor", kScript, PlanSetAnchor);
            a_vm->RegisterFunction("WeddingLetGo", kScript, WeddingLetGo);
            // v33. Main thread: markers placed, links set.
            a_vm->RegisterFunction("WeddingPlaces", kScript, WeddingPlaces);
            a_vm->RegisterFunction("WeddingPlacesClear", kScript, WeddingPlacesClear);
            a_vm->RegisterFunction("PlanToday", kScript, PlanToday, true);
            a_vm->RegisterFunction("WeddingReception", kScript, WeddingReception);
            a_vm->RegisterFunction("PlanOutfit", kScript, PlanOutfit, true);
            a_vm->RegisterFunction("PlanParts", kScript, PlanParts, true);
            a_vm->RegisterFunction("PlanRing", kScript, PlanRing, true);
            a_vm->RegisterFunction("RingWeddingOfMetal", kScript, RingWeddingOfMetal, true);
            a_vm->RegisterFunction("CeremonyOfficiant", kScript, CeremonyOfficiant);
            a_vm->RegisterFunction("CeremonyBetrothed", kScript, CeremonyBetrothed);
            a_vm->RegisterFunction("CeremonyLastOfficiant", kScript, CeremonyLastOfficiant);
            a_vm->RegisterFunction("CeremonyCueTarget", kScript, CeremonyCueTarget);
            a_vm->RegisterFunction("CeremonyCueWanted", kScript, CeremonyCueWanted);
            a_vm->RegisterFunction("CeremonyCueDelay", kScript, CeremonyCueDelay);
            a_vm->RegisterFunction("CeremonyCueSent", kScript, CeremonyCueSent);
            a_vm->RegisterFunction("CeremonyStop", kScript, CeremonyStop);
            a_vm->RegisterFunction("RingWeddingFor", kScript, RingWeddingFor, true);
            a_vm->RegisterFunction("RingBand", kScript, RingBand, true);
            a_vm->RegisterFunction("RingKindOf", kScript, RingKindOf, true);
            a_vm->RegisterFunction("RingMetalOf", kScript, RingMetalOf, true);
            a_vm->RegisterFunction("RingAllOurs", kScript, RingAllOurs, true);
            a_vm->RegisterFunction("AskOpen", kScript, AskOpen, true);
            a_vm->RegisterFunction("AskAnswer", kScript, AskAnswer, true);
            a_vm->RegisterFunction("AskOpenEx", kScript, AskOpenEx, true);
            a_vm->RegisterFunction("AskPeek", kScript, AskPeek, true);
            a_vm->RegisterFunction("AskCancel", kScript, AskCancel, true);
            SKSE::log::info("Registered {} v{}: Version, SetDashboardHotkey, SetDeveloperView, SetDisplaySettings, "
                            "PutBondNumbers, PutBondText, DropBond, FormIdOf, PutPlaythrough, PutRefreshFacts, "
                            "RefreshDone, ActionArgs, ActionDone, CheckBond, RecordChange, Announce, ObserversNear, AppendLog, "
                            "BioPlan, UuidHex, ApiLoaded, ApiSelfTest, Text, ActionText, AnnounceKey, KnownProof, DecoratorsNative, SetDecoratorFacts, CheckDecorators, MarriageState, SetMarriageState, "
                            "MarriageWithState, MaraException, SetMaraException, CanAcceptProposal, CanDeclineProposal, "
                            "NoteProposalDeclined, SetMarriageFacts, MarriageRing, SetMarriageRing, RingsCarried, "
                            "IsOfficiant, CanBless, BetrothedNear, RingNamed, RingGiftFilter, SnapshotRings, "
                            "RingGivenSince, SeverOutfitLockSetting, AskOpen, AskAnswer, CeremonyBegin, CeremonyStage, "
                            "CeremonyOfficiant, CeremonyBetrothed, CeremonyLastOfficiant, CeremonyCueTarget, "
                            "CeremonyCueWanted, CeremonyCueDelay, CeremonyCueSent, CeremonyStop, RingWeddingFor, RingBand, RingKindOf, "
                            "RingMetalOf, RingAllOurs, ClearProposalDeclined, ProposalDaysSinceDeclined, NoteProposalDeclinedAt, RemoveChange, AskOpenEx, AskPeek, AskCancel, CeremonyBeginPlanned, CeremonyPlanned, SetMarasOwns, IsWeddingPlanner, PersonNamed, OfficiantNamed, "
                            "BetrothedNamed, PlanExists, PlanHire, PlanSetDay, PlanSetPlace, PlanSetOfficiant, PlanGuest, "
                            "PlanSetParts, PlanSetRings, PlanSetOutfit, PlanPostpone, PlanClear, PlanOpen, PlanOfficiant, PlanPlanner, "
                            "PlanGuests, PlanPlace, PlanOutfit, PlanParts, PlanRing, RingWeddingOfMetal, "
                            "PlanSetFindable, PlanNear, PlanFindable, PlanTravelTo, BringToWedding, PlanMark, PlanSettleLayout, "
                            "PlanMarked, PlanGuestSide, PlanSideOf, PlanSideNamed, GuestSideOf, PlanSetAnchor, WeddingLetGo, "
                            "WeddingPlaces, WeddingPlacesClear, PlanToday, WeddingReception, MarasInstalled, PlanJudgeStart, PlanHeardField, PlanHeardDone, PlanSetDayAt, PlanPlaceHere, "
                            "PlanHeardSpot",
                            kScript, kVersion);
            return true;
        });
    }
}
