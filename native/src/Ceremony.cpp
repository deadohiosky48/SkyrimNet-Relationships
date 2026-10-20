#include "Ceremony.h"

#include "PCH.h"

#include "Marriage.h"

#include <atomic>
#include <cctype>
#include <chrono>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace SNRom::Ceremony {

    namespace {

        using json = nlohmann::json;

        // ------------------------------------------------------------------
        // The script. THE MINIMUM FOR ANY CEREMONY (the author, 2026-10-20);
        // a more elaborate one adds steps to this list.
        // ------------------------------------------------------------------
        enum class Who { kOfficiant, kPlayer, kBetrothed };

        enum class Cue {
            kNone,          // the player's turn: nobody is cued
            kOpening,       // the officiant opens and asks for the player's vows
            kBetrothedVows, // the betrothed says theirs
            kAskPlayer,     // "do you take..."
            kAskBetrothed,
            kBetrothedAnswer,
            kPronounce,
        };

        struct Step {
            Who  speaker;        // whose line ends this step
            Cue  cue;            // what they are cued to say, if not the player
            Who  target;         // whom the cue addresses
            bool judged = false; // the line is an answer: yes, no or unclear
        };

        const std::vector<Step>& Script() {
            static const std::vector<Step> steps{
                { Who::kOfficiant, Cue::kOpening, Who::kPlayer },
                { Who::kPlayer, Cue::kNone, Who::kBetrothed },
                { Who::kBetrothed, Cue::kBetrothedVows, Who::kPlayer },
                { Who::kOfficiant, Cue::kAskPlayer, Who::kPlayer },
                { Who::kPlayer, Cue::kNone, Who::kOfficiant, true },
                { Who::kOfficiant, Cue::kAskBetrothed, Who::kBetrothed },
                { Who::kBetrothed, Cue::kBetrothedAnswer, Who::kOfficiant, true },
                { Who::kOfficiant, Cue::kPronounce, Who::kPlayer },
            };
            return steps;
        }

        // An NPC's step: cued again once after this long without their line,
        // then the wedding is over. A player's step waits longer: they may be
        // thinking, or typing their vows.
        constexpr float kNpcPatience = 40.0f;
        constexpr float kNpcGiveUp = 90.0f;
        constexpr float kPlayerGiveUp = 240.0f;
        // Gone from the room for this long ends it.
        constexpr float kAwayRange = 3000.0f;
        constexpr float kAwaySeconds = 20.0f;
        // An unclear answer is asked again, this many times.
        constexpr int  kRetries = 2;
        constexpr auto kLook = std::chrono::seconds{ 2 };

        // ------------------------------------------------------------------
        // SkyrimNet's C++ API (CppAPI/PublicAPI.h), resolved at kDataLoaded.
        // ------------------------------------------------------------------
        using VersionFn = int (*)();
        using EventCallbackFn = uint64_t (*)(const char*, std::function<void(const char*)>);
        using CustomPromptFn = bool (*)(const char*, const char*, const char*, std::function<void(const char*, int)>);
        using BusyFn = bool (*)(uint32_t, const char*);
        using ClearBusyFn = bool (*)(uint32_t);

        CustomPromptFn g_prompt = nullptr;
        BusyFn         g_busy = nullptr;
        ClearBusyFn    g_clearBusy = nullptr;
        bool           g_hearing = false;

        // ------------------------------------------------------------------
        // The ceremony. Written on the main thread only; read under g_lock by
        // the decorators, which run on SkyrimNet's threads.
        // ------------------------------------------------------------------
        std::mutex       g_lock;
        bool             g_active = false;
        std::size_t      g_step = 0;        // index into Script()
        std::int32_t     g_token = 0;       // this step's, for its cue
        RE::FormID       g_officiant = 0;
        RE::FormID       g_betrothed = 0;
        RE::FormID       g_lastOfficiant = 0;
        std::string      g_variant;
        bool             g_heard = false;   // this step's line arrived
        std::size_t      g_lastLength = 0;  // the last line heard, in characters
        bool             g_judging = false;
        bool             g_cued = false;
        bool             g_recued = false;
        int              g_retries = 0;
        float            g_still = 0.0f;    // seconds at this step, the game running
        float            g_away = 0.0f;
        std::atomic<int> g_generation{ 0 };

        RE::TESFaction* StageFaction() {
            static auto* f = [] {
                auto* data = RE::TESDataHandler::GetSingleton();
                return data ? data->LookupForm<RE::TESFaction>(0xD72, "SNRom_Integration.esl") : nullptr;
            }();
            return f;
        }

        RE::Actor* ActorOf(RE::FormID a_id) {
            return a_id ? RE::TESForm::LookupByID<RE::Actor>(a_id) : nullptr;
        }

        RE::FormID IdOf(Who a_who) {
            return a_who == Who::kOfficiant ? g_officiant
                 : a_who == Who::kBetrothed ? g_betrothed
                                            : 0x14;
        }

        std::string NameOf(RE::FormID a_id) {
            auto*       actor = ActorOf(a_id);
            const char* name = actor ? actor->GetDisplayFullName() : nullptr;
            return name && *name ? name : "someone";
        }

        std::string SpouseWord(RE::FormID a_id) {
            auto* actor = ActorOf(a_id);
            auto* base = actor ? actor->GetActorBase() : nullptr;
            return base && base->GetSex() == RE::SEX::kFemale ? "wife" : "husband";
        }

        // Main thread.
        void SetRanks(std::int32_t a_rank) {
            auto* faction = StageFaction();
            for (const auto id : { g_officiant, g_betrothed }) {
                if (auto* actor = ActorOf(id); faction && actor) {
                    actor->AddToFaction(faction, static_cast<std::int8_t>(a_rank));
                }
            }
        }

        void SetBusy(bool a_on) {
            for (const auto id : { g_officiant, g_betrothed }) {
                if (!id) {
                    continue;
                }
                if (a_on && g_busy) {
                    g_busy(id, "wedding");
                } else if (!a_on && g_clearBusy) {
                    g_clearBusy(id);
                }
            }
        }

        void SendEvent(const char* a_name, const std::string& a_text, float a_number, RE::FormID a_sender) {
            SKSE::GetTaskInterface()->AddTask([name = std::string(a_name), a_text, a_number, a_sender]() {
                SKSE::ModCallbackEvent event{ RE::BSFixedString(name), RE::BSFixedString(a_text), a_number,
                                              ActorOf(a_sender) };
                if (auto* source = SKSE::GetModCallbackEventSource()) {
                    source->SendEvent(&event);
                }
            });
        }

        // The words of a cue, with the names in, in English (the model's
        // prompts are). FACTS, NEVER INSTRUCTIONS: DirectNarration stores its
        // content word for word as an event every NPC reads back for the rest
        // of the save (the lesson of snrom_question_raised.yaml, 2026-08-21),
        // so a cue says what has just happened, true to keep. What the speaker
        // should do now is in their own prompt, by step (0331 for the
        // officiant, 0330 for the betrothed).
        //
        // a_again: the same step's speaker cued once more after silence. That
        // stores nothing (DirectNarration with no content prompts a response
        // without an event), unless it is a question asked again because the
        // answer was unclear, which is itself a thing that happened.
        std::string CueText(Cue a_cue, bool a_again, bool a_unclear = false) {
            const auto off = NameOf(g_officiant);
            const auto you = NameOf(0x14);
            const auto them = NameOf(g_betrothed);
            if (a_again && !a_unclear) {
                return {};
            }
            switch (a_cue) {
            case Cue::kOpening:
                return off + " has begun the wedding of " + you + " and " + them + ".";
            case Cue::kBetrothedVows:
                return you + " has spoken their vows to " + them + ".";
            case Cue::kAskPlayer:
                return a_unclear ? off + " did not hear a clear answer from " + you + "."
                                 : you + " and " + them + " have both spoken their vows.";
            case Cue::kAskBetrothed:
                return a_unclear ? off + " did not hear a clear answer from " + them + "."
                                 : you + " has said yes, and takes " + them + " to be their " + SpouseWord(g_betrothed) +
                                       ".";
            case Cue::kBetrothedAnswer:
                return off + " has asked " + them + " whether they take " + you + " to be their " + SpouseWord(0x14) +
                       ".";
            case Cue::kPronounce:
                return you + " and " + them + " have both said yes.";
            default:
                return {};
            }
        }

        void End(bool a_married, const std::string& a_why);

        // Begins step g_step: its rank, and its cue once the line before has
        // had time to be heard. Main thread.
        void StartStep(bool a_unclear = false) {
            const auto& step = Script()[g_step];
            g_heard = false;
            g_judging = false;
            g_cued = false;
            g_recued = false;
            g_still = 0.0f;
            ++g_token;
            SetRanks(static_cast<std::int32_t>(g_step) + 1);
            SKSE::log::info("Ceremony: step {} of {}", g_step + 1, Script().size());
            if (step.cue == Cue::kNone) {
                return;
            }
            const auto token = g_token;
            const auto text = CueText(step.cue, a_unclear, a_unclear);
            const auto speaker = IdOf(step.speaker);
            SendEvent("SNRom_CeremonyCue", text, static_cast<float>(token), speaker);
        }

        void Next() {
            if (g_step + 1 >= Script().size()) {
                g_lastOfficiant = g_officiant;
                const auto betrothed = g_betrothed;
                End(true, "");
                SendEvent("SNRom_CeremonyMarried", "", 0.0f, betrothed);
                return;
            }
            ++g_step;
            StartStep();
        }

        // An answer, judged. Main thread.
        void Judged(std::int32_t a_token, const std::string& a_verdict) {
            if (!g_active || a_token != g_token) {
                return;
            }
            const auto& step = Script()[g_step];
            SKSE::log::info("Ceremony: {} answered: {}", step.speaker == Who::kPlayer ? "the player" : "the betrothed",
                            a_verdict);
            if (a_verdict == "yes") {
                Next();
            } else if (a_verdict == "no") {
                End(false, step.speaker == Who::kPlayer ? "the player did not say yes" : "they could not say yes");
            } else if (++g_retries <= kRetries) {
                g_step -= 1;   // the question again
                StartStep(true);
            } else {
                End(false, "stalled");
            }
        }

        void Judge(const std::string& a_line) {
            const auto& step = Script()[g_step];
            if (!g_prompt) {
                Judged(g_token, "yes");   // no way to judge: what was said stands
                return;
            }
            g_judging = true;
            const auto who = step.speaker == Who::kPlayer ? NameOf(0x14) : NameOf(g_betrothed);
            const auto other = step.speaker == Who::kPlayer ? NameOf(g_betrothed) : NameOf(0x14);
            const json ctx{ { "ceremony_speaker", who },
                            { "ceremony_question", "Do you take " + other + " to be your " +
                                                       SpouseWord(step.speaker == Who::kPlayer ? g_betrothed : 0x14) +
                                                       "?" },
                            { "ceremony_answer", a_line } };
            const auto token = g_token;
            const bool queued = g_prompt("snrom_ceremony_judge", g_variant.c_str(),
                                         ctx.dump(-1, ' ', false, json::error_handler_t::replace).c_str(),
                                         [token](const char* a_response, int a_success) {
                                             // The first word of the reply: YES, NO or UNCLEAR.
                                             std::string word;
                                             for (const char* c = a_success && a_response ? a_response : ""; *c;
                                                  ++c) {
                                                 if (std::isalpha(static_cast<unsigned char>(*c))) {
                                                     word += static_cast<char>(
                                                         std::tolower(static_cast<unsigned char>(*c)));
                                                 } else if (!word.empty()) {
                                                     break;
                                                 }
                                             }
                                             const std::string verdict = word == "yes" || word == "no" ? word
                                                                                                       : "unclear";
                                             SKSE::GetTaskInterface()->AddTask(
                                                 [token, verdict]() { Judged(token, verdict); });
                                         });
            if (!queued) {
                g_judging = false;
                Judged(token, "unclear");
            }
        }

        // Someone spoke (SkyrimNet's dialogue events). Main thread.
        void Heard(RE::FormID a_speaker, const std::string& a_line) {
            if (!g_active || g_heard || g_judging) {
                return;
            }
            const auto& step = Script()[g_step];
            if (a_speaker != IdOf(step.speaker)) {
                return;
            }
            g_heard = true;
            g_lastLength = a_line.size();
            SKSE::log::info("Ceremony: step {}: heard {}", g_step + 1, NameOf(a_speaker));
            if (step.judged) {
                Judge(a_line);
            } else {
                Next();
            }
        }

        void OnDialogueEvent(const char* a_json) {
            if (!a_json) {
                return;
            }
            const auto event = json::parse(a_json, nullptr, false);
            if (!event.is_object()) {
                return;
            }
            const auto type = event.value("type", std::string{});
            RE::FormID speaker = type == "dialogue" ? event.value("originatingActorFormId", 0u) : 0x14u;
            std::string line;
            if (const auto it = event.find("data"); it != event.end()) {
                const auto data = it->is_string() ? json::parse(it->get<std::string>(), nullptr, false) : *it;
                if (data.is_object()) {
                    line = data.value("dialogue", data.value("text", std::string{}));
                }
            }
            SKSE::GetTaskInterface()->AddTask([speaker, line]() { Heard(speaker, line); });
        }

        bool Here(RE::FormID a_id, RE::PlayerCharacter* a_player) {
            auto* actor = ActorOf(a_id);
            return actor && !actor->IsDead() && actor->Is3DLoaded() &&
                   actor->GetPosition().GetDistance(a_player->GetPosition()) <= kAwayRange;
        }

        // Main thread, every kLook while one is under way.
        void Look() {
            auto* player = RE::PlayerCharacter::GetSingleton();
            auto* ui = RE::UI::GetSingleton();
            if (!g_active || !player || (ui && ui->GameIsPaused())) {
                return;   // a pause is not time passing at the altar
            }
            const float step = static_cast<float>(kLook.count());
            g_away = Here(g_officiant, player) && Here(g_betrothed, player) ? 0.0f : g_away + step;
            if (g_away >= kAwaySeconds) {
                End(false, "left");
                return;
            }
            if (g_judging) {
                return;
            }
            // Patience counts from the cue, for an NPC's step.
            const auto& now = Script()[g_step];
            const bool  npc = now.speaker != Who::kPlayer;
            if (npc && !g_cued) {
                return;
            }
            g_still += step;
            if (npc && g_still >= kNpcGiveUp) {
                End(false, "stalled");
            } else if (npc && g_still >= kNpcPatience && !g_recued) {
                g_recued = true;
                SendEvent("SNRom_CeremonyCue", CueText(now.cue, true), static_cast<float>(g_token), IdOf(now.speaker));
            } else if (!npc && g_still >= kPlayerGiveUp) {
                End(false, "stalled");
            }
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

        void End(bool a_married, const std::string& a_why) {
            if (!g_active) {
                return;
            }
            SetRanks(-1);
            SetBusy(false);
            const auto betrothed = g_betrothed;
            {
                const std::scoped_lock lock{ g_lock };
                g_active = false;
                g_officiant = 0;
                g_betrothed = 0;
                ++g_token;
            }
            ++g_generation;
            SKSE::log::info("Ceremony: over ({})", a_married ? "married" : a_why);
            if (!a_married) {
                SendEvent("SNRom_CeremonyEnded", a_why, 0.0f, betrothed);
            }
        }
    }

    void Register() {
        const auto mod = GetModuleHandleW(L"SkyrimNet.dll");
        const auto version = mod ? reinterpret_cast<VersionFn>(GetProcAddress(mod, "PublicGetVersion")) : nullptr;
        const auto api = version ? version() : 0;
        if (!mod || api < 8) {
            SKSE::log::warn("Ceremony: SkyrimNet API v{} has no dialogue events or custom prompts; weddings need them",
                            api);
            return;
        }
        auto listen = reinterpret_cast<EventCallbackFn>(GetProcAddress(mod, "PublicRegisterEventCallback"));
        g_prompt = reinterpret_cast<CustomPromptFn>(GetProcAddress(mod, "PublicSendCustomPromptToLLM"));
        g_busy = reinterpret_cast<BusyFn>(GetProcAddress(mod, "PublicSetActorBusy"));
        g_clearBusy = reinterpret_cast<ClearBusyFn>(GetProcAddress(mod, "PublicClearActorBusy"));
        if (listen) {
            const auto a = listen("dialogue", OnDialogueEvent);
            const auto b = listen("dialogue_player_text", OnDialogueEvent);
            const auto c = listen("dialogue_player_stt", OnDialogueEvent);
            g_hearing = a && b && c;
        }
        SKSE::log::info("Ceremony: {} SkyrimNet's dialogue; answers {}", g_hearing ? "hearing" : "NOT hearing",
                        g_prompt ? "judged by snrom_ceremony_judge" : "not judged");
    }

    bool Begin(RE::Actor* a_officiant, RE::Actor* a_betrothed, std::string a_variant) {
        if (!a_officiant || !a_betrothed || a_officiant == a_betrothed || g_active || !g_hearing) {
            return false;
        }
        {
            const std::scoped_lock lock{ g_lock };
            g_active = true;
            g_officiant = a_officiant->GetFormID();
            g_betrothed = a_betrothed->GetFormID();
        }
        g_variant = std::move(a_variant);
        g_step = 0;
        g_retries = 0;
        g_away = 0.0f;
        SetBusy(true);
        SKSE::log::info("Ceremony: {:08X} begins marrying the player to {:08X}", g_officiant, g_betrothed);
        Watch(++g_generation);
        StartStep();
        return true;
    }

    std::int32_t Now() {
        const std::scoped_lock lock{ g_lock };
        return g_active ? static_cast<std::int32_t>(g_step) + 1 : 0;
    }

    RE::Actor* Officiant() {
        return g_active ? ActorOf(g_officiant) : nullptr;
    }

    RE::Actor* Betrothed() {
        return g_active ? ActorOf(g_betrothed) : nullptr;
    }

    RE::Actor* LastOfficiant() {
        return ActorOf(g_lastOfficiant);
    }

    RE::Actor* CueTarget(std::int32_t a_token) {
        if (!g_active || a_token != g_token) {
            return nullptr;
        }
        return ActorOf(IdOf(Script()[g_step].target));
    }

    float CueDelay(std::int32_t a_token) {
        // The line before is still being said: about fifteen characters a
        // second, and a breath.
        return a_token == g_token ? 1.0f + static_cast<float>(g_lastLength) / 15.0f : 0.0f;
    }

    bool CueWanted(std::int32_t a_token) {
        return g_active && a_token == g_token && !g_heard && !g_judging;
    }

    void CueSent(std::int32_t a_token) {
        if (g_active && a_token == g_token && !g_cued) {
            g_cued = true;
            g_still = 0.0f;
        }
    }

    void Stop(std::string a_why) {
        End(false, a_why);
    }

    void Reset() {
        // Quietly: the wedding belonged to the timeline being left.
        if (g_active) {
            SetBusy(false);
            {
                const std::scoped_lock lock{ g_lock };
                g_active = false;
                g_officiant = 0;
                g_betrothed = 0;
                ++g_token;
            }
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
        if (!g_active || a_formId == 0) {
            return 0;
        }
        const auto id = static_cast<RE::FormID>(a_formId);
        return id == g_officiant ? 1 : id == g_betrothed ? 2 : 0;
    }
}
