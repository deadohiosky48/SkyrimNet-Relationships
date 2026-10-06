#include "Dashboard.h"

#include "PCH.h"

// ---------------------------------------------------------------------------
// THE THREADING INVARIANT. Everything in this file runs on the MAIN thread,
// the one SKSE tasks run on. The only entries from any other thread are:
//   - the Meridian listeners (OnRequest, OnClose), on the framework's thread;
//   - the settings watcher (Settings.cpp), on its own thread;
//   - the input sink (Hotkey.cpp), on the input thread;
//   - the Papyrus natives (Natives.cpp), on a VM thread;
// and every one of them QUEUES its work with SKSE's task interface rather than
// touching anything here. The read model (Model.h) is the one exception: the
// natives write it from the VM thread, and it has its own lock.
//
// Found in the WP3 test: "Dashboard opened" was logged from two threads while
// every task ran on a third, because the hotkey opened the view straight from
// the input sink. That raced the queued close and snapshot sends.
// ---------------------------------------------------------------------------

#include "MagelightHost.h"
#include "MeridianHost.h"
#include "Model.h"
#include "PrismaHost.h"
#include "ViewHost.h"

#include <format>
#include <fstream>
#include <thread>

namespace SNRom::Dashboard {

    namespace {

        using json = nlohmann::json;

        // bridge.js's PROTOCOL. Every message both ways carries it.
        constexpr int kProtocol = 1;

        std::unique_ptr<ViewHost> g_host;  // null: no UI framework installed
        bool                      g_created = false;
        std::atomic<int>          g_developer{ -1 };  // -1 until the setting first arrives
        // The display settings start at their defaults, Auto and Normal, which
        // is also what the page does before any snapshot.
        std::atomic<int> g_scale{ 0 };
        std::atomic<int> g_textSize{ 0 };
        RE::FormID                g_captured = 0;  // crosshair at the last open

        // HOW LONG PAPYRUS HAS TO ANSWER A REFRESH before the page is told it
        // hasn't. The VM has run minutes behind on a busy load order in this
        // project, so this is when the page says so, not when the answer is
        // given up on: a late answer is still taken.
        constexpr auto kRefreshPatience = std::chrono::seconds{ 10 };

        // How long Papyrus has to answer an action before the page is told it
        // hasn't: inside the page's own 15-second wait (bridge.js), so the page
        // hears it from us. A late ActionDone still reaches it, as a notice.
        constexpr auto kActionPatience = std::chrono::seconds{ 10 };

        // How long after "started" a pushed row still counts as that action's
        // end. An LLM read that never came back must not claim a later,
        // unrelated push.
        constexpr auto kLongRunningPatience = std::chrono::minutes{ 5 };

        // The no-answer warning, once until an answer arrives. Main thread.
        bool g_noAnswerLogged = false;

        // One snapshot queued for an unsolicited push, however many arrive in
        // the frame. Set on the VM thread, cleared by the task.
        std::atomic<bool> g_snapshotQueued{ false };

        // ------------------------------------------------------------------
        // THE FIXED OP TABLE (ui/relationships/actions.js, bridge.js contract).
        //
        // The page is data and this table is the permission: an `op` the page
        // sends is looked up here and never used to name a Papyrus function
        // directly. What passes goes to Papyrus as the SNRom_DashboardAction
        // ModEvent, and SNRom_Bridge.OnDashboardAction maps it again through
        // its own fixed table to the function beside it here.
        // ------------------------------------------------------------------
        enum class OpScope { kBond, kCrosshair, kPlaythrough };

        struct Op {
            std::string_view op;
            std::string_view calls;
            OpScope          scope;
            // A developer tool (actions.js, developer: true). Refused here
            // unless the developer view is on, and refused again by Papyrus,
            // which reads the setting itself: two locks, because a page can be
            // edited.
            bool developer = false;
            // Finishes in an LLM callback. Papyrus answers "started"; when the
            // callback pushes the row, the page is told this, and gets it.
            std::string_view finished = {};
            std::size_t      minArgs = 0;
            std::size_t      maxArgs = 0;
            bool             wired = true;
            // Answered to the page as soon as Papyrus is asked, with this; the
            // real answer follows as a notice. For work that outlasts the
            // page's own wait for a result.
            std::string_view answerAtOnce = {};
        };

