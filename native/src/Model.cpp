#include "Model.h"

#include "History.h"

#include <algorithm>
#include <format>

namespace SNRom::Model {

    namespace {

        using json = nlohmann::json;

        // Enough for any open-then-act burst; an action Papyrus never answers
        // must not grow this forever.
        constexpr std::size_t kMaxActions = 64;

        std::int32_t Clamp(std::int32_t a_value, std::int32_t a_low, std::int32_t a_high) {
            return std::clamp(a_value, a_low, a_high);
        }

        json GameTime(std::int32_t a_minutes) {
            if (a_minutes < 0) {
                return nullptr;
            }
            return static_cast<double>(a_minutes) / 1440.0;
        }

        // A lookup into one of the schema's enums by the stored number, with
        // the value the StorageUtil readers default to when it is out of range.
        template <std::size_t N>
        const char* Word(const std::array<const char*, N>& a_words, std::int32_t a_value, std::size_t a_fallback) {
            if (a_value < 0 || static_cast<std::size_t>(a_value) >= N) {
                return a_words[a_fallback];
            }
            return a_words[static_cast<std::size_t>(a_value)];
        }

        constexpr std::array<const char*, 4> kIntimacyWords{ "casual", "romantic", "guarded", "never" };
        constexpr std::array<const char*, 4> kOrientationWords{ "none", "men", "women", "both" };
        constexpr std::array<const char*, 3> kBasisWords{ "unknown", "inferred", "known" };
        constexpr std::array<const char*, 4> kCommitmentWords{ "none", "candidate", "engaged", "married" };
        constexpr std::array<const char*, 4> kForeclosureWords{ "", "kin", "minor", "orientation" };

        bool Foreclosed(const Derived& a_d) {
            return a_d.applicability >= 1 && a_d.applicability <= 3;
        }

        // DESIGN 5.2'S STATE, as snapshot.schema.json defines it: no stored
        // flag holds it, so it is derived here, first match wins. Reads only;
        // what each flag means is Papyrus's, unchanged.
        const char* State(const Numbers& a_n, const Derived& a_d) {
            if (Foreclosed(a_d)) {
                return "foreclosed";
            }
            if (a_n[kStance] == -1) {
                return "declined";
            }
            if (a_n[kSparked] == 1 && a_n[kStance] == 1) {
                return "courting";
            }
            if (a_n[kSparked] == 1) {
                return "interested";
            }
            if (a_n[kEndedAt] >= 0) {
                return "ended";
            }
            if (a_n[kSparkDecided] == 1) {
                return "platonic";
            }
            return "unexamined";
        }

        // Romantic only for a mutual romance or a recorded engagement or
        // marriage; everything else, a foreclosed bond included, is platonic,
        // so a platonic bond can never be drawn as Lover (schema, track).
        const char* Track(const Numbers& a_n, const Derived& a_d) {
            if (Foreclosed(a_d)) {
                return "platonic";
            }
            if ((a_n[kSparked] == 1 && a_n[kStance] == 1) || a_d.commitment >= 2) {
                return "romantic";
            }
            return "platonic";
        }

        const char* Stance(std::int32_t a_stance) {
            if (a_stance == -1) {
                return "declined";
            }
            if (a_stance == 1) {
                return "accepted";
            }
            return "unanswered";
        }

        const char* EnrolledBy(const Numbers& a_n) {
            if (a_n[kAutoEnrolled] == 1) {
                return "following";
            }
            if (a_n[kEnrolledFlag] == 1) {
                return "dialogue";
            }
            return "unknown";
        }

        json Party(std::int32_t a_formId, const std::string& a_name, bool a_isPlayer) {
            return { { "formId", a_formId }, { "name", a_name }, { "isPlayer", a_isPlayer } };
        }

        std::string Lower(std::string_view a_text) {
            std::string lower{ a_text };
            for (auto& c : lower) {
                if (c >= 'A' && c <= 'Z') {
                    c = static_cast<char>(c - 'A' + 'a');
                }
            }
            return lower;
        }

        std::string HexName(std::int32_t a_formId) {
            return std::format("{:08X}", static_cast<std::uint32_t>(a_formId));
        }
    }

    std::string_view ScopeName(Scope a_scope) {
        return a_scope == Scope::kFull ? "full" : "numbers";
    }

