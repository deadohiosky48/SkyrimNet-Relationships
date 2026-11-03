#include "PlanJudge.h"

#include "PCH.h"

#include "Ceremony.h"
#include "WeddingPlan.h"

#include <cctype>
#include <chrono>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <thread>
#include <vector>

namespace SNRom::PlanJudge {

    namespace {

        using json = nlohmann::json;
        using VersionFn = int (*)();
        using CustomPromptFn = bool (*)(const char*, const char*, const char*, std::function<void(const char*, int)>);

        constexpr std::uint32_t kPlayer = 0x14;
        // Judged once the planner has answered and nothing more is said for
        // this long: a reply that settles something is usually the last line
        // of its exchange, and a player who goes on talking moves it later.
        constexpr auto kQuiet = std::chrono::seconds{ 8 };
        // A conversation with the planner ends after this long without a word
        // to or from them; the next one starts afresh.
        constexpr auto kWindow = std::chrono::seconds{ 180 };
        constexpr std::size_t kMaxLines = 16;
        // Lines already judged, kept ahead of the new ones as context: "yes,
        // that" means nothing without the line it answers.
        constexpr std::size_t kEarlier = 4;

        // What a judgment may say, as its lines name it. Anything else is
        // ignored.
        const std::vector<std::string> kKeys{ "DAY",          "TIME",         "PLACE",       "NEAR",
                                              "OFFICIANT",    "INVITE_THEIRS", "INVITE_YOURS", "INVITE",
                                              "UNINVITE",     "ADDRESS",      "READING",     "RINGS",
                                              "KISS",         "THEIR_STYLE",  "THEIR_METAL", "YOUR_STYLE",
                                              "YOUR_METAL",   "OUTFIT" };

        struct Line {
            std::string who;
            std::string text;
        };

        CustomPromptFn g_prompt = nullptr;

        // Everything below: the main thread writes it; the VM thread reads the
        // results (Field, Forget) and sets the variant.
        std::mutex                                               g_lock;
        std::string                                              g_variant;
        std::uint32_t                                            g_betrothed = 0;
        std::uint32_t                                            g_planner = 0;
        std::deque<Line>                                         g_lines;
        std::size_t                                              g_judged = 0;   // at the front, already judged
        std::chrono::steady_clock::time_point                    g_lastHeard{};
        std::uint64_t                                            g_generation = 0;
        bool                                                     g_inFlight = false;
        bool                                                     g_again = false;
        std::int32_t                                             g_nextToken = 1;
        std::map<std::int32_t, std::map<std::string, std::string>> g_results;

        std::string NameOf(std::uint32_t a_formId) {
            auto*       form = a_formId ? RE::TESForm::LookupByID(a_formId) : nullptr;
            auto*       actor = form ? form->As<RE::Actor>() : nullptr;
            const char* name = actor ? actor->GetDisplayFullName() : nullptr;
            return name && *name ? name : "";
        }

        std::string Trim(std::string a_text) {
            const auto first = a_text.find_first_not_of(" \t\r\n\"'*`");
            if (first == std::string::npos) {
                return {};
            }
            const auto last = a_text.find_last_not_of(" \t\r\n\"'*`.");
            return a_text.substr(first, last - first + 1);
        }

        std::string Upper(std::string a_text) {
            for (auto& c : a_text) {
                c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
            }
            return a_text;
        }

        std::string Lower(std::string a_text) {
            for (auto& c : a_text) {
                c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            }
            return a_text;
        }

        bool SaysNothing(const std::string& a_value) {
            const auto v = Lower(a_value);
            return v.empty() || v == "none" || v == "nothing" || v == "-" || v == "n/a" || v == "not said" ||
                   v == "unchanged";
        }

        // "address=yes, reading=no" or "style=slim, metal=silver": each pair
        // under its own key, prefixed.
        void Pairs(const std::string& a_value, const std::string& a_prefix,
                   std::map<std::string, std::string>& a_out) {
            std::size_t start = 0;
            while (start < a_value.size()) {
                auto end = a_value.find_first_of(",;", start);
                if (end == std::string::npos) {
                    end = a_value.size();
                }
                const auto pair = a_value.substr(start, end - start);
                start = end + 1;
                const auto eq = pair.find_first_of("=:");
                if (eq == std::string::npos) {
                    continue;
                }
                const auto key = a_prefix + Upper(Trim(pair.substr(0, eq)));
                const auto value = Lower(Trim(pair.substr(eq + 1)));
                if (!SaysNothing(value)) {
                    a_out[key] = value;
                }
            }
        }

