#import "Hook.h"
#import "SimpleDebugger.h"
#include <mach/mach_time.h>

SimpleDebugger *debugger = new SimpleDebugger();

static inline uint64_t nowTicks() {
  return mach_continuous_time();
}

static inline double ticksToNanos(uint64_t dt) {
  static mach_timebase_info_data_t tb = []{
    mach_timebase_info_data_t t{};
    mach_timebase_info(&t);
    return t;
  }();
  return (double)dt * (double)tb.numer / (double)tb.denom;
}

void (^gCallback)(NSString *, double) = NULL;

NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *returnToStarts = [NSMutableDictionary new];
NSMutableDictionary<NSNumber *, NSString*> *startsToName = [NSMutableDictionary new];
NSMutableDictionary<NSNumber *, NSString*> *returnsToName = [NSMutableDictionary new];

void breakpointCallback(mach_port_t thread, arm_thread_state64_t state, std::function<void(bool)> sendReply) {
  NSString *name = startsToName[@(state.__pc)];
  uint64_t startTime = nowTicks();
  if (name != nil) {
    // Entering body
    uint64_t lr = state.__lr;
    NSMutableArray<NSNumber *> *starts = returnToStarts[@(lr)];
    if (starts != nil) {
      [starts addObject:@(startTime)];
    } else {
      NSMutableArray *starts = [NSMutableArray new];
      [starts addObject:@(startTime)];
      returnToStarts[@(lr)] = starts;
    }
    debugger->setBreakpoint(lr);
    returnsToName[@(lr)] = name;
  }
    else {
    // Leaving body
    NSMutableArray<NSNumber *> *starts = returnToStarts[@(state.__pc)];
    if (starts.count > 0) {
      NSNumber *lastStart = [starts lastObject];
      [starts removeLastObject];
      double duration = ticksToNanos(nowTicks() - lastStart.longLongValue);
      NSString *name = returnsToName[@(state.__pc)];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (gCallback) {
          gCallback(name, duration/1000000.0);
        }
      });
    }
  }
  sendReply(false);
}

@implementation Hook

- (instancetype)initWithCallback:(void (^)(NSString *, double))callback {
  if (self = [super init]) {
    gCallback = callback;
    debugger->setExceptionCallback(breakpointCallback);
    debugger->startDebugging();
    return self;
  }
  return nil;
}

- (void)addHook:(uint64_t)address named:(NSString*)name {
  startsToName[@(address)] = name;
  debugger->setBreakpoint(address);
}

@end
