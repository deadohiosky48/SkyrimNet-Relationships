#include "History.h"

#include "PCH.h"

#include <deque>
#include <mutex>
#include <unordered_map>

namespace SNRom::History {

    namespace {

        // The co-save record. The unique id is this plugin's claim on its own
        // records in the .skse file; the type tags the one kind of record it
        // writes. Bump kRecordVersion when the layout below changes, and keep
        // reading the old one.
        constexpr std::uint32_t kUniqueId = 'SNRH';
        constexpr std::uint32_t kRecordType = 'HIST';
        constexpr std::uint32_t kRecordVersion = 1;

        // Generous bounds: a reason is one sentence, and the dashboard shows
        // it on one line or a short paragraph. Also what a damaged co-save is
        // refused at, rather than allocated.
        constexpr std::size_t kMaxKind = 32;
        constexpr std::size_t kMaxReason = 600;
        constexpr std::uint32_t kMaxBonds = 100000;

        struct Entry {
            float        day = 0.0f;  // game days, as Utility.GetCurrentGameTime
            std::int32_t delta = 0;
            std::int32_t total = 0;
            std::string  kind;
            std::string  reason;
        };

        std::mutex                                                g_lock;
        std::unordered_map<std::uint32_t, std::deque<Entry>> g_bonds;  // newest at the front

        // Cut at a byte limit without splitting a UTF-8 sequence: back up over
        // continuation bytes (10xxxxxx) to the start of the character.
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

        float GameDay() {
            const auto* calendar = RE::Calendar::GetSingleton();
            return calendar ? calendar->GetCurrentGameTime() : 0.0f;
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

        void Save(SKSE::SerializationInterface* a_intfc) {
            const std::scoped_lock lock{ g_lock };
            if (!a_intfc->OpenRecord(kRecordType, kRecordVersion)) {
                SKSE::log::error("History: could not open the co-save record; this save has no history");
                return;
            }
            const auto bonds = static_cast<std::uint32_t>(g_bonds.size());
            a_intfc->WriteRecordData(bonds);
            for (const auto& [formId, entries] : g_bonds) {
                a_intfc->WriteRecordData(formId);
                a_intfc->WriteRecordData(static_cast<std::uint32_t>(entries.size()));
                for (const auto& e : entries) {
                    a_intfc->WriteRecordData(e.day);
                    a_intfc->WriteRecordData(e.delta);
                    a_intfc->WriteRecordData(e.total);
                    WriteString(a_intfc, e.kind);
                    WriteString(a_intfc, e.reason);
                }
            }
        }

        void Load(SKSE::SerializationInterface* a_intfc) {
            const std::scoped_lock lock{ g_lock };
            g_bonds.clear();
            std::uint32_t type = 0;
            std::uint32_t version = 0;
            std::uint32_t length = 0;
            std::size_t   kept = 0;
            std::size_t   dropped = 0;
            while (a_intfc->GetNextRecordInfo(type, version, length)) {
                if (type != kRecordType) {
                    continue;
                }
                if (version != kRecordVersion) {
                    SKSE::log::warn("History: co-save record version {} is not one this DLL reads; skipped", version);
                    continue;
                }
                std::uint32_t bonds = 0;
                if (a_intfc->ReadRecordData(bonds) != sizeof(bonds) || bonds > kMaxBonds) {
                    SKSE::log::error("History: the co-save record is damaged; this save's history is empty");
                    g_bonds.clear();
                    return;
                }
                for (std::uint32_t b = 0; b < bonds; ++b) {
                    std::uint32_t savedId = 0;
                    std::uint32_t count = 0;
                    if (a_intfc->ReadRecordData(savedId) != sizeof(savedId) ||
                        a_intfc->ReadRecordData(count) != sizeof(count) || count > kKeep * 4) {
                        SKSE::log::error("History: the co-save record is damaged; this save's history is empty");
                        g_bonds.clear();
                        return;
                    }
                    std::deque<Entry> entries;
                    for (std::uint32_t i = 0; i < count; ++i) {
                        Entry e;
                        if (a_intfc->ReadRecordData(e.day) != sizeof(e.day) ||
                            a_intfc->ReadRecordData(e.delta) != sizeof(e.delta) ||
                            a_intfc->ReadRecordData(e.total) != sizeof(e.total) || !ReadString(a_intfc, e.kind) ||
                            !ReadString(a_intfc, e.reason)) {
                            SKSE::log::error("History: the co-save record is damaged; this save's history is empty");
                            g_bonds.clear();
                            return;
                        }
                        entries.push_back(std::move(e));
                    }
                    // A FormID moves when the load order does; SKSE maps the
                    // saved one to today's. A plugin that is gone takes its
                    // characters' history with it.
                    RE::FormID now = 0;
                    if (!a_intfc->ResolveFormID(savedId, now)) {
                        dropped += entries.size();
                        continue;
                    }
                    while (entries.size() > kKeep) {
                        entries.pop_back();
                    }
                    kept += entries.size();
                    g_bonds[now] = std::move(entries);
                }
            }
            SKSE::log::info("History: {} changes for {} bonds loaded from the save; {} dropped, their "
                            "characters' plugin gone",
                            kept, g_bonds.size(), dropped);
        }

        // A new game, and before any load: the history belongs to the save
        // being left (design 6.4 - nothing outlives its timeline).
        void Revert(SKSE::SerializationInterface*) {
            const std::scoped_lock lock{ g_lock };
            g_bonds.clear();
        }
    }

    void Record(std::int32_t a_formId, std::string a_kind, std::int32_t a_delta, std::int32_t a_total,
                std::string a_reason) {
        if (a_formId == 0) {
            return;
        }
        Truncate(a_kind, kMaxKind);
        // Papyrus keeps one copy of each string whatever its case, so "talk"
        // can arrive as "Talk" (seen in play 2026-10-01). Kinds are ASCII
        // words; the page looks them up in lower case.
        for (auto& c : a_kind) {
            if (c >= 'A' && c <= 'Z') {
                c = static_cast<char>(c - 'A' + 'a');
            }
        }
        Truncate(a_reason, kMaxReason);
        Entry e{ GameDay(), a_delta, a_total, std::move(a_kind), std::move(a_reason) };
        const std::scoped_lock lock{ g_lock };
        auto& entries = g_bonds[static_cast<std::uint32_t>(a_formId)];
        entries.push_front(std::move(e));
        while (entries.size() > kKeep) {
            entries.pop_back();
        }
    }

    nlohmann::json Recent(std::int32_t a_formId) {
        auto out = nlohmann::json::array();
        const std::scoped_lock lock{ g_lock };
        const auto it = g_bonds.find(static_cast<std::uint32_t>(a_formId));
        if (it == g_bonds.end()) {
            return out;
        }
        for (const auto& e : it->second) {
            out.push_back({ { "day", e.day },
                            { "delta", e.delta },
                            { "total", e.total },
                            { "kind", e.kind },
                            { "reason", e.reason } });
        }
        return out;
    }

    bool Register() {
        const auto* serialization = SKSE::GetSerializationInterface();
        if (!serialization) {
            return false;
        }
        serialization->SetUniqueID(kUniqueId);
        serialization->SetSaveCallback(Save);
        serialization->SetLoadCallback(Load);
        serialization->SetRevertCallback(Revert);
        return true;
    }
}
