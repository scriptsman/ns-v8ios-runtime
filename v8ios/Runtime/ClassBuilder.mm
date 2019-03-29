#include <Foundation/Foundation.h>
#include "ClassBuilder.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Caches.h"

using namespace v8;

namespace tns {

void ClassBuilder::Init(ArgConverter argConverter, ObjectManager objectManager) {
    argConverter_ = argConverter;
    objectManager_ = objectManager;
}

Local<v8::Function> ClassBuilder::GetExtendFunction(Local<Context> context, const InterfaceMeta* interfaceMeta) {
    Isolate* isolate = context->GetIsolate();
    CacheItem* item = new CacheItem(interfaceMeta, nullptr, this);
    Local<External> ext = External::New(isolate, item);

    Local<v8::Function> extendFunc;

    if (!v8::Function::New(context, ExtendCallback, ext).ToLocal(&extendFunc)) {
        assert(false);
    }

    return extendFunc;
}

void ClassBuilder::ExtendCallback(const FunctionCallbackInfo<Value>& info) {
    assert(info.Length() > 0 && info[0]->IsObject() && info.This()->IsFunction());

    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    CacheItem* item = static_cast<CacheItem*>(info.Data().As<External>()->Value());

    Local<Object> implementationObject = info[0].As<Object>();
    Local<v8::Function> baseFunc = info.This().As<v8::Function>();
    std::string name = tns::ToString(isolate, baseFunc->GetName());

    const GlobalTable* globalTable = MetaFile::instance()->globalTable();
    const InterfaceMeta* interfaceMeta = globalTable->findInterfaceMeta(name.c_str());
    assert(interfaceMeta != nullptr);

    Class extendedClass = item->self_->GetExtendedClass(name.c_str());
    if (info.Length() > 1 && info[1]->IsObject()) {
        item->self_->ExposeDynamicMembers(isolate, extendedClass, implementationObject, info[1].As<Object>());
        item->self_->ExposeDynamicProtocols(isolate, extendedClass, info[1].As<Object>());
    }
    objc_registerClassPair(extendedClass);

    Persistent<v8::Function>* poBaseCtorFunc = Caches::CtorFuncs.find(item->meta_)->second;
    Local<v8::Function> baseCtorFunc = Local<v8::Function>::New(isolate, *poBaseCtorFunc);

    CacheItem* cacheItem = new CacheItem(nullptr, extendedClass, item->self_);
    Local<External> ext = External::New(isolate, cacheItem);
    Local<FunctionTemplate> extendedClassCtorFuncTemplate = FunctionTemplate::New(isolate, ExtendedClassConstructorCallback, ext);
    extendedClassCtorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);

    Local<v8::Function> extendClassCtorFunc;
    if (!extendedClassCtorFuncTemplate->GetFunction(context).ToLocal(&extendClassCtorFunc)) {
        assert(false);
    }

    bool success;
    if (!implementationObject->SetPrototype(context, baseCtorFunc->Get(tns::ToV8String(isolate, "prototype"))).To(&success) || !success) {
        assert(false);
    }
    if (!implementationObject->SetAccessor(context, tns::ToV8String(isolate, "super"), SuperAccessorGetterCallback, nullptr, ext).To(&success) || !success) {
        assert(false);
    }

    extendClassCtorFunc->SetName(tns::ToV8String(isolate, class_getName(extendedClass)));
    Local<Object> extendFuncPrototype = extendClassCtorFunc->Get(tns::ToV8String(isolate, "prototype")).As<Object>();
    if (!extendFuncPrototype->SetPrototype(context, implementationObject).To(&success) || !success) {
        assert(false);
    }

    if (!extendClassCtorFunc->SetPrototype(context, baseCtorFunc).To(&success) || !success) {
        assert(false);
    }

    info.GetReturnValue().Set(extendClassCtorFunc);
}

void ClassBuilder::ExtendedClassConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();

    CacheItem* item = static_cast<CacheItem*>(info.Data().As<External>()->Value());

    id obj = [[item->data_ alloc] init];

    DataWrapper* wrapper = new DataWrapper(obj);
    Local<External> ext = External::New(isolate, wrapper);

    Local<Object> thiz = info.This();
    thiz->SetInternalField(0, ext);

    item->self_->objectManager_.Register(isolate, thiz);
}

