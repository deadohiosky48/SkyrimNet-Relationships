#include "Rings.h"

#include "PCH.h"

#include "Marriage.h"

#include <chrono>
#include <map>
#include <mutex>
#include <thread>

namespace SNRom::Rings {

    namespace {

        constexpr auto kPlugin = "SNRom_Integration.esl";
        constexpr RE::FormID kSpouseHere = 0xD69;      // GLOB SNRom_SpouseHere
        constexpr RE::FormID kEngagementRing = 0xD66;  // ARMO SNRom_EngagementRingGold
        constexpr RE::FormID kWeddingRing = 0xD68;     // ARMO SNRom_WeddingRingGold
        constexpr float      kNear = 2048.0f;
        constexpr auto       kReequipDelay = std::chrono::seconds{ 2 };
        constexpr auto       kFightWindow = std::chrono::seconds{ 15 };

        template <class T>
        T* Ours(RE::FormID a_local) {
            auto* data = RE::TESDataHandler::GetSingleton();
            return data ? data->LookupForm<T>(a_local, kPlugin) : nullptr;
        }

        bool IsMarriageRing(RE::FormID a_id) {
            static const auto engagement = [] {
                auto* f = Ours<RE::TESObjectARMO>(kEngagementRing);
                return f ? f->GetFormID() : 0;
            }();
            static const auto wedding = [] {
                auto* f = Ours<RE::TESObjectARMO>(kWeddingRing);
                return f ? f->GetFormID() : 0;
            }();
            return a_id && (a_id == engagement || a_id == wedding);
        }

        void After(std::chrono::milliseconds a_delay, std::function<void()> a_task) {
            std::thread([a_delay, task = std::move(a_task)]() {
                std::this_thread::sleep_for(a_delay);
                SKSE::GetTaskInterface()->AddTask(task);
            }).detach();
        }

        // Main thread: does a_actor still carry a_item?
        bool Carries(RE::Actor* a_actor, RE::TESBoundObject* a_item) {
            const auto counts = a_actor->GetInventoryCounts([a_item](RE::TESBoundObject& a_obj) { return &a_obj == a_item; });
            const auto it = counts.find(a_item);
            return it != counts.end() && it->second > 0;
        }

        std::mutex                                                         g_lock;
        std::map<RE::FormID, std::chrono::steady_clock::time_point>      g_putBack;

        void PutBack(RE::FormID a_actorId, RE::FormID a_ringId) {
            auto* actor = RE::TESForm::LookupByID<RE::Actor>(a_actorId);
            auto* ring = RE::TESForm::LookupByID<RE::TESObjectARMO>(a_ringId);
            if (!actor || !ring || actor->IsDead() || !Carries(actor, ring)) {
                return;
            }
            if (actor->GetWornArmor(RE::BGSBipedObjectForm::BipedObjectSlot::kRing) == ring) {
                return;   // already back on, by whatever took it off
            }
            RE::ActorEquipManager::GetSingleton()->EquipObject(actor, ring);
            SKSE::log::info("Rings: {:08X} put their ring back on", a_actorId);
        }

