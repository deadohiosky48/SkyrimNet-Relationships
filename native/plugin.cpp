#include "PCH.h"

#include "src/Dashboard.h"
#include "src/History.h"
#include "src/Hotkey.h"
#include "src/Natives.h"
#include "src/Notices.h"
#include "src/Settings.h"

namespace {

    void InitLogging() {
        auto path = SKSE::log::log_directory();
        if (!path) {
            return;
        }
        *path /= "SkyrimNetRelationships.log";
        auto sink = std::make_shared<spdlog::sinks::basic_file_sink_mt>(path->string(), true);
        auto log = std::make_shared<spdlog::logger>("global", std::move(sink));
        log->set_level(spdlog::level::info);
        log->flush_on(spdlog::level::info);
        spdlog::set_default_logger(std::move(log));
        // The thread id, so a line can be matched to the thread that wrote it:
        // everything that touches the view must log from the main thread,
        // the one SKSE tasks run on (Dashboard.cpp).
        spdlog::set_pattern("[%H:%M:%S.%e] [%t] [%l] %v");
    }

    void OnMessage(SKSE::MessagingInterface::Message* a_msg) {
        switch (a_msg->type) {
        // Meridian is asked at kInputLoaded: it refuses a first query from
        // later worker-thread messages. The input device manager exists by now
        // too.
        case SKSE::MessagingInterface::kInputLoaded:
            SNRom::Dashboard::OnInputLoaded();
            SNRom::Hotkey::Attach();
            break;
        // The view is created once forms exist (Meridian's two-stage startup).
        // The settings watcher starts here too, after the sink it binds for:
        // its first look applies the saved settings before any save loads.
        case SKSE::MessagingInterface::kDataLoaded:
            SNRom::Dashboard::OnDataLoaded();
            SNRom::Settings::StartWatching();
            SNRom::Notices::Start();
            break;
        // THE READ MODEL NEVER OUTLIVES ITS TIMELINE. Cleared before any save
        // loads and when a new game starts, so the dashboard can't show a
        // later save's values after a reload (design 6.4).
        case SKSE::MessagingInterface::kPreLoadGame:
        case SKSE::MessagingInterface::kNewGame:
            SNRom::Dashboard::OnGameLoading();
            SNRom::Notices::Clear();
            break;
        default:
            break;
        }
    }
}

SKSEPluginLoad(const SKSE::LoadInterface* a_skse) {
    InitLogging();
    SKSE::Init(a_skse);

    SKSE::log::info("SkyrimNet Relationships plugin loading");

    // Registered before the messaging listener, so the VM has them the moment
    // scripts run. SNRom_Bridge hands the dashboard settings over through them
    // at every bootstrap; the settings watcher keeps them current in between.
    SNRom::Natives::Register(SKSE::GetPapyrusInterface());

    // What moved each bond lives in the co-save, so it rolls back with the
    // save that holds the points it explains (History.h).
    if (!SNRom::History::Register()) {
        SKSE::log::error("No serialization interface: bond history will not be kept this session");
    }

    // THIS DLL IS OPTIONAL, AND NOTHING MAY COME TO DEPEND ON IT. Without it
    // the player loses the dashboard and nothing else. Without Meridian UI it
    // still loads, logs why there is no dashboard, and carries on.
    if (!SKSE::GetMessagingInterface()->RegisterListener(OnMessage)) {
        SKSE::log::error("Could not register the messaging listener: no dashboard this session");
        return false;
    }

    return true;
}
