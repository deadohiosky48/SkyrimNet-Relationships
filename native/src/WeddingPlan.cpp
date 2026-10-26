#include "WeddingPlan.h"

#include "PCH.h"

#include "Ceremony.h"
#include "Family.h"
#include "Marriage.h"
#include "Model.h"
#include "Officiant.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstring>
#include <format>
#include <map>
#include <mutex>
#include <optional>
#include <thread>

namespace SNRom::WeddingPlan {

    namespace {

        using json = nlohmann::json;

        // 2 (wpm51): the rings per person, and what is settled.
        constexpr std::uint32_t kRecordVersion = 2;
        constexpr std::size_t   kMaxPlace = 120;
        constexpr std::size_t   kMaxGuests = 40;

        // THE DAY, in game days (Plan.day + hour / 24 is when). Everyone is
        // sent to the place this long before; the wedding may begin from an
        // hour before; and the day is missed once this long has passed with
        // no wedding (M4w).
        constexpr float kSendAhead = 4.0f / 24.0f;
        constexpr float kBeginFrom = 1.0f / 24.0f;
        constexpr float kMissedAfter = 6.0f / 24.0f;

        // Present for the wedding: the player within this of both of them.
        constexpr float kHere = 2000.0f;

        std::mutex                         g_lock;
        std::map<std::uint32_t, Plan>      g_plans;  // betrothed -> plan
        std::atomic<int>                   g_generation{ 0 };
        std::chrono::steady_clock::time_point g_beginSentAt{};

        float Now() {
            const auto* calendar = RE::Calendar::GetSingleton();
            return calendar ? calendar->GetCurrentGameTime() : 0.0f;
        }

        float When(const Plan& a_plan) {
            return a_plan.day + static_cast<float>(std::max(a_plan.hour, 0)) / 24.0f;
        }

        std::string NameOf(std::uint32_t a_formId) {
            auto*       form = a_formId ? RE::TESForm::LookupByID(a_formId) : nullptr;
            auto*       actor = form ? form->As<RE::Actor>() : nullptr;
            const char* name = actor ? actor->GetDisplayFullName() : (form ? form->GetName() : nullptr);
            return name && *name ? name : "";
        }

        std::string Lower(std::string a_text) {
            for (auto& c : a_text) {
                c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            }
            return a_text;
        }

        std::string Trim(std::string a_text) {
            const auto first = a_text.find_first_not_of(" \t\r\n\"'.,");
            const auto last = a_text.find_last_not_of(" \t\r\n\"'.,");
            return first == std::string::npos ? std::string{} : a_text.substr(first, last - first + 1);
        }

        const char* TimeWord(std::int32_t a_hour) {
            if (a_hour < 0) {
                return "";
            }
            if (a_hour >= 5 && a_hour <= 10) {
                return "in the morning";
            }
            if (a_hour >= 11 && a_hour <= 13) {
                return "at noon";
            }
            if (a_hour >= 14 && a_hour <= 16) {
                return "in the afternoon";
            }
            if (a_hour >= 17 && a_hour <= 20) {
                return "in the evening";
            }
            return "at night";
        }

        // "today in the evening", "tomorrow at noon", "in 3 days in the
        // morning"; "" when no day is set.
        std::string DayWords(const Plan& a_plan) {
            if (a_plan.day < 0.0f) {
                return "";
            }
            const auto in = static_cast<std::int32_t>(a_plan.day - std::floor(Now()));
            std::string out = in <= 0 ? "today" : in == 1 ? "tomorrow" : std::format("in {} days", in);
            if (const char* time = TimeWord(a_plan.hour); *time) {
                out += std::string(" ") + time;
            }
            return out;
        }

