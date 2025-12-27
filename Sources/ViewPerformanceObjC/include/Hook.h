#import "Foundation/Foundation.h"

NS_ASSUME_NONNULL_BEGIN

@interface Hook: NSObject

- (instancetype)initWithCallback:(void (^)(NSString *, double))callback;

- (void)addHook:(uint64_t)address named:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