    std::string_view StatusName(Status a_status) {
        switch (a_status) {
        case Status::kCurrent:
            return "current";
        case Status::kNotReady:
            return "not ready";
        case Status::kNoAnswer:
            return "no answer";
        default:
            return "reading";
        }
    }

    Derived Derive(std::int32_t a_formId, const Numbers& a_n, const Display::EngineFacts& a_engine,
                   const Display::BatchFacts& a_batch, std::int32_t a_playerSex) {
        const Display::StoredFacts stored{ a_n[kOrientation], a_n[kOrientationBasis], a_n[kPlayerKin] == 1 };
        Derived                    d;
        d.name = a_engine.name.empty() ? HexName(a_formId) : a_engine.name;
        d.following = Display::Following(a_formId, a_engine, a_batch);
        // "Near you": loaded, the presence gate SNRom_Bridge.RequestSparkNow
        // applies (akActor.Is3DLoaded()). The page greys out what needs it.
        d.nearby = a_engine.loaded;
        d.commitment = Display::Commitment(a_formId, a_engine, a_batch);
        d.applicability = Display::Applicability(a_formId, a_engine, a_batch, stored, a_playerSex);
        return d;
    }

    json Bond(std::int32_t a_formId, const Numbers& a_n, const Texts* a_text, const Derived& a_d, const json& a_player) {
        const bool foreclosed = Foreclosed(a_d);
        json       bond;
        bond["subject"] = Party(a_formId, a_d.name, false);
        bond["object"] = a_player;
        bond["following"] = a_d.following;
        bond["nearby"] = a_d.nearby;
        bond["lastFollowingAt"] = GameTime(a_n[kLastFollowingAt]);
        // No join date exists yet (design 7.3): null until phase 2 stores one.
        bond["enrollment"] = { { "by", EnrolledBy(a_n) }, { "joinedAt", nullptr } };
        bond["depth"] = { { "points", std::max(a_n[kPoints], 0) },
                          { "tier", Clamp(a_n[kTier], 0, 5) },
                          { "banked", std::max(a_n[kBanked], 0) } };
        bond["track"] = Track(a_n, a_d);
        bond["state"] = State(a_n, a_d);
        bond["foreclosure"] = foreclosed ? json(kForeclosureWords[static_cast<std::size_t>(a_d.applicability)]) :
                                           json(nullptr);
        bond["stance"] = Stance(a_n[kStance]);
        bond["askPending"] = a_n[kAskPending] == 1;
        bond["spark"] = { { "sparked", a_n[kSparked] == 1 },
                          { "decided", a_n[kSparkDecided] == 1 },
                          { "sparkedAt", GameTime(a_n[kSparkedAt]) },
                          { "lastCheckedAt", GameTime(a_n[kLastSparkCheck]) } };
        bond["commitment"] = Word(kCommitmentWords, a_d.commitment, 0);
        bond["seeded"] = a_n[kSeeded] == 1;
        // Out-of-range values fall back to the defaults StorageUtil's readers
        // use (PhysMinTier 4 is "romantic", Orientation 3 is "both"); nothing
        // Papyrus writes produces one.
        bond["traits"] = { { "authored", a_n[kAuthored] == 1 },
                           { "intimacy", Word(kIntimacyWords, a_n[kIntimacy], 1) },
                           { "ardor", Clamp(a_n[kArdor], 0, 4) },
                           { "exclusivity", Clamp(a_n[kExclusivity], 0, 100) },
                           { "orientation", Word(kOrientationWords, a_n[kOrientation], 3) },
                           { "orientationBasis", Word(kBasisWords, a_n[kOrientationBasis], 0) } };
        // Empty until the text arrives, which the schema reads as "never
        // authored". A full refresh sends it with the numbers, so this only
        // shows for someone enrolled since the last one, who has not been
        // authored yet either.
        bond["prose"] = { { "why", a_text ? (*a_text)[kWhy] : "" },
                          { "limit", a_text ? (*a_text)[kLimit] : "" },
                          { "address", a_text ? (*a_text)[kAddress] : "" } };
        // From the co-save, not from a push: the history is the DLL's own
        // (History.h), so every snapshot has it as of now.
        bond["history"] = History::Recent(a_formId);
        return bond;
    }

    ReadModel& Get() {
        static ReadModel model;
        return model;
    }

