#include "LoversComfort.h"

#include "PCH.h"

#include "Marriage.h"

#include <chrono>
#include <functional>
#include <thread>

namespace SNRom::LoversComfort {

    namespace {

        // Vanilla's handler is Papyrus, run after this event is dispatched;
        // it has run by the first look on an ordinary load, and a busy VM gets
        // a few more. After the last look nothing is changed.
        constexpr auto kFirstLook = std::chrono::milliseconds{ 1500 };
        constexpr auto kLookAgain = std::chrono::milliseconds{ 1000 };
        constexpr int  kLooks = 8;

        struct Vanilla {
            RE::SpellItem*  rested = nullptr;
            RE::SpellItem*  wellRested = nullptr;
            RE::SpellItem*  comfort = nullptr;
            RE::SpellItem*  loverStone = nullptr;
            RE::BGSMessage* message = nullptr;
        };

        void After(std::chrono::milliseconds a_delay, std::function<void()> a_task) {
            std::thread([a_delay, task = std::move(a_task)]() {
                std::this_thread::sleep_for(a_delay);
                SKSE::GetTaskInterface()->AddTask(task);
            }).detach();
        }

        template <class T>
        T* FormProperty(const RE::BSTSmartPointer<RE::BSScript::Object>& a_object, const char* a_name) {
            const auto* property = a_object->GetProperty(a_name);
            return property ? property->Unpack<T*>() : nullptr;
        }

        // Main thread. The sleep quest's spells and message, as its script
        // holds them; read each time, since a load can change what is bound.
        Vanilla ReadVanilla() {
            Vanilla out;
            auto* quest = RE::TESForm::LookupByEditorID<RE::TESQuest>("PlayerSleepQuest");
            auto* vm = RE::BSScript::Internal::VirtualMachine::GetSingleton();
            if (!quest || !vm) {
                return out;
            }
            const auto handle = vm->GetObjectHandlePolicy()->GetHandleForObject(RE::FormType::Quest, quest);
            RE::BSTSmartPointer<RE::BSScript::Object> object;
            if (!vm->FindBoundObject(handle, "PlayerSleepQuestScript", object) || !object) {
                return out;
            }
            out.rested = FormProperty<RE::SpellItem>(object, "Rested");
            out.wellRested = FormProperty<RE::SpellItem>(object, "WellRested");
            out.comfort = FormProperty<RE::SpellItem>(object, "MarriageSleepAbility");
            out.loverStone = FormProperty<RE::SpellItem>(object, "pDoomLoverAbility");
            out.message = FormProperty<RE::BGSMessage>(object, "MarriageRestedMessage");
            return out;
        }

        // A Relationships spouse in the player's location, as vanilla asks it
        // of its own spouse; nullptr if none.
        RE::Actor* SpouseHere(RE::PlayerCharacter* a_player) {
            auto* here = a_player->GetCurrentLocation();
            if (!here) {
                return nullptr;
            }
            for (const auto id : Marriage::WithState(Marriage::State::kMarried)) {
                auto* spouse = RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(id));
                if (spouse && !spouse->IsDead() && spouse->GetCurrentLocation() == here) {
                    return spouse;
                }
            }
            return nullptr;
        }

        void Look(int a_left) {
            auto* player = RE::PlayerCharacter::GetSingleton();
            const auto vanilla = ReadVanilla();
            if (!player || !vanilla.comfort || !vanilla.rested || !vanilla.wellRested) {
                SKSE::log::warn("Lover's Comfort: the sleep quest's spells could not be read; nothing is given");
                return;
            }
            if (player->HasSpell(vanilla.comfort)) {
                return;   // vanilla's own spouse, or given already
            }
            const bool rested = player->HasSpell(vanilla.rested) || player->HasSpell(vanilla.wellRested);
            if (!rested) {
                if (a_left > 1) {
                    After(kLookAgain, [a_left]() { Look(a_left - 1); });
                } else {
                    // Beast blood, the Lover Stone, or a VM too busy to tell.
                    SKSE::log::info("Lover's Comfort: no ordinary rest after sleeping, so nothing to replace");
                }
                return;
            }
            auto* spouse = SpouseHere(player);
            if (!spouse) {
                return;
            }
            player->RemoveSpell(vanilla.rested);
            player->RemoveSpell(vanilla.wellRested);
            player->AddSpell(vanilla.comfort);
            if (vanilla.message) {
                RE::BSString text;
                vanilla.message->GetDescription(text, vanilla.message);
                if (!text.empty()) {
                    RE::SendHUDMessage::ShowHUDMessage(text.c_str());
                }
            }
            SKSE::log::info("Lover's Comfort: slept near {}", spouse->GetDisplayFullName());
        }

        // Main thread. LAST NIGHT'S REST, CLEARED AS THEY LIE DOWN: vanilla
        // clears every rested state on waking anyway, so this changes nothing
        // the player keeps, and a Rested seen after waking is then vanilla's
        // own, given just now, never one left from the night before. Not for
        // the Lover Stone, which vanilla leaves as it was.
        void LieDown() {
            auto* player = RE::PlayerCharacter::GetSingleton();
            const auto vanilla = ReadVanilla();
            if (!player || !vanilla.rested || !vanilla.wellRested ||
                (vanilla.loverStone && player->HasSpell(vanilla.loverStone))) {
                return;
            }
            player->RemoveSpell(vanilla.rested);
            player->RemoveSpell(vanilla.wellRested);
        }

        class Sink final : public RE::BSTEventSink<RE::TESSleepStartEvent>,
                           public RE::BSTEventSink<RE::TESSleepStopEvent> {
        public:
            RE::BSEventNotifyControl ProcessEvent(const RE::TESSleepStartEvent*,
                                                  RE::BSTEventSource<RE::TESSleepStartEvent>*) override {
                if (!Marriage::WithState(Marriage::State::kMarried).empty()) {
                    SKSE::GetTaskInterface()->AddTask([]() { LieDown(); });
                }
                return RE::BSEventNotifyControl::kContinue;
            }

            RE::BSEventNotifyControl ProcessEvent(const RE::TESSleepStopEvent*,
                                                  RE::BSTEventSource<RE::TESSleepStopEvent>*) override {
                if (!Marriage::WithState(Marriage::State::kMarried).empty()) {
                    After(kFirstLook, []() { Look(kLooks); });
                }
                return RE::BSEventNotifyControl::kContinue;
            }
        };
    }

    void Register() {
        static Sink sink;
        auto* events = RE::ScriptEventSourceHolder::GetSingleton();
        if (!events) {
            return;
        }
        events->AddEventSink<RE::TESSleepStartEvent>(&sink);
        events->AddEventSink<RE::TESSleepStopEvent>(&sink);
        SKSE::log::info("Lover's Comfort: given for every spouse nearby on waking");
    }
}
