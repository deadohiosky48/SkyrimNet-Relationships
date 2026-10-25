#pragma once

#include <string>

namespace RE {
    class Actor;
}

// MARAS, CALLED BY ITS OWN SHAPE (2.5, Build B; spec 12.1). Relationships owns
// marriage, so an engagement MARAS makes is reversed (SNRom_Bridge.
// OnMarasStatusChanged). MARAS 2.0 gave PromoteNPCToStatus a third parameter
// (sendEvent, defaulted), and Papyrus fills defaults when it compiles: our call,
// compiled against the two-parameter 0.x, would not bind against 2.0, and the
// reversal would silently stop holding. So the DLL looks the function up in the
// VM and passes as many arguments as the installed MARAS declares.
namespace SNRom::Maras {

    // MARAS.PromoteNPCToStatus(a_actor, a_status[, sendEvent = true]), as the
    // installed MARAS declares it. True when the call was sent; its own answer
    // arrives later and is logged. False when MARAS or the function is not
    // there, or declares a shape we do not know.
    bool PromoteToStatus(RE::Actor* a_actor, const std::string& a_status);
}
