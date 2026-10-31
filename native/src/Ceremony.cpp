#include "Ceremony.h"

#include "PCH.h"

#include "OurPlugin.h"

#include "Marriage.h"
#include "WeddingPlan.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <map>
#include <deque>
#include <cctype>
#include <chrono>
#include <functional>
#include <mutex>
#include <optional>
#include <thread>
#include <unordered_set>
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
            // A planned wedding's (Build B, M4p), by the planner's choice:
            kAddress,       // the officiant addresses everyone gathered
            kReading,       // a reading or a blessing
            kRings,         // the rings exchanged
            kKiss,          // the betrothed kisses the player
        };

        // WHAT AN NPC'S LINE MUST HAVE DONE for its step to count. wpm19
        // took any line from the right speaker: Elisif's "Well spoken, Hroki"
        // passed as "do you take...", and the wedding waited on an answer to a
        // question nobody had asked (2026-10-20). Each is asked of the line by
        // snrom_ceremony_judge; a line that fails is not the step.
        enum class Check { kNone, kAskedForVows, kSpokeVows, kAskedPlayer, kAskedBetrothed, kPronounced, kRings };

        // WHAT A STEP IS, as a number the prompts read (0330, 0331): the
        // faction rank and Now(). 1-8 are the minimum, in order; a planned
        // wedding adds 10-12 where they belong. Kept apart from the step's
        // place in the script, which differs between ceremonies.
        enum Kind : std::int32_t {
            kKindOpening = 1,
            kKindPlayerVows = 2,
            kKindBetrothedVows = 3,
            kKindAskPlayer = 4,
            kKindPlayerAnswer = 5,
            kKindAskBetrothed = 6,
            kKindBetrothedAnswer = 7,
            kKindPronounce = 8,
            kKindAddress = 10,
            kKindReading = 11,
            kKindRings = 12,
            kKindKiss = 13,
        };

        struct Step {
            Who   speaker;              // whose line ends this step
            Cue   cue;                  // what they are cued to say, if not the player
            Who   target;               // whom the cue addresses
            bool  judged = false;       // the line is an answer: yes, no or unclear
            Check check = Check::kNone; // what the line must have done
            std::int32_t kind = 0;      // Kind
        };

        // THIS CEREMONY'S SCRIPT, built at Begin: the minimum, with a planned
        // wedding's parts (WeddingPlan::Part) in their places. The address
        // and the reading come first; the rings after both have said yes,
        // before the pronouncement; the kiss is invited with it (0331).
        std::vector<Step> g_script;

        std::vector<Step> Build(std::uint32_t a_parts) {
            std::vector<Step> steps;
            if (a_parts & WeddingPlan::kAddress) {
                steps.push_back({ Who::kOfficiant, Cue::kAddress, Who::kPlayer, false, Check::kNone, kKindAddress });
            }
            if (a_parts & WeddingPlan::kReading) {
                steps.push_back({ Who::kOfficiant, Cue::kReading, Who::kPlayer, false, Check::kNone, kKindReading });
            }
            steps.insert(steps.end(), {
                { Who::kOfficiant, Cue::kOpening, Who::kPlayer, false, Check::kAskedForVows, kKindOpening },
                { Who::kPlayer, Cue::kNone, Who::kBetrothed, false, Check::kNone, kKindPlayerVows },
                { Who::kBetrothed, Cue::kBetrothedVows, Who::kPlayer, false, Check::kSpokeVows, kKindBetrothedVows },
                { Who::kOfficiant, Cue::kAskPlayer, Who::kPlayer, false, Check::kAskedPlayer, kKindAskPlayer },
                { Who::kPlayer, Cue::kNone, Who::kOfficiant, true, Check::kNone, kKindPlayerAnswer },
                { Who::kOfficiant, Cue::kAskBetrothed, Who::kBetrothed, false, Check::kAskedBetrothed,
                  kKindAskBetrothed },
                { Who::kBetrothed, Cue::kBetrothedAnswer, Who::kOfficiant, true, Check::kNone, kKindBetrothedAnswer },
            });
            if (a_parts & WeddingPlan::kRings) {
                steps.push_back({ Who::kOfficiant, Cue::kRings, Who::kPlayer, false, Check::kRings, kKindRings });
            }
            steps.push_back({ Who::kOfficiant, Cue::kPronounce, Who::kPlayer, false, Check::kPronounced, kKindPronounce });
            // THE KISS (seen in play, wpm72): invited with the pronouncement,
            // it had no time - the wedding was over with the officiant's line,
            // and the betrothed's next prompt no longer knew of it. Now the
            // betrothed's step, after the pronouncement; any line of theirs is
            // it, and the wedding ends married whatever happens in it.
            if (a_parts & WeddingPlan::kKiss) {
                steps.push_back({ Who::kBetrothed, Cue::kKiss, Who::kPlayer, false, Check::kNone, kKindKiss });
            }
            return steps;
        }

        const std::vector<Step>& Script() {
            return g_script;
        }

        bool          g_planned = false;  // a planned wedding, not an elopement
        std::uint32_t g_parts = 0;        // its parts (WeddingPlan::Part)

        // CUED AT ONCE (SkyrimNet beta 28; the author, 2026-10-24, wpm30).
        // Beta 28 makes DirectNarration a directed turn of its own: it takes
        // over a natural reply still waiting for the floor ("intent 67
        // (P1-directed) takes over turn 60 (P4-continuation)", and turn 60
        // ended without a line), passes cooldowns and the speech budget, and
        // waits up to 15 s for the floor. So every NPC step is cued as it
        // begins: never said twice, and never waited for. In wpm29 Elisif's
        // pronouncement waited 33 s for a natural reply that SkyrimNet had
        // dropped 6 s after Aia's "I do". Before beta 28 a cue sent while a
        // natural reply was on its way doubled the line (wpm19); that is what
        // the wait was for, and beta 27 is no longer supported.
        //
        // A cue held longer than the floor allows would be dropped, so one
        // after a long line is sent a little before it ends (CueDelay).
        constexpr float kFloorWait = 15.0f;
        constexpr float kFloorMargin = 5.0f;

        // An NPC's step: cued again once after this long without their line,
        // then the wedding is over. A player's step waits longer: they may be
        // thinking, or typing their vows.
        constexpr float kNpcPatience = 40.0f;
        constexpr float kNpcGiveUp = 90.0f;
        constexpr float kPlayerGiveUp = 240.0f;
        // The kiss: waited for this long, then they are married without it.
        constexpr float kKissWait = 30.0f;
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

        // The officiant's and the betrothed's lines that arrived while this
        // step's line was being judged, in order: looked at once the judging
        // is done.
        struct Line {
            RE::FormID  speaker = 0;
            RE::FormID  target = 0;
            std::string text;
        };
        std::vector<Line> g_ahead;
        // THOSE LINES, CARRIED INTO THE NEXT STEPS (seen in play, wpm65 and
        // wpm70). The judging said yes, so the steps they belong to are now:
        // each heard, in order, before anyone is cued. Danica asked "do you
        // take Haruk?" a quarter of a second before the player's yes was
        // judged (wpm65); Olfina said "I do" to the player's own "I do",
        // before Danica asked her (wpm70). Each line was dropped, Danica was
        // cued to ask what had been answered, pronounced them married instead,
        // and the wedding went round until it stalled.
        std::deque<Line> g_carry;
        // PRONOUNCED ALREADY (seen in play, wpm70): the officiant pronounced
        // them married at the rings, and never mentioned rings again. Once
        // both have said yes, a pronouncement is remembered, and the rings and
        // the pronouncement are not waited for. Before the betrothed's yes it
        // counts for nothing (wpm75, Heard).
        bool g_pronounced = false;
        // Betrothed married by a ceremony since the last load (Begin).
        std::unordered_set<RE::FormID> g_justWed;
        // A carried line is being heard: it is its own step's line or none,
        // and never skips a step (the author, 2026-10-31: "It's a wedding
        // ceremony. It needs to follow a precise script."). Said before the
        // step began, it cannot mean the step before it happened: Olfina's
        // "I do" to the player's "I do" is not Danica's question asked.
        bool g_replaying = false;
        std::size_t      g_lastLength = 0;  // the last line heard, in characters
        std::chrono::steady_clock::time_point g_lastHeardAt{};  // and when
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
                return data ? data->LookupForm<RE::TESFaction>(0xD72, OurPlugin()) : nullptr;
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
                return (g_parts & WeddingPlan::kRings) ? you + " and " + them + " have exchanged rings."
                                                       : you + " and " + them + " have both said yes.";
            // A planned wedding's (M4p). Facts, as every cue is.
            // NOT "everyone has gathered" (seen in play, wpm59): said with no
            // one else there, and a fact everyone reads back.
            case Cue::kAddress:
                return "The hour has come for the wedding of " + you + " and " + them + ".";
            case Cue::kReading:
                return off + " has welcomed everyone to the wedding of " + you + " and " + them + ".";
            case Cue::kRings:
                return you + " and " + them + " have both said yes.";
            case Cue::kKiss:
                return off + " has pronounced " + you + " and " + them + " married, and invites them to kiss.";
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

        // Begins step g_step: its rank; for an NPC's step, its cue at once;
        // for the player's, a word on screen that it is their turn. Main
        // thread.
        void Heard(RE::FormID a_speaker, RE::FormID a_target, const std::string& a_line);

        // The carried lines heard, in order, as this step's. True when the
        // step moved on or is being judged: nothing to cue. A judging keeps
        // the rest of them for after its verdict.
        bool DrainCarry() {
            const auto token = g_token;
            while (!g_carry.empty()) {
                const auto line = std::move(g_carry.front());
                g_carry.pop_front();
                SKSE::log::info("Ceremony: step {}: {} had already spoken", g_step + 1, NameOf(line.speaker));
                g_replaying = true;
                Heard(line.speaker, line.target, line.text);
                g_replaying = false;
                if (!g_active || g_token != token) {
                    return true;   // moved on; the next step heard the rest
                }
                if (g_judging) {
                    g_ahead.insert(g_ahead.begin(), g_carry.begin(), g_carry.end());
                    g_carry.clear();
                    return true;
                }
                if (g_heard) {
                    return true;
                }
            }
            return false;
        }

        void StartStep(bool a_unclear = false) {
            const auto& step = Script()[g_step];
            g_heard = false;
            g_judging = false;
            g_cued = false;
            g_recued = false;
            g_ahead.clear();
            g_unclear = a_unclear;
            g_still = 0.0f;
            ++g_token;
            SetRanks(step.kind);
            SKSE::log::info("Ceremony: step {} of {}", g_step + 1, Script().size());
            if (DrainCarry()) {
                return;
            }
            if (step.cue == Cue::kNone) {
                SendEvent("SNRom_CeremonyYourTurn", step.judged ? "answer" : "vows", 0.0f, g_officiant);
                return;
            }
            CueNow();
        }

        void Next() {
            // Pronounced already: from the betrothed's yes on, nothing is left
            // to wait for - the rings are exchanged when the marriage is
            // recorded (SNRom_CeremonyMarried).
            if (g_pronounced && g_step + 1 < Script().size() &&
                (Script()[g_step + 1].kind == kKindRings || Script()[g_step + 1].kind == kKindPronounce)) {
                SKSE::log::info("Ceremony: {} pronounced them married already; the rest is done", NameOf(g_officiant));
                // To the pronouncement: the kiss, if any, still follows it.
                while (g_step + 1 < Script().size() && Script()[g_step].kind != kKindPronounce) {
                    ++g_step;
                }
            }
            if (g_step + 1 >= Script().size()) {
                g_lastOfficiant = g_officiant;
                const auto betrothed = g_betrothed;
                g_justWed.insert(betrothed);
                const bool planned = g_planned;
                End(true, "");
                SendEvent("SNRom_CeremonyMarried", planned ? "planned" : "", 0.0f, betrothed);
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
                g_carry.insert(g_carry.end(), g_ahead.begin(), g_ahead.end());
                g_ahead.clear();
                Next();
            } else if (a_verdict == "no") {
                End(false, step.speaker == Who::kPlayer ? "the player did not say yes" : "they could not say yes");
            } else if (++g_retries <= kRetries) {
                g_ahead.clear();
                g_step -= 1;   // the question again
                StartStep(true);
            } else {
                End(false, "stalled");
            }
        }

        // A line the step's check found wanting: not the step. Its speaker is
        // cued (once), and the step waits on. Main thread.
        void Checked(std::int32_t a_token, const std::string& a_verdict) {
            if (!g_active || a_token != g_token) {
                return;
            }
            g_judging = false;
            if (a_verdict == "yes") {
                g_carry.insert(g_carry.end(), g_ahead.begin(), g_ahead.end());
                g_ahead.clear();
                Next();
                return;
            }
            SKSE::log::info("Ceremony: step {}: that line was not the step ({})", g_step + 1, a_verdict);
            g_heard = false;
            // Others spoke while it was judged: the step may have happened
            // after all (Heard, catching up).
            g_carry.insert(g_carry.end(), g_ahead.begin(), g_ahead.end());
            g_ahead.clear();
            if (DrainCarry()) {
                return;
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
            case Check::kRings:
                return Has(line, { "ring" });
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
            case Check::kRings:
                return "Did " + off + " invite " + you + " and " + them + " to exchange rings?";
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
            // Pronounced, once BOTH have said yes: remembered (Next). Not
            // before (seen in play, wpm74): Danica pronounced them married in
            // reply to the player's "I do", before Olfina was asked, and the
            // rings and the real pronouncement were skipped for it. Said too
            // soon, it is nothing: the betrothed is still asked, and the rest
            // follows in order.
            const bool pastTheirYes = std::ranges::any_of(
                Script().begin(), Script().begin() + static_cast<std::ptrdiff_t>(g_step),
                [](const Step& a_s) { return a_s.kind == kKindBetrothedAnswer; });
            if (a_speaker == g_officiant && !g_pronounced && WordsDo(Check::kPronounced, a_line)) {
                if (pastTheirYes) {
                    g_pronounced = true;
                    SKSE::log::info("Ceremony: step {}: {} pronounced them married", g_step + 1, NameOf(a_speaker));
                } else {
                    // TEST LOG (wpm75)
                    SKSE::log::info("Ceremony: step {}: {} pronounced them married too soon; not counted",
                                    g_step + 1, NameOf(a_speaker));
                }
            }
            if (g_judging) {
                if (a_speaker == g_officiant || a_speaker == g_betrothed) {
                    g_ahead.push_back(Line{ a_speaker, a_target, a_line });
                }
                return;
            }
            if (g_heard) {
                return;
            }
            // The pronouncement at the rings, or at its own step: done.
            if (g_pronounced && a_speaker == g_officiant && (step.kind == kKindRings || step.kind == kKindPronounce)) {
                g_heard = true;
                Next();
                return;
            }
            // CATCHING UP. The next step's speaker speaking means an NPC's step
            // before it happened, recognised or not: Hroki saying "I do" means
            // she was asked. So that step is taken as done, and the line is
            // heard as the next step's. Never a player's step: those need the
            // player.
            // Never into the kiss: the betrothed speaking before the
            // pronouncement has not been pronounced married.
            if (nextSpeaker && step.check != Check::kNone && !g_replaying &&
                Script()[g_step + 1].kind != kKindKiss) {
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
            g_lastHeardAt = std::chrono::steady_clock::now();
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

        // WHAT WAS SAID LATELY, by anyone, for Said(): the last kRecentLines
        // lines of the last kRecentFor, lowercased. Any thread, under
        // g_recentLock.
        constexpr std::size_t kRecentLines = 40;
        constexpr auto        kRecentFor = std::chrono::minutes(10);
        struct Spoken {
            std::chrono::steady_clock::time_point at;
            std::string                           line;
        };
        std::mutex         g_recentLock;
        std::deque<Spoken> g_recent;

        std::string Lowered(std::string a_text) {
            std::ranges::transform(a_text, a_text.begin(),
                                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
            return a_text;
        }

        // The words of a line: letters and apostrophes, lowercased.
        std::vector<std::string> WordsOf(const std::string& a_line) {
            std::vector<std::string> out;
            std::string              word;
            for (const char c : a_line) {
                if (std::isalpha(static_cast<unsigned char>(c)) || c == '\'' || (c & 0x80)) {
                    word += c;
                } else if (!word.empty()) {
                    out.push_back(word);
                    word.clear();
                }
            }
            if (!word.empty()) {
                out.push_back(word);
            }
            return out;
        }

        std::size_t Edits(const std::string& a_a, const std::string& a_b) {
            std::vector<std::size_t> row(a_b.size() + 1);
            for (std::size_t j = 0; j <= a_b.size(); ++j) {
                row[j] = j;
            }
            for (std::size_t i = 1; i <= a_a.size(); ++i) {
                auto diagonal = row[0];
                row[0] = i;
                for (std::size_t j = 1; j <= a_b.size(); ++j) {
                    const auto above = row[j];
                    row[j] = (std::min)({ row[j] + 1, row[j - 1] + 1, diagonal + (a_a[i - 1] == a_b[j - 1] ? 0 : 1) });
                    diagonal = above;
                }
            }
            return row[a_b.size()];
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
            if (!line.empty()) {
                const std::scoped_lock lock{ g_recentLock };
                g_recent.push_back({ std::chrono::steady_clock::now(), Lowered(line) });
                while (g_recent.size() > kRecentLines) {
                    g_recent.pop_front();
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
            const bool kissing = Script()[g_step].kind == kKindKiss;
            if (g_away >= kAwaySeconds) {
                if (kissing) {
                    Next();   // pronounced married: walking off is not a no
                } else {
                    End(false, "left");
                }
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
            if (kissing && g_still >= kKissWait) {
                SKSE::log::info("Ceremony: step {}: no kiss heard; they are married all the same", g_step + 1);
                Next();
            } else if (npc && g_still >= kNpcGiveUp) {
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
            g_ahead.clear();
            g_carry.clear();
            g_pronounced = false;
            SKSE::log::info("Ceremony: over ({})", a_married ? "married" : a_why);
            if (!a_married) {
                // A planned day that stalled or met a no waits for the
                // officiant to begin it again (WeddingPlan::StoppedShort);
                // one someone walked out of comes back at the hour.
                if (g_planned && a_why != "left") {
                    WeddingPlan::StoppedShort(static_cast<std::int32_t>(betrothed));
                }
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

    bool Begin(RE::Actor* a_officiant, RE::Actor* a_betrothed, std::string a_variant, std::uint32_t a_parts,
               bool a_planned) {
        if (!a_officiant || !a_betrothed || a_officiant == a_betrothed || g_active || !g_hearing) {
            return false;
        }
        // ONLY THE ENGAGED ARE MARRIED (seen in play, wpm68): the day's watch
        // asked for the wedding to begin in the second between the vows and
        // the marriage being recorded, and the couple, married, were married
        // again; that one stalled, and everyone was told they were not
        // married after all.
        if (!Marriage::Engaged(static_cast<std::int32_t>(a_betrothed->GetFormID()))) {
            SKSE::log::info("Ceremony: {} is not engaged to the player; no wedding begins",
                            a_betrothed->GetDisplayFullName());
            return false;
        }
        // MARRIED JUST NOW (seen in play again, wpm72): Papyrus records the
        // marriage when it gets to it, and that took 19 s; the day's watch
        // began the wedding again 0.25 s after it ended. A couple married in
        // this session is never married again before the record says so.
        if (g_justWed.contains(a_betrothed->GetFormID())) {
            SKSE::log::info("Ceremony: {} was married to the player just now; no wedding begins",
                            a_betrothed->GetDisplayFullName());
            return false;
        }
        g_script = Build(a_planned ? a_parts : 0);
        g_planned = a_planned;
        g_parts = a_planned ? a_parts : 0;
        {
            const std::scoped_lock lock{ g_lock };
            g_active = true;
            g_officiant = a_officiant->GetFormID();
            g_betrothed = a_betrothed->GetFormID();
        }
        g_variant = std::move(a_variant);
        g_step = 0;
        g_retries = 0;
        g_ahead.clear();
        g_carry.clear();
        g_pronounced = false;
        g_away = 0.0f;
        SetBusy(true);
        SKSE::log::info("Ceremony: {:08X} begins marrying the player to {:08X}", g_officiant, g_betrothed);
        Watch(++g_generation);
        StartStep();
        return true;
    }

    std::int32_t Now() {
        const std::scoped_lock lock{ g_lock };
        return g_active && g_step < g_script.size() ? g_script[g_step].kind : 0;
    }

    bool Planned() {
        const std::scoped_lock lock{ g_lock };
        return g_active && g_planned;
    }

    std::uint32_t Parts() {
        const std::scoped_lock lock{ g_lock };
        return g_active ? g_parts : 0;
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
        // Counted from when the line was HEARD, not from the cue: wpm21 waited
        // the line's whole length again after the natural-reply wait.
        if (a_token != g_token) {
            return 0.0f;
        }
        // Only what the directed turn's floor wait cannot cover: a line still
        // playing more than kFloorWait - kFloorMargin seconds from now.
        const float length = 1.0f + static_cast<float>(g_lastLength) / 15.0f;
        const float since = std::chrono::duration<float>(std::chrono::steady_clock::now() - g_lastHeardAt).count();
        return std::max(0.0f, length - since - (kFloorWait - kFloorMargin));
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
        // Pronounced married already: nothing left to stop.
        if (g_active && g_step < Script().size() && Script()[g_step].kind == kKindKiss) {
            Next();
            return;
        }
        End(false, a_why);
    }

    void Reset() {
        g_justWed.clear();
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

    bool Said(const std::string& a_name) {
        if (!g_hearing) {
            return true;
        }
        // The name a person is called by: past a title ("Jarl Elisif the
        // Fair" is Elisif), its first word.
        static constexpr std::array<const char*, 8> kTitles{ "jarl", "thane", "lady", "lord", "sir", "steward",
                                                             "housecarl", "the" };
        std::string called;
        for (const auto& word : WordsOf(Lowered(a_name))) {
            if (std::ranges::find_if(kTitles, [&](const char* t) { return word == t; }) == kTitles.end()) {
                called = word;
                break;
            }
        }
        if (called.empty()) {
            return true;
        }
        // Within a letter or two, for a name typed or heard amiss ("Eordlund").
        const std::size_t slack = called.size() >= 6 ? 2 : called.size() >= 4 ? 1 : 0;
        const auto        since = std::chrono::steady_clock::now() - kRecentFor;
        const std::scoped_lock lock{ g_recentLock };
        for (const auto& spoken : g_recent) {
            if (spoken.at < since) {
                continue;
            }
            for (const auto& word : WordsOf(spoken.line)) {
                if (word == called || (slack && Edits(word, called) <= slack)) {
                    return true;
                }
            }
        }
        return false;
    }
}
