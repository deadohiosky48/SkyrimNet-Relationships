#include "Marriage.h"

#include "PCH.h"

#include <algorithm>
#include <map>
#include <mutex>

namespace SNRom::Marriage {

    namespace {

        // Bump when the layout below changes, and keep reading the old one.
        constexpr std::uint32_t kRecordVersion = 1;
        constexpr std::size_t   kMaxWhy = 400;
        constexpr std::uint32_t kMaxRecords = 100000;

        struct Record {
            State        state = State::kNone;
            State        previous = State::kNone;
            float        since = 0.0f;       // game day the state was entered
            float        weddingDay = 0.0f;  // game day they married; 0 never
            bool         eloped = false;
            std::int32_t officiant = 0;      // form id; 0 none or unknown
            std::string  why;
        };

        std::mutex                         g_lock;
        std::map<std::uint32_t, Record>    g_records;
        bool                               g_exception = false;

        float GameDay() {
            const auto* calendar = RE::Calendar::GetSingleton();
            return calendar ? calendar->GetCurrentGameTime() : 0.0f;
        }

        void Truncate(std::string& a_text, std::size_t a_max) {
            if (a_text.size() <= a_max) {
                return;
            }
            std::size_t cut = a_max;
            while (cut > 0 && (static_cast<unsigned char>(a_text[cut]) & 0xC0) == 0x80) {
                --cut;
            }
            a_text.resize(cut);
        }

        // The steps a marriage can take of itself (STANDALONE_PLAN_2.5, M1).
        // Anything else needs a_force: the developer repair, an import from
        // MARAS, a marriage another mod made.
        bool Legal(State a_from, State a_to) {
            switch (a_to) {
            case State::kEngaged:
                return a_from == State::kNone || a_from == State::kBrokenOff || a_from == State::kDivorced ||
                       a_from == State::kWidowed;
            case State::kMarried:
                return a_from == State::kEngaged || a_from == State::kSeparated;
            case State::kBrokenOff:
                return a_from == State::kEngaged;
            case State::kSeparated:
                return a_from == State::kMarried;
            case State::kDivorced:
                return a_from == State::kMarried || a_from == State::kSeparated;
            case State::kWidowed:
                return a_from == State::kEngaged || a_from == State::kMarried || a_from == State::kSeparated;
            case State::kNone:
            default:
                return false;
            }
        }

        bool Known(std::int32_t a_value) {
            return a_value >= 0 && a_value <= static_cast<std::int32_t>(State::kSeparated);
        }

        // SNRom_MarriageChanged: strArg the new state's name, numArg its
        // number, sender the person. Papyrus and other mods listen for it.
        void Announce(std::int32_t a_formId, State a_to) {
            SKSE::GetTaskInterface()->AddTask([a_formId, a_to]() {
                auto* form = RE::TESForm::LookupByID(static_cast<RE::FormID>(a_formId));
                SKSE::ModCallbackEvent event{ "SNRom_MarriageChanged", RE::BSFixedString(Name(a_to)),
                                              static_cast<float>(static_cast<std::int32_t>(a_to)), form };
                if (auto* source = SKSE::GetModCallbackEventSource()) {
                    source->SendEvent(&event);
                }
            });
        }

        bool WriteString(SKSE::SerializationInterface* a_intfc, const std::string& a_text) {
            const auto length = static_cast<std::uint16_t>(a_text.size());
            return a_intfc->WriteRecordData(length) &&
                   (length == 0 || a_intfc->WriteRecordData(a_text.data(), length));
        }

        bool ReadString(SKSE::SerializationInterface* a_intfc, std::string& a_text) {
            std::uint16_t length = 0;
            if (a_intfc->ReadRecordData(length) != sizeof(length)) {
                return false;
            }
            a_text.resize(length);
            return length == 0 || a_intfc->ReadRecordData(a_text.data(), length) == length;
        }
    }

