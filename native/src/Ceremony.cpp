#include "Ceremony.h"

#include "PCH.h"

#include "Marriage.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <functional>
#include <mutex>
#include <optional>
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

        // WHAT AN NPC'S LINE MUST HAVE DONE for its step to count. wpm19
        // took any line from the right speaker: Elisif's "Well spoken, Hroki"
        // passed as "do you take...", and the wedding waited on an answer to a
        // question nobody had asked (2026-10-20). Each is asked of the line by
        // snrom_ceremony_judge; a line that fails is not the step.
        enum class Check { kNone, kAskedForVows, kSpokeVows, kAskedPlayer, kAskedBetrothed, kPronounced };

        struct Step {
            Who   speaker;              // whose line ends this step
            Cue   cue;                  // what they are cued to say, if not the player
            Who   target;               // whom the cue addresses
            bool  judged = false;       // the line is an answer: yes, no or unclear
            Check check = Check::kNone; // what the line must have done
        };

        const std::vector<Step>& Script() {
            static const std::vector<Step> steps{
                { Who::kOfficiant, Cue::kOpening, Who::kPlayer, false, Check::kAskedForVows },
                { Who::kPlayer, Cue::kNone, Who::kBetrothed },
                { Who::kBetrothed, Cue::kBetrothedVows, Who::kPlayer, false, Check::kSpokeVows },
                { Who::kOfficiant, Cue::kAskPlayer, Who::kPlayer, false, Check::kAskedPlayer },
                { Who::kPlayer, Cue::kNone, Who::kOfficiant, true },
                { Who::kOfficiant, Cue::kAskBetrothed, Who::kBetrothed, false, Check::kAskedBetrothed },
                { Who::kBetrothed, Cue::kBetrothedAnswer, Who::kOfficiant, true },
                { Who::kOfficiant, Cue::kPronounce, Who::kPlayer, false, Check::kPronounced },
            };
            return steps;
        }

        // A NATURAL REPLY FIRST. SkyrimNet answers a line on its own, from
        // the one it was said to; a cue sent as well made them say it twice
        // (every doubled question and "I do" in wpm19). So an NPC's step whose
        // speaker was just ADDRESSED waits for them as long as SkyrimNet waits
        // for a reply: its dialogue model's timeout, which the player sets
        // (OpenRouter.yaml; read by Papyrus, CeremonySetReplyWait). One reply
        // took 23 s through the router (2026-10-20). A speaker nobody
        // addressed gets a short wait: no reply of theirs is coming.
        constexpr float kUnaddressedWait = 5.0f;
        float           g_replyWait = 33.0f;   // the dialogue timeout, and a breath

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
        bool             g_unclear = false; // this step asks again after an unclear answer
        RE::FormID       g_lastTarget = 0;  // whom the last line heard was said to

        // A line from the NEXT step's speaker that arrived while this step's
        // line was being judged: looked at once the judging is done.
        struct Line {
            RE::FormID  speaker = 0;
            RE::FormID  target = 0;
            std::string text;
        };
        std::optional<Line> g_ahead;
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

        // Cues this step's speaker, once. Main thread.
        void CueNow() {
            const auto& step = Script()[g_step];
            if (!g_active || g_cued || g_judging || step.cue == Cue::kNone) {
                return;
            }
            g_cued = true;
            g_still = 0.0f;
            SKSE::log::info("Ceremony: step {}: cueing {}", g_step + 1, NameOf(IdOf(step.speaker)));
            SendEvent("SNRom_CeremonyCue", CueText(step.cue, g_unclear, g_unclear), static_cast<float>(g_token),
                      IdOf(step.speaker));
        }

        // Begins step g_step: its rank; for an NPC's step, a cue if they have
        // not spoken by themselves within kNaturalWait; for the player's, a
        // word on screen that it is their turn. Main thread.
        void StartStep(bool a_unclear = false) {
            const auto& step = Script()[g_step];
            g_heard = false;
            g_judging = false;
            g_cued = false;
            g_recued = false;
            g_ahead.reset();
            g_unclear = a_unclear;
            g_still = 0.0f;
            ++g_token;
            SetRanks(static_cast<std::int32_t>(g_step) + 1);
            SKSE::log::info("Ceremony: step {} of {}", g_step + 1, Script().size());
            if (step.cue == Cue::kNone) {
                SendEvent("SNRom_CeremonyYourTurn", step.judged ? "answer" : "vows", 0.0f, g_officiant);
                return;
            }
            const auto token = g_token;
            const bool addressed = g_lastTarget != 0 && g_lastTarget == IdOf(step.speaker);
            const auto wait = std::chrono::milliseconds{ static_cast<long long>(
                (addressed ? g_replyWait : kUnaddressedWait) * 1000.0f) };
            SKSE::log::info("Ceremony: step {}: {} was {}addressed; waiting {:.0f} s for them before a cue", g_step + 1,
                            NameOf(IdOf(step.speaker)), addressed ? "" : "not ",
                            addressed ? g_replyWait : kUnaddressedWait);
            std::thread([token, wait]() {
                std::this_thread::sleep_for(wait);
                SKSE::GetTaskInterface()->AddTask([token]() {
                    if (g_active && token == g_token && !g_heard) {
                        CueNow();
                    }
                });
            }).detach();
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

        void Heard(RE::FormID a_speaker, RE::FormID a_target, const std::string& a_line);

        // A line the step's check found wanting: not the step. Its speaker is
        // cued (once), and the step waits on. Main thread.
        void Checked(std::int32_t a_token, const std::string& a_verdict) {
            if (!g_active || a_token != g_token) {
                return;
            }
            g_judging = false;
            if (a_verdict == "yes") {
                Next();
                return;
            }
            SKSE::log::info("Ceremony: step {}: that line was not the step ({})", g_step + 1, a_verdict);
            g_heard = false;
            // The next speaker spoke while it was judged: the step may have
            // happened after all (Heard, catching up).
            if (g_ahead) {
                const auto ahead = *g_ahead;
                g_ahead.reset();
                Heard(ahead.speaker, ahead.target, ahead.text);
                if (g_heard || g_judging) {
                    return;
                }
            }
            CueNow();
        }

        std::string Lower(std::string a_text) {
            for (auto& c : a_text) {
                c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            }
            return a_text;
        }

        // The line names a_id: any word of their name but a title.
        bool Names(const std::string& a_lowerLine, RE::FormID a_id) {
            static const std::vector<std::string> titles{ "jarl", "the", "of", "thane", "lord", "lady", "high",
                                                          "queen", "king", "sir", "fair" };
            std::string word;
            const auto  name = Lower(NameOf(a_id)) + " ";
            for (const char c : name) {
                if (std::isalpha(static_cast<unsigned char>(c))) {
                    word += c;
                    continue;
                }
                if (word.size() >= 3 && std::find(titles.begin(), titles.end(), word) == titles.end() &&
                    a_lowerLine.find(word) != std::string::npos) {
                    return true;
                }
                word.clear();
            }
            return false;
        }

        bool Has(const std::string& a_lowerLine, std::initializer_list<const char*> a_any) {
            for (const auto* w : a_any) {
                if (a_lowerLine.find(w) != std::string::npos) {
                    return true;
                }
            }
            return false;
        }

        // THE WORDS FIRST. The check is asked of the model only when plain
        // words do not settle it, and the model can then only add a yes: in
        // wpm20 it answered NO to "And Hroki, do you take Haruk to be your
        // lawfully wedded husband...?" and the wedding never ended (2026-10-20).
        bool WordsDo(Check a_check, const std::string& a_line) {
            const auto line = Lower(a_line);
            switch (a_check) {
            case Check::kAskedForVows:
                return Has(line, { "vow", "promise", "pledge", "oath" });
            case Check::kSpokeVows:
                return a_line.size() >= 20;   // whatever they say to the player now is their vow
            // "Do you take <the other one>?": the name after "take" says who
            // is being asked, since both questions name both of them.
            case Check::kAskedPlayer:
            case Check::kAskedBetrothed: {
                const auto take = line.find("take");
                const auto other = a_check == Check::kAskedPlayer ? g_betrothed : 0x14;
                return take != std::string::npos && line.find('?') != std::string::npos &&
                       Names(line.substr(take), other);
            }
            case Check::kPronounced:
                return Has(line, { "pronounce", "husband and wife", "wife and husband", "man and wife",
                                   "now married", "are married", "you are wed", "now wed" });
            default:
                return false;
            }
        }

        // What the line must have done, as a question for the judge.
        std::string CheckQuestion(Check a_check) {
            const auto off = NameOf(g_officiant);
            const auto you = NameOf(0x14);
            const auto them = NameOf(g_betrothed);
            switch (a_check) {
            case Check::kAskedForVows:
                return "Did " + off + " ask or invite " + you + " to speak their vows?";
            case Check::kSpokeVows:
                return "Did " + them + " speak their vows, or promises, to " + you + "?";
            case Check::kAskedPlayer:
                return "Did " + off + " ask " + you + " whether they take " + them + " to be their " +
                       SpouseWord(g_betrothed) + "?";
            case Check::kAskedBetrothed:
                return "Did " + off + " ask " + them + " whether they take " + you + " to be their " +
                       SpouseWord(0x14) + "?";
            case Check::kPronounced:
                return "Did " + off + " pronounce or declare " + you + " and " + them + " married?";
            default:
                return {};
            }
        }

        // One question of one line, to snrom_ceremony_judge: an ANSWER ("do
        // you take...": yes, no or unclear) or a CHECK (did the line do its
        // step: yes, or not). a_then hears YES, NO or UNCLEAR as "yes", "no"
        // or "unclear", on the main thread.
        void Ask(bool a_answer, const std::string& a_who, const std::string& a_question, const std::string& a_line,
                 void (*a_then)(std::int32_t, const std::string&)) {
            const auto token = g_token;
            if (!g_prompt) {
                a_then(token, "yes");   // no way to judge: what was said stands
                return;
            }
            g_judging = true;
            const json ctx{ { "ceremony_mode", a_answer ? "answer" : "check" },
                            { "ceremony_speaker", a_who },
                            { "ceremony_question", a_question },
                            { "ceremony_answer", a_line } };
            const bool queued = g_prompt("snrom_ceremony_judge", g_variant.c_str(),
                                         ctx.dump(-1, ' ', false, json::error_handler_t::replace).c_str(),
                                         [token, a_then](const char* a_response, int a_success) {
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
                                                 [token, verdict, a_then]() { a_then(token, verdict); });
                                         });
            if (!queued) {
                g_judging = false;
                a_then(token, "unclear");
            }
        }

        void Judge(const std::string& a_line) {
            const auto& step = Script()[g_step];
            const bool  player = step.speaker == Who::kPlayer;
            const auto  other = player ? NameOf(g_betrothed) : NameOf(0x14);
            Ask(true, player ? NameOf(0x14) : NameOf(g_betrothed),
                "Do you take " + other + " to be your " + SpouseWord(player ? g_betrothed : 0x14) + "?", a_line,
                Judged);
        }

        // Someone spoke (SkyrimNet's dialogue events). Main thread.
        void Heard(RE::FormID a_speaker, RE::FormID a_target, const std::string& a_line) {
            if (!g_active) {
                return;
            }
            const auto& step = Script()[g_step];
            const bool  hasNext = g_step + 1 < Script().size();
            const bool  nextSpeaker = hasNext && a_speaker == IdOf(Script()[g_step + 1].speaker) &&
                                     a_speaker != IdOf(step.speaker);
            if (g_judging) {
                if (nextSpeaker) {
                    g_ahead = Line{ a_speaker, a_target, a_line };
                }
                return;
            }
            if (g_heard) {
                return;
            }
            // CATCHING UP. The next step's speaker speaking means an NPC's step
            // before it happened, recognised or not: Hroki saying "I do" means
            // she was asked. So that step is taken as done, and the line is
            // heard as the next step's. Never a player's step: those need the
            // player.
            if (nextSpeaker && step.check != Check::kNone) {
                SKSE::log::info("Ceremony: step {} taken as done: {} spoke for the next", g_step + 1,
                                NameOf(a_speaker));
                ++g_step;
                StartStep();
                Heard(a_speaker, a_target, a_line);
                return;
            }
            if (a_speaker != IdOf(step.speaker)) {
                return;
            }
            g_heard = true;
            g_lastLength = a_line.size();
            g_lastTarget = a_target;
            SKSE::log::info("Ceremony: step {}: heard {}", g_step + 1, NameOf(a_speaker));
            if (step.judged) {
                Judge(a_line);
            } else if (step.check != Check::kNone && WordsDo(step.check, a_line)) {
                SKSE::log::info("Ceremony: step {}: the words do it", g_step + 1);
                Next();
            } else if (step.check != Check::kNone) {
                Ask(false, NameOf(a_speaker), CheckQuestion(step.check), a_line, Checked);
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
            RE::FormID target = event.value("targetActorFormId", 0u);
            std::string line;
            if (const auto it = event.find("data"); it != event.end()) {
                const auto data = it->is_string() ? json::parse(it->get<std::string>(), nullptr, false) : *it;
                if (data.is_object()) {
                    line = data.value("dialogue", data.value("text", std::string{}));
                }
            }
            SKSE::GetTaskInterface()->AddTask([speaker, target, line]() { Heard(speaker, target, line); });
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
        g_lastTarget = 0;
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

    void SetReplyWait(float a_seconds) {
        // SkyrimNet's own wait for a reply, and three seconds; within reason.
        g_replyWait = std::clamp(a_seconds + 3.0f, 10.0f, 120.0f);
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