        constexpr std::array kOps{
            Op{ "ReseedActor", "SNRom_Bridge.ReseedActor(Actor)", OpScope::kBond, false,
                "their record has been read again" },
            Op{ "ReauthorCharacter", "SNRom_Bridge.ReauthorCharacter(Actor)", OpScope::kBond, false,
                "their character has been written again" },
            Op{ "SetCharacterField", "SNRom_Bridge.SetCharacterField(Actor, Int, Int)", OpScope::kBond, false, {}, 2,
                2 },
            Op{ "UnenrollActor", "SNRom_Bridge.UnenrollActor(Actor)", OpScope::kBond },
            Op{ "StartFreshStore", "SNRom_Bridge.StartFreshStore()", OpScope::kPlaythrough },
            Op{ "AdoptLegacyStore", "SNRom_Bridge.AdoptLegacyStore()", OpScope::kPlaythrough },
            // WP7: the crosshair target at the last open, enrolled by hand.
            Op{ "EnrollActor", "SNRom_Bridge.EnrollByHand(Actor)", OpScope::kCrosshair, false,
                "their character has been written" },
            // Developer tools. Their LLM reads end in the spark and drift
            // callbacks, which sit beside the consent gate and are left as they
            // are, so no "finished" notice: the next open shows the result.
            Op{ "RequestSparkNow", "SNRom_Bridge.RequestSparkNow(Actor)", OpScope::kBond, true },
            Op{ "UnsparkActor", "SNRom_Bridge.UnsparkActor(Actor)", OpScope::kBond, true },
            Op{ "ForceDriftReview", "SNRom_Bridge.ForceDriftReview(Actor, Int)", OpScope::kBond, true, {}, 0, 1 },
            // Runs the real Papyrus rules for every bond against the display
            // copies (Display.h; CheckBond below). About a minute with 120
            // bonds: it pays the old per-bond cost on purpose.
            Op{ "CheckDisplay", "SNRom_Bridge.CheckDashboardDisplay()", OpScope::kPlaythrough, true, {}, 0, 0, true,
                "Checking every bond against the rules. About a minute with 120 bonds; the answer arrives here." },
        };

        const Op* FindOp(std::string_view a_op) {
            for (const auto& op : kOps) {
                if (op.op == a_op) {
                    return &op;
                }
            }
            return nullptr;
        }

        // ------------------------------------------------------------------
        // Native to page.
        // ------------------------------------------------------------------
        void Send(const json& a_message) {
            if (!g_host || !g_created) {
                return;
            }
            // ensure_ascii: every non-ASCII character leaves as \uXXXX, so no
            // name can break the JavaScript it is spliced into.
            //
            // error_handler_t::replace, because dump() THROWS on invalid UTF-8
            // (type_error 316) and the game hands us names in the plugin's code
            // page, not UTF-8: one Windows-1252 accent was enough. Invalid bytes
            // become U+FFFD, so the name shows a replacement character and the
            // page still gets its message.
            //
            // AND NOTHING ESCAPES. This runs inside SKSE tasks and, through
            // Open(), inside the input sink; an exception there takes the game
            // down. Anything that still throws is logged and the message dropped.
            try {
                g_host->Send(a_message.dump(-1, ' ', true, json::error_handler_t::replace));
            } catch (const json::exception& e) {
                SKSE::log::error("Dropped a message to the page: {}", e.what());
            }
        }

        void Result(const std::string& a_id, bool a_ok, const std::string& a_message) {
            Send({ { "v", kProtocol },
                   { "kind", "result" },
                   { "re", a_id },
                   { "payload", { { "ok", a_ok }, { "message", a_message } } } });
        }

        void Notify(const char* a_text) {
            RE::SendHUDMessage::ShowHUDMessage(a_text);
        }

        // ------------------------------------------------------------------
        // The snapshot (snapshot.schema.json): the read model, plus what only
        // the DLL can know at the moment it is built.
        // ------------------------------------------------------------------
        // The two vanilla factions the display copies read (Display.cpp), looked
        // up once: Skyrim.esm's own records, which never move.
        RE::TESFaction* VanillaFaction(RE::FormID a_localId) {
            auto* data = RE::TESDataHandler::GetSingleton();
            return data ? data->LookupForm<RE::TESFaction>(a_localId, "Skyrim.esm") : nullptr;
        }

        // WHAT THE ENGINE SAYS ABOUT ONE ACTOR, read here on the main thread
        // when a snapshot is built. This replaced about twenty Papyrus calls
        // per bond that each waited a frame (design 7.3, "Measured in play").
        Display::EngineFacts FactsOf(std::int32_t a_formId) {
            static auto* followerFaction = VanillaFaction(0x0005C84E);  // CurrentFollowerFaction
            static auto* marriedFaction = VanillaFaction(0x000C6472);   // PlayerMarriedFaction
            Display::EngineFacts facts;
            auto*                actor = RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(a_formId));
            if (!actor) {
                return facts;
            }
            const char* name = actor->GetDisplayFullName();
            facts.found = true;
            facts.name = name ? name : "";
            facts.teammate = actor->IsPlayerTeammate();
            facts.followerFaction = followerFaction && actor->IsInFaction(followerFaction);
            facts.marriedFaction = marriedFaction && actor->IsInFaction(marriedFaction);
            facts.loaded = actor->Is3DLoaded();
            facts.child = actor->IsChild();
            return facts;
        }