    const char* Name(State a_state) {
        switch (a_state) {
        case State::kEngaged:
            return "engaged";
        case State::kMarried:
            return "married";
        case State::kBrokenOff:
            return "broken_off";
        case State::kDivorced:
            return "divorced";
        case State::kWidowed:
            return "widowed";
        case State::kSeparated:
            return "separated";
        case State::kNone:
        default:
            return "none";
        }
    }

    State StateOf(std::int32_t a_formId) {
        const std::scoped_lock lock{ g_lock };
        const auto it = g_records.find(static_cast<std::uint32_t>(a_formId));
        return it == g_records.end() ? State::kNone : it->second.state;
    }

    bool Married(std::int32_t a_formId) {
        const auto state = StateOf(a_formId);
        return state == State::kMarried || state == State::kSeparated;
    }

    bool Engaged(std::int32_t a_formId) {
        return StateOf(a_formId) == State::kEngaged;
    }

    bool Set(std::int32_t a_formId, State a_to, std::string a_why, bool a_force, std::int32_t a_officiant,
             bool a_eloped) {
        if (a_formId == 0 || !Known(static_cast<std::int32_t>(a_to))) {
            SKSE::log::warn("Marriage: refused a state {} for {:08X}", static_cast<std::int32_t>(a_to),
                            static_cast<std::uint32_t>(a_formId));
            return false;
        }
        Truncate(a_why, kMaxWhy);
        State from = State::kNone;
        {
            const std::scoped_lock lock{ g_lock };
            auto& record = g_records[static_cast<std::uint32_t>(a_formId)];
            from = record.state;
            if (from == a_to) {
                return false;
            }
            if (!a_force && !Legal(from, a_to)) {
                SKSE::log::warn("Marriage: {:08X} cannot go from {} to {} ({}); refused",
                                static_cast<std::uint32_t>(a_formId), Name(from), Name(a_to), a_why);
                if (from == State::kNone && record.why.empty()) {
                    g_records.erase(static_cast<std::uint32_t>(a_formId));
                }
                return false;
            }
            record.previous = from;
            record.state = a_to;
            record.since = GameDay();
            record.why = a_why;
            if (a_to == State::kMarried && from != State::kSeparated) {
                record.weddingDay = record.since;
                record.eloped = a_eloped;
                record.officiant = a_officiant;
            }
            if (a_to == State::kNone) {
                g_records.erase(static_cast<std::uint32_t>(a_formId));
            }
        }
        SKSE::log::info("Marriage: {:08X} {} -> {}{}: {}", static_cast<std::uint32_t>(a_formId), Name(from), Name(a_to),
                        a_force ? " (forced)" : "", a_why);
        Announce(a_formId, a_to);
        return true;
    }

    std::vector<std::int32_t> WithState(State a_state) {
        std::vector<std::int32_t> out;
        const std::scoped_lock    lock{ g_lock };
        for (const auto& [formId, record] : g_records) {
            if (record.state == a_state) {
                out.push_back(static_cast<std::int32_t>(formId));
            }
        }
        return out;
    }

    bool Exception() {
        const std::scoped_lock lock{ g_lock };
        return g_exception;
    }

    void SetException(bool a_granted) {
        {
            const std::scoped_lock lock{ g_lock };
            if (g_exception == a_granted) {
                return;
            }
            g_exception = a_granted;
        }
        SKSE::log::info("Marriage: Mara's exception {}", a_granted ? "granted" : "withdrawn");
    }

    nlohmann::json Of(std::int32_t a_formId) {
        const std::scoped_lock lock{ g_lock };
        const auto             it = g_records.find(static_cast<std::uint32_t>(a_formId));
        if (it == g_records.end()) {
            return nullptr;
        }
        const auto& r = it->second;
        return nlohmann::json{ { "state", Name(r.state) },     { "previous", Name(r.previous) },
                               { "since", r.since },          { "weddingDay", r.weddingDay },
                               { "eloped", r.eloped },        { "officiant", r.officiant },
                               { "why", r.why } };
    }