        // The judgment, a line per thing settled ("GUESTS: ..."), or NOTHING.
        std::map<std::string, std::string> Parse(const std::string& a_text) {
            std::map<std::string, std::string> out;
            std::size_t                        start = 0;
            while (start <= a_text.size()) {
                auto end = a_text.find('\n', start);
                if (end == std::string::npos) {
                    end = a_text.size();
                }
                auto line = Trim(a_text.substr(start, end - start));
                start = end + 1;
                if (line.starts_with("- ")) {
                    line = Trim(line.substr(2));
                }
                const auto colon = line.find(':');
                if (colon == std::string::npos) {
                    continue;
                }
                const auto key = Upper(Trim(line.substr(0, colon)));
                const auto value = Trim(line.substr(colon + 1));
                if (SaysNothing(value)) {
                    continue;
                }
                if (key == "CEREMONY") {
                    Pairs(value, "", out);
                } else if (key == "THEIR_RING") {
                    Pairs(value, "THEIR_", out);
                } else if (key == "YOUR_RING") {
                    Pairs(value, "YOUR_", out);
                } else {
                    out[key] = value;
                }
            }
            std::erase_if(out, [](const auto& a_kv) {
                return std::ranges::find(kKeys, a_kv.first) == kKeys.end();
            });
            return out;
        }

        void Fire(std::uint64_t a_generation);

        void Later(std::uint64_t a_generation) {
            std::thread([a_generation]() {
                std::this_thread::sleep_for(kQuiet);
                SKSE::GetTaskInterface()->AddTask([a_generation]() { Fire(a_generation); });
            }).detach();
        }

        // The judgment back. Main thread.
        void Judged(std::uint32_t a_betrothed, const std::string& a_text) {
            std::map<std::string, std::string> heard = Parse(a_text);
            std::int32_t                       token = 0;
            bool                               again = false;
            std::uint64_t                      generation = 0;
            {
                const std::scoped_lock lock{ g_lock };
                g_inFlight = false;
                again = std::exchange(g_again, false);
                generation = g_generation;
                if (!heard.empty()) {
                    token = g_nextToken++;
                    g_results[token] = heard;
                }
            }
            // TEST LOG (wpm85): what the judge said, and why nothing was sent.
            std::string said;
            for (const auto& [key, value] : heard) {
                said += (said.empty() ? "" : "; ") + key + " " + value;
            }
            if (heard.empty()) {
                SKSE::log::info("PlanJudge: {}'s plan: nothing settled in that exchange (reply: '{}')",
                                NameOf(a_betrothed), Trim(a_text).substr(0, 120));
            } else {
                SKSE::log::info("PlanJudge: {}'s plan heard: {}", NameOf(a_betrothed), said);
                auto* form = RE::TESForm::LookupByID(a_betrothed);
                SKSE::ModCallbackEvent event{ "SNRom_PlanHeard", RE::BSFixedString(std::to_string(token)),
                                              static_cast<float>(token), form };
                if (auto* source = SKSE::GetModCallbackEventSource()) {
                    source->SendEvent(&event);
                }
            }
            if (again) {
                Fire(generation);
            }
        }