        // Game.GetPlayer().GetActorBase().GetSex(), for the orientation copy.
        std::int32_t PlayerSex() {
            auto* player = RE::PlayerCharacter::GetSingleton();
            auto* base = player ? player->GetActorBase() : nullptr;
            return base ? static_cast<std::int32_t>(base->GetSex()) : 0;
        }

        Model::Overlay OverlayNow() {
            Model::Overlay overlay;
            auto*          player = RE::PlayerCharacter::GetSingleton();
            auto*          calendar = RE::Calendar::GetSingleton();
            const char*    playerName = player ? player->GetName() : nullptr;
            overlay.generatedAt = calendar ? calendar->GetCurrentGameTime() : 0.0F;
            overlay.playerName = playerName ? playerName : "";
            overlay.developer = g_developer.load() == 1;
            overlay.scale = g_scale.load();
            overlay.textSize = g_textSize.load();
            // THE CROSSHAIR AS IT WAS WHEN THE DASHBOARD OPENED (design 3.2):
            // the view pauses the game and covers it, so it is read before.
            // Whether they are enrolled is the model's to say.
            if (g_captured != 0) {
                auto* actor = RE::TESForm::LookupByID<RE::Actor>(g_captured);
                if (actor && !actor->IsPlayerRef() && !actor->IsDead() && actor->Is3DLoaded()) {
                    const char* name = actor->GetDisplayFullName();
                    overlay.crosshair =
                        Model::Overlay::Crosshair{ static_cast<std::int32_t>(actor->GetFormID()), name ? name : "" };
                }
            }
            overlay.playerSex = PlayerSex();
            overlay.factsOf = FactsOf;
            return overlay;
        }

        json SnapshotNow() {
            return Model::Get().Snapshot(OverlayNow());
        }

        void SendSnapshot(const json& a_snapshot) {
            Send({ { "v", kProtocol }, { "kind", "snapshot" }, { "payload", a_snapshot } });
        }

        void SendSnapshot() {
            SendSnapshot(SnapshotNow());
        }

        // A setting changed: an open dashboard gets a snapshot carrying it at
        // once. Queued, because the view is the main thread's.
        void ResendIfOpen() {
            SKSE::GetTaskInterface()->AddTask([]() {
                if (g_host && g_created && g_host->HasFocus()) {
                    SendSnapshot();
                }
            });
        }

        void SendNotice(const std::string& a_text, const char* a_level) {
            Send({ { "v", kProtocol }, { "kind", "notice" }, { "payload", { { "text", a_text }, { "level", a_level } } } });
        }

        // READABLE FROM OUTSIDE THE GAME (design 6.4) at no Papyrus cost: the
        // snapshot the page was just sent, beside the log, overwritten each
        // refresh. Derived, like the model: nothing reads it back.
        void WriteSnapshotFile(const json& a_snapshot) {
            auto path = SKSE::log::log_directory();
            if (!path) {
                return;
            }
            *path /= "SkyrimNetRelationships.snapshot.json";
            try {
                const auto    text = a_snapshot.dump(2, ' ', false, json::error_handler_t::replace);
                std::ofstream file(*path, std::ios::binary | std::ios::trunc);
                file << text;
                if (!file) {
                    SKSE::log::warn("Could not write SkyrimNetRelationships.snapshot.json");
                }
            } catch (const std::exception& e) {
                SKSE::log::warn("Could not write SkyrimNetRelationships.snapshot.json: {}", e.what());
            }
        }

        // ------------------------------------------------------------------
        // The refresh (kickoff WP2, c). The page shows whatever the model
        // holds at once; then this asks Papyrus, by ModEvent, to push the
        // roster again, and RefreshDone says when it has.
        // ------------------------------------------------------------------
        void SendModEvent(const char* a_name, std::string_view a_text, std::int32_t a_number, RE::TESForm* a_sender) {
            // numArg is a float: exact for every integer this sends (a
            // generation or a request id, both far below 2^24).
            SKSE::ModCallbackEvent event{ a_name, RE::BSFixedString(a_text), static_cast<float>(a_number),
                                          a_sender };
            if (auto* source = SKSE::GetModCallbackEventSource()) {
                source->SendEvent(&event);
            }
        }

