// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// KeyPunct — in Apple's Simplified Chinese Pinyin keyboard (26-key and 10-key
// alike), a single press of a punctuation key inserts the English/ASCII
// punctuation instead of the Chinese one. Nothing else changes: the key caps
// stay as they are, and candidates, dictation, paste and autofill are left
// alone.
//
// Only an insertion whose every character is in the table (1 to 4 of them, so
// a paired "“”" key and "——" both qualify) is rewritten; a word never is.
//
// Hook points, taken from this device's UIKit (iOS 16.3, UIKeyboardImpl has no
// -insertText: at all):
//   -[UIKeyboardImpl handleKeyWithString:forKeyEvent:executionContext:]
//   -[UIKeyboardImpl insertText:withAlternativePredictions:]
//   -[UIKeyboardImpl insertTextIfShould:]
//   -[UIKeyboardImpl updateKeyboardOutput:withInputForSmartPunctuation:keyboardConfiguration:]
// The last one matters: Chinese smart punctuation rewrites an inserted ASCII
// quote or comma into “ ” ‘ ’ ， in the keyboard output, so it must be
// converted again there.

#import <UIKit/UIKit.h>
#import <os/log.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <dlfcn.h>

static os_log_t TweakLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "tweak");
    });
    return log;
}

// MARK: - The setting
//
// Written by the Settings pane at /Library/PreferenceBundles/KeyPunctPrefs.bundle.
// The domain's plist lives in the jbroot's own var/mobile/Library/Preferences,
// which a sandboxed app cannot reach through cfprefsd, so it is read straight
// from that file first and cfprefsd is only the fallback.

static NSString *const KeyPunctPreferencesDomain = @"com.wm0104.keypunct.preferences";
static NSString *const KeyPunctPreferencesKey = @"enabled";
static NSString *const KeyPunctChangedNotification = @"com.wm0104.keypunct/changed";

static BOOL KeyPunctCachedEnabled = YES;
static CFAbsoluteTime KeyPunctCachedAt = 0;
static const CFAbsoluteTime KeyPunctCacheLifetime = 1.0;

static NSString *KeyPunctBootstrapRoot(void) {
#if APELIN_BOOTSTRAP_ROOTHIDE
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const char anchor = 0;
        Dl_info info;
        if (dladdr(&anchor, &info) == 0 || info.dli_fname == NULL) {
            return;
        }
        NSArray<NSString *> *parts = [@(info.dli_fname) componentsSeparatedByString:@"/"];
        for (NSUInteger index = 0; index < parts.count; index++) {
            if ([parts[index] hasPrefix:@".jbroot-"]) {
                root = [[parts subarrayWithRange:NSMakeRange(0, index + 1)]
                    componentsJoinedByString:@"/"];
                break;
            }
        }
    });
    return root;
#else
    return @"/var/jb";
#endif
}

static NSString *KeyPunctPreferencesFilePath(void) {
    NSString *root = KeyPunctBootstrapRoot();
    if (root == nil) {
        return nil;
    }
    return [root stringByAppendingString:
        @"/var/mobile/Library/Preferences/com.wm0104.keypunct.preferences.plist"];
}

static BOOL KeyPunctReadBoolPreference(NSString *key, BOOL fallback) {
    NSString *path = KeyPunctPreferencesFilePath();
    if (path != nil) {
        NSDictionary<NSString *, id> *stored = [NSDictionary dictionaryWithContentsOfFile:path];
        id value = stored[key];
        if (value != nil) {
            if ([value isKindOfClass:[NSNumber class]]) {
                return [(NSNumber *)value boolValue];
            }
            if ([value isKindOfClass:[NSString class]]) {
                return [(NSString *)value caseInsensitiveCompare:@"NO"] != NSOrderedSame;
            }
        }
    }

    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)KeyPunctPreferencesDomain);
    BOOL result = fallback;
    if (value != NULL) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            result = CFBooleanGetValue((CFBooleanRef)value) ? YES : NO;
        } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            int number = 0;
            if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number)) {
                result = (number != 0);
            }
        } else if (CFGetTypeID(value) == CFStringGetTypeID()) {
            result = CFStringCompare((CFStringRef)value, CFSTR("NO"), kCFCompareCaseInsensitive) != kCFCompareEqualTo;
        }
        CFRelease(value);
    }
    return result;
}