        // THE CALENDAR (RE::Calendar: month 0 Morning Star to 11 Evening Star,
        // day of the month from 1, weekday 0 Sundas to 6 Loredas).
        constexpr std::array<std::int32_t, 12> kMonthLength{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        // As said, lowercased with spaces and apostrophes taken out.
        constexpr std::array<const char*, 12> kMonthKeys{ "morningstar", "sunsdawn", "firstseed", "rainshand",
                                                          "secondseed", "midyear", "sunsheight", "lastseed",
                                                          "hearthfire", "frostfall", "sunsdusk", "eveningstar" };
        constexpr std::array<const char*, 12> kMonthNames{ "Morning Star", "Sun's Dawn", "First Seed", "Rain's Hand",
                                                           "Second Seed", "Midyear", "Sun's Height", "Last Seed",
                                                           "Hearthfire", "Frostfall", "Sun's Dusk", "Evening Star" };
        constexpr std::array<const char*, 7> kWeekdays{ "sundas", "morndas", "tirdas", "middas",
                                                        "turdas", "fredas", "loredas" };
        constexpr std::array<const char*, 7> kWeekdayNames{ "Sundas", "Morndas", "Tirdas", "Middas",
                                                            "Turdas", "Fredas", "Loredas" };

        std::int32_t DayOfYear(std::int32_t a_month, std::int32_t a_day) {
            std::int32_t n = 0;
            for (std::int32_t m = 0; m < a_month; ++m) {
                n += kMonthLength[static_cast<std::size_t>(m)];
            }
            return n + a_day - 1;
        }

        struct Today {
            std::int32_t month = 0;
            std::int32_t day = 1;
            std::int32_t weekday = 0;
        };
        Today TodayIs() {
            Today t;
            if (const auto* cal = RE::Calendar::GetSingleton()) {
                t.month = std::clamp(static_cast<std::int32_t>(cal->GetMonth()), 0, 11);
                t.day = std::clamp(static_cast<std::int32_t>(cal->GetDay()), 1, 31);
                t.weekday = std::clamp(static_cast<std::int32_t>(cal->GetDayOfWeek()), 0, 6);
            }
            return t;
        }

        // "Loredas, the 4th of Sun's Height": the date a_in days from today.
        std::string DateWords(std::int32_t a_in) {
            const auto t = TodayIs();
            auto       doy = (DayOfYear(t.month, t.day) + a_in) % 365;
            std::int32_t month = 0;
            while (doy >= kMonthLength[static_cast<std::size_t>(month)]) {
                doy -= kMonthLength[static_cast<std::size_t>(month)];
                ++month;
            }
            const auto day = doy + 1;
            const char* suffix = (day % 10 == 1 && day != 11) ? "st" : (day % 10 == 2 && day != 12) ? "nd" :
                                 (day % 10 == 3 && day != 13) ? "rd" : "th";
            return std::format("{}, the {}{} of {}", kWeekdayNames[static_cast<std::size_t>((t.weekday + a_in) % 7)],
                               day, suffix, kMonthNames[static_cast<std::size_t>(month)]);
        }

        // The words split on anything not a letter or digit, lowercased,
        // apostrophes dropped ("sun's" is "suns").
        std::vector<std::string> Words(const std::string& a_text) {
            std::vector<std::string> out;
            std::string              word;
            for (const char raw : a_text) {
                const auto c = static_cast<unsigned char>(raw);
                if (c == '\'' || c >= 0x80) {
                    continue;   // ' and the bytes of a curly one
                }
                if (std::isalnum(c)) {
                    word += static_cast<char>(std::tolower(c));
                } else if (!word.empty()) {
                    out.push_back(std::move(word));
                    word.clear();
                }
            }
            if (!word.empty()) {
                out.push_back(std::move(word));
            }
            return out;
        }

        // "4", "4th", "four", "fourth": the number; -1 otherwise.
        std::int32_t NumberIn(const std::string& a_word) {
            static constexpr std::array<const char*, 11> kCardinal{ "zero", "one", "two",   "three", "four", "five",
                                                                    "six",  "seven", "eight", "nine",  "ten" };
            static constexpr std::array<const char*, 11> kOrdinal{ "", "first", "second", "third", "fourth", "fifth",
                                                                   "sixth", "seventh", "eighth", "ninth", "tenth" };
            for (std::size_t i = 0; i < kCardinal.size(); ++i) {
                if (a_word == kCardinal[i] || (i > 0 && a_word == kOrdinal[i])) {
                    return static_cast<std::int32_t>(i);
                }
            }
            if (a_word == "a" || a_word == "an") {
                return 1;
            }
            std::size_t digits = 0;
            while (digits < a_word.size() && std::isdigit(static_cast<unsigned char>(a_word[digits]))) {
                ++digits;
            }
            if (digits == 0 || digits > 3) {
                return -1;
            }
            const auto rest = a_word.substr(digits);
            if (!rest.empty() && rest != "st" && rest != "nd" && rest != "rd" && rest != "th") {
                return -1;
            }
            return std::stoi(a_word.substr(0, digits));
        }

        const char* MetalWord(std::int32_t a_metal) {
            switch (a_metal) {
            case 0:
                return "gold";
            case 1:
                return "silver";
            case 2:
                return "ebony";
            default:
                return "";
            }
        }

        void Send(const char* a_event, const std::string& a_text, float a_number, std::uint32_t a_sender) {
            SKSE::GetTaskInterface()->AddTask([event = std::string(a_event), a_text, a_number, a_sender]() {
                auto*                  sender = a_sender ? RE::TESForm::LookupByID<RE::Actor>(a_sender) : nullptr;
                SKSE::ModCallbackEvent e{ RE::BSFixedString(event), RE::BSFixedString(a_text), a_number, sender };
                if (auto* source = SKSE::GetModCallbackEventSource()) {
                    source->SendEvent(&e);
                }
            });
        }

        bool Present(RE::PlayerCharacter* a_player, std::uint32_t a_id) {
            auto* actor = a_id ? RE::TESForm::LookupByID<RE::Actor>(a_id) : nullptr;
            return actor && !actor->IsDead() && actor->Is3DLoaded() &&
                   actor->GetPosition().GetDistance(a_player->GetPosition()) <= kHere;
        }

        // Main thread, every few seconds while a game is loaded.
        void Tick() {
            auto* player = RE::PlayerCharacter::GetSingleton();
            auto* ui = RE::UI::GetSingleton();
            if (!player || !player->Is3DLoaded() || (ui && ui->GameIsPaused())) {
                return;
            }
            const float now = Now();
            struct Due {
                std::uint32_t betrothed;
                const char*   event;
                std::string   text;
            };
            std::vector<Due> due;
            {
                const std::scoped_lock lock{ g_lock };
                for (auto it = g_plans.begin(); it != g_plans.end();) {
                    const auto id = it->first;
                    auto&      plan = it->second;
                    // Married, broken off, or gone: the plan goes with them.
                    if (!Marriage::Engaged(static_cast<std::int32_t>(id))) {
                        SKSE::log::info("Wedding plan: {:08X} is no longer engaged; their plan is gone", id);
                        it = g_plans.erase(it);
                        continue;
                    }
                    ++it;
                    if (plan.day < 0.0f) {
                        continue;
                    }
                    const float when = When(plan);
                    const bool  ready = Open(plan).empty();
                    if (plan.status == Status::kPlanning) {
                        if (now >= when + kMissedAfter) {
                            // The day came and went, never ready: put off,
                            // with no blame. The betrothed will say so.
                            plan.lapsedDay = plan.day;
                            plan.day = -1.0f;
                            plan.hour = -1;
                            SKSE::log::info("Wedding plan: {:08X}'s day passed with the plan unfinished; put off", id);
                            due.push_back({ id, "SNRom_WeddingLapsed", "" });
                        } else if (ready && now >= when - kSendAhead) {
                            plan.status = Status::kUnderWay;
                            // A jarl chosen weeks ago may hold the hall no
                            // longer: whoever does comes instead (wpm48).
                            if (auto* officiant = Officiant::InPlaceOf(plan.officiant)) {
                                plan.officiant = officiant->GetFormID();
                            }
                            SKSE::log::info("Wedding plan: {:08X}'s wedding day has begun; everyone to {}", id,
                                            plan.place);
                            due.push_back({ id, "SNRom_WeddingDay", plan.place });
                        }
                        continue;
                    }
                    // Under way.
                    if (Ceremony::Now() != 0) {
                        continue;   // it is happening
                    }
                    if (now >= when + kMissedAfter) {
                        plan.status = Status::kPlanning;
                        plan.missedDay = plan.day;
                        plan.day = -1.0f;
                        plan.hour = -1;
                        SKSE::log::info("Wedding plan: {:08X}'s wedding day passed without the player", id);
                        due.push_back({ id, "SNRom_WeddingMissed", "" });
                        continue;
                    }
                    if (now >= when - kBeginFrom && Present(player, id) && Present(player, plan.officiant) &&
                        std::chrono::steady_clock::now() - g_beginSentAt > std::chrono::seconds{ 30 }) {
                        g_beginSentAt = std::chrono::steady_clock::now();
                        due.push_back({ id, "SNRom_WeddingBegin", "" });
                    }
                }
            }
            for (const auto& d : due) {
                Send(d.event, d.text, 0.0f, d.betrothed);
            }
        }

        bool WriteString(SKSE::SerializationInterface* a_intfc, const std::string& a_text) {
            const auto length = static_cast<std::uint16_t>(std::min<std::size_t>(a_text.size(), 0xFFFF));
            return a_intfc->WriteRecordData(length) && (length == 0 || a_intfc->WriteRecordData(a_text.data(), length));
        }

        bool ReadString(SKSE::SerializationInterface* a_intfc, std::string& a_text) {
            std::uint16_t length = 0;
            if (a_intfc->ReadRecordData(length) != sizeof(length)) {
                return false;
            }
            a_text.resize(length);
            return length == 0 || a_intfc->ReadRecordData(a_text.data(), length) == length;
        }

        // A plan to change, made if there is none. Under g_lock.
        Plan& Make(std::int32_t a_betrothed) {
            return g_plans[static_cast<std::uint32_t>(a_betrothed)];
        }
    }

