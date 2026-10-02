#pragma once

#include <string>

// The UI framework that shows the dashboard page, behind the six operations the
// dashboard needs: create, listen, show, focus, hide, send.
//
// MERIDIAN ONLY (MeridianHost.cpp). PrismaUI is not supported for now - the
// author's decision, 2026-09-29, over its license: its API header is not MIT,
// and vendoring it would bring the first non-MIT third-party file into the
// repository. The interface stays anyway, because it costs nothing: a second
// host would be a new file and the one place that picks a host, with nothing in
// Dashboard.cpp changing.
namespace SNRom {

    // Called with ONE string, on the framework's own thread. Copy the payload
    // before returning: Meridian's pointer is valid only during the call.
    using ListenerFn = void (*)(const char* a_payload);

    enum class FocusOutcome {
        Granted,    // focused now, or already was
        Busy,       // another view holds focus; never stolen
        NotReady,   // the page has not finished loading
        Failed      // anything else: invalid view, shutting down
    };

    class ViewHost {
    public:
        virtual ~ViewHost() = default;

        [[nodiscard]] virtual const char* Name() const = 0;

        // Creates the view, hidden. Called once, at kDataLoaded.
        virtual bool Create() = 0;

        // Exposes window.<a_name>(string) to the page.
        virtual bool Listen(const char* a_name, ListenerFn a_fn) = 0;

        virtual bool Show() = 0;

        // Takes input and pauses the game while the view has focus.
        virtual FocusOutcome Focus() = 0;

        // Gives input back and hides the view. Safe to call when already hidden.
        virtual void Hide() = 0;

        [[nodiscard]] virtual bool HasFocus() const = 0;

        // Delivers one message to window.snromReceive. a_json must already be
        // ASCII-only JSON (dump with ensure_ascii), so nothing in it can end the
        // script early.
        virtual bool Send(const std::string& a_json) = 0;
    };
}
