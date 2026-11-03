#include "WeddingPlan.h"

#include "PCH.h"

#include "Ceremony.h"
#include "Family.h"
#include "Marriage.h"
#include "Model.h"
#include "Officiant.h"
#include "OurPlugin.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cctype>
#include <cmath>
#include <cstring>
#include <format>
#include <map>
#include <mutex>
#include <limits>
#include <optional>
#include <thread>

namespace SNRom::WeddingPlan {

    namespace {

        using json = nlohmann::json;

        // 2 (wpm51): the rings per person, and what is settled. 3 (wpm60):
        // what the place is by, and where people are sent. 4 (wpm61): each
        // guest's side, the place found, who has set out; and the venues. 5
        // (wpm62): a venue's marks counted, the betrothed's added. 6 (wpm68):
        // the reception under way. 7 (wpm69): each at it with their own mark.
        constexpr std::uint32_t kRecordVersion = 7;
        constexpr std::size_t   kMaxPlace = 120;
        constexpr std::size_t   kMaxGuests = 40;

        // THE DAY, in game days (Plan.day + hour / 24 is when). Everyone is
        // sent to the place this long before; and the day is missed once
        // this long has passed with no wedding (M4w). It begins AT THE HOUR
        // (seen in play, wpm59): allowed from an hour before, Danica began a
        // noon wedding the moment the player arrived at eleven, with no one
        // else come yet.
        constexpr float kSendAhead = 4.0f / 24.0f;
        constexpr float kMissedAfter = 6.0f / 24.0f;

        // Present for the wedding: the officiant within kHere of the player,
        // and the betrothed BESIDE them (seen in play, wpm59): Olfina, near
        // enough at 2000 to begin it, was not where the player stood, walked
        // on about her day, and the wedding ended as if she had left.
        constexpr float kHere = 2000.0f;
        constexpr float kBeside = 800.0f;

        // How far from the wedding a door may be to bring someone through.
        constexpr float kBringFrom = 4000.0f;

        // EVERYONE IN TIME (wpm61; the author, 2026-10-28: "we must ensure
        // everyone can reach the venue in time"). Each person sets out this
        // many hours before the hour: two, and an hour for every 8000 units
        // of road (straight-line, out of doors; a walk is nearer 16000, the
        // road winds), never less than kSendAhead nor more than 30. From
        // another worldspace a day; from nowhere that can be measured, half
        // of one. Looked at every kSendEvery ticks (30 s).
        constexpr float kUnitsPerHour = 8000.0f;
        constexpr float kLeadBase = 2.0f;
        constexpr float kLeadMost = 30.0f;
        constexpr float kLeadElsewhere = 24.0f;
        constexpr float kLeadUnmeasured = 12.0f;
        constexpr int   kSendEvery = 10;

        // Our plugin's SNRom_WeddingMark, and the packages taken to a mark
        // (SNRom_Integration.esl; docs: copies of Skyrim's own sandbox
        // package, near the reference linked with our keyword, with eating,
        // sleeping and work furniture switched off). The stand is the same
        // within 128 units: it was HoldPosition until wpm64, which holds
        // wherever they already are and never walks them there.
        constexpr RE::FormID kMarkKeyword = 0xD89;
        constexpr RE::FormID kXMarkerHeading = 0x34;   // Skyrim.esm
        constexpr const char* kStand = "SNRom_WeddingStand";                // 128, the officiant and the betrothed
        constexpr const char* kGatherSmall = "SNRom_WeddingGatherSmall";    // 300 units, up to 4 people
        constexpr const char* kGatherMedium = "SNRom_WeddingGatherMedium";  // 500, up to 10
        constexpr const char* kGatherLarge = "SNRom_WeddingGatherLarge";    // 800, more

        constexpr std::array<const char*, kMarkRoles> kRoleWords{ "officiant", "you", "theirs", "yours", "betrothed" };

        std::mutex                         g_lock;
        std::map<std::uint32_t, Plan>      g_plans;  // betrothed -> plan
        std::map<std::string, Venue>       g_venues; // VenueKey -> venue
        bool                               g_relink = false;  // links to set again (a load, a new mark)
        int                                g_sendTicks = 0;
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

        // THE USUAL RING (the author, 2026-11-03): "Default to male characters
        // using the wide wedding band and female characters using the slim
        // engagement/wedding band combo unless the user explicitly expresses
        // otherwise." A style nobody chose is this one, everywhere the plan
        // is read: the prompts, the dashboard, the wedding.
        std::int32_t UsualStyle(std::uint32_t a_formId) {
            auto* form = a_formId ? RE::TESForm::LookupByID(a_formId) : nullptr;
            auto* actor = form ? form->As<RE::Actor>() : nullptr;
            auto* base = actor ? actor->GetActorBase() : nullptr;
            return base && base->GetSex() == RE::SEX::kFemale ? kSlim : kWide;
        }

        std::int32_t StyleOf(std::int32_t a_chosen, std::uint32_t a_wearer) {
            return a_chosen >= 0 ? a_chosen : UsualStyle(a_wearer);
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

        // How many single-letter edits turn one word into the other (a
        // misspelled name among a person's few relatives: "Eordlund").
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
                    row[j] = std::min({ row[j] + 1, row[j - 1] + 1, diagonal + (a_a[i - 1] == a_b[j - 1] ? 0 : 1) });
                    diagonal = above;
                }
            }
            return row[a_b.size()];
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

        bool Present(RE::PlayerCharacter* a_player, std::uint32_t a_id, float a_within) {
            auto* actor = a_id ? RE::TESForm::LookupByID<RE::Actor>(a_id) : nullptr;
            return actor && !actor->IsDead() && actor->Is3DLoaded() &&
                   actor->GetPosition().GetDistance(a_player->GetPosition()) <= a_within;
        }

        // A VENUE'S KEY: the place's name in lower case, without a leading
        // "the", "under", "at"..., so "the Gildergreen", "under the
        // Gildergreen" and "Gildergreen" are the one venue.
        std::string VenueKey(const std::string& a_place) {
            static constexpr std::array<const char*, 10> kLead{ "the ", "under ", "beneath ", "below ", "at ",
                                                                "by ",  "near ",  "in ",      "on ",    "beside " };
            auto key = Lower(Trim(a_place));
            for (bool again = true; again;) {
                again = false;
                for (const auto* word : kLead) {
                    if (key.starts_with(word)) {
                        key.erase(0, std::strlen(word));
                        again = true;
                    }
                }
            }
            return key;
        }

        RE::TESObjectREFR* RefOf(std::uint32_t a_id) {
            auto* ref = a_id ? RE::TESForm::LookupByID<RE::TESObjectREFR>(a_id) : nullptr;
            return ref && !ref->IsDeleted() ? ref : nullptr;
        }

        // THE SPOT AS SAID (wpm86), for the marks being made now (UseSpot).
        std::mutex                     g_spotLock;
        std::optional<WeddingPlan::Spot> g_spot;
        // Farther than this from where they said it, and they have gone
        // elsewhere since: the mark is where they stand.
        constexpr float kSpotFrom = 4096.0f;

        // A marker where the player said "here" (the spot in use), else where
        // they stand. Main thread or a VM thread.
        RE::NiPointer<RE::TESObjectREFR> PlaceMarker() {
            auto* player = RE::PlayerCharacter::GetSingleton();
            auto* marker = RE::TESForm::LookupByID<RE::TESBoundObject>(kXMarkerHeading);
            if (!player || !marker) {
                return {};
            }
            auto placed = player->PlaceObjectAtMe(marker, true);
            std::optional<WeddingPlan::Spot> spot;
            {
                const std::scoped_lock lock{ g_spotLock };
                spot = g_spot;
            }
            auto*      cell = player->GetParentCell();
            auto*      world = player->GetWorldspace();
            const bool same = spot && (world ? world->GetFormID() == spot->world
                                             : cell && cell->GetFormID() == spot->cell);
            if (placed && same && spot->at.GetDistance(player->GetPosition()) <= kSpotFrom) {
                // As Papyrus's SetPosition: within the world it is in.
                placed->SetAngle(RE::NiPoint3{ 0.0f, 0.0f, spot->angle });
                placed->SetPosition(spot->at);
                // TEST LOG (wpm86).
                SKSE::log::info("Venue: marked where the player said it, {:.0f} from where they stand now",
                                spot->at.GetDistance(player->GetPosition()));
            }
            return placed;
        }

        // The nearest place on the map to a_ref, by its marker; else the
        // location it is in. Main thread or a VM thread.
        std::string NearestNamed(RE::TESObjectREFR* a_ref) {
            std::string best;
            float       nearest = std::numeric_limits<float>::max();
            auto* cell = a_ref ? a_ref->GetParentCell() : nullptr;
            if (auto* tes = RE::TES::GetSingleton(); tes && cell && !cell->IsInteriorCell()) {
                const auto origin = a_ref->GetPosition();
                tes->ForEachReferenceInRange(a_ref, 30000.0f, [&](RE::TESObjectREFR* a_other) {
                    auto*       extra = a_other ? a_other->extraList.GetByType<RE::ExtraMapMarker>() : nullptr;
                    const char* name = extra && extra->mapData ? extra->mapData->locationName.GetFullName() : nullptr;
                    if (name && *name) {
                        if (const float d = a_other->GetPosition().GetDistance(origin); d < nearest) {
                            nearest = d;
                            best = name;
                        }
                    }
                    return RE::BSContainer::ForEachResult::kContinue;
                });
            }
            if (best.empty()) {
                auto*       player = RE::PlayerCharacter::GetSingleton();
                auto*       location = player ? player->GetCurrentLocation() : nullptr;
                const char* name = location ? location->GetFullName() : nullptr;
                best = name ? name : "";
            }
            return best;
        }