    std::optional<Plan> Get(std::int32_t a_betrothed) {
        const std::scoped_lock lock{ g_lock };
        const auto             it = g_plans.find(static_cast<std::uint32_t>(a_betrothed));
        return it == g_plans.end() ? std::nullopt : std::optional<Plan>{ it->second };
    }

    bool Hire(std::int32_t a_betrothed, std::uint32_t a_planner) {
        const std::scoped_lock lock{ g_lock };
        auto&                  plan = Make(a_betrothed);
        if (plan.planner == a_planner) {
            return false;
        }
        const bool first = plan.planner == 0;
        plan.planner = a_planner;
        // A planner's wedding has every part until the couple says otherwise.
        if (first) {
            plan.parts = kAllParts;
        }
        return true;
    }

    bool SetDay(std::int32_t a_betrothed, std::int32_t a_daysFromNow, std::int32_t a_hour) {
        if (a_daysFromNow > 365 || a_hour > 23 || (a_daysFromNow < 0 && a_hour < 0)) {
            return false;
        }
        const std::scoped_lock lock{ g_lock };
        auto&                  plan = Make(a_betrothed);
        if (a_daysFromNow >= 0) {
            plan.day = std::floor(Now()) + static_cast<float>(a_daysFromNow);
        }
        if (a_hour >= 0) {
            plan.hour = a_hour;
        }
        plan.status = Status::kPlanning;
        return true;
    }

