/*
 * MPlayerX - RootLayerView.m
 *
 * Copyright (C) 2009 Zongyao QU
 * 
 * MPlayerX is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 * 
 * MPlayerX is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with MPlayerX; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

#import <Quartz/Quartz.h>
#import "UserDefaults.h"
#import "KeyCode.h"
#import "RootLayerView.h"
#import "DisplayLayer.h"
#import "ControlUIView.h"
#import "PlayerController.h"
#import "ShortCutManager.h"
#import "VideoTunerController.h"
#import "TitleView.h"
#import "AppController.h"
#import "GTMStringEncoding.h"
#import "StoreHandler.h"

#define kOnTopModeNormal		(0)
#define kOnTopModeAlways		(1)
#define kOnTopModePlaying		(2)

#define kSnapshotSaveDefaultPath	(@"~/Pictures/SPlayerX")


@interface RootLayerView (RootLayerViewInternal)
-(NSSize) calculateContentSize:(NSSize)refSize;
-(NSPoint) calculatePlayerWindowPosition:(NSSize)winSize;
-(void) adjustWindowSizeAndAspectRatio:(NSSize) sizeVal;
-(void) setupLayers;
-(void) reorderSubviews;
-(void) prepareForStartingDisplay;

-(void) playBackStopped:(NSNotification*)notif;
-(void) playBackStarted:(NSNotification*)notif;
-(void) playBackOpened:(NSNotification*)notif;
-(void) applicationDidBecomeActive:(NSNotification*)notif;
-(void) applicationDidResignActive:(NSNotification*)notif;
@end

@interface RootLayerView (CoreDisplayDelegate)
-(int)  coreController:(id)sender startWithFormat:(DisplayFormat)df buffer:(char**)data total:(NSUInteger)num;
-(void) coreController:(id)sender draw:(NSUInteger)frameNum;
-(void) coreControllerStop:(id)sender;
@end

@implementation RootLayerView

@synthesize fullScrnDevID;
@synthesize lockAspectRatio;

+(void) initialize
{
	NSNumber *boolYes = [NSNumber numberWithBool:YES];
	NSNumber *boolNo  = [NSNumber numberWithBool:NO];
	
	[[NSUserDefaults standardUserDefaults] 
	 registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
					   [NSNumber numberWithInt:kOnTopModePlaying], kUDKeyOnTopMode,
					   kSnapshotSaveDefaultPath, kUDKeySnapshotSavePath,
					   boolNo, kUDKeyStartByFullScreen,
					   boolYes, kUDKeyFullScreenKeepOther,
					   boolYes, kUDKeyQuitOnClose,
					   boolNo, kUDKeyPinPMode,
					   boolNo, kUDKeyAlwaysHideDockInFullScrn,
					   nil]];
}

#pragma mark Init/Dealloc
-(id) initWithCoder:(NSCoder *)aDecoder
{
	self = [super initWithCoder:aDecoder];
	
	if (self) {
		ud = [NSUserDefaults standardUserDefaults];
		notifCenter = [NSNotificationCenter defaultCenter];
		
		trackingArea = [[NSTrackingArea alloc] initWithRect:NSInsetRect([self frame], 1, 1) 
													options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect | NSTrackingAssumeInside
													  owner:self
												   userInfo:nil];
		[self addTrackingArea:trackingArea];
		shouldResize = NO;
		dispLayer = [[DisplayLayer alloc] init];
		displaying = NO;
		fullScreenOptions = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
							 [NSNumber numberWithInt:NSApplicationPresentationAutoHideDock | NSApplicationPresentationAutoHideMenuBar], NSFullScreenModeApplicationPresentationOptions,
							 [NSNumber numberWithBool:![ud boolForKey:kUDKeyFullScreenKeepOther]], NSFullScreenModeAllScreens,
							 [NSNumber numberWithInt:NSTornOffMenuWindowLevel], NSFullScreenModeWindowLevel,
							 nil];
		lockAspectRatio = YES;
		dragShouldResize = NO;
		firstDisplay = YES;
	}
	return self;
}

-(void) dealloc
{
	[notifCenter removeObserver:self];
	
	[self removeTrackingArea:trackingArea];
	[trackingArea release];
	[fullScreenOptions release];
	[dispLayer release];
	[logo release];
	
	[super dealloc];
}

-(void) setupLayers
{
	// 设定LayerHost，现在只Host一个Layer
	[self setWantsLayer:YES];
	
	// 得到基本的rootLayer
	CALayer *root = [self layer];
	
	// 禁用修改尺寸的action
	[root setDelegate:self];
	[root setDoubleSided:NO];

	// 背景颜色
	CGColorRef col =  CGColorCreateGenericGray(0.0, 1.0);
	[root setBackgroundColor:col];
	CGColorRelease(col);
  	
	col = CGColorCreateGenericRGB(0.392, 0.643, 0.812, 0.75);
	[root setBorderColor:col];
	CGColorRelease(col);
	
	// 自动尺寸适应
	[root setAutoresizingMask:kCALayerWidthSizable|kCALayerHeightSizable];
	
	NSBundle *mainB = [NSBundle mainBundle];
	logo = [[NSBitmapImageRep alloc] initWithCIImage:
			[CIImage imageWithContentsOfURL:
			 [[mainB resourceURL] URLByAppendingPathComponent:@"logo.png"]]];
  
	[root setContentsGravity:kCAGravityCenter];
	[root setContents:(id)[logo CGImage]];
	
	// 默认添加dispLayer
	[root insertSublayer:dispLayer atIndex:0];
	
	// 通知DispLayer
	[dispLayer setBounds:[root bounds]];
	[dispLayer setPosition:CGPointMake(root.bounds.size.width/2, root.bounds.size.height/2)];
}
-(id<CAAction>) actionForLayer:(CALayer*)layer forKey:(NSString*)event
{ return ((id<CAAction>)[NSNull null]); }

-(void) reorderSubviews
{
	// 将ControlUI放在最上层以防止被覆盖
	[controlUI retain];
	[controlUI removeFromSuperviewWithoutNeedingDisplay];
	[self addSubview:controlUI positioned:NSWindowAbove	relativeTo:nil];
	[controlUI release];
	
	[titlebar retain];
	[titlebar removeFromSuperviewWithoutNeedingDisplay];
	[self addSubview:titlebar positioned:NSWindowAbove relativeTo:nil];
	[titlebar release];
}

-(void) awakeFromNib
{

	[self setupLayers];
	
	[self reorderSubviews];
	
	// 通知dispView接受mplayer的渲染通知
	[playerController setDisplayDelegateForMPlayer:self];
	
	// 默认的全屏的DisplayID
	fullScrnDevID = [[[[playerWindow screen] deviceDescription] objectForKey:@"NSScreenNumber"] unsignedIntValue];
	
	// 设定可以接受Drag Files
	[self registerForDraggedTypes:[NSArray arrayWithObjects:NSFilenamesPboardType,nil]];
    if ([self respondsToSelector: @selector(setLayerUsesCoreImageFilters:)]) {
        [self setLayerUsesCoreImageFilters:TRUE];
    }
    
	[VTController setLayer:dispLayer];
	
	[notifCenter addObserver:self selector:@selector(playBackOpened:)
						name:kMPCPlayOpenedNotification object:playerController];
	[notifCenter addObserver:self selector:@selector(playBackStarted:)
						name:kMPCPlayStartedNotification object:playerController];
	[notifCenter addObserver:self selector:@selector(playBackStopped:)
						name:kMPCPlayStoppedNotification object:playerController];
	[notifCenter addObserver:self selector:@selector(applicationDidBecomeActive:)
						name:NSApplicationDidBecomeActiveNotification object:NSApp];
	[notifCenter addObserver:self selector:@selector(applicationDidResignActive:)
						name:NSApplicationDidResignActiveNotification object:NSApp];

  
	// show player window when start up
	[self setPlayerWindowLevel];
	
	[playerWindow setContentSize:[playerWindow contentMinSize]];
	[playerWindow makeKeyAndOrderFront:nil];
  
}

-(void) closePlayerWindow
{
	[playerWindow close];
	// [playerWindow orderOut:self];
}

-(void) playBackStopped:(NSNotification*)notif
{
	firstDisplay = YES;
	[self setPlayerWindowLevel];
	[playerWindow setTitle:kMPCStringMPlayerX];

  [centerProgress stopAnimation:self];
  [centerProgress setHidden:YES];
}

-(void) playBackStarted:(NSNotification*)notif
{
	[self setPlayerWindowLevel];

	if ([[[notif userInfo] objectForKey:kMPCPlayStartedAudioOnlyKey] boolValue]) {
		[playerWindow setContentSize:[playerWindow contentMinSize]];
		[playerWindow makeKeyAndOrderFront:nil];
	}
  [centerProgress stopAnimation:self];
  [centerProgress setHidden:YES];
}

-(void) playBackOpened:(NSNotification*)notif
{
  [[self layer] setContents:nil];
  [centerProgress setHidden:NO];
  [centerProgress startAnimation:self];
  
	NSURL *url = [[notif userInfo] objectForKey:kMPCPlayOpenedURLKey];
	if (url) {		
		if ([url isFileURL]) {
			[playerWindow setTitle:[[url path] lastPathComponent]];
		} else {
			[playerWindow setTitle:[[url absoluteString] lastPathComponent]];
		}
	} else {
		[playerWindow setTitle:kMPCStringMPlayerX];
	}
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event 
{ return YES; }
-(BOOL) acceptsFirstResponder
{ return YES; }

-(void) mouseMoved:(NSEvent *)theEvent
{
	if (NSPointInRect([self convertPoint:[theEvent locationInWindow] fromView:nil], self.bounds)) {
		[controlUI showUp];
		[controlUI updateHintTime];
	}
  [super mouseMoved:theEvent];
}

-(void)mouseDown:(NSEvent *)theEvent
{
	dragMousePos = [NSEvent mouseLocation];
	NSRect winRC = [playerWindow frame];
	
	dragShouldResize = ((NSMaxX(winRC) - dragMousePos.x < 16) && (dragMousePos.y - NSMinY(winRC) < 16))?YES:NO;
	
	// MPLog(@"mouseDown");
}

- (void)mouseDragged:(NSEvent *)event
{
	switch ([event modifierFlags] & (NSShiftKeyMask| NSControlKeyMask|NSAlternateKeyMask|NSCommandKeyMask)) {
		case kSCMDragSubPosModifierFlagMask:
			// 改变Sub Position
			// 目前在ass enable的情况下不能工作
			[controlUI changeSubPosBy:[NSNumber numberWithFloat:([event deltaY] * 2) / self.bounds.size.height]];
			break;
		case kSCMDragAudioBalanceModifierFlagMask:
			// 这个也基本不能工作
			[controlUI changeAudioBalanceBy:[NSNumber numberWithFloat:([event deltaX] * 2) / self.bounds.size.width]];
			break;
		case 0:
			if (![self isInFullScreenMode]) {
				// 全屏的时候不能移动屏幕
				NSPoint posNow = [NSEvent mouseLocation];
				NSPoint delta;
				delta.x = (posNow.x - dragMousePos.x);
				delta.y = (posNow.y - dragMousePos.y);
				dragMousePos = posNow;
				
				if (dragShouldResize) {
					NSRect winRC = [playerWindow frame];
					NSRect newFrame = NSMakeRect(winRC.origin.x,
												 posNow.y, 
												 posNow.x-winRC.origin.x,
												 winRC.size.height + winRC.origin.y - posNow.y);
					
					winRC.size = [playerWindow contentRectForFrameRect:newFrame].size;
					
					if (displaying && lockAspectRatio) {
						// there is video displaying
						winRC.size = [self calculateContentSize:winRC.size];
					} else {
						NSSize minSize = [playerWindow contentMinSize];
						
						winRC.size.width = MAX(winRC.size.width, minSize.width);
						winRC.size.height= MAX(winRC.size.height, minSize.height);
					}

					winRC.origin.y -= (winRC.size.height - [[playerWindow contentView] bounds].size.height);
					
					[playerWindow setFrame:[playerWindow frameRectForContentRect:winRC] display:YES];
					// MPLog(@"should resize");
				} else {
					NSPoint winPos = [playerWindow frame].origin;
					winPos.x += delta.x;
					winPos.y += delta.y;
					[playerWindow setFrameOrigin:winPos];
					// MPLog(@"should move");
				}
			}
			break;
		default:
			break;
	}
}

-(void) mouseUp:(NSEvent *)theEvent
{
	if ([theEvent clickCount] == 2) {
		switch ([theEvent modifierFlags] & (NSShiftKeyMask| NSControlKeyMask|NSAlternateKeyMask|NSCommandKeyMask)) {
			case kSCMDragAudioBalanceModifierFlagMask:
				[controlUI changeAudioBalanceBy:nil];
				break;
			case 0:
				[controlUI performKeyEquivalent:[NSEvent keyEventWithType:NSKeyDown location:NSMakePoint(0, 0) modifierFlags:0 timestamp:0
															 windowNumber:0 context:nil
															   characters:kSCMFullScrnKeyEquivalent
											  charactersIgnoringModifiers:kSCMFullScrnKeyEquivalent
																isARepeat:NO keyCode:0]];
				break;
			default:
				break;
		}
		// proper way to do so is add a button and hide the button when playing
		if ([playerController playerState] == kMPCStoppedState) 
			[[AppController sharedAppController] openFile:self];
		
	}
	

	// do not use the playerWindow, since when fullscreen the window holds self is not playerWindow
	[[self window] makeFirstResponder:self];
	// MPLog(@"mouseUp");
}

-(void) mouseEntered:(NSEvent *)theEvent
{
	[controlUI showUp];
}

-(void) mouseExited:(NSEvent *)theEvent
{
	if (![self isInFullScreenMode]) {
		// 全屏模式下，不那么积极的
		[controlUI doHide];
	}
}

-(void) keyDown:(NSEvent *)theEvent
{
	if (![shortCutManager processKeyDown:theEvent]) {
		// 如果shortcut manager不处理这个evetn的话，那么就按照默认的流程
		[super keyDown:theEvent];
	}
}

-(void) cancelOperation:(id)sender
{
	if ([self isInFullScreenMode]) {
		// when pressing Escape, exit fullscreen if being fullscreen
        [controlUI performKeyEquivalent:[NSEvent keyEventWithType:NSKeyDown location:NSMakePoint(0, 0) modifierFlags:0 timestamp:0
                                                     windowNumber:0 context:nil
                                                       characters:kSCMFullScrnKeyEquivalent
                                      charactersIgnoringModifiers:kSCMFullScrnKeyEquivalent
                                                        isARepeat:NO keyCode:0]];
	}
}

-(void)scrollWheel:(NSEvent *)theEvent
{
	float x, y;
	x = [theEvent deltaX];
	y = [theEvent deltaY];
	
	if (abs(x) > abs(y*2)) {
		// MPLog(@"%f", x);
		switch ([playerController playerState]) {
			case kMPCPausedState:
				if (x < 0) {
					[playerController frameStep];
				}
				break;
			case kMPCPlayingState:
				[controlUI changeTimeBy:-x];
				break;
			default:
				break;
		}
	} else if (abs(x*2) < abs(y)) {
		[controlUI changeVolumeBy:[NSNumber numberWithFloat:y*0.2]];
	}
}

-(void) setLockAspectRatio:(BOOL) lock
{
	if (lock != lockAspectRatio) {
		lockAspectRatio = lock;
		
		if (lockAspectRatio) {
			// 如果锁定 aspect ratio的话，那么就按照现在的window的
			NSSize sz = [self bounds].size;
			
			[playerWindow setContentAspectRatio:sz];
			[dispLayer setExternalAspectRatio:(sz.width/sz.height)];
		} else {
			[playerWindow setContentResizeIncrements:NSMakeSize(1.0, 1.0)];
		}
	}
}

-(void) resetAspectRatio
{
	// 如果是全屏，playerWindow是否还拥有rootLayerView不知道
	// 但是全屏的时候并不会立即调整窗口的大小，而是会等推出全屏的时候再调整
	// 如果不是全屏，那么根据现在的size得到最合适的size
	[self adjustWindowSizeAndAspectRatio:[[playerWindow contentView] bounds].size];
}


-(NSSize) calculateContentSize:(NSSize)refSize
{
	NSSize dispSize = [dispLayer displaySize];
	CGFloat aspectRatio = [dispLayer aspectRatio];
	
	NSSize screenContentSize = [playerWindow contentRectForFrameRect:[[playerWindow screen] visibleFrame]].size;
	NSSize minSize = [playerWindow contentMinSize];
	
	if ((refSize.width < 0) || (refSize.height < 0)) {
		// 非法尺寸
		if (aspectRatio <= 0) {
			// 没有在播放
			refSize = [[playerWindow contentView] bounds].size;
		} else {
			// 在播放就用影片尺寸
			refSize.height = dispSize.height;
			refSize.width = refSize.height * aspectRatio;
		}
	}
	
	refSize.width  = MAX(minSize.width, MIN(screenContentSize.width, refSize.width));
	refSize.height = MAX(minSize.height, MIN(screenContentSize.height, refSize.height));
	
	if (aspectRatio > 0) {
		if (refSize.width > (refSize.height * aspectRatio)) {
			// 现在的movie是竖图
			refSize.width = refSize.height*aspectRatio;
		} else {
			// 现在的movie是横图
			refSize.height = refSize.width/aspectRatio;
		}
	}
	return refSize;
}

-(void) magnifyWithEvent:(NSEvent *)event
{
	[self changeWindowSizeBy:NSMakeSize([event magnification], [event magnification]) animate:NO];
}

-(void) swipeWithEvent:(NSEvent *)event
{
	CGFloat x = [event deltaX];
	CGFloat y = [event deltaY];
	unichar key;
	
	if (x < 10) {
		key = NSLeftArrowFunctionKey;
	} else if (x > 10) {
		key = NSRightArrowFunctionKey;
	} else if (y > 0) {
		key = NSUpArrowFunctionKey;
	} else if (y < 0) {
		key = NSDownArrowFunctionKey;
	} else {
		key = 0;
	}

	if (key) {
		[shortCutManager processKeyDown:[NSEvent keyEventWithType:NSKeyDown location:NSMakePoint(0, 0) modifierFlags:0 timestamp:0
													 windowNumber:0 context:nil
													   characters:nil
									  charactersIgnoringModifiers:[NSString stringWithCharacters:&key length:1]
														isARepeat:NO keyCode:0]];
	}
}

-(IBAction) writeSnapshotToFile:(id)sender
{
	if (displaying)
	{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		// 得到图像数据
		CIImage *snapshot = [dispLayer snapshot];
		
		if (snapshot != nil) {
			// 得到图像的Rep
			NSBitmapImageRep *imRep = [[NSBitmapImageRep alloc] initWithCIImage:snapshot];
			// 设定这个Rep的存储方式
			NSData *imData = [NSBitmapImageRep representationOfImageRepsInArray:[NSArray arrayWithObject:imRep]
																	  usingType:NSPNGFileType
																	 properties:nil];
			// 得到存储文件夹
			NSString *savePath = [ud stringForKey:kUDKeySnapshotSavePath];
      

			// 如果是默认路径，那么就更换为绝对地址
			if ([savePath isEqualToString:kSnapshotSaveDefaultPath]) {
				savePath = [savePath stringByExpandingTildeInPath];
			}
          
      NSString *mediaPath = ([playerController.lastPlayedPath isFileURL])?([playerController.lastPlayedPath path]):([playerController.lastPlayedPath absoluteString]);
      
			BOOL isDir = false;
      if (![[NSFileManager defaultManager] fileExistsAtPath:savePath isDirectory:&isDir] || !isDir)
        [[NSFileManager defaultManager] createDirectoryAtPath:savePath withIntermediateDirectories:YES attributes:nil error:NULL];

      // 创建文件名
			// 修改文件名中的：，因为：无法作为文件名存储
			NSString* saveFilePath = [NSString stringWithFormat:@"%@/%@_%@.png",
						savePath, 
						[[mediaPath lastPathComponent] stringByDeletingPathExtension],
						[[NSDateFormatter localizedStringFromDate:[NSDate date]
														dateStyle:NSDateFormatterMediumStyle
														timeStyle:NSDateFormatterMediumStyle] 
						 stringByReplacingOccurrencesOfString:@":" withString:@"."]];							   
			// 写文件
			[imData writeToFile:saveFilePath atomically:YES];
			[imRep release];
      
      [[NSSound soundNamed:@"Purr"] play];
      
      [[NSWorkspace sharedWorkspace] selectFile:saveFilePath inFileViewerRootedAtPath:savePath];
		}
		[pool drain];
	}
}
-(NSString*) snapshotToBase64String
{
  NSString *base64String = nil;
  if (displaying)
	{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		// 得到图像数据
		CIImage *snapshot = [dispLayer snapshot];
		
		if (snapshot != nil) {
			// 得到图像的Rep
			NSBitmapImageRep *imRep = [[[NSBitmapImageRep alloc] initWithCIImage:snapshot] autorelease];
      NSData *imData = [imRep representationUsingType:NSJPEGFileType properties:nil];
      
      base64String = [[[[GTMStringEncoding rfc4648Base64StringEncoding] encode:imData] copy] autorelease];
		}
		[pool drain];
	}
  return base64String;
}

-(NSImage*) snapshot
{
    CIImage *snapshot = [dispLayer snapshot];
    
    if (snapshot != nil) {
        NSCIImageRep *rep = [NSCIImageRep imageRepWithCIImage:snapshot];
        NSImage *nsImage = [[NSImage alloc] initWithSize:rep.size];
        [nsImage addRepresentation:rep];
        return [nsImage autorelease];
    }
    
    return nil;
}

-(void) changeWindowSizeBy:(NSSize)delta animate:(BOOL)animate
{
	if (![self isInFullScreenMode]) {
		// only works in non-fullscreen mode
		NSSize sz;
		
		sz = [[playerWindow contentView] bounds].size;

		sz.width  += delta.width  * sz.width;
		sz.height += delta.height * sz.height;
		
		sz = [self calculateContentSize:sz];
		
		NSPoint pos = [self calculatePlayerWindowPosition:sz];
		
		NSRect rc = NSMakeRect(pos.x, pos.y, sz.width, sz.height);
		rc = [playerWindow frameRectForContentRect:rc];

		[playerWindow setFrame:rc display:YES animate:animate];		
	}
}

-(BOOL) toggleFullScreen
{
    // ！注意：这里的显示状态和mplayer的播放状态时不一样的，比如，mplayer在MP3的时候，播放状态为YES，显示状态为NO
	if ([self isInFullScreenMode]) {
		// 无论否在显示都可以退出全屏

		[self exitFullScreenModeWithOptions:fullScreenOptions];
		
		// 必须砸退出全屏的时候再设定
		// 在退出全屏之前，这个view并不属于window，设定contentsize不起作用
		if (shouldResize) {
			shouldResize = NO;
			NSSize sz = [self calculateContentSize:[[playerWindow contentView] bounds].size];
			
			NSPoint pos = [self calculatePlayerWindowPosition:sz];
			
			NSRect rc = NSMakeRect(pos.x, pos.y, sz.width, sz.height);
			rc = [playerWindow frameRectForContentRect:rc];

			[playerWindow setFrame:rc display:YES];
			[playerWindow setContentAspectRatio:sz];			
		}

		[playerWindow makeKeyAndOrderFront:self];
		[playerWindow makeFirstResponder:self];
		
		// 必须要在退出全屏之后才能设定window level
		[self setPlayerWindowLevel];
        
        
	} else if (displaying) {
		// 应该进入全屏
		// 只有在显示图像的时候才能进入全屏
		
		// 强制Lock Aspect Ratio
		[self setLockAspectRatio:YES];

		BOOL keepOtherSrn = [ud boolForKey:kUDKeyFullScreenKeepOther];
		// 得到window目前所在的screen
		NSScreen *chosenScreen = [playerWindow screen];
		// Presentation Options
		NSApplicationPresentationOptions opts;
		
		if (chosenScreen == [[NSScreen screens] objectAtIndex:0] || (!keepOtherSrn)) {
			// if the main screen
			// there is no reason to always hide Dock, when MPX displayed in the secondary screen
			// so only do it in main screen
			if ([ud boolForKey:kUDKeyAlwaysHideDockInFullScrn]) {
				opts = NSApplicationPresentationHideDock | NSApplicationPresentationAutoHideMenuBar;
			} else {
				opts = NSApplicationPresentationAutoHideDock | NSApplicationPresentationAutoHideMenuBar;
			}
		} else {
			// in secondary screens
            opts = [NSApp presentationOptions] | NSApplicationPresentationAutoHideMenuBar | NSApplicationPresentationAutoHideDock;
        }

		[fullScreenOptions setObject:[NSNumber numberWithInt:opts]
							  forKey:NSFullScreenModeApplicationPresentationOptions];
		// whether grab all the screens
		[fullScreenOptions setObject:[NSNumber numberWithBool:!keepOtherSrn]
							  forKey:NSFullScreenModeAllScreens];
        
        // clear filters or it will bug under 10.9
        NSArray* cifilters = [[dispLayer.filters copy] autorelease];
        if ([self respondsToSelector: @selector(setLayerUsesCoreImageFilters:)]) {
            [self setLayerUsesCoreImageFilters:FALSE];
            [dispLayer setFilters:nil];
        }
        
		[self enterFullScreenMode:chosenScreen withOptions:fullScreenOptions];
        
        if ([self respondsToSelector: @selector(setLayerUsesCoreImageFilters:)]) {
            [self setLayerUsesCoreImageFilters:TRUE];
            [dispLayer setFilters:cifilters];
        }
        
		fullScrnDevID = [[[chosenScreen deviceDescription] objectForKey:@"NSScreenNumber"] unsignedIntValue];
		
		// 得到screen的分辨率，并和播放中的图像进行比较
		// 知道是横图还是竖图
		NSSize sz = [chosenScreen frame].size;
		
		[controlUI setFillScreenMode:(((sz.height * [dispLayer aspectRatio]) >= sz.width)?kFillScreenButtonImageUBKey:kFillScreenButtonImageLRKey)
							   state:([dispLayer fillScreen])?NSOnState:NSOffState];
		[playerWindow orderOut:self];
	} else {
		return NO;
	}
	// 暂停的时候能够正确显示
	[dispLayer setNeedsDisplay];
    

    
	return YES;
}

-(BOOL) toggleFillScreen
{
	[dispLayer setFillScreen: ![dispLayer fillScreen]];
	// 暂停的时候能够正确显示
	[dispLayer setNeedsDisplay];
	return [dispLayer fillScreen];
}

-(void) setPlayerWindowLevel
{
	// in window mode
	NSInteger onTopMode = [ud integerForKey:kUDKeyOnTopMode];
	BOOL fullscr = [self isInFullScreenMode];
	
	if ((((onTopMode == kOnTopModeAlways)||((onTopMode == kOnTopModePlaying) && (playerController.playerState == kMPCPlayingState)))&&(!fullscr)) ||
		([NSApp isActive] && fullscr)) {
		[[self window] setLevel: NSTornOffMenuWindowLevel];
	} else {
		[[self window] setLevel: NSNormalWindowLevel];
	}
}

-(void) setDefaultPlayerWindowSize
{
	[playerWindow setContentSize:[playerWindow contentMinSize]];
}
///////////////////////////////////for dragging/////////////////////////////////////////
- (NSDragOperation) draggingEntered:(id <NSDraggingInfo>)sender
{
	NSPasteboard *pboard = [sender draggingPasteboard];
    NSDragOperation sourceDragMask = [sender draggingSourceOperationMask];
	
    if ( [[pboard types] containsObject:NSFilenamesPboardType] && (sourceDragMask & NSDragOperationCopy)) {
		[[self layer] setBorderWidth:6.0];
		return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (void)draggingExited:(id < NSDraggingInfo >)sender
{
	[[self layer] setBorderWidth:0.0];
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
	NSPasteboard *pboard = [sender draggingPasteboard];
    NSDragOperation sourceDragMask = [sender draggingSourceOperationMask];
	
	if ( [[pboard types] containsObject:NSFilenamesPboardType] ) {
		if (sourceDragMask & NSDragOperationCopy) {
			[[self layer] setBorderWidth:0.0];
			[playerController loadFiles:[pboard propertyListForType:NSFilenamesPboardType] fromLocal:YES];
		}
	}
	return YES;
}
///////////////////////////////////!!!!!!!!!!!!!!!!这三个方法是调用在工作线程上的，如果要操作界面，那么要小心!!!!!!!!!!!!!!!!!!!!!!!!!/////////////////////////////////////////
-(int)  coreController:(id)sender startWithFormat:(DisplayFormat)df buffer:(char**)data total:(NSUInteger)num
{
	if ([dispLayer startWithFormat:df buffer:data total:num] == 0) {
		
		displaying = YES;

		[self performSelectorOnMainThread:@selector(prepareForStartingDisplay) withObject:nil waitUntilDone:YES];

		return 0;
	}
	return 1;
}

-(void) prepareForStartingDisplay
{
	if (firstDisplay) {
		firstDisplay = NO;
		
		[VTController resetFilters:self];
		
		[self adjustWindowSizeAndAspectRatio:NSMakeSize(-1, -1)];
		
		[controlUI displayStarted];
		
		if ([ud boolForKey:kUDKeyStartByFullScreen] && (![self isInFullScreenMode])) {
			[controlUI performKeyEquivalent:[NSEvent keyEventWithType:NSKeyDown location:NSMakePoint(0, 0) modifierFlags:0 timestamp:0
														 windowNumber:0 context:nil
														   characters:kSCMFullScrnKeyEquivalent
										  charactersIgnoringModifiers:kSCMFullScrnKeyEquivalent
															isARepeat:NO keyCode:0]];
		}
	} else {
		[controlUI displayStarted];
	}
}

-(void) adjustWindowSizeAndAspectRatio:(NSSize) sizeVal
{
	NSSize sz;

	// 调用该函数会使DispLayer锁定并且窗口的比例也会锁定
	// 因此在这里设定lock是安全的
	lockAspectRatio = YES;
	// 虽然如果是全屏的话，是无法调用设定窗口的代码，但是全屏的时候无法改变窗口的size
	[dispLayer setExternalAspectRatio:kDisplayAscpectRatioInvalid];
	
	if ([self isInFullScreenMode]) {
		// 如果正在全屏，那么将设定窗口size的工作放到退出全屏的时候进行
		// 必须砸退出全屏的时候再设定
		// 在退出全屏之前，这个view并不属于window，设定contentsize不起作用
		shouldResize = YES;
		
		// 如果是全屏开始的，那么还需要设定ControlUI的FillScreen状态
		// 全屏的时候，view的size和screen的size是一样的
		sz = [self bounds].size;
		
		CGFloat aspectRatio = [dispLayer aspectRatio];
		[controlUI setFillScreenMode:(((sz.height * aspectRatio) >= sz.width)?kFillScreenButtonImageUBKey:kFillScreenButtonImageLRKey)
							   state:([dispLayer fillScreen])?NSOnState:NSOffState];
	} else {
		// 如果没有在全屏
		sz = [self calculateContentSize:sizeVal];
		
		NSPoint pos = [self calculatePlayerWindowPosition:sz];
		
		NSRect rc = NSMakeRect(pos.x, pos.y, sz.width, sz.height);
		rc = [playerWindow frameRectForContentRect:rc];
		
		[playerWindow setFrame:rc display:YES animate:YES];
		[playerWindow setContentAspectRatio:sz];
		
		if (![playerWindow isVisible]) {
			[[self layer] setContents:nil];
			[playerWindow makeKeyAndOrderFront:self];
		}
	}
}

-(NSPoint) calculatePlayerWindowPosition:(NSSize) winSize
{
	NSPoint pos = [playerWindow frame].origin;
	NSSize orgSz = [[playerWindow contentView] bounds].size;
	
	pos.x += (orgSz.width - winSize.width)  / 2;
	pos.y += (orgSz.height - winSize.height)/ 2;
	
	// would not let the monitor screen cut the window
	NSRect screenRc = [[playerWindow screen] visibleFrame];
		
	pos.x = MAX(screenRc.origin.x, MIN(pos.x, screenRc.origin.x + screenRc.size.width - winSize.width));
	pos.y = MAX(screenRc.origin.y, MIN(pos.y, screenRc.origin.y + screenRc.size.height- winSize.height));
	
	return pos;
}

-(void) coreController:(id)sender draw:(NSUInteger)frameNum
{
	[dispLayer draw:frameNum];
}

-(void) coreControllerStop:(id)sender
{
	[dispLayer stop];

	displaying = NO;
	[controlUI displayStopped];
	[playerWindow setContentResizeIncrements:NSMakeSize(1.0, 1.0)];
	[[self layer] setContents:(id)[logo CGImage]];
}
////////////////////////////Application Notification////////////////////////////
-(void) applicationDidBecomeActive:(NSNotification*)notif
{
	[self setPlayerWindowLevel];
}

-(void) applicationDidResignActive:(NSNotification*)notif
{
	[self setPlayerWindowLevel];
}
///////////////////////////////////////////PlayerWindow delegate//////////////////////////////////////////////
-(void) windowWillClose:(NSNotification *)notification
{
	if ([ud boolForKey:kUDKeyQuitOnClose]) {
		[NSApp terminate:nil];
	} else {
		[playerController stop];
	}
}


- (void)window:(NSWindow *)w willEncodeRestorableState:(NSCoder *)state
{

}

- (void)window:(NSWindow *)w didDecodeRestorableState:(NSCoder *)state
{
  [w center];
}

-(BOOL)windowShouldZoom:(NSWindow *)window toFrame:(NSRect)newFrame
{
	return (displaying && (![window isZoomed]));
}

- (NSRect)windowWillUseStandardFrame:(NSWindow *)window defaultFrame:(NSRect)newFrame
{
	if (window == playerWindow) {
		NSRect scrnRect = [[window screen] frame];

		newFrame.size = [self calculateContentSize:scrnRect.size];
		newFrame = [window frameRectForContentRect:newFrame];
		newFrame.origin.x = (scrnRect.size.width - newFrame.size.width)/2;
		newFrame.origin.y = (scrnRect.size.height- newFrame.size.height)/2;
	}
	return newFrame;
}

-(void) windowDidResize:(NSNotification *)notification
{
	if (!lockAspectRatio) {
		// 如果没有锁住aspect ratio
		NSSize sz = [self bounds].size;
		[dispLayer setExternalAspectRatio:(sz.width/sz.height)];
	}
}

@end