        // "here", "right here", "this spot"..., and the words for it after a
        // colon or a dash: nothing when a_said is no place here.
        std::optional<std::string> HereWords(const std::string& a_said) {
            auto       text = Trim(a_said);
            std::string tail;
            for (const auto* sep : { ":", " - ", " -- ", "\xE2\x80\x94" }) {
                if (const auto at = text.find(sep); at != std::string::npos) {
                    tail = Trim(text.substr(at + std::strlen(sep)));
                    text = Trim(text.substr(0, at));
                    break;
                }
            }
            auto head = Lower(text);
            for (bool again = true; again;) {
                again = false;
                for (const auto* lead : { "right ", "just ", "on ", "at ", "in ", "it is ", "it's ", "the wedding is " }) {
                    if (head.starts_with(lead)) {
                        head.erase(0, std::strlen(lead));
                        again = true;
                    }
                }
            }
            static constexpr std::array<const char*, 12> kHereWords{
                "here",           "this spot",        "this place",   "this very spot", "this one",  "where we stand",
                "where we are",   "where we're standing", "where we are standing", "this exact spot", "the spot here",
                "where i stand"
            };
            if (std::ranges::find(kHereWords, head) != kHereWords.end() || head.starts_with("here ") ||
                head.starts_with("here,") || head.starts_with("right where")) {
                return tail;
            }
            return std::nullopt;
        }

        // The plan's marks, each 0 when unmarked or gone. Under g_lock.
        std::array<std::uint32_t, kMarkRoles> MarksOf(const Plan& a_plan) {
            std::array<std::uint32_t, kMarkRoles> out{};
            if (const auto it = g_venues.find(VenueKey(a_plan.place)); it != g_venues.end()) {
                for (std::size_t i = 0; i < out.size(); ++i) {
                    out[i] = RefOf(it->second.marks[i]) ? it->second.marks[i] : 0;
                }
            }
            return out;
        }

        std::uint32_t MarkedBits(const Plan& a_plan) {
            std::uint32_t bits = 0;
            const auto    marks = MarksOf(a_plan);
            for (std::size_t i = 0; i < marks.size(); ++i) {
                if (marks[i]) {
                    bits |= 1u << i;
                }
            }
            return bits;
        }

        RE::BGSKeyword* MarkKeyword() {
            return OurForm<RE::BGSKeyword>(kMarkKeyword);
        }

        // Someone linked to their mark with our keyword, or the link cleared
        // (a_at 0), and their packages looked at again. Main thread.
        void Link(RE::Actor* a_who, RE::TESObjectREFR* a_at) {
            auto* keyword = MarkKeyword();
            if (!a_who || !keyword) {
                return;
            }
            a_who->extraList.SetLinkedRef(a_at, keyword);
            a_who->EvaluatePackage();
        }

        // TESObjectREFR::MoveTo_Impl, private in CommonLib: a_who moved into
        // a_ref's cell, at a position and rotation of our own. Main thread.
        void PutAt(RE::Actor* a_who, RE::TESObjectREFR* a_ref, const RE::NiPoint3& a_at, const RE::NiPoint3& a_rotation) {
            using func_t = void(RE::TESObjectREFR*, const RE::ObjectRefHandle&, RE::TESObjectCELL*,
                                RE::TESWorldSpace*, const RE::NiPoint3&, const RE::NiPoint3&);
            static REL::Relocation<func_t> moveTo{ RELOCATION_ID(56227, 56626) };
            moveTo(a_who, a_ref->CreateRefHandle(), a_ref->GetParentCell(), a_ref->GetWorldspace(), a_at, a_rotation);
        }

        // a_a where a_b is: the one cell indoors, the one worldspace out.
        bool SameSpace(RE::TESObjectREFR* a_a, RE::TESObjectREFR* a_b) {
            auto* cell = a_b->GetParentCell();
            if (cell && cell->IsInteriorCell()) {
                return a_a->GetParentCell() == cell;
            }
            auto* world = a_b->GetWorldspace();
            return world && a_a->GetWorldspace() == world;
        }

        float Across(const RE::NiPoint3& a_a, const RE::NiPoint3& a_b) {
            return std::hypot(a_a.x - a_b.x, a_a.y - a_b.y);
        }

        // The heading that faces a_to from a_from (0 is north, clockwise).
        float HeadingTo(const RE::NiPoint3& a_from, const RE::NiPoint3& a_to) {
            return std::atan2(a_to.x - a_from.x, a_to.y - a_from.y);
        }

        // On the screen now: a_at at head height projects inside the view.
        // Walls are not looked at, so a spot behind one counts as seen.
        bool OnScreen(const RE::NiPoint3& a_at) {
            auto* camera = RE::Main::WorldRootCamera();
            if (!camera) {
                return false;
            }
            float x = -1.0f;
            float y = -1.0f;
            float z = -1.0f;
            camera->WorldPtToScreenPt3({ a_at.x, a_at.y, a_at.z + 100.0f }, x, y, z, 1e-5f);
            return z > 0.0f && x >= 0.0f && x <= 1.0f && y >= 0.0f && y <= 1.0f;
        }

        // THE LATE ONES (wpm65; the author, 2026-10-30). Skyrim moves no one
        // far while they are not loaded: Kayla and Elisif, sent a day ahead,
        // never came until the player summoned them. So from an hour before,
        // whoever set out and is not loaded within kOnTheirWay of their mark
        // is summoned ONTO it - the one spot known to be ground, because the
        // player stood there (a cliff's edge a step away is not). Unseen when
        // the player is away from the venue or the mark is off the screen; at
        // the hour, seen or not: the ceremony comes before the illusion. One
        // to a mark each look, so a crowd never lands on one spot. A place
        // found rather than marked is a door's other side: brought to it.
        constexpr float kSummonAhead = 1.0f / 24.0f;
        constexpr float kOnTheirWay = 2000.0f;
        constexpr float kSeenFrom = 8000.0f;
        std::vector<std::uint32_t> g_summoned;  // who was, this session; under g_lock

        // STOPPED SHORT (wpm67; the author, 2026-10-31: "have Danica offer to
        // begin again instead"). A planned wedding that stalled, or met a no,
        // does not begin again by itself: in wpm65 one began from the top two
        // seconds after the last went round until it stalled. The officiant
        // knows (OfficiatingFor) and may offer; MarriageBless begins it again.
        // Someone walking off still brings it back at the hour, as before.
        // The betrothed of each such day; this session, under g_lock.
        std::vector<std::uint32_t> g_stoppedShort;

        // THE RECEPTION (wpm68; the author, 2026-10-31: everyone should
        // "sandbox in the area for a while, probably 2 hours, to emulate them
        // socializing with one another and giving the couple a chance to talk
        // to them before they disperse"). A planned wedding that ends married
        // keeps everyone who set out for it at the place, gathered wide around
        // the couple's mark, for kReceptionHours; then they go their ways.
        // Kept in the co-save (v6), so a load in the middle still ends it.
        // Under g_lock.
        // EACH AROUND THEIR OWN MARK (seen in play, wpm68): around the
        // couple's, all seventeen walked in on the altar as the rings were
        // given. So each mingles about where they stood for it - each side
        // at its own mark - and at only for anyone without one.
        struct Reception {
            std::vector<std::uint32_t> who;
            std::vector<std::uint32_t> atEach;        // who[i]'s mark, 0 for at
            std::uint32_t              at = 0;
            bool                       ours = false;  // a marker placed for it, removed after
            float                      until = 0.0f;  // game days

            RE::TESObjectREFR* AtOf(std::size_t a_i) const {
                auto* own = a_i < atEach.size() ? RefOf(atEach[a_i]) : nullptr;
                return own ? own : RefOf(at);
            }
        };
        std::optional<Reception> g_reception;
        constexpr float          kReceptionHours = 2.0f;

        // EACH TO THEIR PLACE (wpm65; the author, 2026-10-30: "When the
        // ceremony begins, they should go to the mark and stand still,
        // facing the couple"). The officiant and the betrothed to their own
        // marks; each guest who came to a place of their own, in rows of
        // kPerRow at their side's mark, facing the couple. They WALK there
        // (SNRom_WeddingPlace, a PapyrusUtil override, which SkyrimNet's hold
        // does not stop), so a place over an edge leaves them at the nearest
        // ground they can reach. Settled when there, or when kGiveUpAfter
        // looks bring them no nearer: turned to face the couple, and held
        // still by Papyrus (SNRom_WeddingInPlace). Main thread only.
        struct Place {
            std::uint32_t who = 0;
            std::uint32_t at = 0;      // their mark, or a marker of ours
            bool          ours = false;
            RE::NiPoint3  faceTo;
            const char*   role = "";   // "officiant", "betrothed", "theirs", "yours"
            float         best = -1.0f;
            int           still = 0;
            bool          settled = false;
        };
        std::vector<Place>    g_places;
        constexpr float       kInPlace = 80.0f;
        constexpr int         kGiveUpAfter = 5;    // looks, 3 s apart
        constexpr std::size_t kPerRow = 4;
        constexpr float       kSideBySide = 90.0f;
        constexpr float       kRowBehind = 100.0f;

        // WHERE SOMEONE IS, OUT OF DOORS: where they stand, or inside, the
        // door out of their cell. Nothing for a cell with no door outside.
        struct Outside {
            RE::TESWorldSpace* world = nullptr;
            RE::NiPoint3       at;
        };
        std::optional<Outside> OutdoorsOf(RE::TESObjectREFR* a_ref) {
            auto* cell = a_ref ? a_ref->GetParentCell() : nullptr;
            if (!cell || !cell->IsInteriorCell()) {
                auto* world = a_ref ? a_ref->GetWorldspace() : nullptr;
                return world ? std::optional<Outside>{ Outside{ world, a_ref->GetPosition() } } : std::nullopt;
            }
            std::optional<Outside> out;
            cell->ForEachReference([&](RE::TESObjectREFR* a_door) {
                auto* here = a_door ? a_door->extraList.GetByType<RE::ExtraTeleport>() : nullptr;
                auto  other = here && here->teleportData ? here->teleportData->linkedDoor.get() : nullptr;
                auto* world = other ? other->GetWorldspace() : nullptr;
                if (world) {
                    out = Outside{ world, other->GetPosition() };
                    return RE::BSContainer::ForEachResult::kStop;
                }
                return RE::BSContainer::ForEachResult::kContinue;
            });
            return out;
        }

        // How long before the hour a_who sets out for a_to, in game days;
        // a_distance the straight-line distance out of doors, -1 unmeasured.
        float LeadFor(RE::TESObjectREFR* a_who, RE::TESObjectREFR* a_to, float& a_distance) {
            a_distance = -1.0f;
            const auto from = OutdoorsOf(a_who);
            const auto to = OutdoorsOf(a_to);
            float      hours = kLeadUnmeasured;
            if (from && to && from->world == to->world) {
                a_distance = from->at.GetDistance(to->at);
                hours = kLeadBase + a_distance / kUnitsPerHour;
            } else if (from && to) {
                hours = kLeadElsewhere;
            }
            return std::clamp(hours, kSendAhead * 24.0f, kLeadMost) / 24.0f;
        }

