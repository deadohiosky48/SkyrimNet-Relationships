#include "Ceremony.h"

#include "PCH.h"

#include "Marriage.h"

#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

namespace SNRom::Ceremony {

    namespace {

        // A step nobody takes for this long, of time the game runs, ends it:
        // the moment has passed.
        constexpr float kStallSeconds = 300.0f;
        // Gone from the room: either of them this far from the player, or not
        // there at all, for this long.
        constexpr float kAwayRange = 3000.0f;
        constexpr float kAwaySeconds = 20.0f;
        constexpr auto  kLook = std::chrono::seconds{ 2 };

        std::mutex       g_lock;
        Stage            g_stage = Stage::kNone;
        RE::FormID       g_officiant = 0;
        RE::FormID       g_betrothed = 0;
        float            g_still = 0.0f;  // seconds at this step
        float            g_away = 0.0f;   // seconds someone has been gone
        std::atomic<int> g_generation{ 0 };

        RE::TESFaction* StageFaction() {
            static auto* f = [] {
                auto* data = RE::TESDataHandler::GetSingleton();
                return data ? data->LookupForm<RE::TESFaction>(0xD72, "SNRom_Integration.esl") : nullptr;
            }();
            return f;
        }

        // Main thread.
        void SetRank(RE::FormID a_id, std::int32_t a_rank) {
            auto* faction = StageFaction();
            auto* actor = a_id ? RE::TESForm::LookupByID<RE::Actor>(a_id) : nullptr;
            if (faction && actor) {
                actor->AddToFaction(faction, static_cast<std::int8_t>(a_rank));
            }
        }

        void SetRanks(RE::FormID a_officiant, RE::FormID a_betrothed, Stage a_stage) {
            const auto rank = a_stage == Stage::kNone ? -1 : static_cast<std::int32_t>(a_stage);
            SetRank(a_officiant, rank);
            SetRank(a_betrothed, rank);
        }

        void Announce(RE::FormID a_betrothed, const std::string& a_why) {
            SKSE::GetTaskInterface()->AddTask([a_betrothed, a_why]() {
                auto*                  form = a_betrothed ? RE::TESForm::LookupByID(a_betrothed) : nullptr;
                SKSE::ModCallbackEvent event{ "SNRom_CeremonyEnded", RE::BSFixedString(a_why), 0.0f, form };
                if (auto* source = SKSE::GetModCallbackEventSource()) {
                    source->SendEvent(&event);
                }
            });
        }

        bool Here(RE::FormID a_id, RE::PlayerCharacter* a_player) {
            auto* actor = RE::TESForm::LookupByID<RE::Actor>(a_id);
            return actor && !actor->IsDead() && actor->Is3DLoaded() &&
                   actor->GetPosition().GetDistance(a_player->GetPosition()) <= kAwayRange;
        }

        // Main thread, every kLook while one is under way.
        void Look() {
            auto* player = RE::PlayerCharacter::GetSingleton();
            auto* ui = RE::UI::GetSingleton();
            if (!player || (ui && ui->GameIsPaused())) {
                return;   // a pause is not time passing at the altar
            }
            std::string why;
            {
                const std::scoped_lock lock{ g_lock };
                if (g_stage == Stage::kNone) {
                    return;
                }
                const float step = static_cast<float>(kLook.count());
                g_still += step;
                const bool both = Here(g_officiant, player) && Here(g_betrothed, player);
                g_away = both ? 0.0f : g_away + step;
                if (g_away >= kAwaySeconds) {
                    why = "left";
                } else if (g_still >= kStallSeconds) {
                    why = "stalled";
                } else {
                    return;
                }
            }
            End(false, why);
        }

        void Watch(int a_generation) {
            std::thread([a_generation]() {
                while (g_generation.load() == a_generation) {
                    std::this_thread::sleep_for(kLook);
                    if (g_generation.load() != a_generation) {
                        return;
                    }
                    SKSE::GetTaskInterface()->AddTask([]() { Look(); });
                }
            }).detach();
        }
    }