        // Judge what has been said since the last judgment, if nothing has
        // been said since this was scheduled. Main thread.
        void Fire(std::uint64_t a_generation) {
            json          ctx;
            std::string   variant;
            std::uint32_t betrothed = 0;
            {
                const std::scoped_lock lock{ g_lock };
                if (a_generation != g_generation || g_judged >= g_lines.size() || !g_betrothed) {
                    return;
                }
                if (g_inFlight) {
                    g_again = true;
                    return;
                }
                json earlier = json::array();
                json fresh = json::array();
                for (std::size_t i = 0; i < g_lines.size(); ++i) {
                    if (i < g_judged) {
                        if (i + kEarlier >= g_judged) {
                            earlier.push_back(g_lines[i].who + ": " + g_lines[i].text);
                        }
                    } else {
                        fresh.push_back(g_lines[i].who + ": " + g_lines[i].text);
                    }
                }
                betrothed = g_betrothed;
                variant = g_variant;
                ctx = { { "plan_betrothed", NameOf(g_betrothed) },
                        { "plan_planner", NameOf(g_planner) },
                        { "plan_player", NameOf(kPlayer) },
                        { "plan_earlier", earlier },
                        { "plan_lines", fresh } };
                g_judged = g_lines.size();
                g_inFlight = true;
            }
            ctx["plan_now"] = WeddingPlan::ForPrompt(static_cast<std::int32_t>(betrothed));
            const bool queued = g_prompt(
                "snrom_plan_judge", variant.c_str(), ctx.dump(-1, ' ', false, json::error_handler_t::replace).c_str(),
                [betrothed](const char* a_response, int a_success) {
                    std::string text = a_success && a_response ? a_response : "";
                    SKSE::GetTaskInterface()->AddTask([betrothed, text]() { Judged(betrothed, text); });
                });
            if (!queued) {
                const std::scoped_lock lock{ g_lock };
                g_inFlight = false;
                SKSE::log::warn("PlanJudge: SkyrimNet would not send snrom_plan_judge");
            }
        }
    }

    void Register() {
        const auto mod = GetModuleHandleW(L"SkyrimNet.dll");
        const auto version = mod ? reinterpret_cast<VersionFn>(GetProcAddress(mod, "PublicGetVersion")) : nullptr;
        if (!version || version() < 8) {
            SKSE::log::warn("PlanJudge: SkyrimNet has no custom prompts; a planner's agreements are recorded only by "
                            "their actions");
            return;
        }
        g_prompt = reinterpret_cast<CustomPromptFn>(GetProcAddress(mod, "PublicSendCustomPromptToLLM"));
        SKSE::log::info("PlanJudge: {}", g_prompt ? "a planner's agreements are also heard (snrom_plan_judge)"
                                                  : "no custom prompt call; not heard");
    }

    void SetVariant(std::string a_variant) {
        const std::scoped_lock lock{ g_lock };
        g_variant = std::move(a_variant);
    }

    void Heard(std::uint32_t a_speaker, std::uint32_t a_target, const std::string& a_line) {
        if (!g_prompt || a_line.empty() || !a_speaker || Ceremony::Now() != 0) {
            return;
        }
        // The planner, speaking or spoken to.
        std::uint32_t planner = 0;
        std::uint32_t betrothed = 0;
        if (a_speaker != kPlayer) {
            if (const auto b = WeddingPlan::PlannedBy(a_speaker)) {
                planner = a_speaker;
                betrothed = b;
            }
        } else if (a_target) {
            if (const auto b = WeddingPlan::PlannedBy(a_target)) {
                planner = a_target;
                betrothed = b;
            }
        }
        const auto    now = std::chrono::steady_clock::now();
        std::uint64_t schedule = 0;
        {
            const std::scoped_lock lock{ g_lock };
            if (g_variant.empty()) {
                return;
            }
            const bool open = g_planner && now - g_lastHeard <= kWindow;
            if (planner) {
                if (!open || planner != g_planner || betrothed != g_betrothed) {
                    g_lines.clear();
                    g_judged = 0;
                    g_planner = planner;
                    g_betrothed = betrothed;
                }
            } else {
                // The betrothed, or the player to them, in the same
                // conversation: what they settle between them counts too.
                const bool couple = a_speaker == g_betrothed ||
                                    (a_speaker == kPlayer && (a_target == g_betrothed || a_target == 0));
                if (!open || !couple) {
                    return;
                }
            }
            g_lines.push_back({ NameOf(a_speaker), a_line });
            while (g_lines.size() > kMaxLines) {
                g_lines.pop_front();
                if (g_judged) {
                    --g_judged;
                }
            }
            g_lastHeard = now;
            ++g_generation;
            if (a_speaker == g_planner) {
                schedule = g_generation;
            }
        }
        if (schedule) {
            Later(schedule);
        }
    }

    std::string Field(std::int32_t a_token, const std::string& a_key) {
        const std::scoped_lock lock{ g_lock };
        const auto             it = g_results.find(a_token);
        if (it == g_results.end()) {
            return {};
        }
        const auto field = it->second.find(Upper(a_key));
        return field == it->second.end() ? std::string{} : field->second;
    }

    void Forget(std::int32_t a_token) {
        const std::scoped_lock lock{ g_lock };
        g_results.erase(a_token);
    }
}
