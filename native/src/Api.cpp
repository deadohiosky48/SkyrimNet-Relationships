#include "Api.h"

#include "PCH.h"

#include "Dashboard.h"
#include "Display.h"
#include "Model.h"
#include "Settings.h"

#define SNREL_API_NO_LOADER
#include "SkyrimNetRelationships/SNRelationships_API.h"

#include <algorithm>
#include <cstring>
#include <functional>
#include <map>
#include <optional>
#include <vector>

namespace SNRom::Api {

    namespace {

        namespace P = SNREL_API;

        // ---- game-thread state ---------------------------------------------
        bool                                  g_ready = false;
        std::map<std::uint32_t, P::Values>    g_last;  // what listeners last saw
        struct Listener {
            std::uint32_t handle;
            P::ChangeFn   fn;
            void*         user;
        };
        std::vector<Listener> g_listeners;
        std::uint32_t         g_nextHandle = 1;

        void Notify(std::uint32_t a_formId, std::uint32_t a_changed) {
            const auto listeners = g_listeners;  // a listener may remove itself
            for (const auto& l : listeners) {
                l.fn(a_formId, a_changed, l.user);
            }
        }

        // SNRom_Decorators.PhysicalOk, from the pushed values: the gate is
        // closed by anything that forecloses romance, opens at the tier the
        // disposition asks for (Confidant for ROMANTIC, and then only once
        // sparked or engaged), by points banked short of Lover, or by
        // attraction above the bypass bar.
        bool Gate(const Model::Numbers& n, std::int32_t a_applicability, std::int32_t a_commitment) {
            if (a_applicability != 0) {
                return false;
            }
            std::int32_t minTier = n[Model::kPhysMinTier];
            if (minTier < 0) {
                return false;
            }
            const auto rank = n[Model::kIntimacy];
            if (rank >= 1) {
                if (n[Model::kSparked] != 1 && a_commitment < 2) {
                    return false;
                }
                if (rank == 1) {
                    minTier = 3;
                }
            }
            if (n[Model::kTier] >= minTier) {
                return true;
            }
            const auto banked = n[Model::kBanked];
            if (banked > 0 && (n[Model::kPoints] + banked) / 500 >= minTier) {
                return true;
            }
            if (n[Model::kAttrBypass] == 1) {
                const float ratio = static_cast<float>(n[Model::kAttractionMilli]) / 1000.0f;
                if (ratio > 0.0f && ratio >= Settings::AttractionBypassRatio()) {
                    return true;
                }
            }
            return false;
        }

        std::optional<P::Values> Compute(std::uint32_t a_formId) {
            const auto id = static_cast<std::int32_t>(a_formId);
            const auto numbers = Model::Get().NumbersOf(id);
            if (!numbers) {
                return std::nullopt;
            }
            const auto& n = *numbers;
            const auto  engine = Dashboard::EngineFactsOf(id);
            const auto  batch = Model::Get().Facts();
            const Display::StoredFacts stored{ n[Model::kOrientation], n[Model::kOrientationBasis],
                                               n[Model::kPlayerKin] != 0 };
            const auto commitment = Display::Commitment(id, engine, batch);
            const auto applicability = Display::Applicability(id, engine, batch, stored, Dashboard::PlayerSexNow());

            P::Values v{};
            v.size = sizeof(P::Values);
            v.formId = a_formId;
            v.tier = n[Model::kTier];
            v.points = n[Model::kPoints];
            v.sparked = n[Model::kSparked];
            v.stance = n[Model::kStance];
            v.romanceEnded = n[Model::kEndedAt] >= 0 ? 1 : 0;
            v.endedAtMinutes = n[Model::kEndedAt];
            v.commitment = commitment;
            v.orientation = n[Model::kOrientation];
            v.orientationBasis = n[Model::kOrientationBasis];
            v.intimacyRank = n[Model::kIntimacy];
            v.intimacyGate = Gate(n, applicability, commitment) ? 1 : 0;
            v.followingSinceMinutes = n[Model::kFirstSeenFollowing];
            return v;
        }

        std::uint32_t Diff(const P::Values& a, const P::Values& b) {
            std::uint32_t m = 0;
            if (a.tier != b.tier) m |= P::kTier;
            if (a.points != b.points) m |= P::kPoints;
            if (a.sparked != b.sparked) m |= P::kSparked;
            if (a.stance != b.stance) m |= P::kStance;
            if (a.romanceEnded != b.romanceEnded || a.endedAtMinutes != b.endedAtMinutes) m |= P::kRomanceEnded;
            if (a.commitment != b.commitment) m |= P::kCommitment;
            if (a.orientation != b.orientation || a.orientationBasis != b.orientationBasis) m |= P::kOrientation;
            if (a.intimacyRank != b.intimacyRank) m |= P::kIntimacyRank;
            if (a.intimacyGate != b.intimacyGate) m |= P::kIntimacyGate;
            if (a.followingSinceMinutes != b.followingSinceMinutes) m |= P::kFollowingSince;
            return m;
        }