    std::vector<Action> ReadModel::Clear() {
        const std::scoped_lock lock{ m_lock };
        std::vector<Action>    dropped;
        for (auto& [id, action] : m_actions) {
            if (!action.pageAnswered) {
                dropped.push_back(std::move(action));
            }
        }
        m_rows.clear();
        m_playthrough.reset();
        m_facts = Display::BatchFacts{};
        m_actions.clear();
        m_awaited.clear();
        // Anything asked before now belongs to the timeline being unloaded.
        m_floor = m_generation;
        m_outstanding.reset();
        m_status = Status::kReading;
        m_message.clear();
        m_haveText = false;
        m_answered = false;
        return dropped;
    }

    std::optional<Refresh> ReadModel::Begin(Clock::time_point a_now, std::chrono::milliseconds a_patience) {
        const std::scoped_lock lock{ m_lock };
        // ONE OUT AT A TIME. Reopening while Papyrus is still walking the
        // roster would queue a second walk behind the first, on a VM that may
        // already be behind; the answer to the first serves this open too.
        if (m_outstanding && !m_outstanding->timedOut && a_now - m_outstanding->sentAt < a_patience) {
            return std::nullopt;
        }
        const Refresh refresh{ ++m_generation, m_haveText ? Scope::kNumbers : Scope::kFull };
        m_outstanding = Outstanding{ refresh.generation, refresh.scope, a_now, m_status, m_message, false };
        m_status = Status::kReading;
        m_message.clear();
        return refresh;
    }

    void ReadModel::Abandon(std::uint32_t a_generation) {
        const std::scoped_lock lock{ m_lock };
        if (m_outstanding && m_outstanding->generation == a_generation) {
            m_status = m_outstanding->before;
            m_message = m_outstanding->beforeMessage;
            m_outstanding.reset();
        }
    }

    bool ReadModel::TimeOut(std::uint32_t a_generation) {
        const std::scoped_lock lock{ m_lock };
        if (!m_outstanding || m_outstanding->generation != a_generation || m_outstanding->timedOut) {
            return false;
        }
        m_outstanding->timedOut = true;
        m_status = Status::kNoAnswer;
        m_message.clear();
        return true;
    }

    void ReadModel::RequireFull() {
        const std::scoped_lock lock{ m_lock };
        m_haveText = false;
    }

    bool ReadModel::StaleLocked(std::int32_t a_generation) const {
        if (a_generation <= 0) {
            return false;
        }
        // Asked before the last load, or never asked by this process at all: a
        // script stack restored from a save can still hold an old number.
        const auto generation = static_cast<std::uint32_t>(a_generation);
        return generation <= m_floor || generation > m_generation;
    }

    Push ReadModel::PutNumbers(std::int32_t a_generation, std::int32_t a_formId,
                               const std::vector<std::int32_t>& a_values) {
        if (a_values.size() != kNumberCount) {
            return Push::kWrongSize;
        }
        const std::scoped_lock lock{ m_lock };
        if (StaleLocked(a_generation)) {
            return Push::kStale;
        }
        auto&   row = m_rows[a_formId];
        Numbers numbers{};
        std::copy(a_values.begin(), a_values.end(), numbers.begin());
        row.numbers = numbers;
        if (a_generation > 0) {
            row.seenIn = static_cast<std::uint32_t>(a_generation);
        }
        return Push::kAccepted;
    }

    Push ReadModel::PutText(std::int32_t a_generation, std::int32_t a_formId, const std::vector<std::string>& a_values) {
        if (a_values.size() != kTextCount) {
            return Push::kWrongSize;
        }
        const std::scoped_lock lock{ m_lock };
        if (StaleLocked(a_generation)) {
            return Push::kStale;
        }
        Texts text;
        std::copy(a_values.begin(), a_values.end(), text.begin());
        m_rows[a_formId].text = std::move(text);
        return Push::kAccepted;
    }

    Push ReadModel::PutPlaythrough(std::int32_t a_generation, std::string a_id, std::string a_store,
                                   std::int32_t a_decision) {
        const std::scoped_lock lock{ m_lock };
        if (StaleLocked(a_generation)) {
            return Push::kStale;
        }
        m_playthrough = Playthrough{ std::move(a_id), std::move(a_store), a_decision };
        return Push::kAccepted;
    }

    Push ReadModel::PutFacts(std::int32_t a_generation, Display::BatchFacts a_facts) {
        const std::scoped_lock lock{ m_lock };
        if (StaleLocked(a_generation)) {
            return Push::kStale;
        }
        m_facts = std::move(a_facts);
        return Push::kAccepted;
    }

