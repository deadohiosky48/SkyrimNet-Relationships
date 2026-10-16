#pragma once

#include <cstdint>

// THE CO-SAVE, SHARED (2.5). SKSE gives a plugin one unique id and one set of
// save, load and revert callbacks. The bond history had them to itself; the
// marriage record (Marriage.h) needs them too. This owns the callbacks and
// hands each record to the module whose type it is. The unique id is the one
// the history always used, so every save made since 2.0 reads as before.
namespace SNRom::Cosave {

    // SKSEPluginLoad. False if SKSE has no serialization interface for us.
    bool Register();
}