    std::optional<std::int32_t> DaysFromWords(const std::string& a_words) {
        const auto words = Words(a_words);
        if (words.empty()) {
            return std::nullopt;
        }
        std::string joined;
        for (const auto& w : words) {
            joined += w;
        }
        const auto has = [&](const char* a_word) { return std::ranges::find(words, a_word) != words.end(); };
        const auto t = TodayIs();
        const bool today = has("today");

        // A MONTH NAMED: that date, this year or the next.
        int month = -1;
        for (std::size_t m = 0; m < kMonthKeys.size(); ++m) {
            if (joined.find(kMonthKeys[m]) != std::string::npos) {
                month = static_cast<int>(m);
                break;
            }
        }
        int weekday = -1;
        for (std::size_t d = 0; d < kWeekdays.size(); ++d) {
            if (has(kWeekdays[d])) {
                weekday = static_cast<int>(d);
                break;
            }
        }
        if (month >= 0) {
            std::int32_t day = -1;
            for (const auto& w : words) {
                if (const auto n = NumberIn(w); n >= 1 && n <= kMonthLength[static_cast<std::size_t>(month)]) {
                    day = n;
                    break;
                }
            }
            if (day < 0) {
                return std::nullopt;
            }
            auto in = DayOfYear(month, day) - DayOfYear(t.month, t.day);
            if (in < 0) {
                in += 365;
            }
            if (weekday >= 0 && (t.weekday + in) % 7 != weekday) {
                SKSE::log::warn("Wedding plan: '{}' names {}, but that date is a {}; the date is kept", a_words,
                                kWeekdayNames[static_cast<std::size_t>(weekday)],
                                kWeekdayNames[static_cast<std::size_t>((t.weekday + in) % 7)]);
            }
            return in;
        }
        // A WEEKDAY ALONE: the next one ("Loredas", "next Loredas"); today's
        // own only when today is said.
        if (weekday >= 0) {
            auto in = (weekday - t.weekday + 7) % 7;
            if (in == 0 && !today) {
                in = 7;
            }
            return in;
        }
        // HOW FAR OFF.
        if (today) {
            return 0;
        }
        if (has("tomorrow")) {
            return has("after") ? 2 : 1;
        }
        if (has("fortnight")) {
            return 14;
        }
        for (std::size_t i = 0; i < words.size(); ++i) {
            const auto n = NumberIn(words[i]);
            if (n < 0) {
                continue;
            }
            const auto unit = i + 1 < words.size() ? words[i + 1] : std::string{};
            if (unit == "week" || unit == "weeks") {
                return n * 7 <= 365 ? std::optional<std::int32_t>{ n * 7 } : std::nullopt;
            }
            if (unit.empty() || unit == "day" || unit == "days") {
                return n <= 365 ? std::optional<std::int32_t>{ n } : std::nullopt;
            }
        }
        if (has("week")) {
            return 7;
        }
        return std::nullopt;
    }

    bool SetDayFromWords(std::int32_t a_betrothed, const std::string& a_day, const std::string& a_time) {
        const bool daySaid = !Trim(a_day).empty();
        const bool timeSaid = !Trim(a_time).empty();
        const auto days = daySaid ? DaysFromWords(a_day) : std::nullopt;
        const auto hour = timeSaid ? HourOf(a_time) : -1;
        if (daySaid && !days) {
            SKSE::log::warn("Wedding plan: '{}' is not a day this can read; the day is not changed", a_day);
        }
        if (timeSaid && hour < 0) {
            SKSE::log::warn("Wedding plan: '{}' is not a time of day this can read; the hour is not changed", a_time);
        }
        if (!days && hour < 0) {
            SKSE::log::info("Wedding plan: {:08X}: no day or hour to set", static_cast<std::uint32_t>(a_betrothed));
            return false;
        }
        // TEST LOG (wpm51): how a day as said was read; remove once validated.
        SKSE::log::info("Wedding plan: {:08X}: '{}' at '{}' read as {}, hour {}",
                        static_cast<std::uint32_t>(a_betrothed), a_day, a_time,
                        days ? std::format("{} days from today ({})", *days, DateWords(*days)) : "the day as it was",
                        hour >= 0 ? std::to_string(hour) : "as it was");
        return SetDay(a_betrothed, days ? *days : -1, hour);
    }

    bool SetPlace(std::int32_t a_betrothed, std::string a_place) {
        a_place = Trim(std::move(a_place));
        if (a_place.empty()) {
            return false;
        }
        if (a_place.size() > kMaxPlace) {
            a_place.resize(kMaxPlace);
        }
        const std::scoped_lock lock{ g_lock };
        auto&                  plan = Make(a_betrothed);
        if (plan.place == a_place) {
            return false;
        }
        plan.place = std::move(a_place);
        return true;
    }

    bool SetOfficiant(std::int32_t a_betrothed, std::uint32_t a_officiant) {
        const std::scoped_lock lock{ g_lock };
        auto&                  plan = Make(a_betrothed);
        if (plan.officiant == a_officiant) {
            return false;
        }
        plan.officiant = a_officiant;
        return true;
    }

    bool AddGuest(std::int32_t a_betrothed, std::uint32_t a_guest) {
        if (!a_guest || a_guest == static_cast<std::uint32_t>(a_betrothed) || a_guest == 0x14) {
            return false;
        }
        const std::scoped_lock lock{ g_lock };
        auto&                  plan = Make(a_betrothed);
        plan.settled |= kGuestsSettled;
        if (std::find(plan.guests.begin(), plan.guests.end(), a_guest) != plan.guests.end() ||
            plan.guests.size() >= kMaxGuests) {
            return false;
        }
        plan.guests.push_back(a_guest);
        return true;
    }

    bool RemoveGuest(std::int32_t a_betrothed, std::uint32_t a_guest) {
        const std::scoped_lock lock{ g_lock };
        const auto             it = g_plans.find(static_cast<std::uint32_t>(a_betrothed));
        if (it == g_plans.end()) {
            return false;
        }
        it->second.settled |= kGuestsSettled;
        return std::erase(it->second.guests, a_guest) > 0;
    }

    bool SettleGuests(std::int32_t a_betrothed) {
        const std::scoped_lock lock{ g_lock };
        auto&                  plan = Make(a_betrothed);
        if (plan.settled & kGuestsSettled) {
            return false;
        }
        plan.settled |= kGuestsSettled;
        return true;
    }