        void OnRefreshTimeout(std::uint32_t a_generation) {
            if (!Model::Get().TimeOut(a_generation)) {
                return;
            }
            if (!g_noAnswerLogged) {
                g_noAnswerLogged = true;
                SKSE::log::warn("Roster refresh {} has had no answer from the game's scripts in {} seconds. "
                                "The Papyrus VM may be running behind; a late answer is still taken.",
                                a_generation, kRefreshPatience.count());
            }
            SendNotice("The game's scripts haven't answered yet, so the roster may be out of date. "
                       "It updates when they do.",
                       "warn");
            SendSnapshot();
        }

        void AskForRefresh(const Model::Refresh& a_refresh) {
            SendModEvent("SNRom_DashboardRefresh", Model::ScopeName(a_refresh.scope),
                         static_cast<std::int32_t>(a_refresh.generation), nullptr);
            SKSE::log::info("Roster refresh {} asked of Papyrus ({})", a_refresh.generation,
                            Model::ScopeName(a_refresh.scope));
            // A thread per open to time it, because nothing here ticks. Opens
            // are a person pressing a key, so there are never many.
            std::thread([generation = a_refresh.generation]() {
                std::this_thread::sleep_for(kRefreshPatience);
                SKSE::GetTaskInterface()->AddTask([generation]() { OnRefreshTimeout(generation); });
            }).detach();
        }

        // An unsolicited push while the view is open: show it. Coalesced, so a
        // writer pushing numbers and text sends one snapshot, not two.
        void QueueSnapshot() {
            if (g_snapshotQueued.exchange(true)) {
                return;
            }
            SKSE::GetTaskInterface()->AddTask([]() {
                g_snapshotQueued = false;
                if (g_host && g_created && g_host->HasFocus()) {
                    SendSnapshot();
                }
            });
        }

        // ------------------------------------------------------------------
        // Page to native. Runs as an SKSE task on the main thread, never on
        // the framework's callback thread, because it reads game state.
        // ------------------------------------------------------------------
        void Close() {
            if (g_host && g_created) {
                g_host->Hide();
                SKSE::log::info("Dashboard closed");
            }
        }

        // ------------------------------------------------------------------
        // Actions (kickoff WP2, d): page to DLL to Papyrus, and back.
        // ------------------------------------------------------------------
        void OnActionTimeout(std::int32_t a_requestId) {
            const auto action = Model::Get().MarkUnanswered(a_requestId);
            if (!action) {
                return;
            }
            SKSE::log::warn("Action {} (request {}) has had no answer from the game's scripts in {} seconds",
                            action->op, a_requestId, kActionPatience.count());
            Result(action->pageId, false,
                   "The game's scripts haven't answered yet. It may still happen; you'll be told if it does.");
        }

        std::string DisplayName(std::int32_t a_formId) {
            const auto facts = FactsOf(a_formId);
            return facts.name.empty() ? "They" : facts.name;
        }