void ClassBuilder::ExposeDynamicMembers(Isolate* isolate, Class extendedClass, Local<Object> implementationObject, Local<Object> nativeSignature) {
    Local<Value> exposedMethods = nativeSignature->Get(tns::ToV8String(isolate, "exposedMethods"));
    if (!exposedMethods.IsEmpty() && exposedMethods->IsObject()) {
        Local<Context> context = isolate->GetCurrentContext();
        Local<v8::Array> methodNames;
        if (!exposedMethods.As<Object>()->GetOwnPropertyNames(context).ToLocal(&methodNames)) {
            assert(false);
        }

        for (int i = 0; i < methodNames->Length(); i++) {
            Local<Value> methodName = methodNames->Get(i);
            Local<Value> methodSignature = exposedMethods.As<Object>()->Get(methodName);
            assert(methodSignature->IsObject());
            Local<Value> method = implementationObject->Get(methodName);
            if (method.IsEmpty() || !method->IsFunction()) {
                assert(false);
            }

            // TODO: Prepare the TypeEncoding* from the v8 arguments and return type
            const InterfaceMeta* interfaceMeta = argConverter_.FindInterfaceMeta(extendedClass);
            std::string typeInfo = "v@:@";
            int argsCount = 1;
            std::string methodNameStr = tns::ToString(isolate, methodName);
            SEL selector = NSSelectorFromString([NSString stringWithUTF8String:(methodNameStr + ":").c_str()]);

            TypeEncoding* typeEncoding = reinterpret_cast<TypeEncoding*>(calloc(2, sizeof(TypeEncoding)));
            typeEncoding->type = BinaryTypeEncodingType::VoidEncoding;
            TypeEncoding* next = reinterpret_cast<TypeEncoding*>(reinterpret_cast<char*>(typeEncoding) + sizeof(BinaryTypeEncodingType));
            next->type = BinaryTypeEncodingType::InterfaceDeclarationReference;

            Persistent<v8::Object>* poCallback = new Persistent<v8::Object>(isolate, method.As<Object>());
            MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 2, argsCount, typeEncoding, &argConverter_);
            IMP methodBody = interop_.CreateMethod(2, argsCount, typeEncoding, ArgConverter::MethodCallback, userData);
            class_addMethod(extendedClass, selector, methodBody, typeInfo.c_str());
        }
    }
}

void ClassBuilder::ExposeDynamicProtocols(Isolate* isolate, Class extendedClass, Local<Object> nativeSignature) {
    Local<Value> exposedProtocols = nativeSignature->Get(tns::ToV8String(isolate, "protocols"));
    if (exposedProtocols.IsEmpty() || !exposedProtocols->IsArray()) {
        return;
    }

    Local<v8::Array> protocols = exposedProtocols.As<v8::Array>();
    if (protocols->Length() < 1) {
        return;
    }

    for (uint32_t i = 0; i < protocols->Length(); i++) {
        Local<Value> element = protocols->Get(i);
        assert(!element.IsEmpty() && element->IsObject());

        Local<Object> protoObj = element.As<Object>();
        assert(protoObj->InternalFieldCount() > 0);

        Local<External> ext = protoObj->GetInternalField(0).As<External>();
        DataWrapper* wrapper = static_cast<DataWrapper*>(ext->Value());
        const char* protocolName = wrapper->meta_->name();
        Protocol* proto = objc_getProtocol(protocolName);
        assert(proto != nullptr);

        class_addProtocol(extendedClass, proto);
    }
}

void ClassBuilder::SuperAccessorGetterCallback(Local<Name> property, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> thiz = info.This();

    CacheItem* item = static_cast<CacheItem*>(info.Data().As<External>()->Value());
    Local<Object> superValue = item->self_->argConverter_.CreateEmptyObject(context);

    superValue->SetPrototype(context, thiz->GetPrototype().As<Object>()->GetPrototype().As<Object>()->GetPrototype()).ToChecked();
    superValue->SetInternalField(0, thiz->GetInternalField(0));

    info.GetReturnValue().Set(superValue);
}

Class ClassBuilder::GetExtendedClass(std::string baseClassName) {
    Class baseClass = objc_getClass(baseClassName.c_str());
    std::string name = baseClassName + "_" + std::to_string(++ClassBuilder::classNameCounter_);
    Class clazz = objc_getClass(name.c_str());

    if (clazz != nil) {
        return GetExtendedClass(baseClassName);
    }

    clazz = objc_allocateClassPair(baseClass, name.c_str(), 0);
    return clazz;
}

unsigned long long ClassBuilder::classNameCounter_ = 0;

}