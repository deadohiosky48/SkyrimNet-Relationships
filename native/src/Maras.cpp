#include "Maras.h"

#include "PCH.h"

#include <cstring>

namespace SNRom::Maras {

    namespace {

        constexpr const char* kClass = "MARAS";
        constexpr const char* kPromote = "PromoteNPCToStatus";

        // MARAS's answer, which comes back after the call: logged, since the
        // caller has already moved on.
        class Logged : public RE::BSScript::IStackCallbackFunctor {
        public:
            Logged(RE::FormID a_id, std::string a_status) : _id(a_id), _status(std::move(a_status)) {}

            void operator()(RE::BSScript::Variable a_result) override {
                const bool done = a_result.IsBool() && a_result.GetBool();
                if (done) {
                    SKSE::log::info("MARAS: {:08X} set to {}", _id, _status);
                } else {
                    SKSE::log::warn("MARAS: refused to set {:08X} to {}", _id, _status);
                }
            }

            void SetObject(const RE::BSTSmartPointer<RE::BSScript::Object>&) override {}

        private:
            RE::FormID  _id;
            std::string _status;
        };

        // How many parameters the installed MARAS declares for a_name; -1 when
        // it has no such global function, or MARAS is not loaded.
        int ParamCount(RE::BSScript::Internal::VirtualMachine* a_vm, const char* a_name) {
            RE::BSTSmartPointer<RE::BSScript::ObjectTypeInfo> type;
            if (!a_vm->GetScriptObjectType1(kClass, type) || !type) {
                return -1;
            }
            auto* funcs = type->GetGlobalFuncIter();
            for (std::uint32_t i = 0; funcs && i < type->GetNumGlobalFuncs(); ++i) {
                const auto& func = funcs[i].func;
                if (func && _stricmp(func->GetName().c_str(), a_name) == 0) {
                    return static_cast<int>(func->GetParamCount());
                }
            }
            return -1;
        }
    }

    bool PromoteToStatus(RE::Actor* a_actor, const std::string& a_status) {
        auto* vm = RE::BSScript::Internal::VirtualMachine::GetSingleton();
        if (!vm || !a_actor) {
            return false;
        }
        const int params = ParamCount(vm, kPromote);
        RE::BSScript::IFunctionArguments* args = nullptr;
        if (params == 2) {
            args = RE::MakeFunctionArguments(std::move(a_actor), RE::BSFixedString(a_status));
        } else if (params == 3) {
            // 2.0's sendEvent, at its default.
            args = RE::MakeFunctionArguments(std::move(a_actor), RE::BSFixedString(a_status), true);
        } else {
            SKSE::log::warn("MARAS: {}.{} {}; nothing sent", kClass, kPromote,
                            params < 0 ? "is not there" : std::format("takes {} parameters, a shape we do not know", params));
            return false;
        }
        RE::BSTSmartPointer<RE::BSScript::IStackCallbackFunctor> callback{ new Logged(a_actor->GetFormID(), a_status) };
        return vm->DispatchStaticCall(kClass, kPromote, args, callback);
    }
}
