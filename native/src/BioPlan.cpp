#include "BioPlan.h"

#include "PCH.h"

#include "BioLibrary.inl"

#include <algorithm>
#include <array>
#include <cctype>
#include <string_view>

namespace SNRom::BioPlan {

    namespace {

        constexpr std::size_t kCats = 4;
        constexpr std::size_t kLimits = 3;

        bool EqualNoCase(std::string_view a_left, std::string_view a_right) {
            return a_left.size() == a_right.size() &&
                   std::equal(a_left.begin(), a_left.end(), a_right.begin(), [](char a, char b) {
                       return std::tolower(static_cast<unsigned char>(a)) == std::tolower(static_cast<unsigned char>(b));
                   });
        }

        bool StartsNoCase(std::string_view a_text, std::string_view a_prefix) {
            return a_text.size() >= a_prefix.size() && EqualNoCase(a_text.substr(0, a_prefix.size()), a_prefix);
        }

        std::string_view Trim(std::string_view a_text) {
            while (!a_text.empty() && std::isspace(static_cast<unsigned char>(a_text.front()))) {
                a_text.remove_prefix(1);
            }
            while (!a_text.empty() && std::isspace(static_cast<unsigned char>(a_text.back()))) {
                a_text.remove_suffix(1);
            }
            return a_text;
        }

        // "Drawn To: Both (2)" -> "Drawn To: Both". SeverActions adds the
        // suffix when a title already existed with different text.
        std::string_view StripCopySuffix(std::string_view a_title) {
            if (!a_title.empty() && a_title.back() == ')') {
                const auto at = a_title.rfind(" (");
                if (at != std::string_view::npos && at > 0) {
                    return Trim(a_title.substr(0, at));
                }
            }
            return a_title;
        }

        // The library index of a title in a category, or -1 for a block in
        // that category that is not one of ours (a player's own wording).
        int IndexOf(std::size_t a_cat, std::string_view a_title) {
            const auto bare = StripCopySuffix(Trim(a_title));
            for (std::size_t i = 0; i < Library::kCount[a_cat]; ++i) {
                if (EqualNoCase(bare, Library::kTitles[a_cat][i])) {
                    return static_cast<int>(i);
                }
            }
            return -1;
        }

        struct Category {
            int                 count = 0;     // blocks in this category
            std::array<bool, 6> ours{};        // which library entries are present
            int                 answer = -2;   // -2 none, -1 unreadable/contradiction, else index
        };

        std::array<Category, kCats> Read(const std::vector<std::string>& a_titles) {
            std::array<Category, kCats> cats{};
            for (const auto& raw : a_titles) {
                const auto title = Trim(raw);
                for (std::size_t c = 0; c < kCats; ++c) {
                    if (!StartsNoCase(title, Library::kPrefix[c])) {
                        continue;
                    }
                    auto& cat = cats[c];
                    ++cat.count;
                    const int at = IndexOf(c, title);
                    if (at >= 0) {
                        cat.ours[static_cast<std::size_t>(at)] = true;
                    }
                    // The answer this category gives, as BlockAnswer did: one
                    // value, or a contradiction when two differ.
                    if (cat.answer == -2) {
                        cat.answer = at;
                    } else if (cat.answer != at) {
                        cat.answer = -1;
                    }
                    break;
                }
            }
            return cats;
        }

        // The record's keys, as library indices. Limits are bits; the others
        // are 1 + index. 0 none, -1 "the player took ours off".
        std::vector<int> RecordIndices(std::size_t a_cat, std::int32_t a_record) {
            std::vector<int> out;
            if (a_record <= 0) {
                return out;
            }
            if (a_cat == kLimits) {
                for (int i = 0; i < 6; ++i) {
                    if (a_record & (1 << i)) {
                        out.push_back(i);
                    }
                }
            } else {
                out.push_back(a_record - 1);
            }
            return out;
        }

        std::int32_t RecordFrom(std::size_t a_cat, const std::vector<int>& a_indices) {
            if (a_indices.empty()) {
                return 0;
            }
            if (a_cat == kLimits) {
                std::int32_t bits = 0;
                for (const int i : a_indices) {
                    bits |= 1 << i;
                }
                return bits;
            }
            return a_indices.front() + 1;
        }