static void KeyPunctPreferencesChanged(CFNotificationCenterRef center, void *observer,
                                       CFNotificationName name, const void *object,
                                       CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    KeyPunctCachedAt = 0;
}

static BOOL KeyPunctEnabled(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (KeyPunctCachedAt == 0 || now - KeyPunctCachedAt > KeyPunctCacheLifetime) {
        KeyPunctCachedEnabled = KeyPunctReadBoolPreference(KeyPunctPreferencesKey, YES);
        KeyPunctCachedAt = now;
    }
    return KeyPunctCachedEnabled;
}

// MARK: - Which keyboard is up

typedef id (*KeyPunctObjectMessage)(id, SEL);

static id KeyPunctSend(id receiver, SEL selector) {
    return ((KeyPunctObjectMessage)objc_msgSend)(receiver, selector);
}

static NSString *KeyPunctCurrentInputIdentifier(void);

// Only Apple's Simplified Chinese Pinyin keyboard: "zh_Hans-Pinyin" (26-key)
// and "zh_Hans-Pinyin@sw=Pinyin-Simplified…" (10-key). English, third-party
// keyboards and the handwriting/stroke input modes have other identifiers.
static BOOL KeyPunctIsSimplifiedPinyin(void) {
    NSString *identifier = KeyPunctCurrentInputIdentifier();
    return [identifier isKindOfClass:[NSString class]] && [identifier hasPrefix:@"zh_Hans-Pinyin"];
}

static NSString *KeyPunctCurrentInputIdentifier(void) {
    Class controllerClass = objc_getClass("UIKeyboardInputModeController");
    if (controllerClass == Nil) {
        return nil;
    }
    SEL sharedSelector = sel_registerName("sharedInputModeController");
    if (!class_respondsToSelector(object_getClass(controllerClass), sharedSelector)) {
        return nil;
    }
    id controller = KeyPunctSend((id)controllerClass, sharedSelector);
    SEL currentSelector = sel_registerName("currentInputMode");
    if (controller == nil || ![controller respondsToSelector:currentSelector]) {
        return nil;
    }
    UITextInputMode *mode = KeyPunctSend(controller, currentSelector);
    if (![mode isKindOfClass:[UITextInputMode class]]) {
        return nil;
    }
    // -identifier is the input mode's own property, not one UITextInputMode's
    // public header declares: send it by name.
    id identifier = KeyPunctSend(mode, sel_registerName("identifier"));
    return [identifier isKindOfClass:[NSString class]] ? identifier : nil;
}

// MARK: - The table

static NSString *KeyPunctMappedString(unichar character) {
    switch (character) {
        case 0xFF0C: return @",";   // ，
        // 。 and 、 keep their Chinese form: they are the sentence full stop
        // and the list separator, not a period or a comma.
        case 0xFF1F: return @"?";   // ？
        case 0xFF01: return @"!";   // ！
        case 0xFF1A: return @":";   // ：
        case 0xFF1B: return @";";   // ；
        case 0x201C: return @"\"";  // “
        case 0x201D: return @"\"";  // ”
        case 0x2018: return @"'";   // ‘
        case 0x2019: return @"'";   // ’
        case 0xFF08: return @"(";   // （
        case 0xFF09: return @")";   // ）
        case 0x3010: return @"[";   // 【
        case 0x3011: return @"]";   // 】
        case 0x300A: return @"<";   // 《
        case 0x300B: return @">";   // 》
        case 0x2026: return @"..."; // …
        case 0x2014: return @"--";  // —
        case 0xFF5E: return @"~";   // ～
        default: return nil;        // · and everything without an ASCII twin
    }
}

// Set while a candidate, dictation or autofill insertion is running, so their
// text never goes through the table even when it is a single punctuation mark.
static __thread NSInteger KeyPunctNonKeyDepth = 0;

static NSString *KeyPunctConvertedText(id text) {
    if (KeyPunctNonKeyDepth > 0 || ![text isKindOfClass:[NSString class]]) {
        return text;
    }
    NSString *string = (NSString *)text;
    NSUInteger length = string.length;
    if (length == 0 || length > 4) {
        return text;  // a word or a sentence: never a single punctuation key
    }
    NSMutableString *converted = [NSMutableString stringWithCapacity:length];
    for (NSUInteger index = 0; index < length; index++) {
        NSString *mapped = KeyPunctMappedString([string characterAtIndex:index]);
        if (mapped == nil) {
            return text;  // one character without an ASCII twin keeps the whole string
        }
        [converted appendString:mapped];
    }
    if (!KeyPunctEnabled() || !KeyPunctIsSimplifiedPinyin()) {
        return text;
    }
    return converted;
}

