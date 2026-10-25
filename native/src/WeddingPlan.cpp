#include "WeddingPlan.h"

#include "PCH.h"

#include "Ceremony.h"
#include "Marriage.h"
#include "Model.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cmath>
#include <map>
#include <mutex>
#include <thread>

namespace SNRom::WeddingPlan {

    namespace {

        using json = nlohmann::json;

        constexpr std::uint32_t kRecordVersion = 1;
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
        if (a_daysFromNow < 0 || a_daysFromNow > 365 || a_hour < 0 || a_hour > 23) {
            return false;
        }
        const std::scoped_lock lock{ g_lock };
        auto&                  plan = Make(a_betrothed);
        plan.day = std::floor(Now()) + static_cast<float>(a_daysFromNow);
        plan.hour = a_hour;
        plan.status = Status::kPlanning;
        return true;
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
        return std::erase(it->second.guests, a_guest) > 0;
    }

    bool SetParts(std::int32_t a_betrothed, std::uint32_t a_parts) {
        const std::scoped_lock lock{ g_lock };
        auto&                  plan = Make(a_betrothed);
        a_parts &= kAllParts;
        if (plan.parts == a_parts) {
            return false;
        }
        plan.parts = a_parts;
        return true;
    }

    bool SetRings(std::int32_t a_betrothed, std::int32_t a_ringMetal, std::int32_t a_bandMetal, std::int32_t a_bandWide) {
        const auto metal = [](std::int32_t a_m) { return a_m >= 0 && a_m <= 2 ? a_m : -1; };
        const std::scoped_lock lock{ g_lock };
        auto&                  plan = Make(a_betrothed);
        plan.ringMetal = metal(a_ringMetal);
        plan.bandMetal = metal(a_bandMetal);
        plan.bandWide = a_bandWide < 0 ? -1 : (a_bandWide ? 1 : 0);
        return true;
    }

    bool SetOutfit(std::int32_t a_betrothed, bool a_saved) {
        const std::scoped_lock lock{ g_lock };
        auto&                  plan = Make(a_betrothed);
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
        if (a_plan.day < 0.0f || a_plan.hour < 0) {
            open.emplace_back("day");
        }
        if (a_plan.place.empty()) {
            open.emplace_back("place");
        }
        if (!a_plan.officiant) {
            open.emplace_back("officiant");
        }
        return open;
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
        return { { "exists", 1 },
                 { "day", DayWords(*plan) },
                 { "place", plan->place },
                 { "officiant", NameOf(plan->officiant) },
                 { "guests", guests },
                 { "planner", NameOf(plan->planner) },
                 { "address", (plan->parts & kAddress) ? 1 : 0 },
                 { "reading", (plan->parts & kReading) ? 1 : 0 },
                 { "rings", (plan->parts & kRings) ? 1 : 0 },
                 { "kiss", (plan->parts & kKiss) ? 1 : 0 },
                 { "ring", MetalWord(plan->ringMetal) },
                 { "band", MetalWord(plan->bandMetal) },
                 { "bandWide", plan->bandWide },
                 { "outfit", plan->outfit ? 1 : 0 },
                 { "open", Open(*plan) },
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
                 { "ring", MetalWord(plan->ringMetal) },
                 { "band", MetalWord(plan->bandMetal) },
                 { "bandWide", plan->bandWide },
                 { "outfit", plan->outfit },
                 { "status", plan->status == Status::kUnderWay ? "underWay" : "planning" },
                 { "open", Open(*plan) },
                 { "missedDay", plan->missedDay >= 0.0f ? json(plan->missedDay) : json(nullptr) } };
    }

    RE::Actor* PersonNamed(const std::string& a_name) {
        const auto wanted = Lower(Trim(a_name));
        if (wanted.empty()) {
            return nullptr;
        }
        RE::Actor* partial = nullptr;
        const auto consider = [&](RE::Actor* a_actor) -> bool {
            if (!a_actor || a_actor->IsPlayerRef() || a_actor->IsDead()) {
                return false;
            }
            const char* name = a_actor->GetDisplayFullName();
            if (!name || !*name) {
                return false;
            }
            const auto lower = Lower(name);
            if (lower == wanted) {
                return true;
            }
            if (!partial && lower.starts_with(wanted)) {
                partial = a_actor;
            }
            return false;
        };
        if (auto* lists = RE::ProcessLists::GetSingleton()) {
            for (auto& handle : lists->highActorHandles) {
                if (auto actor = handle.get(); actor && consider(actor.get())) {
                    return actor.get();
                }
            }
        }
        for (const auto id : Model::Get().FormIds()) {
            if (auto* actor = RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(id)); consider(actor)) {
                return actor;
            }
        }
        return partial;
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
            a_intfc->WriteRecordData(p.ringMetal);
            a_intfc->WriteRecordData(p.bandMetal);
            a_intfc->WriteRecordData(p.bandWide);
            a_intfc->WriteRecordData(static_cast<std::uint8_t>(p.outfit ? 1 : 0));
            a_intfc->WriteRecordData(static_cast<std::int32_t>(p.status));
            a_intfc->WriteRecordData(p.missedDay);
            a_intfc->WriteRecordData(p.lapsedDay);
        }
    }

    void Load(SKSE::SerializationInterface* a_intfc, std::uint32_t a_version) {
        const std::scoped_lock lock{ g_lock };
        g_plans.clear();
        if (a_version != kRecordVersion) {
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
            if (a_intfc->ReadRecordData(p.parts) != sizeof(p.parts) ||
                a_intfc->ReadRecordData(p.ringMetal) != sizeof(p.ringMetal) ||
                a_intfc->ReadRecordData(p.bandMetal) != sizeof(p.bandMetal) ||
                a_intfc->ReadRecordData(p.bandWide) != sizeof(p.bandWide) ||
                a_intfc->ReadRecordData(outfit) != sizeof(outfit) || a_intfc->ReadRecordData(status) != sizeof(status) ||
                a_intfc->ReadRecordData(p.missedDay) != sizeof(p.missedDay) ||
                a_intfc->ReadRecordData(p.lapsedDay) != sizeof(p.lapsedDay)) {
                return damaged();
            }
            p.outfit = outfit != 0;
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
