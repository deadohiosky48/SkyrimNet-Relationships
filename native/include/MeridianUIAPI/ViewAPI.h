// SPDX-License-Identifier: MIT

#pragma once

#include "Settings.h"

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace Meridian::UI::View
{
    inline constexpr char EXTENSION_NAME[] = "Meridian.View";
    inline constexpr std::uint32_t INTERFACE_VERSION = 1;

    using ViewHandle = std::uint64_t;
    inline constexpr ViewHandle INVALID_VIEW_HANDLE = 0;

    using ListenerCallback = void(__cdecl*)(const char* a_payload);
    using DOMReadyCallback = void(__cdecl*)(ViewHandle a_view);

    enum class FocusMode : std::uint32_t
    {
        Unpaused = 0,
        PauseGame = 1,
    };

    enum class FocusResult : std::uint32_t
    {
        Granted = 0,
        AlreadyFocused = 1,
        Busy = 2,
        NotReady = 3,
        InvalidView = 4,
        ShuttingDown = 5,
    };

    struct ViewCreateInfo
    {
        std::uint32_t structSize = sizeof(ViewCreateInfo);
        const char* ownerName = nullptr;
        const char* viewName = nullptr;
        const char* startUrl = nullptr;
        std::int32_t frameRate = 60;
        bool initiallyVisible = false;
        std::uint8_t reserved[3] = {};
        DOMReadyCallback onDOMReady = nullptr;
    };

    inline constexpr std::uint32_t VIEW_CREATE_INFO_MIN_SIZE_1 =
        static_cast<std::uint32_t>(offsetof(ViewCreateInfo, onDOMReady) + sizeof(DOMReadyCallback));
    static_assert(sizeof(ViewCreateInfo) == VIEW_CREATE_INFO_MIN_SIZE_1);

    inline bool IsSupported(const char* a_name, std::uint32_t a_version)
    {
        return a_name != nullptr &&
               std::strcmp(a_name, EXTENSION_NAME) == 0 &&
               a_version == INTERFACE_VERSION;
    }

    class IViewAPI
    {
    public:
        virtual ~IViewAPI() = default;

        virtual ViewHandle __cdecl CreateView(const ViewCreateInfo* a_info) = 0;
        virtual void __cdecl DestroyView(ViewHandle a_view) = 0;
        virtual bool __cdecl IsValid(ViewHandle a_view) const = 0;
        virtual bool __cdecl IsReady(ViewHandle a_view) const = 0;

        /// Listener callbacks run on Meridian's CEF callback thread. Skyrim
        /// state changes must be marshalled through SKSE's task interface.
        virtual bool __cdecl RegisterListener(ViewHandle a_view,
                                              const char* a_name,
                                              ListenerCallback a_callback) = 0;
        virtual bool __cdecl ExecuteJavaScript(ViewHandle a_view, const char* a_script) = 0;

        virtual bool __cdecl Show(ViewHandle a_view) = 0;
        virtual bool __cdecl Hide(ViewHandle a_view) = 0;
        virtual FocusResult __cdecl TryFocus(ViewHandle a_view, FocusMode a_mode) = 0;
        virtual void __cdecl Unfocus(ViewHandle a_view) = 0;
        virtual bool __cdecl HasFocus(ViewHandle a_view) const = 0;
        virtual bool __cdecl HasAnyFocus() const = 0;
    };

    using QueryMeridianExtensionFn = bool(__cdecl*)(const char* a_name,
                                                    std::uint32_t a_version,
                                                    void** a_outInterface,
                                                    Meridian::UI::Settings* a_settings,
                                                    const char* a_consumerName);
}