// MARK: - Diagnostics

static void KeyPunctTrace(const char *source, id text) {
    if (![text isKindOfClass:[NSString class]] || [(NSString *)text length] > 6) {
        return;
    }
    NSString *string = (NSString *)text;
    char codes[160] = "";
    for (NSUInteger index = 0; index < string.length; index++) {
        char piece[16];
        snprintf(piece, sizeof(piece), "%s%04X", index ? " " : "",
                 (unsigned int)[string characterAtIndex:index]);
        strlcat(codes, piece, sizeof(codes));
    }
    os_log(TweakLog(), "KeyPunctTry %{public}s len=%lu codes=%{public}s mode=%{public}@ on=%d",
           source, (unsigned long)string.length, codes,
           KeyPunctCurrentInputIdentifier(), KeyPunctEnabled() ? 1 : 0);
}

// MARK: - Conversion hooks

static void (*KeyPunctOriginalHandleKeyWithString)(id, SEL, id, id, id);

static void KeyPunctHandleKeyWithString(id self, SEL _cmd, id string, id event, id context) {
    KeyPunctTrace("handleKeyWithString", string);
    NSString *converted = KeyPunctConvertedText(string);
    if (converted != string) {
        os_log(TweakLog(), "KeyPunct key %{public}@ -> %{public}@", string, converted);
    }
    if (KeyPunctOriginalHandleKeyWithString != NULL) {
        KeyPunctOriginalHandleKeyWithString(self, _cmd, converted, event, context);
    }
}

static void (*KeyPunctOriginalInsertTextWithPredictions)(id, SEL, id, id);

static void KeyPunctInsertTextWithPredictions(id self, SEL _cmd, id text, id predictions) {
    KeyPunctTrace("insertText:withAlternativePredictions:", text);
    NSString *converted = KeyPunctConvertedText(text);
    if (converted != text) {
        os_log(TweakLog(), "KeyPunct insert %{public}@ -> %{public}@", text, converted);
    }
    if (KeyPunctOriginalInsertTextWithPredictions != NULL) {
        KeyPunctOriginalInsertTextWithPredictions(self, _cmd, converted, predictions);
    }
}

static BOOL (*KeyPunctOriginalInsertTextIfShould)(id, SEL, id);

static BOOL KeyPunctInsertTextIfShould(id self, SEL _cmd, id text) {
    KeyPunctTrace("insertTextIfShould:", text);
    NSString *converted = KeyPunctConvertedText(text);
    if (converted != text) {
        os_log(TweakLog(), "KeyPunct insertIfShould %{public}@ -> %{public}@", text, converted);
    }
    if (KeyPunctOriginalInsertTextIfShould != NULL) {
        return KeyPunctOriginalInsertTextIfShould(self, _cmd, converted);
    }
    return NO;
}

// The last stop before the text reaches the document. Chinese smart
// punctuation rewrites an inserted ASCII quote into “ or ”, so a character
// already converted earlier can be undone here; converting the output's
// insertion text again keeps it ASCII.

static void (*KeyPunctOriginalUpdateKeyboardOutput)(id, SEL, id, id, id);

static void KeyPunctUpdateKeyboardOutput(id self, SEL _cmd, id output, id input, id configuration) {
    if (KeyPunctOriginalUpdateKeyboardOutput != NULL) {
        KeyPunctOriginalUpdateKeyboardOutput(self, _cmd, output, input, configuration);
    }
    if (output == nil) {
        return;
    }
    id insertion = nil;
    @try {
        insertion = [output valueForKey:@"insertionText"];
    } @catch (__unused NSException *exception) {
        return;
    }
    KeyPunctTrace("keyboardOutput", insertion);
    NSString *converted = KeyPunctConvertedText(insertion);
    if (converted != insertion) {
        @try {
            [output setValue:converted forKey:@"insertionText"];
            os_log(TweakLog(), "KeyPunct output %{public}@ -> %{public}@", insertion, converted);
        } @catch (__unused NSException *exception) {
        }
    }
}