        // WHERE EACH ONE GOES (wpm61): the officiant to their mark, the
        // betrothed to the couple's, each guest to their side's; a mark not
        // made, the next that is (docs: the couple's, then the officiant's,
        // then the place found). A guest whose side is not known is the
        // player's when they have a bond with the player; otherwise, or when
        // they are both's, they join the smaller side. How many share a mark decides how
        // wide they gather. Empty when there is nowhere to send anyone.
        // Under g_lock.
        struct Goal {
            std::uint32_t who = 0;
            std::uint32_t at = 0;
            const char*   where = "";
            const char*   package = kStand;
        };
        // a_bonds: everyone with a bond with the player (Model::FormIds, read
        // before g_lock is taken).
        std::vector<Goal> GoalsOf(std::uint32_t a_betrothed, const Plan& a_plan, const std::vector<std::int32_t>& a_bonds) {
            static constexpr std::array<const char*, kMarkRoles + 1> kWhere{
                "the officiant's mark", "the player's mark",    "their guests' mark",
                "your guests' mark",    "the betrothed's mark", "the place found"
            };
            const auto marks = MarksOf(a_plan);
            std::array<std::uint32_t, kMarkRoles + 1> at{};
            std::copy(marks.begin(), marks.end(), at.begin());
            at[kMarkRoles] = RefOf(a_plan.anchor) ? a_plan.anchor : 0;
            const auto first = [&](std::initializer_list<std::size_t> a_order) {
                for (const auto i : a_order) {
                    if (at[i]) {
                        return i;
                    }
                }
                return at.size();
            };
            std::vector<Goal> out;
            const auto        add = [&](std::uint32_t a_who, std::size_t a_at, const char* a_package) {
                if (a_who && a_at < at.size()) {
                    out.push_back({ a_who, at[a_at], kWhere[a_at], a_package });
                }
            };
            add(a_plan.officiant, first({ kMarkOfficiant, kMarkYou, kMarkBetrothed, kMarkRoles }), kStand);
            add(a_betrothed, first({ kMarkBetrothed, kMarkYou, kMarkOfficiant, kMarkRoles }), kStand);
            const std::array<std::size_t, 2> sideAt{
                first({ kMarkTheirs, kMarkYou, kMarkBetrothed, kMarkOfficiant, kMarkRoles }),
                first({ kMarkYours, kMarkYou, kMarkBetrothed, kMarkOfficiant, kMarkRoles })
            };
            std::array<std::vector<std::uint32_t>, 2> side;
            std::vector<std::uint32_t>                either;
            for (const auto guest : a_plan.guests) {
                if (guest == a_plan.officiant) {
                    continue;
                }
                const auto it = a_plan.sides.find(guest);
                const auto s = it == a_plan.sides.end() ? kSideUnknown : it->second;
                if (s == kSideTheirs || s == kSideYours) {
                    side[s].push_back(guest);
                } else {
                    either.push_back(guest);
                }
            }
            for (const auto guest : either) {
                // NO SIDE SAID (wpm66; the author, 2026-10-31): someone with a
                // bond with the player is the player's guest. Camilla and
                // Tormir, the player's friends, stood with Olfina's family,
                // which was the smaller side. Anyone else, and anyone who is
                // both's, joins the smaller side.
                const auto it = a_plan.sides.find(guest);
                if ((it == a_plan.sides.end() || it->second == kSideUnknown) &&
                    std::ranges::find(a_bonds, static_cast<std::int32_t>(guest)) != a_bonds.end()) {
                    side[kSideYours].push_back(guest);
                    continue;
                }
                side[side[0].size() <= side[1].size() ? 0 : 1].push_back(guest);
            }
            std::map<std::size_t, std::size_t> sharing;
            for (std::size_t s = 0; s < 2; ++s) {
                sharing[sideAt[s]] += side[s].size();
            }
            for (std::size_t s = 0; s < 2; ++s) {
                const auto n = sharing[sideAt[s]];
                for (const auto guest : side[s]) {
                    add(guest, sideAt[s], n <= 4 ? kGatherSmall : n <= 10 ? kGatherMedium : kGatherLarge);
                }
            }
            return out;
        }