        class Sink final : public RE::BSTEventSink<RE::TESEquipEvent>,
                           public RE::BSTEventSink<RE::TESActorLocationChangeEvent> {
        public:
            RE::BSEventNotifyControl ProcessEvent(const RE::TESEquipEvent* a_event,
                                                  RE::BSTEventSource<RE::TESEquipEvent>*) override {
                if (!a_event || a_event->equipped || !a_event->actor || !IsMarriageRing(a_event->baseObject)) {
                    return RE::BSEventNotifyControl::kContinue;
                }
                auto* actor = a_event->actor->As<RE::Actor>();
                if (!actor || actor->IsPlayerRef()) {
                    return RE::BSEventNotifyControl::kContinue;
                }
                const auto id = static_cast<std::int32_t>(actor->GetFormID());
                const bool wearsOurs = Marriage::Ring(id, true) == static_cast<std::int32_t>(a_event->baseObject);
                if (!wearsOurs || !(Marriage::Engaged(id) || Marriage::Married(id))) {
                    return RE::BSEventNotifyControl::kContinue;
                }
                const auto now = std::chrono::steady_clock::now();
                {
                    const std::scoped_lock lock{ g_lock };
                    const auto it = g_putBack.find(actor->GetFormID());
                    if (it != g_putBack.end() && now - it->second < kFightWindow) {
                        SKSE::log::warn("Rings: {:08X}'s ring came off again within {}s of going back on; something "
                                        "is enforcing an outfit, so it stays in their inventory",
                                        actor->GetFormID(), kFightWindow.count());
                        return RE::BSEventNotifyControl::kContinue;
                    }
                    g_putBack[actor->GetFormID()] = now;
                }
                const auto actorId = actor->GetFormID();
                const auto ringId = a_event->baseObject;
                After(kReequipDelay, [actorId, ringId]() { PutBack(actorId, ringId); });
                return RE::BSEventNotifyControl::kContinue;
            }

            RE::BSEventNotifyControl ProcessEvent(const RE::TESActorLocationChangeEvent* a_event,
                                                  RE::BSTEventSource<RE::TESActorLocationChangeEvent>*) override {
                if (a_event && a_event->actor && a_event->actor->IsPlayerRef()) {
                    UpdateSpouseHere();
                    // Followers arrive a moment after the player does.
                    After(std::chrono::seconds{ 3 }, []() { UpdateSpouseHere(); });
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
        events->AddEventSink<RE::TESEquipEvent>(&sink);
        events->AddEventSink<RE::TESActorLocationChangeEvent>(&sink);
        SKSE::log::info("Rings: watching marriage rings and the player's location");
    }

    void UpdateSpouseHere() {
        auto* global = Ours<RE::TESGlobal>(kSpouseHere);
        auto* player = RE::PlayerCharacter::GetSingleton();
        if (!global || !player) {
            return;
        }
        auto*      here = player->GetCurrentLocation();
        const auto pos = player->GetPosition();
        bool       found = false;
        for (const auto id : Marriage::WithState(Marriage::State::kMarried)) {
            auto* spouse = RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(id));
            if (!spouse || spouse->IsDead() || !spouse->Is3DLoaded()) {
                continue;
            }
            if ((here && spouse->GetCurrentLocation() == here) || spouse->GetPosition().GetDistance(pos) <= kNear) {
                found = true;
                break;
            }
        }
        const float value = found ? 1.0f : 0.0f;
        if (global->value != value) {
            global->value = value;
            SKSE::log::info("Rings: a spouse is {}here", found ? "" : "no longer ");
        }
    }

    namespace {
        // Main thread: name the copy of a_ring that a_actor wears.
        void Name(RE::FormID a_actor, RE::FormID a_ring, const std::string& a_name) {
            auto* actor = RE::TESForm::LookupByID<RE::Actor>(a_actor);
            auto* ring = RE::TESForm::LookupByID<RE::TESBoundObject>(a_ring);
            auto* changes = actor ? actor->GetInventoryChanges() : nullptr;
            if (!ring || !changes || !changes->entryList) {
                return;
            }
            for (auto* entry : *changes->entryList) {
                if (!entry || entry->object != ring || !entry->extraLists) {
                    continue;
                }
                RE::ExtraDataList* worn = nullptr;
                for (auto* list : *entry->extraLists) {
                    if (list && list->HasType(RE::ExtraDataType::kWorn)) {
                        worn = list;
                        break;
                    }
                }
                if (!worn) {
                    SKSE::log::warn("Rings: {:08X} is not wearing {:08X}; not named", a_actor, a_ring);
                    return;
                }
                if (auto* text = worn->GetByType<RE::ExtraTextDisplayData>()) {
                    text->SetName(a_name.c_str());
                } else {
                    worn->Add(new RE::ExtraTextDisplayData(a_name.c_str()));
                }
                SKSE::log::info("Rings: {:08X} wears \"{}\"", a_actor, a_name);
                return;
            }
        }

        void TryWear(RE::FormID a_actor, RE::FormID a_ring, std::string a_name, int a_tries) {
            After(std::chrono::milliseconds{ 500 }, [=]() {
                auto* ui = RE::UI::GetSingleton();
                if (ui && ui->GameIsPaused()) {
                    if (a_tries < 600) {   // five minutes of menus, then give up
                        TryWear(a_actor, a_ring, a_name, a_tries + 1);
                    }
                    return;
                }
                auto* actor = RE::TESForm::LookupByID<RE::Actor>(a_actor);
                auto* ring = RE::TESForm::LookupByID<RE::TESObjectARMO>(a_ring);
                if (!actor || !ring || actor->IsDead() || !Carries(actor, ring)) {
                    return;
                }
                if (actor->GetWornArmor(RE::BGSBipedObjectForm::BipedObjectSlot::kRing) != ring) {
                    RE::ActorEquipManager::GetSingleton()->EquipObject(actor, ring);
                }
                After(std::chrono::seconds{ 1 }, [=]() { Name(a_actor, a_ring, a_name); });
            });
        }
    }

    void WearWhenResumed(RE::FormID a_actor, RE::FormID a_ring, std::string a_name) {
        TryWear(a_actor, a_ring, std::move(a_name), 0);
    }

    void UpdateSpouseHereSoon() {
        SKSE::GetTaskInterface()->AddTask([]() { UpdateSpouseHere(); });
    }
}
