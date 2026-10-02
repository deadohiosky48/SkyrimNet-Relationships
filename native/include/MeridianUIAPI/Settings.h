// SPDX-License-Identifier: MIT

#pragma once

#include <cstdint>

namespace Meridian::UI
{
    /// <summary>
    /// Renderer for browser surfaces.
    /// - RingBuffer (default): triple-buffered shared-texture ring; honors
    ///   per-browser rect/scale/z geometry. Use this.
    /// - SyncCopy: synchronous full-copy renderer; slower, full geometry
    ///   parity since 1.0. Fallback/diagnostic path, selectable via INI.
    /// - DeferredContext: legacy pre-1.0 copy renderer (D3D11 deferred
    ///   context), fullscreen only — ignores rect/scale geometry. Kept for
    ///   compatibility/diagnostics; deliberately NOT selectable via
    ///   MeridianUI.ini.
    /// </summary>
    enum class RendererType : char
    {
        DeferredContext = 0,
        SyncCopy = 1,
        RingBuffer = 2,
    };

    /// <summary>
    /// Minimum accepted structSize for a caller-supplied Settings: the full
    /// 1.0 struct size. Any caller whose structSize claims less than this is
    /// either pre-1.0 (predates structSize entirely) or corrupt, and cannot
    /// be read.
    /// </summary>
    inline constexpr std::uint32_t kSettingsMinSize10 = 12;

    /// <summary>
    /// Global (API) settings
    /// </summary>
    struct Settings
    {
        /// <summary>Caller MUST leave this as-is (defaulted to sizeof). The
        /// platform copies min(structSize, its own sizeof) and defaults the
        /// rest — 1.x can append fields without breaking compiled callers.</summary>
        std::uint32_t structSize = sizeof(Settings);
        /// <summary>
        /// Cef debugging port. 0 (or any value
        /// outside CEF's [1024, 65535] range) disables remote debugging.
        /// </summary>
        int remoteDebuggingPort = 0;
        /// <summary>
        /// Set to true to allow language switching in the game native menus (console, race, etc.)
        /// </summary>
        bool nativeMenuLangSwitching = true;
        /// <summary>
        /// Renderer type
        /// </summary>
        RendererType rendererType = RendererType::RingBuffer;
        char pad1[2] = {};
        /// <summary>
        /// Development-only opt-in for ordinary remote HTTP/HTTPS content in
        /// browsers without native bindings. False keeps every browser on a
        /// pinned mod:// host, which is the secure release default.
        /// </summary>
        bool allowRemoteContent = false;
        char pad2[3] = {};
    };
    static_assert(sizeof(Settings) == 16);

    /// <summary>
    /// Minimum accepted structSize for a caller-supplied BrowserSettings: the
    /// full 1.0 struct size. Any caller whose structSize claims less than
    /// this is either pre-1.0 (predates structSize entirely) or corrupt, and
    /// cannot be read.
    /// </summary>
    inline constexpr std::uint32_t kBrowserSettingsMinSize10 = 12;

    /// <summary>
    /// Browser settings
    /// </summary>
    struct BrowserSettings
    {
        /// <summary>Caller MUST leave this as-is (defaulted to sizeof). The
        /// platform copies min(structSize, its own sizeof) and defaults the
        /// rest — 1.x can append fields without breaking compiled callers.</summary>
        std::uint32_t structSize = sizeof(BrowserSettings);
        /// <summary>
        /// Desired frame rate
        /// </summary>
        int frameRate = 60;
        int reservPad = 0;
    };
    static_assert(sizeof(BrowserSettings) == 12);
}