    Display::BatchFacts ReadModel::Facts() const {
        const std::scoped_lock lock{ m_lock };
        return m_facts;
    }

    std::optional<Numbers> ReadModel::NumbersOf(std::int32_t a_formId) const {
        const std::scoped_lock lock{ m_lock };
        const auto             it = m_rows.find(a_formId);
        if (it == m_rows.end()) {
            return std::nullopt;
        }
        return it->second.numbers;
    }

    std::vector<std::int32_t> ReadModel::FormIds() const {
        const std::scoped_lock    lock{ m_lock };
        std::vector<std::int32_t> ids;
        for (const auto& [id, row] : m_rows) {
            if (row.numbers) {
                ids.push_back(id);
            }
        }
        return ids;
    }

    void ReadModel::Drop(std::int32_t a_formId) {
        const std::scoped_lock lock{ m_lock };
        m_rows.erase(a_formId);
        m_awaited.erase(a_formId);
    }

    Finished ReadModel::Finish(std::int32_t a_generation, std::int32_t a_count, std::string_view a_status,
                               Clock::time_point a_now) {
        const std::scoped_lock lock{ m_lock };
        Finished               done;
        if (a_generation <= 0 || !m_outstanding ||
            m_outstanding->generation != static_cast<std::uint32_t>(a_generation)) {
            return done;
        }
        const auto generation = static_cast<std::uint32_t>(a_generation);
        done.accepted = true;
        done.scope = m_outstanding->scope;
        done.late = m_outstanding->timedOut;
        done.milliseconds =
            std::chrono::duration_cast<std::chrono::milliseconds>(a_now - m_outstanding->sentAt).count();
        done.reported = a_count;
        // "ok", or "not ready: <why>". Anything else is not ready, and says
        // what it was. Compared ignoring case: the Papyrus compiler interns
        // strings case-insensitively, first spelling wins, so a variable
        // named Ok anywhere in the script would ship the literal as "Ok".
        done.ok = Lower(a_status) == "ok";
        if (done.ok) {
            // THE REFRESH IS THE ROSTER. A row this walk did not push is
            // someone no longer on it, however they left.
            for (auto it = m_rows.begin(); it != m_rows.end();) {
                if (it->second.seenIn == generation) {
                    ++done.pushed;
                    ++it;
                } else {
                    it = m_rows.erase(it);
                    ++done.dropped;
                }
            }
            m_status = Status::kCurrent;
            m_message.clear();
            m_answered = true;
            if (done.scope == Scope::kFull) {
                m_haveText = true;
            }
        } else {
            constexpr std::string_view kPrefix = "not ready: ";
            const bool prefixed = Lower(a_status.substr(0, kPrefix.size())) == kPrefix;
            done.message = std::string(prefixed ? a_status.substr(kPrefix.size()) : a_status);
            m_status = Status::kNotReady;
            m_message = done.message;
        }
        m_outstanding.reset();
        for (const auto& [id, row] : m_rows) {
            if (row.numbers) {
                ++done.bonds;
            }
        }
        return done;
    }

    std::int32_t ReadModel::AddAction(Action a_action) {
        const std::scoped_lock lock{ m_lock };
        while (m_actions.size() >= kMaxActions) {
            m_actions.erase(m_actions.begin());
        }
        a_action.requestId = ++m_nextRequest;
        const auto id = a_action.requestId;
        m_actions.emplace(id, std::move(a_action));
        return id;
    }

    std::optional<std::vector<std::int32_t>> ReadModel::ArgsFor(std::int32_t a_requestId) const {
        const std::scoped_lock lock{ m_lock };
        const auto             it = m_actions.find(a_requestId);
        if (it == m_actions.end()) {
            return std::nullopt;
        }
        return it->second.args;
    }

    std::optional<Action> ReadModel::TakeAction(std::int32_t a_requestId) {
        const std::scoped_lock lock{ m_lock };
        const auto             it = m_actions.find(a_requestId);
        if (it == m_actions.end()) {
            return std::nullopt;
        }
        Action action = std::move(it->second);
        m_actions.erase(it);
        return action;
    }

