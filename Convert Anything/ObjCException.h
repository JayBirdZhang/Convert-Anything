#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised as an NSError, or nil if it raised none.
/// Swift can't catch exceptions, and a few Apple APIs raise them instead of returning errors.
NSError * _Nullable CACatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