    bool Begin(RE::Actor* a_officiant, RE::Actor* a_betrothed) {
        if (!a_officiant || !a_betrothed || a_officiant == a_betrothed) {
            return false;
        }
        int generation = 0;
        {
            const std::scoped_lock lock{ g_lock };
            if (g_stage != Stage::kNone) {
                return false;
            }
            g_stage = Stage::kAskPlayer;
            g_officiant = a_officiant->GetFormID();
            g_betrothed = a_betrothed->GetFormID();
            g_still = 0.0f;
            g_away = 0.0f;
            generation = ++g_generation;
        }
        SetRanks(a_officiant->GetFormID(), a_betrothed->GetFormID(), Stage::kAskPlayer);
        SKSE::log::info("Ceremony: {:08X} begins marrying the player to {:08X}", a_officiant->GetFormID(),
                        a_betrothed->GetFormID());
        Watch(generation);
        return true;
    }

    Stage Now() {
        const std::scoped_lock lock{ g_lock };
        return g_stage;
    }

    RE::Actor* Officiant() {
        const std::scoped_lock lock{ g_lock };
        return g_stage == Stage::kNone ? nullptr : RE::TESForm::LookupByID<RE::Actor>(g_officiant);
    }

    RE::Actor* Betrothed() {
        const std::scoped_lock lock{ g_lock };
        return g_stage == Stage::kNone ? nullptr : RE::TESForm::LookupByID<RE::Actor>(g_betrothed);
    }

    bool Advance(Stage a_to) {
        RE::FormID officiant = 0;
        RE::FormID betrothed = 0;
        {
            const std::scoped_lock lock{ g_lock };
            if (g_stage == Stage::kNone ||
                static_cast<std::int32_t>(a_to) != static_cast<std::int32_t>(g_stage) + 1) {
                return false;
            }
            g_stage = a_to;
            g_still = 0.0f;
            officiant = g_officiant;
            betrothed = g_betrothed;
        }
        SetRanks(officiant, betrothed, a_to);
        SKSE::log::info("Ceremony: on to step {}", static_cast<std::int32_t>(a_to));
        return true;
    }

    void End(bool a_married, std::string a_why) {
        RE::FormID officiant = 0;
        RE::FormID betrothed = 0;
        {
            const std::scoped_lock lock{ g_lock };
            if (g_stage == Stage::kNone) {
                return;
            }
            officiant = g_officiant;
            betrothed = g_betrothed;
            g_stage = Stage::kNone;
            g_officiant = 0;
            g_betrothed = 0;
            ++g_generation;
        }
        // Ranks are the main thread's; End can come from the watcher's task
        // (already there) or a native (also there), so this runs inline.
        SetRanks(officiant, betrothed, Stage::kNone);
        SKSE::log::info("Ceremony: over ({})", a_married ? "married" : a_why);
        if (!a_married) {
            Announce(betrothed, a_why);
        }
    }

    void Reset() {
        {
            const std::scoped_lock lock{ g_lock };
            g_stage = Stage::kNone;
            g_officiant = 0;
            g_betrothed = 0;
            ++g_generation;
        }
        // A save made mid-ceremony keeps the ranks; clear them from everyone
        // loaded and from everyone engaged.
        SKSE::GetTaskInterface()->AddTask([]() {
            auto* faction = StageFaction();
            if (!faction) {
                return;
            }
            const auto clear = [faction](RE::Actor* a_actor) {
                if (a_actor && a_actor->GetFactionRank(faction, false) > 0) {
                    a_actor->AddToFaction(faction, -1);
                }
            };
            if (auto* lists = RE::ProcessLists::GetSingleton()) {
                for (auto& handle : lists->highActorHandles) {
                    clear(handle.get().get());
                }
            }
            for (const auto id : Marriage::AllEngaged()) {
                clear(RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(id)));
            }
        });
    }

    std::int32_t RoleOf(RE::Actor* a_actor) {
        return a_actor ? RoleOf(static_cast<std::int32_t>(a_actor->GetFormID())) : 0;
    }

    std::int32_t RoleOf(std::int32_t a_formId) {
        const std::scoped_lock lock{ g_lock };
        if (g_stage == Stage::kNone || a_formId == 0) {
            return 0;
        }
        const auto id = static_cast<RE::FormID>(a_formId);
        return id == g_officiant ? 1 : id == g_betrothed ? 2 : 0;
    }
}