        void DispatchAction(const std::string& a_pageId, const json& a_payload) {
            if (!a_payload.is_object()) {
                Result(a_pageId, false, "The dashboard sent a request the game could not read.");
                return;
            }
            const auto  op = a_payload.value("op", std::string{});
            const auto* entry = FindOp(op);
            if (!entry) {
                SKSE::log::warn("Action '{}' is not in the op table; refused", op);
                Result(a_pageId, false, "Unknown operation " + op + ".");
                return;
            }
            if (!entry->wired) {
                SKSE::log::info("Action {} requested ({}): not wired yet", entry->op, entry->calls);
                Result(a_pageId, false, "Not wired yet.");
                return;
            }
            // THE FIRST LOCK. Papyrus holds the second.
            if (entry->developer && g_developer.load() != 1) {
                SKSE::log::warn("Action {} refused: a developer tool, and the developer view is off", entry->op);
                Result(a_pageId, false, "That is a developer tool. Turn on Dashboard Developer View to use it.");
                return;
            }

            // The Int arguments go to Papyrus through SNRom_Native.ActionArgs,
            // never parsed from a string there.
            std::vector<std::int32_t> args;
            const auto                argsIt = a_payload.find("args");
            if (argsIt != a_payload.end() && !argsIt->is_null()) {
                if (!argsIt->is_array()) {
                    Result(a_pageId, false, "The dashboard sent arguments the game could not read.");
                    return;
                }
                for (const auto& arg : *argsIt) {
                    if (!arg.is_number_integer() || arg.get<std::int64_t>() < INT32_MIN ||
                        arg.get<std::int64_t>() > INT32_MAX) {
                        Result(a_pageId, false, "The dashboard sent arguments the game could not read.");
                        return;
                    }
                    args.push_back(arg.get<std::int32_t>());
                }
            }
            if (args.size() < entry->minArgs || args.size() > entry->maxArgs) {
                Result(a_pageId, false,
                       std::format("{} takes {} to {} arguments; the dashboard sent {}.", entry->op, entry->minArgs,
                                   entry->maxArgs, args.size()));
                return;
            }

            // THE ACTOR TRAVELS AS THE EVENT'S SENDER FORM, not as a form id in
            // a string, so Papyrus receives an Actor and resolves nothing.
            RE::Actor*   actor = nullptr;
            std::int32_t subject = 0;
            if (entry->scope == OpScope::kBond) {
                const auto subjectIt = a_payload.find("subject");
                if (subjectIt == a_payload.end() || !subjectIt->is_number_integer()) {
                    Result(a_pageId, false, "The dashboard did not say who this is for.");
                    return;
                }
                subject = subjectIt->get<std::int32_t>();
                actor = RE::TESForm::LookupByID<RE::Actor>(static_cast<RE::FormID>(subject));
                if (!actor) {
                    Result(a_pageId, false, "They could not be found in the game right now.");
                    return;
                }
            } else if (entry->scope == OpScope::kCrosshair) {
                // WHOEVER WAS UNDER THE CROSSHAIR AT THE OPEN, as the DLL read
                // it then - not the page's word for it. The view covers the
                // crosshair, so this is the only reading there is. Found in
                // play 2026-10-01: until WP7 nothing used this scope, and
                // Enroll reached Papyrus with no actor at all.
                subject = static_cast<std::int32_t>(g_captured);
                actor = g_captured ? RE::TESForm::LookupByID<RE::Actor>(g_captured) : nullptr;
                if (!actor) {
                    Result(a_pageId, false, "Nobody was under your crosshair when the dashboard opened.");
                    return;
                }
            }

            Model::Action action;
            action.pageId = a_pageId;
            action.op = std::string(entry->op);
            action.subject = subject;
            action.args = std::move(args);
            action.longRunning = !entry->finished.empty();
            action.pageAnswered = !entry->answerAtOnce.empty();
            const auto requestId = Model::Get().AddAction(std::move(action));
            SendModEvent("SNRom_DashboardAction", entry->op, requestId, actor);
            SKSE::log::info("Action {} sent to Papyrus as request {}{}", entry->op, requestId,
                            subject ? std::format(" for {:08X}", static_cast<std::uint32_t>(subject)) : "");
            if (!entry->answerAtOnce.empty()) {
                Result(a_pageId, true, std::string(entry->answerAtOnce));
                return;
            }
            std::thread([requestId]() {
                std::this_thread::sleep_for(kActionPatience);
                SKSE::GetTaskInterface()->AddTask([requestId]() { OnActionTimeout(requestId); });
            }).detach();
        }

        void HandleRequest(const std::string& a_text) {
            const auto message = json::parse(a_text, nullptr, false);
            if (message.is_discarded() || !message.is_object()) {
                SKSE::log::warn("snromRequest: not a JSON object, ignored");
                return;
            }
            const auto idIt = message.find("id");
            if (idIt == message.end() || !idIt->is_string() || idIt->get<std::string>().empty()) {
                SKSE::log::warn("snromRequest: no id, so nothing can be answered; ignored");
                return;
            }
            const auto id = idIt->get<std::string>();
            // EVERY REQUEST WITH AN ID IS ANSWERED, malformed ones included: the
            // page waits for its result and would otherwise sit out a timeout.
            try {
                if (message.value("v", 0) != kProtocol) {
                    Result(id, false, "This dashboard and SkyrimNetRelationships.dll disagree on the protocol version.");
                    return;
                }
                const auto kind = message.value("kind", std::string{});
                if (kind == "snapshot") {
                    SendSnapshot();
                    Result(id, true, "");
                } else if (kind == "action") {
                    DispatchAction(id, message.value("payload", json::object()));
                } else {
                    Result(id, false, "Unknown request kind " + kind + ".");
                }
            } catch (const json::exception& e) {
                SKSE::log::warn("snromRequest {}: malformed ({})", id, e.what());
                Result(id, false, "The dashboard sent a request the game could not read.");
            }
        }

        // The page's two window functions. Each is its own static function
        // because a Meridian listener is a bare function pointer with no user
        // data. Both run on the framework's callback thread: copy the payload,
        // which is valid only during the call, and hand everything else to the
        // main thread.
        void __cdecl OnRequest(const char* a_payload) {
            std::string text = a_payload ? a_payload : "";
            SKSE::GetTaskInterface()->AddTask([text = std::move(text)]() { HandleRequest(text); });
        }