        // Main thread, every few seconds while a game is loaded.
        void Tick() {
            auto* player = RE::PlayerCharacter::GetSingleton();
            auto* ui = RE::UI::GetSingleton();
            if (!player || !player->Is3DLoaded() || (ui && ui->GameIsPaused())) {
                return;
            }
            const auto bonds = Model::Get().FormIds();
            const float now = Now();
            struct Due {
                std::uint32_t betrothed;
                const char*   event;
                std::string   text;
            };
            std::vector<Due> due;
            struct Going {
                Goal  goal;
                float distance = -1.0f;
                float lead = 0.0f;
                bool  again = false;  // already on their way: linked again only
            };
            std::vector<Going>        going;
            std::vector<std::uint32_t> letGo;
            struct Late {
                Goal goal;
                bool hour = false;   // the hour has come
                bool found = false;  // a place found, not marked
            };
            std::vector<Late> late;
            std::uint32_t            receptionMarker = 0;  // ours, to remove
            std::optional<Reception> receptionAgain;       // to link again
            // The day will not come after all: no one goes on waiting for it.
            const auto recall = [&](std::uint32_t a_id, Plan& a_plan) {
                std::erase(g_stoppedShort, a_id);
                if (!a_plan.sent.empty()) {
                    letGo.insert(letGo.end(), a_plan.sent.begin(), a_plan.sent.end());
                    a_plan.sent.clear();
                    due.push_back({ a_id, "SNRom_WeddingRecall", "" });
                }
            };
            {
                const std::scoped_lock lock{ g_lock };
                for (auto it = g_plans.begin(); it != g_plans.end();) {
                    const auto id = it->first;
                    auto&      plan = it->second;
                    // Married, broken off, or gone: the plan goes with them.
                    if (!Marriage::Engaged(static_cast<std::int32_t>(id))) {
                        SKSE::log::info("Wedding plan: {:08X} is no longer engaged; their plan is gone", id);
                        recall(id, plan);
                        it = g_plans.erase(it);
                        continue;
                    }
                    ++it;
                    // Wed by a ceremony just now: the rest is the reception's.
                    if (plan.day < 0.0f || Ceremony::JustWed(id)) {
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
                            recall(id, plan);
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
                        recall(id, plan);
                        due.push_back({ id, "SNRom_WeddingMissed", "" });
                        continue;
                    }
                    if (now >= when && std::ranges::find(g_stoppedShort, id) == g_stoppedShort.end() &&
                        Present(player, id, kBeside) && Present(player, plan.officiant, kHere) &&
                        std::chrono::steady_clock::now() - g_beginSentAt > std::chrono::seconds{ 30 }) {
                        g_beginSentAt = std::chrono::steady_clock::now();
                        due.push_back({ id, "SNRom_WeddingBegin", "" });
                    }
                }
                // WHO SETS OUT NOW (wpm61): each one ready plan's people, by
                // how far they have to come; and after a load or a new mark,
                // those already on their way are linked again.
                const bool relink = std::exchange(g_relink, false);
                if (++g_sendTicks >= kSendEvery || relink) {
                    g_sendTicks = 0;
                    for (auto& [id, plan] : g_plans) {
                        if (plan.day < 0.0f || !Open(plan).empty() || Ceremony::JustWed(id)) {
                            continue;
                        }
                        const float when = When(plan);
                        for (const auto& goal : GoalsOf(id, plan, bonds)) {
                            if (std::ranges::find(plan.sent, goal.who) != plan.sent.end()) {
                                if (relink) {
                                    going.push_back({ goal, -1.0f, 0.0f, true });
                                }
                                continue;
                            }
                            auto* who = RE::TESForm::LookupByID<RE::Actor>(goal.who);
                            auto* to = RefOf(goal.at);
                            if (!who || who->IsDead() || !to) {
                                continue;
                            }
                            float      distance = -1.0f;
                            const auto lead = LeadFor(who, to, distance);
                            if (now >= when - lead) {
                                plan.sent.push_back(goal.who);
                                going.push_back({ goal, distance, lead, false });
                            }
                        }
                    }
                }
                // THE LATE ONES (wpm65): looked at every tick from an hour before.
                if (Ceremony::Now() == 0) {
                    for (auto& [id, plan] : g_plans) {
                        if (plan.status != Status::kUnderWay || plan.day < 0.0f || Ceremony::JustWed(id) ||
                            now < When(plan) - kSummonAhead) {
                            continue;
                        }
                        for (const auto& goal : GoalsOf(id, plan, bonds)) {
                            if (std::ranges::find(plan.sent, goal.who) != plan.sent.end() &&
                                std::ranges::find(g_summoned, goal.who) == g_summoned.end()) {
                                late.push_back({ goal, now >= When(plan), goal.at == plan.anchor });
                            }
                        }
                    }
                }
                // THE RECEPTION (wpm68): over at its hour, everyone their own
                // way; after a load, everyone at it linked again.
                if (g_reception && now >= g_reception->until) {
                    letGo.insert(letGo.end(), g_reception->who.begin(), g_reception->who.end());
                    if (g_reception->ours) {
                        receptionMarker = g_reception->at;
                    }
                    due.push_back({ 0, "SNRom_WeddingRecall", "" });
                    SKSE::log::info("Wedding: the reception is over; {} go their ways", g_reception->who.size());
                    g_reception.reset();
                } else if (g_reception && relink) {
                    receptionAgain = *g_reception;
                }
            }
            for (const auto id : letGo) {
                Link(RE::TESForm::LookupByID<RE::Actor>(id), nullptr);
            }
            if (auto* marker = RefOf(receptionMarker)) {
                marker->Disable();
                marker->SetDelete(true);
            }
            if (receptionAgain) {
                for (std::size_t i = 0; i < receptionAgain->who.size(); ++i) {
                    Link(RE::TESForm::LookupByID<RE::Actor>(receptionAgain->who[i]), receptionAgain->AtOf(i));
                }
            }
            for (const auto& g : going) {
                auto* who = RE::TESForm::LookupByID<RE::Actor>(g.goal.who);
                auto* to = RefOf(g.goal.at);
                if (!who || !to) {
                    continue;
                }
                Link(who, to);
                if (g.again) {
                    SKSE::log::info("Wedding: {} is linked again to {}", who->GetDisplayFullName(), g.goal.where);
                    continue;
                }
                // TEST LOG (wpm61): who set out, from how far, how early.
                SKSE::log::info("Wedding: {} sets out for {} ({}), {}, {:.1f} h before the hour",
                                who->GetDisplayFullName(), g.goal.where, g.goal.package,
                                g.distance >= 0.0f ? std::format("{:.0f} away", g.distance) : std::string("distance unknown"),
                                g.lead * 24.0f);
                Send("SNRom_WeddingGo", g.goal.package, g.lead * 24.0f, g.goal.who);
            }
            std::vector<std::uint32_t> landedOn;   // marks used this look
            for (const auto& l : late) {
                auto* who = RE::TESForm::LookupByID<RE::Actor>(l.goal.who);
                auto* to = RefOf(l.goal.at);
                if (!who || !to || who->IsDead() || who->IsDisabled() ||
                    std::ranges::find(landedOn, l.goal.at) != landedOn.end()) {
                    continue;
                }
                const bool  sameSpace = SameSpace(who, to);
                const float from = sameSpace ? who->GetPosition().GetDistance(to->GetPosition()) : -1.0f;
                if (who->Is3DLoaded() && sameSpace && from <= kOnTheirWay) {
                    continue;   // there, or walking in
                }
                auto*       venue = to->GetParentCell();
                const bool  away = !SameSpace(player, to) || !venue || !venue->IsAttached() ||
                                   player->GetPosition().GetDistance(to->GetPosition()) > kSeenFrom;
                const char* how = away                            ? "while the player was away" :
                                  !OnScreen(to->GetPosition())    ? "out of the player's sight" :
                                  l.hour                          ? "at the hour, in the player's sight" :
                                                                    nullptr;
                if (!how) {
                    continue;
                }
                landedOn.push_back(l.goal.at);
                {
                    const std::scoped_lock lock{ g_lock };
                    g_summoned.push_back(l.goal.who);
                }
                // TEST LOG (wpm65): who was summoned, from how far, and how.
                SKSE::log::info("Wedding: {} summoned {} to {}, from {}", who->GetDisplayFullName(), how, l.goal.where,
                                from >= 0.0f ? std::format("{:.0f} away", from) : std::string("elsewhere"));
                if (l.found) {
                    BringBeside(who, to);
                } else {
                    PutAt(who, to, to->GetPosition(), to->data.angle);
                    who->EvaluatePackage();
                }
            }
            for (auto& p : g_places) {
                auto* who = p.settled ? nullptr : RE::TESForm::LookupByID<RE::Actor>(p.who);
                auto* at = who ? RefOf(p.at) : nullptr;
                if (!who || !at || who->IsDead() || !who->Is3DLoaded()) {
                    continue;
                }
                // Still on a bench or a stool is not in place (wpm66): held
                // still there, they would watch the vows sitting down.
                const auto* state = who->AsActorState();
                const bool  seated = state && state->GetSitSleepState() != RE::SIT_SLEEP_STATE::kNormal;
                const float off = Across(who->GetPosition(), at->GetPosition());
                if (off > kInPlace || seated) {
                    if (!seated && (p.best < 0.0f || off < p.best - 16.0f)) {
                        p.best = off;
                        p.still = 0;
                        continue;
                    }
                    if (++p.still < kGiveUpAfter) {
                        continue;
                    }
                }
                p.settled = true;
                who->SetHeading(HeadingTo(who->GetPosition(), p.faceTo));
                // TEST LOG (wpm65): who settled where.
                SKSE::log::info("Wedding: {} in their place ({}), {:.0f} from it{}", who->GetDisplayFullName(), p.role,
                                off, seated ? ", still seated" : "");
                Send("SNRom_WeddingInPlace", p.role, 0.0f, p.who);
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

    bool SetPlace(std::int32_t a_betrothed, std::string a_place, std::string a_near) {
        a_place = Trim(std::move(a_place));
        a_near = Trim(std::move(a_near));
        a_place.resize(std::min(a_place.size(), kMaxPlace));
        a_near.resize(std::min(a_near.size(), kMaxPlace));
        std::unique_lock lock{ g_lock };
        auto&            plan = Make(a_betrothed);
        const bool       newPlace = !a_place.empty() && plan.place != a_place;
        if (!newPlace && (a_near.empty() || plan.nearTo == a_near)) {
            return false;
        }
        // A SPOT CHOSEN STANDS (wpm86): what it is by, said afterwards, would
        // have it looked for by that name and everyone sent to "The Reach".
        if (!newPlace && plan.findable == 2) {
            return false;
        }
        const std::uint32_t oldSpot = newPlace && plan.findable == 2 ? plan.anchor : 0;
        if (newPlace) {
            // Marks made before the place had a name are this place's.
            const auto pending = g_venues.find(VenueKey(plan.place));
            if (pending != g_venues.end() && pending->first.empty()) {
                auto& venue = g_venues[VenueKey(a_place)];
                if (std::ranges::all_of(venue.marks, [](std::uint32_t a_mark) { return a_mark == 0; })) {
                    venue.name = a_place;
                    venue.marks = pending->second.marks;
                    g_venues.erase(pending);
                }
            }
            plan.place = std::move(a_place);
            plan.nearTo = std::move(a_near);
            if (const auto bits = MarkedBits(plan)) {
                SKSE::log::info("Venue '{}' is known: {} of its {} marks made", VenueKey(plan.place),
                                std::popcount(bits), static_cast<int>(kMarkRoles));
            }
        } else {
            plan.nearTo = std::move(a_near);
        }
        plan.travelTo.clear();
        plan.findable = -1;
        plan.anchor = 0;
        g_relink = true;
        lock.unlock();
        if (auto* gone = RefOf(oldSpot)) {
            gone->Disable();
            gone->SetDelete(true);
        }
        return true;
    }

    std::optional<Spot> PlayerSpot() {
        auto* player = RE::PlayerCharacter::GetSingleton();
        auto* cell = player ? player->GetParentCell() : nullptr;
        if (!cell) {
            return std::nullopt;
        }
        auto* world = player->GetWorldspace();
        return Spot{ player->GetPosition(), player->GetAngleZ(), cell->GetFormID(), world ? world->GetFormID() : 0 };
    }

    void UseSpot(std::optional<Spot> a_spot) {
        const std::scoped_lock lock{ g_spotLock };
        g_spot = a_spot;
    }

    std::int32_t SetPlaceHere(std::int32_t a_betrothed, const std::string& a_said, bool a_always) {
        auto words = HereWords(a_said);
        if (!words && !a_always) {
            return 0;
        }
        auto placed = PlaceMarker();
        if (!placed) {
            SKSE::log::warn("Wedding plan: no marker could be placed for a place here");
            return -1;
        }
        const auto by = NearestNamed(placed.get());
        // Named by its own words when it was given some ("the crag above
        // Karthwasten"); a_always (the dashboard) by what it was given.
        std::string given = words ? *words : Trim(a_said);
        if (HereWords(given)) {
            given.clear();
        }
        std::string   name;
        std::uint32_t old = 0;
        {
            const std::scoped_lock lock{ g_lock };
            auto&                  plan = Make(a_betrothed);
            // "Right here" again, unnamed: the same spot moved, its name and
            // marks kept.
            name = !given.empty()                            ? given :
                   plan.findable == 2 && !plan.place.empty() ? plan.place :
                   by.empty()                                ? std::string("the spot they chose") :
                                                               "the spot they chose near " + by;
            name.resize(std::min(name.size(), kMaxPlace));
            if (plan.place != name) {
                // Marks made before the place had a name are this place's.
                const auto pending = g_venues.find(VenueKey(plan.place));
                if (pending != g_venues.end() && pending->first.empty()) {
                    auto& venue = g_venues[VenueKey(name)];
                    if (std::ranges::all_of(venue.marks, [](std::uint32_t a_mark) { return a_mark == 0; })) {
                        venue.name = name;
                        venue.marks = pending->second.marks;
                        g_venues.erase(pending);
                    }
                }
            }
            old = plan.findable == 2 ? plan.anchor : 0;
            plan.place = name;
            plan.nearTo = by;
            plan.travelTo.clear();
            plan.findable = 2;
            plan.anchor = placed->GetFormID();
            g_relink = true;
        }
        if (auto* gone = RefOf(old); gone && gone != placed.get()) {
            gone->Disable();
            gone->SetDelete(true);
        }
        const auto at = placed->GetPosition();
        // TEST LOG (wpm86).
        SKSE::log::info("Wedding plan: {:08X}: the place is the spot chosen, '{}' (by '{}'), marked at ({:.0f}, "
                        "{:.0f}, {:.0f}); everyone gathers there",
                        static_cast<std::uint32_t>(a_betrothed), name, by, at.x, at.y, at.z);
        return 1;
    }

    bool SetFindable(std::int32_t a_betrothed, std::string a_travelTo) {
        const std::scoped_lock lock{ g_lock };
        const auto             it = g_plans.find(static_cast<std::uint32_t>(a_betrothed));
        if (it == g_plans.end()) {
            return false;
        }
        auto& plan = it->second;
        if (plan.findable == 2) {
            return false;   // a spot chosen: it is the place, and its anchor
        }
        plan.findable = a_travelTo.empty() ? 0 : 1;
        plan.travelTo = std::move(a_travelTo);
        if (plan.findable) {
            SKSE::log::info("Wedding plan: {:08X}: '{}'{} can be found; people are sent to '{}'",
                            static_cast<std::uint32_t>(a_betrothed), plan.place,
                            plan.nearTo.empty() ? "" : " (by '" + plan.nearTo + "')", plan.travelTo);
        } else {
            SKSE::log::warn("Wedding plan: {:08X}: neither '{}' nor '{}' is a place anyone can find; no one can be "
                            "sent, and they will be brought when it begins",
                            static_cast<std::uint32_t>(a_betrothed), plan.place, plan.nearTo);
        }
        return true;
    }

    bool BringBeside(RE::Actor* a_who, RE::TESObjectREFR* a_near) {
        if (!a_who || !a_near || a_who->IsDead()) {
            return false;
        }
        // The other side of a load door holds where one comes out on this
        // side: its ExtraTeleport. The nearest such door wins.
        auto*            tes = RE::TES::GetSingleton();
        RE::ObjectRefHandle door;
        RE::NiPoint3     spot;
        RE::NiPoint3     facing;
        float            best = kBringFrom;
        const auto       origin = a_near->GetPosition();
        const auto       look = [&](RE::TESObjectREFR* a_ref) {
            auto* base = a_ref ? a_ref->GetBaseObject() : nullptr;
            auto* here = base && base->Is(RE::FormType::Door) ? a_ref->extraList.GetByType<RE::ExtraTeleport>() : nullptr;
            auto  other = here && here->teleportData ? here->teleportData->linkedDoor.get() : nullptr;
            auto* back = other ? other->extraList.GetByType<RE::ExtraTeleport>() : nullptr;
            if (back && back->teleportData) {
                const float distance = back->teleportData->position.GetDistance(origin);
                if (distance < best) {
                    best = distance;
                    door = a_ref->CreateRefHandle();
                    spot = back->teleportData->position;
                    facing = back->teleportData->rotation;
                }
            }
            return RE::BSContainer::ForEachResult::kContinue;
        };
        if (auto* cell = a_near->GetParentCell(); cell && cell->IsInteriorCell()) {
            cell->ForEachReference([&](RE::TESObjectREFR* a_ref) { return look(a_ref); });
        } else if (tes) {
            tes->ForEachReferenceInRange(a_near, kBringFrom, look);
        }
        if (!door) {
            SKSE::log::warn("Wedding: no door within {:.0f} of the wedding; {} is not brought", kBringFrom,
                            a_who->GetDisplayFullName());
            return false;
        }
        SKSE::log::info("Wedding: {} brought to the door {:.0f} from the wedding", a_who->GetDisplayFullName(), best);
        SKSE::GetTaskInterface()->AddTask([who = a_who->CreateRefHandle(), door, spot, facing]() {
            auto actor = who.get();
            auto at = door.get();
            if (actor && at) {
                PutAt(actor.get(), at.get(), spot, facing);
            }
        });
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
        it->second.sides.erase(a_guest);
        return std::erase(it->second.guests, a_guest) > 0;
    }

    bool SetSide(std::int32_t a_betrothed, std::uint32_t a_guest, std::int32_t a_side) {
        if (a_side < kSideTheirs || a_side > kSideBoth) {
            return false;
        }
        const std::scoped_lock lock{ g_lock };
        const auto             it = g_plans.find(static_cast<std::uint32_t>(a_betrothed));
        if (it == g_plans.end() || std::ranges::find(it->second.guests, a_guest) == it->second.guests.end()) {
            return false;
        }
        auto&      sides = it->second.sides;
        const auto was = sides.find(a_guest);
        if (was != sides.end() && was->second == a_side) {
            return false;
        }
        sides[a_guest] = a_side;
        return true;
    }

    std::int32_t SideNamed(RE::Actor* a_betrothed, RE::Actor* a_speaker, const std::string& a_words) {
        const auto words = Lower(Trim(a_words));
        if (words.empty()) {
            return kSideUnknown;
        }
        std::vector<std::string> tokens;
        std::string              token;
        for (const char c : words + " ") {
            if (std::isalpha(static_cast<unsigned char>(c))) {
                token += c;
            } else if (!token.empty()) {
                tokens.push_back(std::exchange(token, {}));
            }
        }
        const auto said = [&](std::initializer_list<const char*> a_any) {
            return std::ranges::any_of(a_any, [&](const char* a_word) { return std::ranges::find(tokens, a_word) != tokens.end(); });
        };
        // A name: whole, or its first name ("Olfina's").
        const auto named = [&](RE::Actor* a_actor) {
            const auto name = a_actor ? Lower(a_actor->GetDisplayFullName()) : std::string{};
            const auto first = name.substr(0, name.find_first_of(" -"));
            return !name.empty() && (words.find(name) != std::string::npos ||
                                     (first.size() >= 3 && std::ranges::find(tokens, first) != tokens.end()));
        };
        if (said({ "both", "either", "each", "everyone", "everybody" })) {
            return kSideBoth;
        }
        const bool theirs = named(a_betrothed);
        const bool yours = named(RE::PlayerCharacter::GetSingleton());
        if (theirs && yours) {
            return kSideBoth;
        }
        if (theirs) {
            return kSideTheirs;
        }
        if (yours || said({ "you", "your", "yours" })) {
            return kSideYours;
        }
        if (a_speaker && a_speaker == a_betrothed && said({ "my", "mine", "me" })) {
            return kSideTheirs;
        }
        return kSideUnknown;
    }

    std::int32_t SideOf(RE::Actor* a_betrothed, RE::Actor* a_guest) {
        auto* player = RE::PlayerCharacter::GetSingleton();
        if (!a_betrothed || !a_guest || !player) {
            return kSideUnknown;
        }
        const auto among = [&](RE::Actor* a_of, std::initializer_list<const char*> a_relations) {
            for (const auto* relation : a_relations) {
                const auto kin = Family::Relatives(a_of, relation);
                if (std::ranges::find(kin, a_guest) != kin.end()) {
                    return true;
                }
            }
            return false;
        };
        const bool theirs = among(a_betrothed, { "parents", "siblings", "children" });
        const bool yours = among(player, { "parents", "siblings", "children", "spouses" });
        return theirs && yours ? kSideBoth : theirs ? kSideTheirs : yours ? kSideYours : kSideUnknown;
    }

    bool SetMark(std::int32_t a_betrothed, std::int32_t a_role) {
        if (a_role < 0 || a_role >= kMarkRoles) {
            return false;
        }
        const auto placed = PlaceMarker();
        if (!placed) {
            SKSE::log::warn("Venue: no marker could be placed where the player stands");
            return false;
        }
        std::uint32_t old = 0;
        std::string   key;
        {
            const std::scoped_lock lock{ g_lock };
            auto&                  plan = Make(a_betrothed);
            key = VenueKey(plan.place);
            auto& venue = g_venues[key];
            if (venue.name.empty()) {
                venue.name = plan.place;
            }
            old = std::exchange(venue.marks[a_role], placed->GetFormID());
            g_relink = true;
        }
        if (auto* gone = old ? RefOf(old) : nullptr; gone && gone != placed.get()) {
            gone->Disable();
            gone->SetDelete(true);
        }
        const auto  at = placed->GetPosition();
        auto*       cell = placed->GetParentCell();
        const char* cellName = cell ? cell->GetFormEditorID() : "";
        // TEST LOG (wpm61).
        SKSE::log::info("Venue '{}': {} marked at ({:.0f}, {:.0f}, {:.0f}) in {}{}", key.empty() ? "(no place yet)" : key,
                        kRoleWords[a_role], at.x, at.y, at.z,
                        cellName && *cellName ? cellName : std::format("{:08X}", cell ? cell->GetFormID() : 0),
                        old ? "; the old mark removed" : "");
        return true;
    }

    bool SettleLayout(std::int32_t a_betrothed) {
        const std::scoped_lock lock{ g_lock };
        auto&                  plan = Make(a_betrothed);
        if (plan.settled & kLayoutSettled) {
            return false;
        }
        plan.settled |= kLayoutSettled;
        return true;
    }

    std::uint32_t Marked(std::int32_t a_betrothed) {
        const std::scoped_lock lock{ g_lock };
        const auto             it = g_plans.find(static_cast<std::uint32_t>(a_betrothed));
        return it == g_plans.end() ? 0 : MarkedBits(it->second);
    }

    bool SetAnchor(std::int32_t a_betrothed, RE::TESObjectREFR* a_found) {
        // A door is the way in: the spot is its other side.
        auto* found = a_found;
        if (auto* base = found ? found->GetBaseObject() : nullptr; base && base->Is(RE::FormType::Door)) {
            auto* here = found->extraList.GetByType<RE::ExtraTeleport>();
            if (auto other = here && here->teleportData ? here->teleportData->linkedDoor.get() : nullptr) {
                found = other.get();
            }
        }
        const std::scoped_lock lock{ g_lock };
        const auto             it = g_plans.find(static_cast<std::uint32_t>(a_betrothed));
        const auto             id = found ? found->GetFormID() : 0;
        if (it == g_plans.end() || it->second.anchor == id || it->second.findable == 2) {
            return false;
        }
        it->second.anchor = id;
        g_relink = true;
        SKSE::log::info("Wedding plan: {:08X}: everyone gathers at {:08X} when nothing is marked",
                        static_cast<std::uint32_t>(a_betrothed), id);
        return true;
    }

    void LetGo(RE::Actor* a_who) {
        if (!a_who) {
            return;
        }
        Link(a_who, nullptr);
        const std::scoped_lock lock{ g_lock };
        for (auto& [id, plan] : g_plans) {
            std::erase(plan.sent, a_who->GetFormID());
        }
    }

    std::vector<RE::Actor*> TakePlaces(std::int32_t a_betrothed) {
        ClearPlaces();
        auto* player = RE::PlayerCharacter::GetSingleton();
        auto* marker = RE::TESForm::LookupByID<RE::TESBoundObject>(kXMarkerHeading);
        if (!player || !marker) {
            return {};
        }
        const auto                          betrothed = static_cast<std::uint32_t>(a_betrothed);
        std::vector<Goal>                   goals;
        std::array<std::uint32_t, kMarkRoles> marks{};
        std::uint32_t                       officiant = 0;
        std::map<std::uint32_t, std::int32_t> sides;
        const auto                          bonds = Model::Get().FormIds();
        {
            const std::scoped_lock lock{ g_lock };
            const auto             it = g_plans.find(betrothed);
            if (it == g_plans.end()) {
                return {};
            }
            goals = GoalsOf(betrothed, it->second, bonds);
            marks = MarksOf(it->second);
            officiant = it->second.officiant;
            sides = it->second.sides;
        }
        const auto posOf = [](std::uint32_t a_id) -> std::optional<RE::NiPoint3> {
            auto* ref = RefOf(a_id);
            return ref ? std::optional<RE::NiPoint3>{ ref->GetPosition() } : std::nullopt;
        };
        // Where the couple stands: between the player's mark and the
        // betrothed's; at either; else where the player is.
        const auto   you = posOf(marks[kMarkYou]);
        const auto   them = posOf(marks[kMarkBetrothed]);
        RE::NiPoint3 couple = player->GetPosition();
        if (you && them) {
            couple = { (you->x + them->x) / 2.0f, (you->y + them->y) / 2.0f, (you->z + them->z) / 2.0f };
        } else if (you || them) {
            couple = you ? *you : *them;
        }
        std::optional<RE::NiPoint3> officiantAt;
        for (const auto& goal : goals) {
            if (goal.who == officiant) {
                officiantAt = posOf(goal.at);
            }
        }
        // Only those here to walk it: anyone else is brought (BringBeside).
        const auto here = [&](const Goal& a_goal) -> RE::Actor* {
            auto* who = RE::TESForm::LookupByID<RE::Actor>(a_goal.who);
            return who && RefOf(a_goal.at) && !who->IsDead() && who->Is3DLoaded() &&
                           who->GetPosition().GetDistance(player->GetPosition()) <= kBringFrom ?
                       who :
                       nullptr;
        };
        std::vector<RE::Actor*>                             out;
        std::map<std::uint32_t, std::vector<std::uint32_t>> gathering;   // a mark: the guests coming to it
        for (const auto& goal : goals) {
            auto* who = here(goal);
            if (!who) {
                continue;
            }
            if (goal.who == officiant || goal.who == betrothed) {
                const bool   isOfficiant = goal.who == officiant;
                const auto   at = RefOf(goal.at)->GetPosition();
                // The betrothed faces the officiant, the officiant the couple.
                const auto   face = !isOfficiant && officiantAt && Across(*officiantAt, at) > 50.0f ? *officiantAt : couple;
                Link(who, RefOf(goal.at));
                g_places.push_back({ goal.who, goal.at, false, face, isOfficiant ? "officiant" : "betrothed" });
                out.push_back(who);
            } else {
                gathering[goal.at].push_back(goal.who);
            }
        }
        for (const auto& [markId, coming] : gathering) {
            auto*      mark = RefOf(markId);
            const auto m = mark->GetPosition();
            // Forward is toward the couple; the rows run across it.
            float      fx = couple.x - m.x;
            float      fy = couple.y - m.y;
            const auto length = std::hypot(fx, fy);
            if (length < 50.0f) {
                fx = std::sin(mark->GetAngleZ());
                fy = std::cos(mark->GetAngleZ());
            } else {
                fx /= length;
                fy /= length;
            }
            const auto n = coming.size();
            for (std::size_t k = 0; k < n; ++k) {
                const auto   row = k / kPerRow;
                const auto   inRow = std::min(kPerRow, n - row * kPerRow);
                const float  across = (static_cast<float>(k % kPerRow) - static_cast<float>(inRow - 1) / 2.0f) * kSideBySide;
                const float  behind = static_cast<float>(row) * kRowBehind;
                RE::NiPoint3 at{ m.x + fy * across - fx * behind, m.y - fx * across - fy * behind, m.z };
                const auto   placed = mark->PlaceObjectAtMe(marker, false);
                auto*        who = RE::TESForm::LookupByID<RE::Actor>(coming[k]);
                if (!placed || !who) {
                    continue;
                }
                // TEST LOG (wpm66): how far each one has to walk.
                SKSE::log::info("Wedding: {}'s place is {:.0f} from them", who->GetDisplayFullName(),
                                Across(who->GetPosition(), at));
                placed->SetPosition(at);
                placed->SetAngle({ 0.0f, 0.0f, HeadingTo(at, couple) });
                Link(who, placed.get());
                const auto side = sides.find(coming[k]);
                g_places.push_back({ coming[k], placed->GetFormID(), true, couple,
                                     side != sides.end() && side->second == kSideTheirs ? "theirs" : "yours" });
                out.push_back(who);
            }
        }
        // TEST LOG (wpm65).
        SKSE::log::info("Wedding: {} take their places, the guests at {} marks", out.size(), gathering.size());
        return out;
    }

    void ClearPlaces() {
        if (g_places.empty()) {
            return;
        }
        for (const auto& p : std::exchange(g_places, {})) {
            if (auto* ref = p.ours ? RefOf(p.at) : nullptr) {
                ref->Disable();
                ref->SetDelete(true);
            }
        }
        // A wedding that did not finish leaves the day under way: everyone
        // linked to their marks again.
        const std::scoped_lock lock{ g_lock };
        g_relink = true;
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

    std::int32_t RingStyle(std::int32_t a_betrothed, bool a_theirs) {
        const auto plan = Get(a_betrothed);
        if (!plan) {
            return -1;
        }
        return a_theirs ? StyleOf(plan->theirStyle, static_cast<std::uint32_t>(a_betrothed)) :
                          StyleOf(plan->yourStyle, 0x14);
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
        // Whoever set out comes back (Papyrus lets them go: LetGo).
        it->second.sent.clear();
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

    // WHO HAS NO MARK YET (wpm86; the author: "I was never asked where the
    // bride, groom, or guests would stand"). One mark settled the whole
    // layout, so the officiant's alone ended the asking. Now the planner asks
    // until each is marked or left to them: the officiant, the couple (either
    // one: the other stands beside), and each side that has guests.
    std::vector<std::string> Unmarked(const Plan& a_plan, std::uint32_t a_marked) {
        std::vector<std::string> out;
        const auto               has = [&](std::int32_t a_role) { return (a_marked & (1u << a_role)) != 0; };
        const auto               side = [&](std::int32_t a_side) {
            return std::ranges::any_of(a_plan.sides, [&](const auto& a_kv) { return a_kv.second == a_side; });
        };
        if (!has(kMarkOfficiant)) {
            out.emplace_back(kRoleWords[kMarkOfficiant]);
        }
        if (!has(kMarkYou) && !has(kMarkBetrothed)) {
            out.emplace_back(kRoleWords[kMarkYou]);
        }
        if (!has(kMarkTheirs) && side(kSideTheirs)) {
            out.emplace_back(kRoleWords[kMarkTheirs]);
        }
        if (!has(kMarkYours) && side(kSideYours)) {
            out.emplace_back(kRoleWords[kMarkYours]);
        }
        return out;
    }

    std::vector<std::string> Unsettled(const Plan& a_plan) {
        std::vector<std::string> out;
        const bool planner = a_plan.planner != 0;
        const auto marked = [&]() {
            const std::scoped_lock lock{ g_lock };
            return MarkedBits(a_plan);
        }();
        if (a_plan.findable == 0 && a_plan.nearTo.empty() && !marked) {
            out.emplace_back("near");
        }
        if (!(a_plan.settled & kGuestsSettled)) {
            out.emplace_back("guests");
        }
        if (std::ranges::any_of(a_plan.guests, [&](std::uint32_t a_guest) { return !a_plan.sides.contains(a_guest); })) {
            out.emplace_back("sides");
        }
        if (planner && !(a_plan.settled & kCeremonySettled)) {
            out.emplace_back("ceremony");
        }
        // Only the metal is still to talk through: a style nobody chose is the
        // usual one (UsualStyle).
        if (planner && a_plan.theirMetal < 0) {
            out.emplace_back("theirRing");
        }
        if (planner && a_plan.yourMetal < 0) {
            out.emplace_back("yourRing");
        }
        if (!(a_plan.settled & kOutfitSettled)) {
            out.emplace_back("outfit");
        }
        // Last: it is walked at the place itself, so everything that can be
        // settled anywhere is asked first.
        if (planner && !(a_plan.settled & kLayoutSettled) && !Unmarked(a_plan, marked).empty()) {
            out.emplace_back("layout");
        }
        return out;
    }

    json ForPrompt(std::int32_t a_betrothed) {
        const auto plan = Get(a_betrothed);
        if (!plan) {
            return nullptr;
        }
        json guests = json::array();
        // Each side's guests by name (wpm61), and those whose side is not
        // known, for the planner to ask about.
        json theirs = json::array();
        json yours = json::array();
        json both = json::array();
        json unsided = json::array();
        for (const auto guest : plan->guests) {
            auto name = NameOf(guest);
            if (name.empty()) {
                continue;
            }
            const auto side = plan->sides.contains(guest) ? plan->sides.at(guest) : kSideUnknown;
            (side == kSideTheirs ? theirs : side == kSideYours ? yours : side == kSideBoth ? both : unsided).push_back(name);
            guests.push_back(std::move(name));
        }
        json                marked = json::array();
        const std::uint32_t bits = Marked(a_betrothed);
        for (std::size_t i = 0; i < kRoleWords.size(); ++i) {
            if (bits & (1u << i)) {
                marked.push_back(kRoleWords[i]);
            }
        }
        const json  unmarked = (plan->settled & kLayoutSettled) ? std::vector<std::string>{} : Unmarked(*plan, bits);
        const float now = Now();
        // The style as it will be: chosen, or the usual one for the wearer,
        // and which (0332 says the usual one is theirs unless they say so).
        const auto  ring = [](std::int32_t a_chosen, std::int32_t a_metal, std::uint32_t a_wearer) {
            const auto style = StyleOf(a_chosen, a_wearer);
            return json{ { "style", style == kWide ? "the wide plain band" : "the slim set" },
                         { "usual", a_chosen < 0 ? 1 : 0 },
                         { "metal", MetalWord(a_metal) } };
        };
        const auto in = plan->day >= 0.0f ? static_cast<std::int32_t>(plan->day - std::floor(now)) : -1;
        return { { "exists", 1 },
                 { "day", DayWords(*plan) },
                 { "date", in >= 0 ? DateWords(in) : std::string{} },
                 { "place", plan->place },
                 { "near", plan->nearTo },
                 { "spot", plan->findable == 2 },
                 { "unmarked", unmarked },
                 { "officiant", NameOf(plan->officiant) },
                 { "guests", guests },
                 { "theirGuests", theirs },
                 { "yourGuests", yours },
                 { "bothGuests", both },
                 { "unsided", unsided },
                 { "marked", marked },
                 { "planner", NameOf(plan->planner) },
                 { "address", (plan->parts & kAddress) ? 1 : 0 },
                 { "reading", (plan->parts & kReading) ? 1 : 0 },
                 { "rings", (plan->parts & kRings) ? 1 : 0 },
                 { "kiss", (plan->parts & kKiss) ? 1 : 0 },
                 { "theirRing", ring(plan->theirStyle, plan->theirMetal, static_cast<std::uint32_t>(a_betrothed)) },
                 { "yourRing", ring(plan->yourStyle, plan->yourMetal, 0x14) },
                 { "outfit", plan->outfit ? 1 : 0 },
                 { "open", Open(*plan) },
                 { "unsettled", Unsettled(*plan) },
                 { "underWay", plan->status == Status::kUnderWay ? 1 : 0 },
                 { "soon", plan->day >= 0.0f && When(*plan) - now <= 1.5f ? 1 : 0 },
                 { "missed", plan->missedDay >= 0.0f ? 1 : 0 },
                 { "lapsed", plan->lapsedDay >= 0.0f && plan->day < 0.0f ? 1 : 0 } };
    }

    std::uint32_t PlannedBy(std::uint32_t a_planner) {
        if (!a_planner) {
            return 0;
        }
        const std::scoped_lock lock{ g_lock };
        for (const auto& [id, plan] : g_plans) {
            if (plan.planner == a_planner && plan.status == Status::kPlanning) {
                return id;
            }
        }
        return 0;
    }

    json OfficiatingFor(std::uint32_t a_officiant) {
        json out = json::array();
        std::vector<std::pair<std::uint32_t, Plan>> mine;
        std::vector<std::uint32_t>                  stopped;
        {
            const std::scoped_lock lock{ g_lock };
            for (const auto& [id, plan] : g_plans) {
                if (plan.officiant == a_officiant) {
                    mine.emplace_back(id, plan);
                }
            }
            stopped = g_stoppedShort;
        }
        for (const auto& [id, plan] : mine) {
            out.push_back({ { "betrothed", NameOf(id) },
                            { "day", DayWords(plan) },
                            { "place", plan.place },
                            { "underWay", plan.status == Status::kUnderWay ? 1 : 0 },
                            { "stoppedShort", std::ranges::find(stopped, id) != stopped.end() ? 1 : 0 } });
        }
        return out;
    }

    json ForSnapshot(std::int32_t a_betrothed) {
        const auto plan = Get(a_betrothed);
        if (!plan) {
            return nullptr;
        }
        json guests = json::array();
        json unsided = json::array();
        // Each guest with their side (2026-11-03), for the page's plan editor.
        json guestSides = json::array();
        for (const auto guest : plan->guests) {
            if (auto name = NameOf(guest); !name.empty()) {
                const auto side = plan->sides.contains(guest) ? plan->sides.at(guest) : kSideUnknown;
                if (!plan->sides.contains(guest)) {
                    unsided.push_back(name);
                }
                guestSides.push_back({ { "name", name },
                                       { "side", side == kSideTheirs ? "theirs" : side == kSideYours ? "yours" :
                                                 side == kSideBoth   ? "both" : "" } });
                guests.push_back(std::move(name));
            }
        }
        json                marked = json::array();
        const std::uint32_t bits = Marked(a_betrothed);
        for (std::size_t i = 0; i < kRoleWords.size(); ++i) {
            if (bits & (1u << i)) {
                marked.push_back(kRoleWords[i]);
            }
        }
        return { { "planner", NameOf(plan->planner) },
                 { "marked", marked },
                 { "unsided", unsided },
                 { "day", plan->day >= 0.0f ? json(plan->day) : json(nullptr) },
                 { "hour", plan->hour },
                 { "place", plan->place },
                 { "near", plan->nearTo },
                 { "spot", plan->findable == 2 },
                 { "officiant", NameOf(plan->officiant) },
                 { "guests", guests },
                 { "parts", { { "address", (plan->parts & kAddress) != 0 },
                              { "reading", (plan->parts & kReading) != 0 },
                              { "rings", (plan->parts & kRings) != 0 },
                              { "kiss", (plan->parts & kKiss) != 0 } } },
                 { "theirRing", { { "style", StyleOf(plan->theirStyle, static_cast<std::uint32_t>(a_betrothed)) },
                                  { "chosen", plan->theirStyle >= 0 },
                                  { "metal", MetalWord(plan->theirMetal) } } },
                 { "yourRing", { { "style", StyleOf(plan->yourStyle, 0x14) },
                                 { "chosen", plan->yourStyle >= 0 },
                                 { "metal", MetalWord(plan->yourMetal) } } },
                 { "guestSides", guestSides },
                 { "outfit", plan->outfit },
                 { "status", plan->status == Status::kUnderWay ? "underWay" : "planning" },
                 { "open", Open(*plan) },
                 { "unsettled", Unsettled(*plan) },
                 { "missedDay", plan->missedDay >= 0.0f ? json(plan->missedDay) : json(nullptr) } };
    }

    // Named, as it was said.
    static RE::Actor* PersonAsSaid(const std::string& a_name) {
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

    RE::Actor* PersonNamed(const std::string& a_name) {
        if (auto* actor = PersonAsSaid(a_name)) {
            return actor;
        }
        // Without a leading title (wpm89): "Mother Hamal" is Hamal.
        const auto bare = Officiant::TitleOff(a_name);
        auto*      actor = bare.empty() ? nullptr : PersonAsSaid(bare);
        // TEST LOG (wpm89): a name found only without its title; remove once
        // validated.
        if (!bare.empty()) {
            SKSE::log::info("Names: '{}' without its title is '{}': {}", a_name, bare,
                            actor ? actor->GetDisplayFullName() : "still no one");
        }
        return actor;
    }

    std::vector<RE::Actor*> GuestsNamed(RE::Actor* a_speaker, const std::string& a_list) {
        std::vector<RE::Actor*> out;
        auto*                   player = RE::PlayerCharacter::GetSingleton();
        // THE SPEAKER, NAMED OUTRIGHT (seen in play, wpm85): "Orla and you,
        // Senna" lost Senna, the planner, who was the one speaking. Only a
        // relation leaves the speaker out ("my family").
        const auto              keep = [&](RE::Actor* a_actor, bool a_named = false) {
            if (a_actor && (a_named || a_actor != a_speaker) && !a_actor->IsPlayerRef() &&
                std::ranges::find(out, a_actor) == out.end()) {
                out.push_back(a_actor);
            }
        };
        // ONLY A NAME SOMEONE SAID (seen in play, wpm58): the planner's
        // action, seeing her own line but not Olfina's "Put Thorald on the
        // list", invited Brenuin from the actors nearby. A person named
        // outright must have been named aloud lately (Ceremony::Said); a
        // relation ("my brothers") is the game's own record and stands.
        const auto spoken = [&](const std::string& a_item, RE::Actor* a_actor) {
            if (Ceremony::Said(a_actor->GetDisplayFullName())) {
                return true;
            }
            SKSE::log::warn("Guests: '{}' would be {}, but no one has said that name lately; not invited", a_item,
                            a_actor->GetDisplayFullName());
            return false;
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
        static constexpr std::array<const char*, 36> kTitles{
            "the ", "my ", "dear ", "old ", "little ", "uncle ", "aunt ", "auntie ", "cousin ", "grandma ",
            "grandpa ", "granny ", "grandmother ", "grandfather ", "jarl ", "thane ", "lady ", "lord ", "sir ",
            "steward ", "housecarl ", "young ", "mother ", "father ", "mom ", "dad ", "brother ", "sister ",
            "son ", "daughter ", "wife ", "husband ", "friend ", "her ", "his ", "our "
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
                    if (spoken(item, named)) {
                        SKSE::log::info("Guests: '{}' is {}", item, named->GetDisplayFullName());
                        keep(named, true);
                    }
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
                auto kin = Family::Relatives(owner, relation);
                // A RELATION AND A NAME (seen in play, wpm53: "my mother
                // Fralia", "my father Eordlund"): the relation is the first
                // word, and the name picks among those relatives - by its
                // start, or within two letters' spelling. Where the relation
                // has one person, they are the one, misspelled or not.
                if (kin.empty()) {
                    if (const auto space = relation.find(' '); space != std::string::npos) {
                        const auto name = Trim(relation.substr(space + 1));
                        relation = relation.substr(0, space);
                        kin = Family::Relatives(owner, relation);
                        if (kin.size() > 1 && !name.empty()) {
                            std::vector<RE::Actor*> named;
                            for (auto* k : kin) {
                                const auto full = Lower(k->GetDisplayFullName());
                                const auto first = full.substr(0, full.find_first_of(" -"));
                                if (full.starts_with(name) || Edits(first, name) <= 2) {
                                    named.push_back(k);
                                }
                            }
                            kin = std::move(named);
                        }
                    }
                }
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
            // A bare relation is the speaker's own: Olfina's "sister-wives".
            if (!relational && a_speaker) {
                const auto kin = Family::Relatives(a_speaker, lower);
                if (!kin.empty()) {
                    std::string names;
                    for (auto* k : kin) {
                        names += (names.empty() ? "" : ", ") + std::string(k->GetDisplayFullName());
                        keep(k);
                    }
                    SKSE::log::info("Guests: '{}' is {} ({}'s {})", item, names, a_speaker->GetDisplayFullName(),
                                    lower);
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
                if (spoken(item, named)) {
                    SKSE::log::info("Guests: '{}' is {}", item, named->GetDisplayFullName());
                    keep(named, true);
                }
                continue;
            }
            // 4. A NAME AT THE END (seen in play, wpm85): "her housemate
            // Tormir" is no relation the game records and no title, but it
            // ends in a name someone said.
            if (const auto space = item.find_last_of(' '); space != std::string::npos) {
                const auto last = Trim(item.substr(space + 1));
                auto*      named = last.size() >= 3 && std::isupper(static_cast<unsigned char>(last[0])) ?
                                       PersonNamed(last) :
                                       nullptr;
                const auto full = named ? Lower(named->GetDisplayFullName()) : std::string{};
                const auto lastLower = Lower(last);
                if (named && (full == lastLower || full.starts_with(lastLower + " ") || full.starts_with(lastLower + "-"))) {
                    if (spoken(item, named)) {
                        SKSE::log::info("Guests: '{}' is {}", item, named->GetDisplayFullName());
                        keep(named, true);
                    }
                    continue;
                }
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
            WriteString(a_intfc, p.nearTo);
            WriteString(a_intfc, p.travelTo);
            a_intfc->WriteRecordData(p.findable);
            a_intfc->WriteRecordData(static_cast<std::uint32_t>(p.sides.size()));
            for (const auto& [guest, side] : p.sides) {
                a_intfc->WriteRecordData(guest);
                a_intfc->WriteRecordData(side);
            }
            a_intfc->WriteRecordData(p.anchor);
            a_intfc->WriteRecordData(static_cast<std::uint32_t>(p.sent.size()));
            for (const auto who : p.sent) {
                a_intfc->WriteRecordData(who);
            }
        }
        a_intfc->WriteRecordData(static_cast<std::uint32_t>(g_venues.size()));
        for (const auto& [key, venue] : g_venues) {
            WriteString(a_intfc, key);
            WriteString(a_intfc, venue.name);
            a_intfc->WriteRecordData(static_cast<std::uint32_t>(venue.marks.size()));
            for (const auto mark : venue.marks) {
                a_intfc->WriteRecordData(mark);
            }
        }
        a_intfc->WriteRecordData(static_cast<std::uint8_t>(g_reception ? 1 : 0));
        if (g_reception) {
            a_intfc->WriteRecordData(g_reception->until);
            a_intfc->WriteRecordData(g_reception->at);
            a_intfc->WriteRecordData(static_cast<std::uint8_t>(g_reception->ours ? 1 : 0));
            a_intfc->WriteRecordData(static_cast<std::uint32_t>(g_reception->who.size()));
            for (std::size_t i = 0; i < g_reception->who.size(); ++i) {
                a_intfc->WriteRecordData(g_reception->who[i]);
                a_intfc->WriteRecordData(i < g_reception->atEach.size() ? g_reception->atEach[i] : 0u);
            }
        }
    }

    void Load(SKSE::SerializationInterface* a_intfc, std::uint32_t a_version) {
        const std::scoped_lock lock{ g_lock };
        g_plans.clear();
        if (a_version < 1 || a_version > kRecordVersion) {
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
            // Before v3 the place was never looked for: findable stays -1,
            // and it is looked for on the day.
            if (a_version >= 3 && (!ReadString(a_intfc, p.nearTo) || !ReadString(a_intfc, p.travelTo) ||
                                   a_intfc->ReadRecordData(p.findable) != sizeof(p.findable))) {
                return damaged();
            }
            if (a_version >= 4) {
                std::uint32_t sides = 0;
                if (a_intfc->ReadRecordData(sides) != sizeof(sides) || sides > kMaxGuests * 4) {
                    return damaged();
                }
                for (std::uint32_t s = 0; s < sides; ++s) {
                    std::uint32_t guest = 0;
                    std::int32_t  side = kSideUnknown;
                    if (a_intfc->ReadRecordData(guest) != sizeof(guest) ||
                        a_intfc->ReadRecordData(side) != sizeof(side)) {
                        return damaged();
                    }
                    if (const auto now = resolve(guest)) {
                        p.sides[now] = side;
                    }
                }
                std::uint32_t sent = 0;
                if (a_intfc->ReadRecordData(p.anchor) != sizeof(p.anchor) ||
                    a_intfc->ReadRecordData(sent) != sizeof(sent) || sent > kMaxGuests * 4) {
                    return damaged();
                }
                p.anchor = resolve(p.anchor);
                for (std::uint32_t s = 0; s < sent; ++s) {
                    std::uint32_t who = 0;
                    if (a_intfc->ReadRecordData(who) != sizeof(who)) {
                        return damaged();
                    }
                    if (const auto now = resolve(who)) {
                        p.sent.push_back(now);
                    }
                }
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
        g_venues.clear();
        if (a_version >= 4) {
            std::uint32_t venues = 0;
            if (a_intfc->ReadRecordData(venues) != sizeof(venues) || venues > 10000) {
                return damaged();
            }
            for (std::uint32_t v = 0; v < venues; ++v) {
                std::string key;
                Venue       venue;
                if (!ReadString(a_intfc, key) || !ReadString(a_intfc, venue.name)) {
                    return damaged();
                }
                // v4 kept four marks; from v5 the count comes first.
                std::uint32_t marks = 4;
                if (a_version >= 5 && (a_intfc->ReadRecordData(marks) != sizeof(marks) || marks > 64)) {
                    return damaged();
                }
                for (std::uint32_t m = 0; m < marks; ++m) {
                    std::uint32_t mark = 0;
                    if (a_intfc->ReadRecordData(mark) != sizeof(mark)) {
                        return damaged();
                    }
                    if (m < venue.marks.size()) {
                        venue.marks[m] = resolve(mark);
                    }
                }
                g_venues[key] = std::move(venue);
            }
        }
        g_reception.reset();
        std::uint8_t celebrating = 0;
        if (a_version >= 6 && a_intfc->ReadRecordData(celebrating) == sizeof(celebrating) && celebrating) {
            Reception    r;
            std::uint8_t ours = 0;
            std::uint32_t staying = 0;
            if (a_intfc->ReadRecordData(r.until) != sizeof(r.until) || a_intfc->ReadRecordData(r.at) != sizeof(r.at) ||
                a_intfc->ReadRecordData(ours) != sizeof(ours) || a_intfc->ReadRecordData(staying) != sizeof(staying) ||
                staying > kMaxGuests * 4) {
                return damaged();
            }
            for (std::uint32_t c = 0; c < staying; ++c) {
                std::uint32_t who = 0;
                std::uint32_t own = 0;   // v7: their own mark
                if (a_intfc->ReadRecordData(who) != sizeof(who) ||
                    (a_version >= 7 && a_intfc->ReadRecordData(own) != sizeof(own))) {
                    return damaged();
                }
                if (const auto now = resolve(who)) {
                    r.who.push_back(now);
                    r.atEach.push_back(resolve(own));
                }
            }
            r.at = resolve(r.at);
            r.ours = ours != 0;
            g_reception = std::move(r);
        }
        // Links to a mark are not kept in the save: set again on the first
        // look after the load.
        g_relink = true;
        SKSE::log::info("Wedding plan: {} plans and {} venues loaded from the save", g_plans.size(), g_venues.size());
    }

    void Revert() {
        const std::scoped_lock lock{ g_lock };
        g_plans.clear();
        g_venues.clear();
        g_relink = false;
        g_summoned.clear();
        g_stoppedShort.clear();
        g_places.clear();
        g_reception.reset();
    }

    void StoppedShort(std::int32_t a_betrothed) {
        const std::scoped_lock lock{ g_lock };
        const auto             id = static_cast<std::uint32_t>(a_betrothed);
        if (g_plans.contains(id) && std::ranges::find(g_stoppedShort, id) == g_stoppedShort.end()) {
            g_stoppedShort.push_back(id);
            SKSE::log::info("Wedding plan: {:08X}'s wedding stopped short; it begins again only when the officiant does",
                            id);
        }
    }

    std::int32_t BeginReception(std::int32_t a_betrothed) {
        std::vector<std::uint32_t> who;
        std::vector<std::uint32_t> atEach;
        std::uint32_t              at = 0;
        const auto                 bonds = Model::Get().FormIds();
        {
            const std::scoped_lock lock{ g_lock };
            const auto             it = g_plans.find(static_cast<std::uint32_t>(a_betrothed));
            if (it == g_plans.end()) {
                return 0;
            }
            const auto goals = GoalsOf(static_cast<std::uint32_t>(a_betrothed), it->second, bonds);
            for (const auto id : it->second.sent) {
                const auto goal = std::ranges::find(goals, id, &Goal::who);
                atEach.push_back(goal != goals.end() ? goal->at : 0);
            }
            // Around where the couple stood; else the betrothed's mark, the
            // officiant's, or the place found.
            const auto marks = MarksOf(it->second);
            for (const auto role : { kMarkYou, kMarkBetrothed, kMarkOfficiant }) {
                if (marks[role]) {
                    at = marks[role];
                    break;
                }
            }
            if (!at && RefOf(it->second.anchor)) {
                at = it->second.anchor;
            }
            // Theirs now: the plan's end (no longer engaged) lets no one go.
            who = std::exchange(it->second.sent, {});
            // AND THE DAY IS DONE (seen in play, wpm81). The marriage is
            // recorded a moment after this, and the plan lives until then: in
            // that half second the day's watch found everyone "not yet sent",
            // sent all seventeen back to their places for the ceremony, and
            // the plan's end then let them all go home - the reception over
            // three seconds after it began. A plan with no day sends no one.
            it->second.day = -1.0f;
            it->second.hour = -1;
        }
        if (who.empty()) {
            return 0;
        }
        bool ours = false;
        if (!at) {
            auto* player = RE::PlayerCharacter::GetSingleton();
            auto* marker = RE::TESForm::LookupByID<RE::TESBoundObject>(kXMarkerHeading);
            const auto placed = player && marker ? player->PlaceObjectAtMe(marker, true) : nullptr;
            if (!placed) {
                return 0;
            }
            at = placed->GetFormID();
            ours = true;
        }
        std::uint32_t oldMarker = 0;
        {
            const std::scoped_lock lock{ g_lock };
            if (g_reception && g_reception->ours) {
                oldMarker = g_reception->at;
            }
            g_reception = Reception{ who, atEach, at, ours, Now() + kReceptionHours / 24.0f };
        }
        if (auto* gone = RefOf(oldMarker)) {
            gone->Disable();
            gone->SetDelete(true);
        }
        const Reception now{ who, atEach, at, ours, 0.0f };
        for (std::size_t i = 0; i < who.size(); ++i) {
            Link(RE::TESForm::LookupByID<RE::Actor>(who[i]), now.AtOf(i));
            Send("SNRom_WeddingGo", kGatherLarge, 0.0f, who[i]);
        }
        // TEST LOG (wpm68).
        SKSE::log::info("Wedding: the reception begins; {} stay {:.0f} hours", who.size(), kReceptionHours);
        return static_cast<std::int32_t>(who.size());
    }

    void BegunAgain(std::int32_t a_betrothed) {
        const std::scoped_lock lock{ g_lock };
        std::erase(g_stoppedShort, static_cast<std::uint32_t>(a_betrothed));
    }

    bool Today(std::int32_t a_betrothed) {
        const std::scoped_lock lock{ g_lock };
        const auto             it = g_plans.find(static_cast<std::uint32_t>(a_betrothed));
        return it != g_plans.end() && it->second.status == Status::kUnderWay;
    }
}