        // True while the category holds exactly what we recorded, and nothing
        // else. A copy the player made of ours sits beside it and makes two.
        bool OursAlone(const Category& a_cat, std::int32_t a_record, std::size_t a_index) {
            const auto keys = RecordIndices(a_index, a_record);
            if (keys.empty() || a_cat.count != static_cast<int>(keys.size())) {
                return false;
            }
            return std::all_of(keys.begin(), keys.end(), [&](int k) { return a_cat.ours[static_cast<std::size_t>(k)]; });
        }

        // The block that says what the character already says; -1 for none.
        // Drawn To only for a STATED orientation (an inference is not a fact).
        int Desired(std::size_t a_cat, std::int32_t a_orient, std::int32_t a_known, std::int32_t a_ardor,
                    std::int32_t a_excl) {
            switch (a_cat) {
            case 0:
                if (a_known < 2) {
                    return -1;
                }
                return a_orient == 1 ? 0 : a_orient == 2 ? 1 : a_orient == 0 ? 3 : 2;
            case 1:
                return std::clamp(a_ardor, 0, 4);
            case 2:
                return a_excl <= 12 ? 0 : a_excl <= 37 ? 1 : a_excl <= 62 ? 2 : a_excl <= 87 ? 3 : 4;
            default:
                return -1;
            }
        }

        // What a library answer sets. Drawn To indices are men, women, both,
        // no one -> orientation 1, 2, 3, 0. Attachment indices are the five
        // authored seeds.
        constexpr std::array<std::int32_t, 4> kOrientationOf{ 1, 2, 3, 0 };
        constexpr std::array<std::int32_t, 5> kExclusivityOf{ 0, 25, 50, 75, 100 };

        bool OrientationExcludesPlayer(std::int32_t a_orient) {
            const auto* player = RE::PlayerCharacter::GetSingleton();
            const auto* base = player ? player->GetActorBase() : nullptr;
            if (!base) {
                return false;
            }
            // As SNRom_Bridge.OrientationExcludesPlayer: none always does;
            // men unless the player is male; women unless the player is female.
            const auto sex = base->GetSex();
            return a_orient == 0 || (a_orient == 1 && sex != RE::SEX::kMale) || (a_orient == 2 && sex != RE::SEX::kFemale);
        }

        static_assert(std::all_of(std::begin(Library::kCount), std::end(Library::kCount),
                                  [](std::size_t n) { return n <= 6; }),
                      "Category::ours holds six entries; widen it before a category grows past six");
    }