// MARK: - Everything that is not a key press

static void (*KeyPunctOriginalAcceptCandidate)(id, SEL, id);

static void KeyPunctAcceptCandidate(id self, SEL _cmd, id candidate) {
    KeyPunctNonKeyDepth++;
    if (KeyPunctOriginalAcceptCandidate != NULL) {
        KeyPunctOriginalAcceptCandidate(self, _cmd, candidate);
    }
    KeyPunctNonKeyDepth--;
}

static void (*KeyPunctOriginalAcceptCandidateForInput)(id, SEL, id, id);

static void KeyPunctAcceptCandidateForInput(id self, SEL _cmd, id candidate, id input) {
    KeyPunctNonKeyDepth++;
    if (KeyPunctOriginalAcceptCandidateForInput != NULL) {
        KeyPunctOriginalAcceptCandidateForInput(self, _cmd, candidate, input);
    }
    KeyPunctNonKeyDepth--;
}

static id (*KeyPunctOriginalAcceptCurrentCandidate)(id, SEL);

static id KeyPunctAcceptCurrentCandidate(id self, SEL _cmd) {
    KeyPunctNonKeyDepth++;
    id result = (KeyPunctOriginalAcceptCurrentCandidate != NULL)
                    ? KeyPunctOriginalAcceptCurrentCandidate(self, _cmd)
                    : nil;
    KeyPunctNonKeyDepth--;
    return result;
}

static void (*KeyPunctOriginalAcceptFirstCandidate)(id, SEL);

static void KeyPunctAcceptFirstCandidate(id self, SEL _cmd) {
    KeyPunctNonKeyDepth++;
    if (KeyPunctOriginalAcceptFirstCandidate != NULL) {
        KeyPunctOriginalAcceptFirstCandidate(self, _cmd);
    }
    KeyPunctNonKeyDepth--;
}

static void (*KeyPunctOriginalAcceptAutocorrection)(id, SEL);

static void KeyPunctAcceptAutocorrection(id self, SEL _cmd) {
    KeyPunctNonKeyDepth++;
    if (KeyPunctOriginalAcceptAutocorrection != NULL) {
        KeyPunctOriginalAcceptAutocorrection(self, _cmd);
    }
    KeyPunctNonKeyDepth--;
}

static void (*KeyPunctOriginalCandidateListAcceptCandidate)(id, SEL, id);

static void KeyPunctCandidateListAcceptCandidate(id self, SEL _cmd, id candidate) {
    KeyPunctNonKeyDepth++;
    if (KeyPunctOriginalCandidateListAcceptCandidate != NULL) {
        KeyPunctOriginalCandidateListAcceptCandidate(self, _cmd, candidate);
    }
    KeyPunctNonKeyDepth--;
}

static void (*KeyPunctOriginalHandleAcceptedCandidate)(id, SEL, id, id);

static void KeyPunctHandleAcceptedCandidate(id self, SEL _cmd, id candidate, id context) {
    KeyPunctNonKeyDepth++;
    if (KeyPunctOriginalHandleAcceptedCandidate != NULL) {
        KeyPunctOriginalHandleAcceptedCandidate(self, _cmd, candidate, context);
    }
    KeyPunctNonKeyDepth--;
}

static void (*KeyPunctOriginalInsertDictationResult)(id, SEL, id);

static void KeyPunctInsertDictationResult(id self, SEL _cmd, id result) {
    KeyPunctNonKeyDepth++;
    if (KeyPunctOriginalInsertDictationResult != NULL) {
        KeyPunctOriginalInsertDictationResult(self, _cmd, result);
    }
    KeyPunctNonKeyDepth--;
}

// MARK: - Installation

static BOOL KeyPunctInstallHook(Class cls, const char *selectorName, const char *expectedTypes,
                                IMP replacement, IMP *original, const char *label) {
    SEL selector = sel_registerName(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        os_log(TweakLog(), "KeyPunctInstall %{public}s: missing on this firmware", label);
        return NO;
    }
    const char *types = method_getTypeEncoding(method);
    if (strcmp(types, expectedTypes) != 0) {
        os_log(TweakLog(), "KeyPunctInstall %{public}s: encoding %{public}s != %{public}s, skipped",
               label, types, expectedTypes);
        return NO;
    }
    MSHookMessageEx(cls, selector, replacement, original);
    os_log(TweakLog(), "KeyPunctInstall %{public}s: hooked", label);
    return YES;
}