    bool SetParts(std::int32_t a_betrothed, std::uint32_t a_parts) {
        const std::scoped_lock lock{ g_lock };
        auto&                  plan = Make(a_betrothed);
        a_parts &= kAllParts;
        // Said, even as it was ("the usual is fine"): settled.
        const bool wasSettled = (plan.settled & kCeremonySettled) != 0;
        plan.settled |= kCeremonySettled;
        if (plan.parts == a_parts) {
            return !wasSettled;
        }
        plan.parts = a_parts;
        return true;
    }

    bool SetRings(std::int32_t a_betrothed, std::int32_t a_yourStyle, std::int32_t a_yourMetal,
                  std::int32_t a_theirStyle, std::int32_t a_theirMetal) {
        const std::scoped_lock lock{ g_lock };
        auto&                  plan = Make(a_betrothed);
        bool                   changed = false;
        const auto set = [&](std::int32_t& a_field, std::int32_t a_value, std::int32_t a_max) {
            if (a_value >= 0 && a_value <= a_max && a_field != a_value) {
                a_field = a_value;
                changed = true;
            }
        };
        set(plan.yourStyle, a_yourStyle, kWide);
        set(plan.yourMetal, a_yourMetal, 2);
        set(plan.theirStyle, a_theirStyle, kWide);
        set(plan.theirMetal, a_theirMetal, 2);
        return changed;
    }

    bool SetOutfit(std::int32_t a_betrothed, bool a_saved) {
        const std::scoped_lock lock{ g_lock };
        auto&                  plan = Make(a_betrothed);
        plan.settled |= kOutfitSettled;
        if (plan.outfit == a_saved) {
            return false;
        }
        plan.outfit = a_saved;
        return true;
    }

    bool Postpone(std::int32_t a_betrothed) {
        const std::scoped_lock lock{ g_lock };
        const auto             it = g_plans.find(static_cast<std::uint32_t>(a_betrothed));
        if (it == g_plans.end() || it->second.day < 0.0f) {
            return false;
        }
        it->second.day = -1.0f;
        it->second.hour = -1;
        it->second.status = Status::kPlanning;
        return true;
    }

    void Clear(std::int32_t a_betrothed) {
        const std::scoped_lock lock{ g_lock };
        if (g_plans.erase(static_cast<std::uint32_t>(a_betrothed)) > 0) {
            SKSE::log::info("Wedding plan: {:08X}'s plan cleared", static_cast<std::uint32_t>(a_betrothed));
        }
    }

    std::vector<std::string> Open(const Plan& a_plan) {
        std::vector<std::string> open;
        if (a_plan.place.empty()) {
            open.emplace_back("place");
        }
        if (!a_plan.officiant) {
            open.emplace_back("officiant");
        }
        if (a_plan.day < 0.0f) {
            open.emplace_back("day");
        }
        if (a_plan.hour < 0) {
            open.emplace_back("hour");
        }
        return open;
    }

    std::vector<std::string> Unsettled(const Plan& a_plan) {
        std::vector<std::string> out;
        const bool planner = a_plan.planner != 0;
        if (!(a_plan.settled & kGuestsSettled)) {
            out.emplace_back("guests");
        }
        if (planner && !(a_plan.settled & kCeremonySettled)) {
            out.emplace_back("ceremony");
        }
        if (planner && (a_plan.theirStyle < 0 || a_plan.theirMetal < 0)) {
            out.emplace_back("theirRing");
        }
        if (planner && (a_plan.yourStyle < 0 || a_plan.yourMetal < 0)) {
            out.emplace_back("yourRing");
        }
        if (!(a_plan.settled & kOutfitSettled)) {
            out.emplace_back("outfit");
        }
        return out;
    }

    json ForPrompt(std::int32_t a_betrothed) {
        const auto plan = Get(a_betrothed);
        if (!plan) {
            return nullptr;
        }
        json guests = json::array();
        for (const auto guest : plan->guests) {
            if (auto name = NameOf(guest); !name.empty()) {
                guests.push_back(std::move(name));
            }
        }
        const float now = Now();
        const auto  ring = [](std::int32_t a_style, std::int32_t a_metal) {
            return json{ { "style", a_style == kWide ? "the wide plain band" : a_style == kSlim ? "the slim set" : "" },
                         { "metal", MetalWord(a_metal) } };
        };
        const auto in = plan->day >= 0.0f ? static_cast<std::int32_t>(plan->day - std::floor(now)) : -1;
        return { { "exists", 1 },
                 { "day", DayWords(*plan) },
                 { "date", in >= 0 ? DateWords(in) : std::string{} },
                 { "place", plan->place },
                 { "officiant", NameOf(plan->officiant) },
                 { "guests", guests },
                 { "planner", NameOf(plan->planner) },
                 { "address", (plan->parts & kAddress) ? 1 : 0 },
                 { "reading", (plan->parts & kReading) ? 1 : 0 },
                 { "rings", (plan->parts & kRings) ? 1 : 0 },
                 { "kiss", (plan->parts & kKiss) ? 1 : 0 },
                 { "theirRing", ring(plan->theirStyle, plan->theirMetal) },
                 { "yourRing", ring(plan->yourStyle, plan->yourMetal) },
                 { "outfit", plan->outfit ? 1 : 0 },
                 { "open", Open(*plan) },
                 { "unsettled", Unsettled(*plan) },
                 { "underWay", plan->status == Status::kUnderWay ? 1 : 0 },
                 { "soon", plan->day >= 0.0f && When(*plan) - now <= 1.5f ? 1 : 0 },
                 { "missed", plan->missedDay >= 0.0f ? 1 : 0 },
                 { "lapsed", plan->lapsedDay >= 0.0f && plan->day < 0.0f ? 1 : 0 } };
    }

