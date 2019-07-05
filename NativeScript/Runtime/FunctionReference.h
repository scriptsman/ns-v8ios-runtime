#ifndef FunctionReference_h
#define FunctionReference_h

#include "Common.h"

namespace tns {

class FunctionReference {
public:
    static void Register(v8::Isolate* isolate, v8::Local<v8::Object> interop);
private:
    static v8::Local<v8::Function> GetFunctionReferenceCtorFunc(v8::Isolate* isolate);
    static void FunctionReferenceConstructorCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
};

}

#endif /* FunctionReference_h */
