#include "Notices.h"

#include "PCH.h"

#include <chrono>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>

namespace SNRom::Notices {

    namespace {

        using namespace std::chrono_literals;

        // How often a waiting notice looks again. Long enough to cost nothing,
        // short enough that it appears the moment a fight or a scene ends.
        constexpr auto kInterval = 1s;
        // At most this many wait; past it the oldest go, because a notice
        // nobody saw for that long is no longer news.
        constexpr std::size_t kMaxWaiting = 8;

        struct Notice {
            std::string                           text;
            std::chrono::steady_clock::time_point posted;
            // The first reason it had to wait, for the log: a hold is what a
            // tester checks, and the screen alone cannot show one happened.
            const char* heldFor = nullptr;
        };

        std::mutex              g_lock;
        std::condition_variable g_wake;
        std::deque<Notice>      g_waiting;
        std::atomic_bool        g_checkQueued{ false };

        // The scene frameworks' "in a scene" factions, by plugin-local FormID,
        // so no EditorID lookup is needed: OStim NG adds everyone in a scene
        // to OStimActorCountFaction, and SexLab to SexLabAnimatingFaction.
        // Null when that framework is not installed, and then never checked.
        RE::TESFaction* g_ostim = nullptr;
        RE::TESFaction* g_sexlab = nullptr;

        // Why the player cannot see a notice now, or null when they can.
        const char* WhyNotNow() {
            // Not const: CommonLib declares these two queries non-const.
            auto* ui = RE::UI::GetSingleton();
            if (!ui) {
                return "no interface yet";
            }
            if (ui->GameIsPaused()) {
                return "game paused";
            }
            if (ui->IsMenuOpen(RE::LoadingMenu::MENU_NAME)) {
                return "loading";
            }
            if (ui->IsMenuOpen(RE::DialogueMenu::MENU_NAME)) {
                return "in dialogue";
            }
            const auto* player = RE::PlayerCharacter::GetSingleton();
            if (!player) {
                return "no player yet";
            }
            if (player->IsInCombat()) {
                return "in combat";
            }
            if (g_ostim && player->IsInFaction(g_ostim)) {
                return "in an OStim scene";
            }
            if (g_sexlab && player->IsInFaction(g_sexlab)) {
                return "in a SexLab scene";
            }
            return nullptr;
        }

        // On the main thread: show the oldest waiting notice, if the player
        // can see it. One per look, so several arrive a second apart rather
        // than piled on one another.
        void ShowOne() {
            g_checkQueued = false;
            const char* why = WhyNotNow();
            Notice      notice;
            {
                const std::scoped_lock lock{ g_lock };
                if (g_waiting.empty()) {
                    return;
                }
                if (why) {
                    auto& front = g_waiting.front();
                    if (!front.heldFor) {
                        front.heldFor = why;
                        SKSE::log::info("Tier notice held ({}): {}", why, front.text);
                    }
                    return;
                }
                notice = std::move(g_waiting.front());
                g_waiting.pop_front();
            }
            if (notice.heldFor) {
                const auto waited =
                    std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now() - notice.posted);
                SKSE::log::info("Tier notice shown after {} s, held first for: {}", waited.count(), notice.heldFor);
            } else {
                SKSE::log::info("Tier notice shown: {}", notice.text);
            }
            SKSE::ModCallbackEvent event{ "SNRom_ShowNotice", RE::BSFixedString(notice.text), 0.0f, nullptr };
            if (auto* source = SKSE::GetModCallbackEventSource()) {
                source->SendEvent(&event);
            }
        }

        void Wait() {
            for (;;) {
                try {
                    {
                        std::unique_lock lock{ g_lock };
                        g_wake.wait(lock, [] { return !g_waiting.empty(); });
                    }
                    // One look in the queue at a time: if the main thread has
                    // not run the last one yet, a second would only repeat it.
                    if (!g_checkQueued.exchange(true)) {
                        if (auto* tasks = SKSE::GetTaskInterface()) {
                            tasks->AddTask([] { ShowOne(); });
                        } else {
                            g_checkQueued = false;
                        }
                    }
                } catch (const std::exception& e) {
                    // NOTHING ESCAPES THIS THREAD: an exception here would end
                    // the game.
                    SKSE::log::error("Notices: {}", e.what());
                }
                std::this_thread::sleep_for(kInterval);
            }
        }
    }

    bool PlayerInScene() {
        const auto* player = RE::PlayerCharacter::GetSingleton();
        return player && ((g_ostim && player->IsInFaction(g_ostim)) || (g_sexlab && player->IsInFaction(g_sexlab)));
    }

    void Start() {
        if (auto* data = RE::TESDataHandler::GetSingleton()) {
            g_ostim = data->LookupForm<RE::TESFaction>(0xECA, "OStim.esp");
            g_sexlab = data->LookupForm<RE::TESFaction>(0xE50F, "SexLab.esm");
        }
        SKSE::log::info("Tier notices wait out combat, pauses{}{}", g_ostim ? ", OStim scenes" : "",
                        g_sexlab ? ", SexLab scenes" : "");
        std::thread(Wait).detach();
    }

    void Clear() {
        const std::scoped_lock lock{ g_lock };
        g_waiting.clear();
    }

    void Post(std::string a_text) {
        if (a_text.empty()) {
            return;
        }
        {
            const std::scoped_lock lock{ g_lock };
            g_waiting.push_back(Notice{ std::move(a_text), std::chrono::steady_clock::now() });
            while (g_waiting.size() > kMaxWaiting) {
                g_waiting.pop_front();
            }
        }
        g_wake.notify_one();
    }
}
