#pragma once

#include <array>
#include <chrono>
#include <cstdint>
#include <functional>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include <nlohmann/json.hpp>

#include "Display.h"

// ---------------------------------------------------------------------------
// THE READ MODEL (design 7.3, "WP2 transport").
//
// What the dashboard shows, pushed here by Papyrus through the SNRom_Native
// natives. DERIVED, NEVER READ BACK AS TRUTH: the co-save and the disposition
// store stay authoritative, and this is cleared whenever a save loads
// (kPreLoadGame, kNewGame), so it cannot outlive the timeline it came from.
// That keeps open question 19 (bond state owned by the DLL) open.
//
// FREE OF GAME TYPES, so a plain g++ harness can test it: form ids are ints,
// time is steady_clock, and the one thing only the game can answer (the name
// of an actor with no text pushed yet) comes in through a callback.
//
// THREADS. The natives write it from a Papyrus VM thread and the main thread
// reads it to build snapshots, so every public member takes the lock. Nothing
// here touches the view; Dashboard.cpp does that, on the main thread.
// ---------------------------------------------------------------------------
namespace SNRom::Model {

    // -----------------------------------------------------------------------
    // THE NUMBERS ARRAY, SNRom_Native.PutBondNumbers. Papyrus builds it in
    // SNRom_Bridge.DashboardNumbers, in exactly this order; that function
    // cites this list, and a change to one is a change to both. Every value
    // is an Int. Game times are whole game MINUTES (days x 1440), -1 for never,
    // because the arrays are Int[] and a minute is finer than anything shown.
    //
    // STORAGEUTIL READS ONLY, points included since WP4 made them ours (7.3,
    // "Measured in play": a refresh makes no per-bond call that waits a frame).
    // What the engine knows (following, loaded, child, married, the name) the
    // DLL reads itself when it builds a snapshot; see Display.h.
    // -----------------------------------------------------------------------
    enum Number : std::size_t {
        kPoints,            // DashboardPoints [0]: SNRom_Bridge.PointsOf, ours since WP4
        kTier,              // DashboardPoints [1]: derived from the points, 0-5
        kBanked,            // DashboardPoints [2]: StorageUtil Int SNRom_BankedPoints
        kLastFollowingAt,   // StorageUtil Float SNRom_LastFollowingAt, minutes or -1
        kAutoEnrolled,      // StorageUtil Int SNRom_AutoEnrolled, 0/1
        kEnrolledFlag,      // StorageUtil Int SNRom_Enrolled, 0/1
        kStance,            // StorageUtil Int SNRom_PlayerStance: -1, 0, 1
        kAskPending,        // StorageUtil Int SNRom_AskPending, 0/1
        kSparked,           // StorageUtil Int SNRom_Sparked, 0/1
        kSparkDecided,      // SNRom_Bridge.SparkDecided (StorageUtil), 0/1
        kSparkedAt,         // StorageUtil Float SNRom_SparkedAt, minutes or -1
        kLastSparkCheck,    // StorageUtil Float SNRom_LastSparkCheck, minutes or -1
        kEndedAt,           // StorageUtil Float SNRom_EndedAt, minutes or -1
        kSeeded,            // StorageUtil Int SNRom_Seeded, 0/1
        kAuthored,          // StorageUtil Int SNRom_DispositionAuthored: 0, 1 LLM, 2 archetype
        kIntimacy,          // SNRom_Decorators.IntimacyRank(SNRom_PhysMinTier): 0-3
        kArdor,             // StorageUtil Int SNRom_Ardor, 0-4
        kExclusivity,       // StorageUtil Int SNRom_Exclusivity, 0-100
        kOrientation,       // StorageUtil Int SNRom_Orientation: 0 none, 1 men, 2 women, 3 both
        kOrientationBasis,  // StorageUtil Int SNRom_OrientationKnown: 0-2
        kPlayerKin,         // SNRom_Decorators.IsPlayerKin (StorageUtil), 0/1
        kNumberCount
    };

    // -----------------------------------------------------------------------
    // THE TEXT ARRAY, SNRom_Native.PutBondText. Built by
    // SNRom_Bridge.DashboardText in exactly this order, which cites this list.
    // Text changes only at authoring, so it is pushed on the first open after
    // a load and by its writers after that (the numbers come every open). The
    // name is not here: the DLL reads it from the engine.
    // -----------------------------------------------------------------------
    enum Text : std::size_t {
        kWhy,      // store key <formId>.Why
        kLimit,    // store key <formId>.Limit
        kAddress,  // store key <formId>.Address
        kTextCount
    };

