#pragma once

#include <cstdint>
#include <vector>

namespace RE {
    class TESForm;
}

// OUR RINGS, IN ONE PLACE (2.5; the author, 2026-10-20). Four shapes in three
// metals, the records in SNRom_Integration.esl (tools/rings/add_ring_records.py,
// RING_TABLE, the source of the FormIDs here):
//
//   the engagement ring  (the resource's solitaire)
//   the wedding ring     (the engagement ring with its band; made only at a
//                         wedding, when an engagement ring of ours becomes one)
//   the wedding band     (the resource's braided band alone)
//   the wide band        (our own plain band, traditionally a man's)
//
// in gold, silver and ebony. Everything that asks whether a ring is ours, which
// wedding ring an engagement ring becomes, or which band the player is given,
// asks here; and the jewelers are stocked from here.
namespace SNRom::RingCatalog {

    enum class Kind : std::int32_t { kEngagement = 0, kWedding = 1, kBand = 2, kWideBand = 3 };
    enum class Metal : std::int32_t { kGold = 0, kSilver = 1, kEbony = 2 };

    // One of ours, of any kind or metal.
    bool IsOurs(const RE::TESForm* a_form);

    // Its kind and metal; -1 for a ring not ours.
    std::int32_t KindOf(const RE::TESForm* a_form);
    std::int32_t MetalOf(const RE::TESForm* a_form);

    // The ring of a_kind in a_metal; null when the plugin lacks it.
    RE::TESForm* Find(Kind a_kind, Metal a_metal);

    // Every ring of ours (SeverActions' equipment blacklist takes them all).
    std::vector<RE::TESForm*> All();

    // kDataLoaded: every ring but the wedding ring, one of each, into the
    // stock of every merchant who sells jewellery: whose buy list takes
    // VendorItemJewelry and not spell tomes (a spell vendor buys enchanted
    // jewellery but never sells it). In vanilla: Kerah's stall by Markarth's
    // gate, Madesi's in Riften, Fralia Gray-Mane's in Whiterun and Radiant
    // Raiment in Solitude; a modded jeweler the same way. A merchant's chest
    // takes it at its next restock; in a new game, at once.
    void StockJewelers();
}