        constexpr std::uint32_t kAllValues = P::kTier | P::kPoints | P::kSparked | P::kStance | P::kRomanceEnded |
                                             P::kCommitment | P::kOrientation | P::kIntimacyRank | P::kIntimacyGate |
                                             P::kFollowingSince;

        // Brings g_last up to date for one person and says what changed. Quiet
        // until Loaded: the load-time publish is announced once, as kReloaded.
        void Recompute(std::uint32_t a_formId) {
            auto       now = Compute(a_formId);
            const auto it = g_last.find(a_formId);
            std::uint32_t changed = 0;
            if (now && it == g_last.end()) {
                changed = P::kEnrolled | kAllValues;
                g_last.emplace(a_formId, *now);
            } else if (!now && it != g_last.end()) {
                changed = P::kUnenrolled;
                g_last.erase(it);
            } else if (now) {
                changed = Diff(it->second, *now);
                it->second = *now;
            }
            if (changed && g_ready) {
                Notify(a_formId, changed);
            }
        }

        void RecomputeAll() {
            std::vector<std::uint32_t> ids;
            for (const auto& [id, values] : g_last) {
                ids.push_back(id);
            }
            for (const auto id : Model::Get().FormIds()) {
                ids.push_back(static_cast<std::uint32_t>(id));
            }
            std::sort(ids.begin(), ids.end());
            ids.erase(std::unique(ids.begin(), ids.end()), ids.end());
            for (const auto id : ids) {
                Recompute(id);
            }
        }

        // ---- the exported interface ----------------------------------------
        bool IsReady() { return g_ready; }

        bool GetValues(std::uint32_t a_formId, P::Values* a_out) {
            if (!g_ready || !a_out || a_out->size < sizeof(std::uint32_t) * 2) {
                return false;
            }
            const auto it = g_last.find(a_formId);
            if (it == g_last.end()) {
                return false;
            }
            const auto size = std::min<std::size_t>(a_out->size, sizeof(P::Values));
            const auto keep = a_out->size;
            std::memcpy(a_out, &it->second, size);
            a_out->size = keep;
            return true;
        }

        std::uint32_t ListEnrolled(std::uint32_t* a_out, std::uint32_t a_capacity) {
            if (!g_ready) {
                return 0;
            }
            std::uint32_t i = 0;
            for (const auto& [id, values] : g_last) {
                if (a_out && i < a_capacity) {
                    a_out[i] = id;
                }
                ++i;
            }
            return i;
        }

        std::uint32_t AddListener(P::ChangeFn a_fn, void* a_user) {
            if (!a_fn) {
                return 0;
            }
            const auto handle = g_nextHandle++;
            g_listeners.push_back({ handle, a_fn, a_user });
            return handle;
        }

        void RemoveListener(std::uint32_t a_handle) {
            std::erase_if(g_listeners, [a_handle](const Listener& l) { return l.handle == a_handle; });
        }

        const P::Api1 g_api1{ P::kApiVersion1, IsReady, GetValues, ListEnrolled, AddListener, RemoveListener };

        void Post(std::function<void()> a_task) {
            if (auto* tasks = SKSE::GetTaskInterface()) {
                tasks->AddTask(std::move(a_task));
            }
        }
    }

    void Changed(std::int32_t a_formId) {
        Post([id = static_cast<std::uint32_t>(a_formId)]() { Recompute(id); });
    }

    void ChangedAll() {
        Post([]() { RecomputeAll(); });
    }

    void Loaded(std::int32_t a_count) {
        Post([a_count]() {
            g_ready = false;  // the publish is announced once, not per person
            RecomputeAll();
            g_ready = true;
            SKSE::log::info("Read API: {} enrolled published ({} pushed), {} listener(s) told", g_last.size(), a_count,
                            g_listeners.size());
            Notify(0, P::kReloaded);
        });
    }

    const void* Request(std::uint32_t a_version) {
        return a_version == SNREL_API::kApiVersion1 ? &g_api1 : nullptr;
    }

    void Reset() {
        // Called from the load message on the game thread.
        const bool had = g_ready || !g_last.empty();
        g_ready = false;
        g_last.clear();
        if (had) {
            Notify(0, P::kUnloaded);
        }
    }
}

// The one export other plugins look up (SNREL_API::RequestApi1). An unknown
// version is null, never a guess.
extern "C" __declspec(dllexport) const void* SNRelationships_RequestApi(std::uint32_t a_version) {
    return SNRom::Api::Request(a_version);
}