    using Numbers = std::array<std::int32_t, kNumberCount>;
    using Texts = std::array<std::string, kTextCount>;

    // 3 added settings.scale and settings.textSize.
    inline constexpr int kSchemaVersion = 3;

    // Where tiers 0-5 begin (snapshot.schema.json, ladder).
    inline constexpr std::array<int, 6> kThresholds{ 0, 500, 1000, 1500, 2000, 2500 };

    // What a refresh asks Papyrus for: everything, or the numbers alone.
    enum class Scope { kFull, kNumbers };

    // The snapshot's roster.status.
    enum class Status { kReading, kCurrent, kNotReady, kNoAnswer };

    std::string_view ScopeName(Scope a_scope);
    std::string_view StatusName(Status a_status);

    // What became of a push.
    enum class Push {
        kAccepted,
        kStale,      // from a refresh asked before the last load; dropped
        kWrongSize,  // the scripts and the DLL disagree on the field order
    };

    struct Refresh {
        std::uint32_t generation = 0;
        Scope         scope = Scope::kNumbers;
    };

    // What RefreshDone came to.
    struct Finished {
        bool          accepted = false;  // false: not the refresh we are waiting for
        bool          ok = false;        // false: Papyrus said "not ready"
        bool          late = false;      // answered after the no-answer notice went out
        Scope         scope = Scope::kNumbers;
        std::string   message;           // why not ready
        std::int64_t  milliseconds = 0;  // from the ModEvent to RefreshDone
        std::size_t   bonds = 0;         // bonds in the model afterwards
        std::size_t   pushed = 0;        // rows this refresh pushed numbers for
        std::int32_t  reported = 0;      // how many Papyrus says it pushed
        std::size_t   dropped = 0;       // rows no longer on the roster
    };

    // A page action handed to Papyrus and not yet answered.
    struct Action {
        std::int32_t              requestId = 0;
        std::string               pageId;  // the page's request id, which the result carries back
        std::string               op;
        std::int32_t              subject = 0;  // form id; 0 for a playthrough action
        std::vector<std::int32_t> args;
        bool                      longRunning = false;
        bool                      pageAnswered = false;  // the page was already told it timed out
    };

    // What the DLL overlays onto the model (design 7.3, as amended by WP2):
    // settings and the crosshair, which only it can know at the moment of
    // opening, plus the game time and the player.
    struct Overlay {
        struct Crosshair {
            std::int32_t formId = 0;
            std::string  name;
        };

        double                   generatedAt = 0.0;
        std::int32_t             playerFormId = 0x14;
        std::string              playerName;
        bool                     developer = false;
        // dashboardScale (0 Auto, else a percent) and dashboardTextSize
        // (0 Normal, 1 Large, 2 Larger), as Settings::ScaleFromName and
        // TextSizeFromName read them.
        std::int32_t             scale = 0;
        std::int32_t             textSize = 0;
        std::optional<Crosshair> crosshair;
        // The player's GetActorBase().GetSex(), for the orientation copy.
        std::int32_t playerSex = 0;
        // What the engine says about one actor, read when the snapshot is
        // built (Display::EngineFacts). The only game access a snapshot needs.
        std::function<Display::EngineFacts(std::int32_t)> factsOf;
    };

    // What the display copies decide for one row (Display.h): the parts of a
    // bond the DLL works out itself rather than asking Papyrus per bond.
    struct Derived {
        std::string  name;
        bool         following = false;
        bool         nearby = false;
        std::int32_t commitment = 0;
        std::int32_t applicability = 0;
    };

    class ReadModel {
    public:
        using Clock = std::chrono::steady_clock;

        // kPreLoadGame and kNewGame. Returns the actions still waiting on
        // Papyrus, which are dropped with everything else, so the caller can
        // answer the page for each.
        std::vector<Action> Clear();

        // ---- the refresh, main thread ----------------------------------

        // A new generation to ask Papyrus for, or nothing if one is already
        // out and younger than a_patience (it will answer for this open too).
        // Full when no full refresh has come back since the last load.
        std::optional<Refresh> Begin(Clock::time_point a_now, std::chrono::milliseconds a_patience);

        // The view refused focus after Begin: forget that generation.
        void Abandon(std::uint32_t a_generation);

        // a_generation has had its time. True, once, if it is still the one
        // outstanding; the roster status is then "no answer".
        bool TimeOut(std::uint32_t a_generation);