        void __cdecl OnClose(const char*) {
            SKSE::GetTaskInterface()->AddTask([]() { Close(); });
        }

        void OpenUnguarded() {
            if (!g_host || !g_created) {
                Notify("[Relationships] The dashboard needs Meridian UI or Prisma UI.");
                return;
            }

            // CAPTURED NOW, before anything opens. The view pauses the game
            // and covers the crosshair, so afterwards there is nothing to read
            // (design 3.2, the dashboard route to "Enroll <name>").
            g_captured = 0;
            if (auto* pick = RE::CrosshairPickData::GetSingleton()) {
                if (auto ref = pick->GetActiveTarget().get()) {
                    g_captured = ref->GetFormID();
                }
            }

            // THE PAGE OPENS AT ONCE, from whatever the model holds: on the
            // first open after a load that is nothing, and the page says it is
            // reading. It never waits for Papyrus. The refresh is begun first
            // only so this snapshot already says "reading"; it is asked for
            // once the view has focus.
            const auto refresh = Model::Get().Begin(Model::ReadModel::Clock::now(), kRefreshPatience);
            SendSnapshot();
            g_host->Show();
            const auto outcome = g_host->Focus();
            if (outcome != FocusOutcome::Granted && refresh) {
                Model::Get().Abandon(refresh->generation);
            }
            switch (outcome) {
            case FocusOutcome::Granted:
                Send({ { "v", kProtocol }, { "kind", "opened" } });
                SKSE::log::info("Dashboard opened");
                if (refresh) {
                    AskForRefresh(*refresh);
                }
                return;
            case FocusOutcome::Busy:
                g_host->Hide();
                SKSE::log::info("Dashboard not opened: another view has focus");
                Notify("[Relationships] Another menu has the screen. Close it and try again.");
                return;
            case FocusOutcome::NotReady:
                g_host->Hide();
                SKSE::log::info("Dashboard not opened: the page has not finished loading");
                Notify("[Relationships] The dashboard is still loading. Try again in a moment.");
                return;
            default:
                g_host->Hide();
                SKSE::log::warn("Dashboard not opened: {} refused focus", g_host->Name());
                Notify("[Relationships] The dashboard could not open. See SkyrimNetRelationships.log.");
                return;
            }
        }