    std::vector<std::int32_t> Plan(const RE::Actor* a_actor, const std::vector<std::string>& a_titles,
                                   const std::vector<std::int32_t>& a_state) {
        std::vector<std::int32_t> out(kHeaderCount, -1);
        for (std::size_t c = 0; c < kCats; ++c) {
            out[kNewRecord0 + c] = kUnchanged;
        }
        out[kHasBits] = 0;
        out[kPlayerHoldsBits] = 0;
        out[kNoteBits] = 0;
        out[kLiftedLimits] = 0;
        out[kActionCount] = 0;
        if (a_state.size() < kStateCount) {
            SKSE::log::warn("BioPlan: expected {} state values, got {} - nothing planned", static_cast<int>(kStateCount),
                            a_state.size());
            return out;
        }

        auto       cats = Read(a_titles);
        const auto flags = a_state[kFlags];
        std::array<std::int32_t, kCats> record{};
        for (std::size_t c = 0; c < kCats; ++c) {
            record[c] = a_state[kRecord0 + c];
        }
        const bool api = (flags & kApiReady) != 0;

        std::array<bool, kCats> mine{};
        for (std::size_t c = 0; c < kCats; ++c) {
            mine[c] = api && OursAlone(cats[c], record[c], c);
            if (cats[c].count > 0 && !mine[c]) {
                out[kPlayerHoldsBits] |= 1 << c;
            }
        }

        std::int32_t orient = a_state[kOrientation];
        std::int32_t known = a_state[kOrientationKnown];
        std::int32_t ardor = a_state[kArdor];
        std::int32_t excl = a_state[kExclusivity];

        // ---- the player's blocks set the traits (EnforceBlockAnswers) ----
        if (flags & kEnforce) {
            for (std::size_t c = 0; c < kLimits; ++c) {
                if (mine[c] || cats[c].answer == -2) {
                    continue;
                }
                if (cats[c].answer == -1) {
                    out[kNoteBits] |= 1 << (kNoteUnreadable + c);
                    continue;
                }
                const auto at = static_cast<std::size_t>(cats[c].answer);
                if (c == 0) {
                    const auto o = kOrientationOf[at];
                    if (a_state[kMarriedToPlayer] == 1 && OrientationExcludesPlayer(o)) {
                        out[kNoteBits] |= 1 << kNoteMarriage;
                    } else if (orient != o || known != 2) {
                        orient = o;
                        known = 2;
                        out[kNewOrientation] = o;
                        out[kNewOrientationKnown] = 2;
                    }
                } else if (c == 1) {
                    if (ardor != static_cast<std::int32_t>(at)) {
                        ardor = static_cast<std::int32_t>(at);
                        out[kNewArdor] = ardor;
                    }
                } else if (excl != kExclusivityOf[at]) {
                    excl = kExclusivityOf[at];
                    out[kNewExclusivity] = excl;
                }
            }
        }

        auto act = [&](Op a_op, std::size_t a_cat, int a_index) {
            out.push_back(a_op);
            out.push_back(static_cast<std::int32_t>(a_cat));
            out.push_back(a_index);
            ++out[kActionCount];
            if (a_op == kApply) {
                cats[a_cat].ours[static_cast<std::size_t>(a_index)] = true;
                ++cats[a_cat].count;
            } else {
                cats[a_cat].ours[static_cast<std::size_t>(a_index)] = false;
                --cats[a_cat].count;
            }
        };
        auto replace = [&](std::size_t a_cat, const std::vector<int>& a_new) {
            const auto old = RecordIndices(a_cat, record[a_cat]);
            for (const int k : old) {
                if (std::find(a_new.begin(), a_new.end(), k) == a_new.end()) {
                    act(kUnapply, a_cat, k);
                }
            }
            for (const int k : a_new) {
                if (std::find(old.begin(), old.end(), k) == old.end() || !cats[a_cat].ours[static_cast<std::size_t>(k)]) {
                    act(kApply, a_cat, k);
                }
            }
            record[a_cat] = RecordFrom(a_cat, a_new);
            out[kNewRecord0 + a_cat] = record[a_cat];
        };

        // ---- lift ours before a re-author ----
        if (api && (flags & kLift)) {
            for (std::size_t c = 0; c < kCats; ++c) {
                if (mine[c]) {
                    if (c == kLimits) {
                        out[kLiftedLimits] = record[c];
                    }
                    replace(c, {});
                    mine[c] = false;
                }
            }
        }

        // ---- our blocks follow the character (SyncOurBlocks) ----
        const bool sync = api && (flags & kSync) && (flags & kAssignOn) && (flags & kEnrolled);
        if (sync && a_actor && a_actor->IsChild()) {
            // Not for children: the blocks describe how someone is with a
            // partner. Theirs stay; ours come off.
            for (std::size_t c = 0; c < kCats; ++c) {
                if (mine[c]) {
                    replace(c, {});
                    out[kNoteBits] |= 1 << kNoteWithdrawn;
                }
            }
        } else if (sync) {
            for (std::size_t c = 0; c < kCats; ++c) {
                std::vector<int> want;
                if (c == kLimits) {
                    if (a_state[kLimitPicks] < 0) {
                        continue;  // nothing has chosen limits
                    }
                    want = RecordIndices(c, a_state[kLimitPicks]);
                } else if (const int d = Desired(c, orient, known, ardor, excl); d >= 0) {
                    want.push_back(d);
                }
                if (record[c] == -1) {
                    continue;  // the player took ours off here: theirs now
                }
                if (record[c] > 0) {
                    const auto keys = RecordIndices(c, record[c]);
                    const bool gone = std::any_of(keys.begin(), keys.end(),
                                                  [&](int k) { return !cats[c].ours[static_cast<std::size_t>(k)]; });
                    if (gone) {
                        record[c] = -1;
                        out[kNewRecord0 + c] = -1;
                        out[kNoteBits] |= 1 << (kNoteTakenOff + c);
                        continue;
                    }
                }
                const bool emptyAndNeverOurs = cats[c].count == 0 && record[c] == 0;
                if (emptyAndNeverOurs || (mine[c] && RecordFrom(c, want) != record[c])) {
                    replace(c, want);
                }
            }
        }

        for (std::size_t c = 0; c < kCats; ++c) {
            if (cats[c].count > 0) {
                out[kHasBits] |= 1 << c;
            }
        }
        return out;
    }
}