    json OfficiatingFor(std::uint32_t a_officiant) {
        json out = json::array();
        std::vector<std::pair<std::uint32_t, Plan>> mine;
        {
            const std::scoped_lock lock{ g_lock };
            for (const auto& [id, plan] : g_plans) {
                if (plan.officiant == a_officiant) {
                    mine.emplace_back(id, plan);
                }
            }
        }
        for (const auto& [id, plan] : mine) {
            out.push_back({ { "betrothed", NameOf(id) },
                            { "day", DayWords(plan) },
                            { "place", plan.place },
                            { "underWay", plan.status == Status::kUnderWay ? 1 : 0 } });
        }
        return out;
    }

    json ForSnapshot(std::int32_t a_betrothed) {
        const auto plan = Get(a_betrothed);
        if (!plan) {
            return nullptr;
        }
        json guests = json::array();
        for (const auto guest : plan->guests) {
            if (auto name = NameOf(guest); !name.empty()) {
                guests.push_back(std::move(name));
            }
        }
        return { { "planner", NameOf(plan->planner) },
                 { "day", plan->day >= 0.0f ? json(plan->day) : json(nullptr) },
                 { "hour", plan->hour },
                 { "place", plan->place },
                 { "officiant", NameOf(plan->officiant) },
                 { "guests", guests },
                 { "parts", { { "address", (plan->parts & kAddress) != 0 },
                              { "reading", (plan->parts & kReading) != 0 },
                              { "rings", (plan->parts & kRings) != 0 },
                              { "kiss", (plan->parts & kKiss) != 0 } } },
                 { "theirRing", { { "style", plan->theirStyle }, { "metal", MetalWord(plan->theirMetal) } } },
                 { "yourRing", { { "style", plan->yourStyle }, { "metal", MetalWord(plan->yourMetal) } } },
                 { "outfit", plan->outfit },
                 { "status", plan->status == Status::kUnderWay ? "underWay" : "planning" },
                 { "open", Open(*plan) },
                 { "unsettled", Unsettled(*plan) },
                 { "missedDay", plan->missedDay >= 0.0f ? json(plan->missedDay) : json(nullptr) } };
    }

    RE::Actor* PersonNamed(const std::string& a_name) {
        const auto wanted = Lower(Trim(a_name));
        if (wanted.empty()) {
            return nullptr;
        }
        // How well a name matches: 3 the whole name, 2 the first name or the
        // name's first words ("eorlund" of "eorlund gray-mane"), 1 the name
        // begins with or holds what was said; 0 not at all.
        const auto quality = [&](const std::string& a_lower) {
            if (a_lower == wanted) {
                return 3;
            }
            if (a_lower.starts_with(wanted + " ") || a_lower.starts_with(wanted + "-")) {
                return 2;
            }
            if (wanted.size() >= 3 && (a_lower.starts_with(wanted) || a_lower.find(wanted) != std::string::npos)) {
                return 1;
            }
            return 0;
        };
        RE::Actor* best = nullptr;
        int        bestQuality = 0;
        const auto consider = [&](RE::Actor* a_actor) {
            if (!a_actor || a_actor->IsPlayerRef() || a_actor->IsDead()) {
                return;
            }
            const char* name = a_actor->GetDisplayFullName();
            if (!name || !*name) {
                return;
            }
            // Strictly better only: the first found of equals keeps it, and
            // the scopes are asked nearest first.
            if (const auto q = quality(Lower(name)); q > bestQuality) {
                best = a_actor;
                bestQuality = q;
            }
        };
        if (auto* lists = RE::ProcessLists::GetSingleton()) {
            for (auto& handle : lists->highActorHandles) {
                if (auto actor = handle.get()) {
                    consider(actor.get());
                }
            }
        }
        if (bestQuality < 3) {
            for (const auto id : Model::Get().FormIds()) {
                consider(RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(id)));
            }
        }
        if (bestQuality < 3) {
            if (auto* data = RE::TESDataHandler::GetSingleton()) {
                for (auto* npc : data->GetFormArray<RE::TESNPC>()) {
                    if (npc && npc->IsUnique()) {
                        consider(npc->GetUniqueActor());
                    }
                }
            }
        }
        return best;
    }

