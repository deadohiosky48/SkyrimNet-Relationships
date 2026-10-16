#include "Cosave.h"

#include "PCH.h"

#include "History.h"
#include "Marriage.h"

namespace SNRom::Cosave {

    namespace {

        // This plugin's claim on its records in the .skse file. The history's
        // since 2.0; kept, so every earlier save loads unchanged.
        constexpr std::uint32_t kUniqueId = 'SNRH';

        void Save(SKSE::SerializationInterface* a_intfc) {
            History::Save(a_intfc);
            Marriage::Save(a_intfc);
        }

        void Load(SKSE::SerializationInterface* a_intfc) {
            // Empty first: a save made before 2.5 has no marriage record, and
            // must not inherit the marriages of the save just left.
            History::Revert();
            Marriage::Revert();
            std::uint32_t type = 0;
            std::uint32_t version = 0;
            std::uint32_t length = 0;
            while (a_intfc->GetNextRecordInfo(type, version, length)) {
                switch (type) {
                case History::kRecordType:
                    History::Load(a_intfc, version);
                    break;
                case Marriage::kRecordType:
                    Marriage::Load(a_intfc, version);
                    break;
                default:
                    SKSE::log::warn("Co-save: a record of unknown type {:08X} skipped", type);
                    break;
                }
            }
        }

        // A new game, and before any load: nothing outlives its timeline
        // (design 6.4).
        void Revert(SKSE::SerializationInterface*) {
            History::Revert();
            Marriage::Revert();
        }
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