__attribute__((constructor)) static void TweakInitialize(void) {
    // Apelin's confirm_loaded looks for this exact marker and build id under
    // the package id's subsystem. Keep the line, and keep it public.
    os_log(TweakLog(), "ApelinLoaded %{public}s in %{public}s", APELIN_BUILD_ID, getprogname());

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    KeyPunctPreferencesChanged,
                                    (__bridge CFStringRef)KeyPunctChangedNotification,
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    Class keyboard = objc_getClass("UIKeyboardImpl");
    if (keyboard == Nil) {
        return;  // not a process that has the keyboard
    }

    KeyPunctInstallHook(keyboard, "handleKeyWithString:forKeyEvent:executionContext:",
                        "v40@0:8@16@24@32",
                        (IMP)KeyPunctHandleKeyWithString,
                        (IMP *)&KeyPunctOriginalHandleKeyWithString,
                        "handleKeyWithString:forKeyEvent:executionContext:");

    KeyPunctInstallHook(keyboard, "insertText:withAlternativePredictions:",
                        "v32@0:8@16@24",
                        (IMP)KeyPunctInsertTextWithPredictions,
                        (IMP *)&KeyPunctOriginalInsertTextWithPredictions,
                        "insertText:withAlternativePredictions:");

    KeyPunctInstallHook(keyboard, "insertTextIfShould:",
                        "B24@0:8@16",
                        (IMP)KeyPunctInsertTextIfShould,
                        (IMP *)&KeyPunctOriginalInsertTextIfShould,
                        "insertTextIfShould:");

    KeyPunctInstallHook(keyboard, "updateKeyboardOutput:withInputForSmartPunctuation:keyboardConfiguration:",
                        "v40@0:8@16@24@32",
                        (IMP)KeyPunctUpdateKeyboardOutput,
                        (IMP *)&KeyPunctOriginalUpdateKeyboardOutput,
                        "updateKeyboardOutput:withInputForSmartPunctuation:keyboardConfiguration:");

    KeyPunctInstallHook(keyboard, "acceptCandidate:", "v24@0:8@16",
                        (IMP)KeyPunctAcceptCandidate,
                        (IMP *)&KeyPunctOriginalAcceptCandidate, "acceptCandidate:");

    KeyPunctInstallHook(keyboard, "acceptCandidate:forInput:", "v32@0:8@16@24",
                        (IMP)KeyPunctAcceptCandidateForInput,
                        (IMP *)&KeyPunctOriginalAcceptCandidateForInput, "acceptCandidate:forInput:");

    KeyPunctInstallHook(keyboard, "acceptCurrentCandidate", "@16@0:8",
                        (IMP)KeyPunctAcceptCurrentCandidate,
                        (IMP *)&KeyPunctOriginalAcceptCurrentCandidate, "acceptCurrentCandidate");

    KeyPunctInstallHook(keyboard, "acceptFirstCandidate", "v16@0:8",
                        (IMP)KeyPunctAcceptFirstCandidate,
                        (IMP *)&KeyPunctOriginalAcceptFirstCandidate, "acceptFirstCandidate");

    KeyPunctInstallHook(keyboard, "acceptAutocorrection", "v16@0:8",
                        (IMP)KeyPunctAcceptAutocorrection,
                        (IMP *)&KeyPunctOriginalAcceptAutocorrection, "acceptAutocorrection");

    KeyPunctInstallHook(keyboard, "candidateListAcceptCandidate:", "v24@0:8@16",
                        (IMP)KeyPunctCandidateListAcceptCandidate,
                        (IMP *)&KeyPunctOriginalCandidateListAcceptCandidate,
                        "candidateListAcceptCandidate:");

    KeyPunctInstallHook(keyboard, "handleAcceptedCandidate:executionContext:", "v32@0:8@16@24",
                        (IMP)KeyPunctHandleAcceptedCandidate,
                        (IMP *)&KeyPunctOriginalHandleAcceptedCandidate,
                        "handleAcceptedCandidate:executionContext:");

    KeyPunctInstallHook(keyboard, "insertDictationResult:", "v24@0:8@16",
                        (IMP)KeyPunctInsertDictationResult,
                        (IMP *)&KeyPunctOriginalInsertDictationResult, "insertDictationResult:");
}
