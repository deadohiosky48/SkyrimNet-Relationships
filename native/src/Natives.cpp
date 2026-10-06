#include "Natives.h"

#include "PCH.h"

#include "BioPlan.h"
#include "Dashboard.h"
#include "History.h"
#include "Hotkey.h"
#include "Notices.h"
#include "Settings.h"

#include <chrono>
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

        std::vector<RE::Actor*> ObserversNear(RE::StaticFunctionTag*, float a_range) {
            std::vector<RE::Actor*> out;
            static RE::TESFaction* bond = nullptr;
            if (!bond) {
                if (auto* data = RE::TESDataHandler::GetSingleton()) {
                    bond = data->LookupForm<RE::TESFaction>(0xD63, "SNRom_Integration.esl");
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
            a_vm->RegisterFunction("ActionDone", kScript, ActionDone, true);
            a_vm->RegisterFunction("CheckBond", kScript, CheckBond);  // main thread: see above
            a_vm->RegisterFunction("RecordChange", kScript, RecordChange, true);
            a_vm->RegisterFunction("Announce", kScript, Announce, true);
            a_vm->RegisterFunction("ObserversNear", kScript, ObserversNear);  // main thread: see above
            a_vm->RegisterFunction("AppendLog", kScript, AppendLog, true);
            a_vm->RegisterFunction("BioPlan", kScript, BioPlan, true);
            a_vm->RegisterFunction("UuidHex", kScript, UuidHex, true);
            SKSE::log::info("Registered {} v{}: Version, SetDashboardHotkey, SetDeveloperView, SetDisplaySettings, "
                            "PutBondNumbers, PutBondText, DropBond, FormIdOf, PutPlaythrough, PutRefreshFacts, "
                            "RefreshDone, ActionArgs, ActionDone, CheckBond, RecordChange, Announce, ObserversNear, AppendLog, "
                            "BioPlan, UuidHex",
                            kScript, kVersion);
            return true;
        });
    }
}
