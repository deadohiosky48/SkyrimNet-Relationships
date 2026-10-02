#pragma once

#include "ViewHost.h"

#include <memory>

namespace SNRom {

    // Asks a running PrismaUI.dll for its modder interface v1. Null when Prisma
    // UI is not installed, which is a supported configuration.
    //
    // Prisma asks to be queried at or after kPostLoad; kInputLoaded, where
    // Meridian is asked, comes after it.
    std::unique_ptr<ViewHost> AcquirePrisma();
}
