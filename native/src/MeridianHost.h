#pragma once

#include "ViewHost.h"

#include <memory>

namespace SNRom {

    // Asks a running MeridianUI.dll for Meridian.View/1. Null when Meridian is
    // not installed or too old to offer it, which is a supported configuration:
    // no dashboard, and nothing else in the mod notices.
    //
    // Call at kInputLoaded. Meridian rejects a first query from later
    // worker-thread messages such as kDataLoaded (its author guide).
    std::unique_ptr<ViewHost> AcquireMeridian();
}