    std::vector<RE::Actor*> GuestsNamed(RE::Actor* a_speaker, const std::string& a_list) {
        std::vector<RE::Actor*> out;
        auto*                   player = RE::PlayerCharacter::GetSingleton();
        const auto              keep = [&](RE::Actor* a_actor) {
            if (a_actor && a_actor != a_speaker && !a_actor->IsPlayerRef() &&
                std::ranges::find(out, a_actor) == out.end()) {
                out.push_back(a_actor);
            }
        };
        // The list's items: split on commas, semicolons and the word "and".
        std::vector<std::string> items;
        {
            std::string text = a_list;
            for (const auto* sep : { " and ", " & " }) {
                for (auto at = Lower(text).find(sep); at != std::string::npos; at = Lower(text).find(sep)) {
                    text.replace(at, std::strlen(sep), ",");
                }
            }
            std::string item;
            for (const char c : text) {
                if (c == ',' || c == ';') {
                    items.push_back(Trim(item));
                    item.clear();
                } else {
                    item += c;
                }
            }
            items.push_back(Trim(item));
        }
        static constexpr std::array<const char*, 6> kMine{ "my ", "her ", "his ", "their ", "our ", "your " };
        static constexpr std::array<const char*, 22> kTitles{
            "the ", "my ", "dear ", "old ", "little ", "uncle ", "aunt ", "auntie ", "cousin ", "grandma ",
            "grandpa ", "granny ", "grandmother ", "grandfather ", "jarl ", "thane ", "lady ", "lord ", "sir ",
            "steward ", "housecarl ", "young "
        };
        for (const auto& item : items) {
            if (item.empty()) {
                continue;
            }
            const auto lower = Lower(item);
            // 1. A name, whole or the first name.
            if (auto* named = PersonNamed(item)) {
                const auto q = Lower(named->GetDisplayFullName());
                if (q == lower || q.starts_with(lower + " ") || q.starts_with(lower + "-")) {
                    SKSE::log::info("Guests: '{}' is {}", item, named->GetDisplayFullName());
                    keep(named);
                    continue;
                }
            }
            // 2. A relation: "<someone>'s <relation>", or "my <relation>".
            RE::Actor*  owner = nullptr;
            std::string relation;
            bool        relational = false;
            if (const auto at = lower.find("'s "); at != std::string::npos) {
                const auto who = Trim(item.substr(0, at));
                relation = Trim(lower.substr(at + 3));
                relational = true;
                const auto whoLower = Lower(who);
                if (player && whoLower == Lower(player->GetDisplayFullName())) {
                    owner = player;
                } else if (a_speaker && whoLower == Lower(a_speaker->GetDisplayFullName())) {
                    owner = a_speaker;
                } else {
                    owner = PersonNamed(who);
                }
            } else {
                for (const auto* mine : kMine) {
                    if (lower.starts_with(mine)) {
                        relation = Trim(lower.substr(std::strlen(mine)));
                        owner = std::string_view(mine) == "your " ? static_cast<RE::Actor*>(player) : a_speaker;
                        relational = true;
                        break;
                    }
                }
            }
            if (relational && owner) {
                const auto kin = Family::Relatives(owner, relation);
                if (!kin.empty()) {
                    std::string names;
                    for (auto* k : kin) {
                        names += (names.empty() ? "" : ", ") + std::string(k->GetDisplayFullName());
                        keep(k);
                    }
                    SKSE::log::info("Guests: '{}' is {} ({}'s {})", item, names, owner->GetDisplayFullName(),
                                    relation);
                    continue;
                }
            }
            // 3. A name behind a title or a family word: "Uncle Vignar".
            std::string bare = lower;
            for (bool again = true; again;) {
                again = false;
                for (const auto* title : kTitles) {
                    if (bare.starts_with(title)) {
                        bare.erase(0, std::strlen(title));
                        again = true;
                    }
                }
            }
            if (auto* named = bare != lower || !relational ? PersonNamed(bare) : nullptr) {
                SKSE::log::info("Guests: '{}' is {}", item, named->GetDisplayFullName());
                keep(named);
                continue;
            }
            SKSE::log::warn("Guests: no one living could be found for '{}'{}", item,
                            relational ? (owner ? std::format(" ({} has no such relative in the game's records)",
                                                              owner->GetDisplayFullName())
                                                : std::string(" (whose relative is not known)"))
                                       : std::string{});
        }
        return out;
    }

    std::int32_t HourOf(const std::string& a_words) {
        const auto w = Lower(Trim(a_words));
        if (w.empty()) {
            return -1;
        }
        if (std::all_of(w.begin(), w.end(), [](char c) { return std::isdigit(static_cast<unsigned char>(c)); })) {
            const auto h = std::atoi(w.c_str());
            return h >= 0 && h <= 23 ? h : -1;
        }
        if (w.find("dawn") != std::string::npos || w.find("sunrise") != std::string::npos) {
            return 6;
        }
        if (w.find("morning") != std::string::npos) {
            return 9;
        }
        if (w.find("noon") != std::string::npos || w.find("midday") != std::string::npos) {
            return 12;
        }
        if (w.find("afternoon") != std::string::npos) {
            return 15;
        }
        if (w.find("dusk") != std::string::npos || w.find("sunset") != std::string::npos) {
            return 18;
        }
        if (w.find("evening") != std::string::npos) {
            return 18;
        }
        if (w.find("night") != std::string::npos) {
            return 21;
        }
        return -1;
    }

    void Start() {
        const auto generation = ++g_generation;
        std::thread([generation]() {
            while (g_generation.load() == generation) {
                std::this_thread::sleep_for(std::chrono::seconds{ 3 });
                SKSE::GetTaskInterface()->AddTask([]() { Tick(); });
            }
        }).detach();
    }

