#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AVFoundation reports some hardware problems as Objective-C exceptions, which Swift cannot catch.
@interface ObjCTry : NSObject
+ (BOOL)perform:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
