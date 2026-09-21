#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface AeonDSPAudioUnit : AUAudioUnit
+ (AVAudioUnitEffect *)makeNode;
- (BOOL)submitParameters:(NSData *)parameters;
@property(nonatomic, readonly) uint64_t overloadCount;
@end
NS_ASSUME_NONNULL_END
