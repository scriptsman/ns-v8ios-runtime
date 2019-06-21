#include "ObjectManager.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Caches.h"

using namespace v8;
using namespace std;

namespace tns {

Persistent<Value>* ObjectManager::Register(Isolate* isolate, const v8::Local<v8::Value> obj) {
    Persistent<Value>* objectHandle = new Persistent<Value>(isolate, obj);
    ObjectWeakCallbackState* state = new ObjectWeakCallbackState(objectHandle);
    objectHandle->SetWeak(state, FinalizerCallback, WeakCallbackType::kFinalizer);
    return objectHandle;
}

void ObjectManager::FinalizerCallback(const WeakCallbackInfo<ObjectWeakCallbackState>& data) {
    ObjectWeakCallbackState* state = data.GetParameter();
    Isolate* isolate = data.GetIsolate();
    Local<Value> value = state->target_->Get(isolate);
    ObjectManager::DisposeValue(isolate, value);

    state->target_->Reset();
    delete state->target_;
    delete state;
}

void ObjectManager::DisposeValue(Isolate* isolate, Local<Value> value) {
    if (value.IsEmpty() || value->IsNullOrUndefined() || !value->IsObject()) {
        return;
    }

    Local<Object> obj = value.As<Object>();
    if (obj->InternalFieldCount() < 1) {
        return;
    }

    if (obj->InternalFieldCount() > 1) {
        Local<Value> superValue = obj->GetInternalField(1);
        if (!superValue.IsEmpty() && superValue->IsString()) {
            // Do not dispose the ObjCWrapper contained in a "super" instance
            return;
        }
    }

    Local<Value> internalField = obj->GetInternalField(0);
    if (internalField.IsEmpty() || internalField->IsNullOrUndefined() || !internalField->IsExternal()) {
        return;
    }

    void* internalFieldValue = internalField.As<External>()->Value();
    BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(internalFieldValue);
    if (wrapper == nullptr) {
        obj->SetInternalField(0, v8::Undefined(isolate));
        return;
    }

    switch (wrapper->Type()) {
        case WrapperType::Struct: {
            StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
            void* data = structWrapper->Data();
            if (data) {
                std::free(data);
            }
            break;
        }
        case WrapperType::ObjCObject: {
            ObjCDataWrapper* objCObjectWrapper = static_cast<ObjCDataWrapper*>(wrapper);
            if (objCObjectWrapper->Data() != nil) {
                auto it = Caches::Instances.find(objCObjectWrapper->Data());
                if (it != Caches::Instances.end()) {
                    Caches::Instances.erase(it);
                }
            }
            break;
        }
        case WrapperType::Block: {
            BlockWrapper* blockWrapper = static_cast<BlockWrapper*>(wrapper);
            std::free(blockWrapper->Block());
            break;
        }
        case WrapperType::Reference: {
            ReferenceWrapper* referenceWrapper = static_cast<ReferenceWrapper*>(wrapper);
            if (referenceWrapper->Value() != nullptr) {
                Local<Value> value = referenceWrapper->Value()->Get(isolate);
                ObjectManager::DisposeValue(isolate, value);
                DisposeValue(isolate, referenceWrapper->Value()->Get(isolate));
                referenceWrapper->Value()->Reset();
            }

            if (referenceWrapper->Data() != nullptr) {
                std::free(referenceWrapper->Data());
                referenceWrapper->SetData(nullptr);
            }

            break;
        }
        case WrapperType::Pointer: {
            PointerWrapper* pointerWrapper = static_cast<PointerWrapper*>(wrapper);
            if (pointerWrapper->Data() != nullptr) {
                auto it = Caches::PointerInstances.find(pointerWrapper->Data());
                if (it != Caches::PointerInstances.end()) {
                    delete it->second;
                    Caches::PointerInstances.erase(it);
                }

                if (pointerWrapper->IsAdopted()) {
                    std::free(pointerWrapper->Data());
                    pointerWrapper->SetData(nullptr);
                }
            }
            break;
        }
        case WrapperType::FunctionReference: {
            FunctionReferenceWrapper* funcWrapper = static_cast<FunctionReferenceWrapper*>(wrapper);
            if (funcWrapper->Function() != nullptr) {
                DisposeValue(isolate, funcWrapper->Function()->Get(isolate));
                funcWrapper->Function()->Reset();
            }
            break;
        }

        default:
            break;
    }

    delete wrapper;
    wrapper = nullptr;
    obj->SetInternalField(0, v8::Undefined(isolate));
}

}
