#pragma once

#include "ViewHost.h"

#include <memory>

namespace SNRom {

    // Asks a running Magelight.dll for its v4 interface. Null when Magelight UI
    // is not installed - a supported configuration. Magelight comes with
    // SeverActions 4.x, so many players have it without knowing.
    std::unique_ptr<ViewHost> AcquireMagelight();
}
