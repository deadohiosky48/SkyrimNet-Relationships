#include "RingCatalog.h"

#include "PCH.h"

#include <array>
#include <unordered_set>

namespace SNRom::RingCatalog {

    namespace {

        constexpr auto kPlugin = "SNRom_Integration.esl";

        struct Entry {
            RE::FormID local;   // the ARMO's FormID in our plugin
            Kind       kind;
            Metal      metal;
        };

        // As tools/rings/add_ring_records.py, RING_TABLE.
        constexpr std::array kRings{
            Entry{ 0xD66, Kind::kEngagement, Metal::kGold },   Entry{ 0xD76, Kind::kEngagement, Metal::kSilver },
            Entry{ 0xD78, Kind::kEngagement, Metal::kEbony },  Entry{ 0xD68, Kind::kWedding, Metal::kGold },
            Entry{ 0xD7A, Kind::kWedding, Metal::kSilver },    Entry{ 0xD7C, Kind::kWedding, Metal::kEbony },
            Entry{ 0xD74, Kind::kBand, Metal::kGold },         Entry{ 0xD7E, Kind::kBand, Metal::kSilver },
            Entry{ 0xD80, Kind::kBand, Metal::kEbony },        Entry{ 0xD82, Kind::kWideBand, Metal::kGold },
            Entry{ 0xD84, Kind::kWideBand, Metal::kSilver },   Entry{ 0xD86, Kind::kWideBand, Metal::kEbony },
        };

        const Entry* EntryOf(const RE::TESForm* a_form) {
            const auto* file = a_form ? a_form->GetFile(0) : nullptr;
            if (!file || std::string_view(file->GetFilename()) != kPlugin) {
                return nullptr;
            }
            const auto local = a_form->GetLocalFormID();
            for (const auto& e : kRings) {
                if (e.local == local) {
                    return &e;
                }
            }
            return nullptr;
        }

        RE::TESForm* FormOf(const Entry& a_entry) {
            auto* data = RE::TESDataHandler::GetSingleton();
            return data ? data->LookupForm(a_entry.local, kPlugin) : nullptr;
        }

        bool ListHas(const RE::BGSListForm* a_list, RE::FormID a_id) {
            if (!a_list) {
                return false;
            }
            for (const auto* form : a_list->forms) {
                if (form && form->GetFormID() == a_id) {
                    return true;
                }
            }
            return false;
        }
    }

    bool IsOurs(const RE::TESForm* a_form) {
        return EntryOf(a_form) != nullptr;
    }

    std::int32_t KindOf(const RE::TESForm* a_form) {
        const auto* e = EntryOf(a_form);
        return e ? static_cast<std::int32_t>(e->kind) : -1;
    }

    std::int32_t MetalOf(const RE::TESForm* a_form) {
        const auto* e = EntryOf(a_form);
        return e ? static_cast<std::int32_t>(e->metal) : -1;
    }

    RE::TESForm* Find(Kind a_kind, Metal a_metal) {
        for (const auto& e : kRings) {
            if (e.kind == a_kind && e.metal == a_metal) {
                return FormOf(e);
            }
        }
        return nullptr;
    }

    std::vector<RE::TESForm*> All() {
        std::vector<RE::TESForm*> out;
        for (const auto& e : kRings) {
            if (auto* form = FormOf(e)) {
                out.push_back(form);
            }
        }
        return out;
    }

    void StockJewelers() {
        auto* data = RE::TESDataHandler::GetSingleton();
        if (!data) {
            return;
        }
        constexpr RE::FormID kJewelry = 0x0008F95A;    // KYWD VendorItemJewelry (Skyrim.esm)
        constexpr RE::FormID kSpellTome = 0x000937A5;  // KYWD VendorItemSpellTome
        std::vector<RE::TESBoundObject*> stock;
        for (const auto& e : kRings) {
            if (e.kind == Kind::kWedding) {
                continue;   // made at a wedding, never sold
            }
            if (auto* armor = data->LookupForm<RE::TESObjectARMO>(e.local, kPlugin)) {
                stock.push_back(armor);
            }
        }
        std::unordered_set<RE::TESObjectCONT*> done;
        std::size_t                            merchants = 0;
        for (auto* faction : data->GetFormArray<RE::TESFaction>()) {
            const auto* list = faction ? faction->vendorData.vendorSellBuyList : nullptr;
            auto*       chest = faction ? faction->vendorData.merchantContainer : nullptr;
            if (!list || !chest || !ListHas(list, kJewelry) || ListHas(list, kSpellTome)) {
                continue;
            }
            auto* base = chest->GetBaseObject();
            auto* container = base ? base->As<RE::TESObjectCONT>() : nullptr;
            if (!container || !done.insert(container).second) {
                continue;
            }
            for (auto* ring : stock) {
                if (container->GetObjectCount(ring) == 0) {
                    container->AddObjectToContainer(ring, 1, nullptr);
                }
            }
            ++merchants;
            SKSE::log::info("Rings: stocked merchant {:08X} (chest {:08X})", faction->GetFormID(),
                            container->GetFormID());
        }
        SKSE::log::info("Rings: {} rings for sale at {} jewelers", stock.size(), merchants);
    }
}
