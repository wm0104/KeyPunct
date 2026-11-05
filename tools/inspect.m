// Runtime inspector: dumps Objective-C methods (name + type encoding) of classes
// that only exist after UIKit is loaded. Run on the device, not shipped.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>

static BOOL Matches(const char *name, const char *const *filters, int count) {
    if (count == 0) {
        return YES;
    }
    for (int i = 0; i < count; i++) {
        if (strstr(name, filters[i]) != NULL) {
            return YES;
        }
    }
    return NO;
}

static void DumpClass(const char *className, const char *const *filters, int count) {
    Class cls = objc_getClass(className);
    if (cls == Nil) {
        printf("== %s: MISSING\n", className);
        return;
    }
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    printf("== %s (%u methods)\n", className, methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        if (Matches(name, filters, count)) {
            printf("%s :: %s\n", name, method_getTypeEncoding(methods[i]));
        }
    }
    free(methods);

    // Class methods too, for the singletons we may call.
    Class meta = object_getClass(cls);
    unsigned int classMethodCount = 0;
    Method *classMethods = class_copyMethodList(meta, &classMethodCount);
    for (unsigned int i = 0; i < classMethodCount; i++) {
        const char *name = sel_getName(method_getName(classMethods[i]));
        if (Matches(name, filters, count)) {
            printf("+%s :: %s\n", name, method_getTypeEncoding(classMethods[i]));
        }
    }
    free(classMethods);
    printf("\n");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        void *handle = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW);
        if (handle == NULL) {
            printf("dlopen UIKit failed: %s\n", dlerror());
        }

        const char *filters[] = {"insert", "punct", "Key", "key", "candidate", "Candidate",
                                 "accept", "Accept", "text", "Text"};
        int filterCount = (int)(sizeof(filters) / sizeof(filters[0]));

        const char *classes[] = {"UIKeyboardImpl", "UIKeyboardInputModeController",
                                 "UITextInputMode", "UIKeyboardInputMode"};
        for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) {
            DumpClass(classes[i], filters, filterCount);
        }
        (void)argv;
        (void)argc;
    }
    return 0;
}