    void Save(SKSE::SerializationInterface* a_intfc) {
        const std::scoped_lock lock{ g_lock };
        if (!a_intfc->OpenRecord(kRecordType, kRecordVersion)) {
            SKSE::log::error("Wedding plan: could not open the co-save record");
            return;
        }
        a_intfc->WriteRecordData(static_cast<std::uint32_t>(g_plans.size()));
        for (const auto& [id, p] : g_plans) {
            a_intfc->WriteRecordData(id);
            a_intfc->WriteRecordData(p.planner);
            a_intfc->WriteRecordData(p.day);
            a_intfc->WriteRecordData(p.hour);
            WriteString(a_intfc, p.place);
            a_intfc->WriteRecordData(p.officiant);
            a_intfc->WriteRecordData(static_cast<std::uint32_t>(p.guests.size()));
            for (const auto guest : p.guests) {
                a_intfc->WriteRecordData(guest);
            }
            a_intfc->WriteRecordData(p.parts);
            a_intfc->WriteRecordData(p.theirStyle);
            a_intfc->WriteRecordData(p.theirMetal);
            a_intfc->WriteRecordData(p.yourStyle);
            a_intfc->WriteRecordData(p.yourMetal);
            a_intfc->WriteRecordData(p.settled);
            a_intfc->WriteRecordData(static_cast<std::uint8_t>(p.outfit ? 1 : 0));
            a_intfc->WriteRecordData(static_cast<std::int32_t>(p.status));
            a_intfc->WriteRecordData(p.missedDay);
            a_intfc->WriteRecordData(p.lapsedDay);
        }
    }

    void Load(SKSE::SerializationInterface* a_intfc, std::uint32_t a_version) {
        const std::scoped_lock lock{ g_lock };
        g_plans.clear();
        if (a_version != 1 && a_version != kRecordVersion) {
            SKSE::log::warn("Wedding plan: co-save record version {} is not one this DLL reads; skipped", a_version);
            return;
        }
        const auto damaged = [&]() {
            SKSE::log::error("Wedding plan: the co-save record is damaged; no plans loaded");
            g_plans.clear();
        };
        const auto resolve = [&](std::uint32_t a_saved) -> std::uint32_t {
            RE::FormID now = 0;
            return a_saved && a_intfc->ResolveFormID(a_saved, now) ? now : 0;
        };
        std::uint32_t count = 0;
        if (a_intfc->ReadRecordData(count) != sizeof(count) || count > 10000) {
            return damaged();
        }
        for (std::uint32_t i = 0; i < count; ++i) {
            std::uint32_t id = 0;
            Plan          p;
            std::uint32_t guests = 0;
            std::uint8_t  outfit = 0;
            std::int32_t  status = 0;
            if (a_intfc->ReadRecordData(id) != sizeof(id) || a_intfc->ReadRecordData(p.planner) != sizeof(p.planner) ||
                a_intfc->ReadRecordData(p.day) != sizeof(p.day) || a_intfc->ReadRecordData(p.hour) != sizeof(p.hour) ||
                !ReadString(a_intfc, p.place) || a_intfc->ReadRecordData(p.officiant) != sizeof(p.officiant) ||
                a_intfc->ReadRecordData(guests) != sizeof(guests) || guests > kMaxGuests * 4) {
                return damaged();
            }
            for (std::uint32_t g = 0; g < guests; ++g) {
                std::uint32_t guest = 0;
                if (a_intfc->ReadRecordData(guest) != sizeof(guest)) {
                    return damaged();
                }
                if (const auto now = resolve(guest)) {
                    p.guests.push_back(now);
                }
            }
            if (a_intfc->ReadRecordData(p.parts) != sizeof(p.parts)) {
                return damaged();
            }
            if (a_version == 1) {
                // v1: the betrothed's wedding ring (the slim set, by its
                // metal), and the player's band (metal, 1 wide, 0 braided).
                // What was chosen counts as settled.
                std::int32_t ringMetal = -1, bandMetal = -1, bandWide = -1;
                if (a_intfc->ReadRecordData(ringMetal) != sizeof(ringMetal) ||
                    a_intfc->ReadRecordData(bandMetal) != sizeof(bandMetal) ||
                    a_intfc->ReadRecordData(bandWide) != sizeof(bandWide)) {
                    return damaged();
                }
                p.theirMetal = ringMetal;
                p.theirStyle = ringMetal >= 0 ? kSlim : -1;
                p.yourMetal = bandMetal;
                p.yourStyle = bandWide;
            } else if (a_intfc->ReadRecordData(p.theirStyle) != sizeof(p.theirStyle) ||
                       a_intfc->ReadRecordData(p.theirMetal) != sizeof(p.theirMetal) ||
                       a_intfc->ReadRecordData(p.yourStyle) != sizeof(p.yourStyle) ||
                       a_intfc->ReadRecordData(p.yourMetal) != sizeof(p.yourMetal) ||
                       a_intfc->ReadRecordData(p.settled) != sizeof(p.settled)) {
                return damaged();
            }
            if (a_intfc->ReadRecordData(outfit) != sizeof(outfit) || a_intfc->ReadRecordData(status) != sizeof(status) ||
                a_intfc->ReadRecordData(p.missedDay) != sizeof(p.missedDay) ||
                a_intfc->ReadRecordData(p.lapsedDay) != sizeof(p.lapsedDay)) {
                return damaged();
            }
            p.outfit = outfit != 0;
            if (a_version == 1) {
                if (!p.guests.empty()) {
                    p.settled |= kGuestsSettled;
                }
                if (p.outfit) {
                    p.settled |= kOutfitSettled;
                }
            }
            p.status = status == 1 ? Status::kUnderWay : Status::kPlanning;
            p.planner = resolve(p.planner);
            p.officiant = resolve(p.officiant);
            if (const auto now = resolve(id)) {
                g_plans[now] = std::move(p);
            }
        }
        SKSE::log::info("Wedding plan: {} plans loaded from the save", g_plans.size());
    }

    void Revert() {
        const std::scoped_lock lock{ g_lock };
        g_plans.clear();
    }
}
