// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// The Settings pane KeyPunct shows through PreferenceLoader. The rows come from
// Root.plist; PSListController reads and writes the values in the
// com.wm0104.keypunct.preferences domain and posts com.wm0104.keypunct/changed,
// which the tweak listens for.

#import <Preferences/PSListController.h>

@interface KeyPunctPrefsRootListController : PSListController
@end

@implementation KeyPunctPrefsRootListController

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end