    void Save(SKSE::SerializationInterface* a_intfc) {
        const std::scoped_lock lock{ g_lock };
        if (!a_intfc->OpenRecord(kRecordType, kRecordVersion)) {
            SKSE::log::error("Marriage: could not open the co-save record; this save keeps no marriages");
            return;
        }
        a_intfc->WriteRecordData(static_cast<std::uint8_t>(g_exception ? 1 : 0));
        a_intfc->WriteRecordData(static_cast<std::uint32_t>(g_records.size()));
        for (const auto& [formId, r] : g_records) {
            a_intfc->WriteRecordData(formId);
            a_intfc->WriteRecordData(static_cast<std::int32_t>(r.state));
            a_intfc->WriteRecordData(static_cast<std::int32_t>(r.previous));
            a_intfc->WriteRecordData(r.since);
            a_intfc->WriteRecordData(r.weddingDay);
            a_intfc->WriteRecordData(static_cast<std::uint8_t>(r.eloped ? 1 : 0));
            a_intfc->WriteRecordData(static_cast<std::uint32_t>(r.officiant));
            WriteString(a_intfc, r.why);
        }
    }

    void Load(SKSE::SerializationInterface* a_intfc, std::uint32_t a_version) {
        const std::scoped_lock lock{ g_lock };
        if (a_version != kRecordVersion) {
            SKSE::log::warn("Marriage: co-save record version {} is not one this DLL reads; skipped", a_version);
            return;
        }
        auto damaged = [&]() {
            SKSE::log::error("Marriage: the co-save record is damaged; this save's marriages are empty");
            g_records.clear();
        };
        std::uint8_t  exception = 0;
        std::uint32_t count = 0;
        if (a_intfc->ReadRecordData(exception) != sizeof(exception) ||
            a_intfc->ReadRecordData(count) != sizeof(count) || count > kMaxRecords) {
            return damaged();
        }
        g_exception = exception == 1;
        std::size_t dropped = 0;
        for (std::uint32_t i = 0; i < count; ++i) {
            std::uint32_t savedId = 0;
            std::int32_t  state = 0;
            std::int32_t  previous = 0;
            std::uint8_t  eloped = 0;
            std::uint32_t officiant = 0;
            Record        r;
            if (a_intfc->ReadRecordData(savedId) != sizeof(savedId) ||
                a_intfc->ReadRecordData(state) != sizeof(state) ||
                a_intfc->ReadRecordData(previous) != sizeof(previous) ||
                a_intfc->ReadRecordData(r.since) != sizeof(r.since) ||
                a_intfc->ReadRecordData(r.weddingDay) != sizeof(r.weddingDay) ||
                a_intfc->ReadRecordData(eloped) != sizeof(eloped) ||
                a_intfc->ReadRecordData(officiant) != sizeof(officiant) || !ReadString(a_intfc, r.why) ||
                !Known(state) || !Known(previous)) {
                return damaged();
            }
            r.state = static_cast<State>(state);
            r.previous = static_cast<State>(previous);
            r.eloped = eloped == 1;
            // An officiant from a plugin that is gone is simply unknown.
            RE::FormID officiantNow = 0;
            r.officiant = officiant && a_intfc->ResolveFormID(officiant, officiantNow)
                              ? static_cast<std::int32_t>(officiantNow)
                              : 0;
            RE::FormID now = 0;
            if (!a_intfc->ResolveFormID(savedId, now)) {
                ++dropped;
                continue;
            }
            g_records[now] = std::move(r);
        }
        SKSE::log::info("Marriage: {} records loaded from the save ({} dropped, their plugin gone); Mara's "
                        "exception {}",
                        g_records.size(), dropped, g_exception ? "granted" : "not granted");
    }

    void Revert() {
        const std::scoped_lock lock{ g_lock };
        g_records.clear();
        g_exception = false;
    }
}