    std::optional<Action> ReadModel::MarkUnanswered(std::int32_t a_requestId) {
        const std::scoped_lock lock{ m_lock };
        const auto             it = m_actions.find(a_requestId);
        if (it == m_actions.end() || it->second.pageAnswered) {
            return std::nullopt;
        }
        it->second.pageAnswered = true;
        return it->second;
    }

    void ReadModel::Await(std::int32_t a_formId, std::string a_what, Clock::time_point a_now) {
        const std::scoped_lock lock{ m_lock };
        m_awaited[a_formId] = Awaited{ std::move(a_what), a_now };
    }

    std::optional<std::string> ReadModel::TakeAwaited(std::int32_t a_formId, Clock::time_point a_now,
                                                      std::chrono::milliseconds a_patience) {
        const std::scoped_lock lock{ m_lock };
        const auto             it = m_awaited.find(a_formId);
        if (it == m_awaited.end()) {
            return std::nullopt;
        }
        auto awaited = std::move(it->second);
        m_awaited.erase(it);
        // Too old to be that action's answer: an LLM read that never came
        // back, and this push is something else.
        if (a_now - awaited.since > a_patience) {
            return std::nullopt;
        }
        return awaited.what;
    }

    json ReadModel::Snapshot(const Overlay& a_overlay) const {
        const std::scoped_lock lock{ m_lock };
        const json             player = Party(a_overlay.playerFormId, a_overlay.playerName, true);

        json snap;
        snap["schemaVersion"] = kSchemaVersion;
        snap["generatedAt"] = a_overlay.generatedAt;
        snap["roster"] = { { "status", StatusName(m_status) },
                           { "message", m_message.empty() ? json(nullptr) : json(m_message) } };
        if (m_playthrough) {
            // SNRom_SaveId: 0 undecided, 1 legacy, 2 own; anything else is a
            // leftover EnsureSaveId re-decides, so it reads as undecided.
            const char* decision = m_playthrough->decision == 1 ? "legacy" :
                                   m_playthrough->decision == 2 ? "own" :
                                                                  "undecided";
            snap["playthrough"] = { { "id", m_playthrough->id },
                                    { "store", m_playthrough->store },
                                    { "storeDecision", decision } };
        } else {
            snap["playthrough"] = { { "id", nullptr }, { "store", nullptr }, { "storeDecision", nullptr } };
        }
        snap["ladder"] = { { "thresholds", kThresholds } };
        snap["player"] = player;
        snap["settings"] = { { "developer", a_overlay.developer },
                             { "scale", a_overlay.scale == 0 ? json("auto") : json(a_overlay.scale) },
                             { "textSize", a_overlay.textSize == 2 ? "larger" :
                                           a_overlay.textSize == 1 ? "large" :
                                                                     "normal" } };
        if (a_overlay.crosshair) {
            json enrolled = nullptr;
            if (m_answered) {
                const auto it = m_rows.find(a_overlay.crosshair->formId);
                enrolled = it != m_rows.end() && it->second.numbers.has_value();
            }
            snap["crosshairTarget"] = { { "formId", a_overlay.crosshair->formId },
                                        { "name", a_overlay.crosshair->name },
                                        { "enrolled", enrolled } };
        } else {
            snap["crosshairTarget"] = nullptr;
        }
        json bonds = json::array();
        for (const auto& [formId, row] : m_rows) {
            // A row with text and no numbers came from a writer before any
            // refresh this load: nothing to draw it with yet.
            if (!row.numbers) {
                continue;
            }
            const Texts* text = row.text ? &*row.text : nullptr;
            const auto   engine = a_overlay.factsOf ? a_overlay.factsOf(formId) : Display::EngineFacts{};
            const auto   derived = Derive(formId, *row.numbers, engine, m_facts, a_overlay.playerSex);
            bonds.push_back(Bond(formId, *row.numbers, text, derived, player));
        }
        snap["bonds"] = std::move(bonds);
        return snap;
    }

    std::optional<bool> ReadModel::Enrolled(std::int32_t a_formId) const {
        const std::scoped_lock lock{ m_lock };
        if (!m_answered) {
            return std::nullopt;
        }
        const auto it = m_rows.find(a_formId);
        return it != m_rows.end() && it->second.numbers.has_value();
    }

    Status ReadModel::GetStatus() const {
        const std::scoped_lock lock{ m_lock };
        return m_status;
    }

    bool ReadModel::HasText() const {
        const std::scoped_lock lock{ m_lock };
        return m_haveText;
    }
}