        // Runs inside the input sink, where an escaping exception crashes the
        // game. Send() already catches its own; this is the backstop for
        // anything else between the keypress and the view. A failure after
        // Show() would leave the view up without focus, so it is hidden again
        // (Hide is idempotent).
        void Open() {
            try {
                OpenUnguarded();
                return;
            } catch (const json::exception& e) {
                SKSE::log::error("Dashboard not opened: {}", e.what());
            } catch (const std::exception& e) {
                SKSE::log::error("Dashboard not opened: {}", e.what());
            }
            if (g_host && g_created) {
                g_host->Hide();
            }
        }
    }

    void OnInputLoaded() {
        // THE FIRST HOST PRESENT, in this order (the author, 2026-10-05):
        //   flat:      Meridian, Magelight, Prisma
        //   Skyrim VR: Magelight, Prisma
        // Meridian does not run in VR (its author guide). Magelight runs in
        // both, ships with SeverActions 4.x - so many players have it without
        // knowing - and is the better VR host (controller laser and trigger).
        // All are asked at kInputLoaded: Meridian refuses a first query from
        // later worker-thread messages; the others only need kPostLoad.
        const bool vr = REL::Module::IsVR();
        if (vr) {
            g_host = AcquireMagelight();
            if (!g_host) {
                g_host = AcquirePrisma();
            }
        } else {
            g_host = AcquireMeridian();
            if (!g_host) {
                g_host = AcquireMagelight();
            }
            if (!g_host) {
                g_host = AcquirePrisma();
            }
        }
        if (g_host) {
            SKSE::log::info("{} found{}", g_host->Name(), vr ? " (Skyrim VR)" : "");
        } else {
            // ONCE, and not an error. No dashboard is a supported configuration
            // (design 7.5), and nothing else in the mod depends on it.
            SKSE::log::info("No Meridian UI, Magelight UI or Prisma UI found: no dashboard. "
                            "Everything else in SkyrimNet Relationships works without it.");
        }
    }

    void OnDataLoaded() {
        if (!g_host) {
            return;
        }
        g_created = g_host->Create();
        if (!g_created) {
            SKSE::log::error("{} refused to create the dashboard view: no dashboard this session", g_host->Name());
            return;
        }
        const bool listening = g_host->Listen("snromRequest", OnRequest) && g_host->Listen("snromClose", OnClose);
        if (!listening) {
            SKSE::log::error("Could not register snromRequest/snromClose: the page cannot reach the game");
        }
        SKSE::log::info("Dashboard view created in {}, hidden until the hotkey", g_host->Name());
    }

    void Toggle() {
        if (g_host && g_created && g_host->HasFocus()) {
            Close();
        } else {
            Open();
        }
    }

    void SetDeveloperView(bool a_on) {
        // Logged when it CHANGES. Papyrus and the settings watcher both hand
        // it over, the first time included, and the same value twice is not
        // news.
        const int next = a_on ? 1 : 0;
        if (g_developer.exchange(next) == next) {
            return;
        }
        SKSE::log::info("Developer view {}", a_on ? "on" : "off");
        // An open dashboard follows at once: mode.js applies
        // settings.developer from every snapshot.
        ResendIfOpen();
    }

    void SetDisplay(std::optional<std::int32_t> a_scale, std::optional<std::int32_t> a_textSize) {
        // Logged when either CHANGES, for the reason SetDeveloperView gives.
        bool changed = false;
        if (a_scale && g_scale.exchange(*a_scale) != *a_scale) {
            changed = true;
        }
        if (a_textSize && g_textSize.exchange(*a_textSize) != *a_textSize) {
            changed = true;
        }
        if (!changed) {
            return;
        }
        const auto scale = g_scale.load();
        const auto textSize = g_textSize.load();
        SKSE::log::info("Dashboard scale {}, text size {}", scale == 0 ? "Auto"s : std::format("{}%", scale),
                        textSize == 2 ? "Larger" : textSize == 1 ? "Large" : "Normal");
        // An open dashboard follows at once: app.js applies settings.scale and
        // settings.textSize from every snapshot.
        ResendIfOpen();
    }

    void OnGameLoading() {
        // Every action still waiting on Papyrus belongs to the timeline being
        // left: answered, so the page does not sit out its own timeout.
        for (const auto& action : Model::Get().Clear()) {
            Result(action.pageId, false, "A save was loaded before the game's scripts answered.");
        }
        g_noAnswerLogged = false;
        SKSE::log::info("A save is loading: the dashboard's read model is cleared");
    }

    // ---- From the Papyrus natives, on a VM thread ------------------------

    namespace {
        void LogPush(Model::Push a_push, const char* a_what, std::int32_t a_generation) {
            if (a_push == Model::Push::kWrongSize) {
                // Every time: this is a build mismatch, and each push lost to it
                // is a bond the page cannot show.
                SKSE::log::error("{}: the array is the wrong size for this DLL. SNRom_Bridge.psc and "
                                 "SkyrimNetRelationships.dll are from different builds.",
                                 a_what);
            } else if (a_push == Model::Push::kStale) {
                SKSE::log::debug("{} for refresh {} dropped: asked before the last load", a_what, a_generation);
            }
        }
    }

    namespace {
        // An unsolicited push (a writer, or an LLM callback): shown at once if
        // the view is open, and if it ends a long-running action the page
        // started, the page is told.
        void Unsolicited(std::int32_t a_formId) {
            if (auto what = Model::Get().TakeAwaited(a_formId, Model::ReadModel::Clock::now(), kLongRunningPatience)) {
                SKSE::GetTaskInterface()->AddTask([a_formId, what = std::move(*what)]() {
                    SendNotice(DisplayName(a_formId) + ": " + what + ".", "info");
                });
            }
            QueueSnapshot();
        }
    }

    void PushNumbers(std::int32_t a_generation, std::int32_t a_formId, const std::vector<std::int32_t>& a_values) {
        const auto push = Model::Get().PutNumbers(a_generation, a_formId, a_values);
        LogPush(push, "PutBondNumbers", a_generation);
        if (push == Model::Push::kAccepted && a_generation == 0) {
            Unsolicited(a_formId);
        }
    }

    void PushText(std::int32_t a_generation, std::int32_t a_formId, const std::vector<std::string>& a_values) {
        const auto push = Model::Get().PutText(a_generation, a_formId, a_values);
        LogPush(push, "PutBondText", a_generation);
        if (push == Model::Push::kAccepted && a_generation == 0) {
            Unsolicited(a_formId);
        }
    }

    void PushPlaythrough(std::int32_t a_generation, std::string a_id, std::string a_store, std::int32_t a_decision) {
        LogPush(Model::Get().PutPlaythrough(a_generation, std::move(a_id), std::move(a_store), a_decision),
                "PutPlaythrough", a_generation);
    }

    void PushFacts(std::int32_t a_generation, Display::BatchFacts a_facts) {
        LogPush(Model::Get().PutFacts(a_generation, std::move(a_facts)), "PutRefreshFacts", a_generation);
    }

    void DropBond(std::int32_t a_formId) {
        Model::Get().Drop(a_formId);
        QueueSnapshot();
    }

    void RefreshDone(std::int32_t a_generation, std::int32_t a_count, std::string a_status) {
        auto done = Model::Get().Finish(a_generation, a_count, a_status, Model::ReadModel::Clock::now());
        if (!done.accepted) {
            SKSE::log::debug("RefreshDone for refresh {} ignored: not the one outstanding", a_generation);
            return;
        }
        SKSE::GetTaskInterface()->AddTask([done = std::move(done), a_generation]() {
            g_noAnswerLogged = false;
            const char* late = done.late ? ", after the no-answer notice" : "";
            if (done.ok) {
                // THIS LINE IS HOW THE AUTHOR DECIDES whether a refresh on
                // every open is cheap enough to keep past WP4 (design 7.3).
                SKSE::log::info("Roster refreshed: {} bonds ({}) in {} ms{}", done.bonds,
                                Model::ScopeName(done.scope), done.milliseconds, late);
                if (done.reported != static_cast<std::int32_t>(done.pushed)) {
                    SKSE::log::warn("Refresh {}: Papyrus reported {} bonds but pushed {}", a_generation,
                                    done.reported, done.pushed);
                }
            } else {
                SKSE::log::info("Roster not ready: {} ({} ms{})", done.message, done.milliseconds, late);
            }
            const auto snapshot = SnapshotNow();
            SendSnapshot(snapshot);
            WriteSnapshotFile(snapshot);
        });
    }

    std::int32_t CheckBond(std::int32_t a_formId, bool a_following, std::int32_t a_commitment,
                           std::int32_t a_applicability) {
        // THE COPY, FROM FRESH FACTS, AT THE SAME MOMENT: engine facts read now,
        // the batch sets CheckDashboardDisplay fetched moments ago, and the
        // row's StorageUtil values it pushed just before calling this.
        const auto numbers = Model::Get().NumbersOf(a_formId);
        if (!numbers) {
            SKSE::log::warn("Display check: {:08X} has no numbers pushed; not compared",
                            static_cast<std::uint32_t>(a_formId));
            return 1;
        }
        const auto engine = FactsOf(a_formId);
        const auto copy = Model::Derive(a_formId, *numbers, engine, Model::Get().Facts(), PlayerSex());
        std::int32_t disagreements = 0;
        auto         compare = [&](const char* a_field, auto a_rules, auto a_display) {
            if (a_rules != a_display) {
                ++disagreements;
                SKSE::log::warn("Display check: {} ({:08X}) {}: the rules say {}, the display says {}", copy.name,
                                static_cast<std::uint32_t>(a_formId), a_field, a_rules, a_display);
            }
        };
        compare("following (IsFollowing)", a_following, copy.following);
        compare("commitment (CommitmentState)", a_commitment, copy.commitment);
        compare("foreclosure (RomanceApplicability)", a_applicability, copy.applicability);
        return disagreements;
    }

    std::vector<std::int32_t> ActionArgs(std::int32_t a_requestId) {
        return Model::Get().ArgsFor(a_requestId).value_or(std::vector<std::int32_t>{});
    }

    void ActionDone(std::int32_t a_requestId, bool a_ok, std::string a_message) {
        auto action = Model::Get().TakeAction(a_requestId);
        if (!action) {
            SKSE::log::debug("ActionDone for request {} ignored: not waiting on it", a_requestId);
            return;
        }
        // Started, not finished: the row that comes back from its LLM callback
        // is its end (Unsolicited, above).
        if (a_ok && action->longRunning && action->subject != 0) {
            if (const auto* entry = FindOp(action->op)) {
                Model::Get().Await(action->subject, std::string(entry->finished), Model::ReadModel::Clock::now());
            }
        }
        SKSE::GetTaskInterface()->AddTask([action = std::move(*action), a_ok, message = std::move(a_message)]() {
            SKSE::log::info("Action {} (request {}) {}: {}", action.op, action.requestId,
                            a_ok ? "done" : "refused", message);
            // THE ROW FIRST, THEN THE ANSWER: Papyrus pushed the actor's row
            // before calling ActionDone, so this snapshot already has it.
            if (action.pageAnswered) {
                SendNotice(message, a_ok ? "info" : "warn");
            } else {
                Result(action.pageId, a_ok, message);
            }
            SendSnapshot();
        });
    }
}