        // The next refresh must be full: the store under the text changed.
        void RequireFull();

        // ---- pushes, VM thread -----------------------------------------
        //
        // a_generation > 0: part of that refresh. 0: unsolicited, from a text
        // writer or a finished LLM callback. < 0: part of a page action, whose
        // ActionDone follows and sends the snapshot.

        Push PutNumbers(std::int32_t a_generation, std::int32_t a_formId, const std::vector<std::int32_t>& a_values);
        Push PutText(std::int32_t a_generation, std::int32_t a_formId, const std::vector<std::string>& a_values);
        Push PutPlaythrough(std::int32_t a_generation, std::string a_id, std::string a_store, std::int32_t a_decision);
        // Once per refresh: what Papyrus fetched with the batch APIs.
        Push PutFacts(std::int32_t a_generation, Display::BatchFacts a_facts);
        Display::BatchFacts Facts() const;
        // One row's numbers, if it has any (the display check reads them).
        std::optional<Numbers> NumbersOf(std::int32_t a_formId) const;
        void Drop(std::int32_t a_formId);
        Finished Finish(std::int32_t a_generation, std::int32_t a_count, std::string_view a_status,
                        Clock::time_point a_now);

        // ---- actions ---------------------------------------------------

        // Records it and returns its request id.
        std::int32_t AddAction(Action a_action);
        std::optional<std::vector<std::int32_t>> ArgsFor(std::int32_t a_requestId) const;
        std::optional<Action> TakeAction(std::int32_t a_requestId);
        // The page is told it timed out; the action stays, for a late ActionDone.
        std::optional<Action> MarkUnanswered(std::int32_t a_requestId);

        // A long-running action said "started" for this actor. The next
        // unsolicited push for them within a_patience is its end.
        void Await(std::int32_t a_formId, std::string a_what, Clock::time_point a_now);
        std::optional<std::string> TakeAwaited(std::int32_t a_formId, Clock::time_point a_now,
                                               std::chrono::milliseconds a_patience);

        // ---- reading, main thread --------------------------------------

        nlohmann::json Snapshot(const Overlay& a_overlay) const;
        // On the roster? Nothing until a refresh has answered since the load.
        std::optional<bool> Enrolled(std::int32_t a_formId) const;
        Status              GetStatus() const;
        bool                HasText() const;

    private:
        struct Row {
            std::optional<Numbers> numbers;
            std::optional<Texts>   text;
            std::uint32_t          seenIn = 0;  // the refresh that last pushed numbers
        };

        struct Playthrough {
            std::string  id;
            std::string  store;
            std::int32_t decision = 0;
        };

        struct Outstanding {
            std::uint32_t     generation = 0;
            Scope             scope = Scope::kNumbers;
            Clock::time_point sentAt;
            Status            before = Status::kReading;
            std::string       beforeMessage;
            bool              timedOut = false;
        };

        struct Awaited {
            std::string       what;
            Clock::time_point since;
        };

        bool StaleLocked(std::int32_t a_generation) const;

        mutable std::mutex                        m_lock;
        std::map<std::int32_t, Row>               m_rows;  // ordered, so snapshot.json diffs cleanly
        std::optional<Playthrough>                m_playthrough;
        Display::BatchFacts                       m_facts;
        std::uint32_t                             m_generation = 0;  // the last one handed out
        std::uint32_t                             m_floor = 0;       // at or below: asked before the last load
        std::optional<Outstanding>                m_outstanding;
        Status                                    m_status = Status::kReading;
        std::string                               m_message;
        bool                                      m_haveText = false;
        bool                                      m_answered = false;
        std::int32_t                              m_nextRequest = 0;
        std::map<std::int32_t, Action>            m_actions;
        std::unordered_map<std::int32_t, Awaited> m_awaited;
    };

    // The one model.
    ReadModel& Get();

    // The display copies for one row: engine facts, batch facts and the row's
    // own StorageUtil values in; what the page shows out.
    Derived Derive(std::int32_t a_formId, const Numbers& a_numbers, const Display::EngineFacts& a_engine,
                   const Display::BatchFacts& a_batch, std::int32_t a_playerSex);

    // A bond as snapshot.schema.json's $defs/bond, from one row. Exposed for
    // the harness; Snapshot() is the only other caller.
    nlohmann::json Bond(std::int32_t a_formId, const Numbers& a_numbers, const Texts* a_text, const Derived& a_derived,
                        const nlohmann::json& a_player);
}
