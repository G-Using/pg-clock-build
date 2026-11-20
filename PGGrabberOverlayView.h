#import <UIKit/UIKit.h>

@interface PGGrabberOverlayView : UIView
- (void)startUpdating;
- (void)stopUpdating;
- (void)refreshAppearance;
/// 按当前内容与字号算出贴合文字的尺寸，供横屏常驻块这类需要自适应宽度的宿主使用。
- (CGSize)preferredContentSizeForMaxWidth:(CGFloat)maxWidth;
@end

