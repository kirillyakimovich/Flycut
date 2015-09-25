//
//  AppController.m
//  Jumpcut
//
//  Created by Steve Cook on 4/3/06.
//  Copyright 2006 __MyCompanyName__. All rights reserved.
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <http://jumpcut.sourceforge.net/> for details.

#import "AppController.h"
#import "SGHotKey.h"
#import "SGHotKeyCenter.h"
#import "SRRecorderCell.h"
#import "UKLoginItemRegistry.h"
#import "NSWindow+TrueCenter.h"
#import "NSWindow+ULIZoomEffect.h"
#import "DBUserDefaults.h"

#define _DISPLENGTH 40

static NSString *const kFCMainHotKey = @"ShortcutRecorder mainHotkey";
static NSString *const kFCImportantThingHotKey = @"ShortcutRecorder importantThingHotkey";
static NSString *const kFCImportantThingText = @"ShortcutRecorder Important Thing Text";

@interface AppController () <NSTextFieldDelegate>

@property (nonatomic, strong) SGHotKey *pasteImportantThingHotKey;
@property (nonatomic, copy) NSString *importantThingString;
@property (nonatomic, strong) IBOutlet NSTextField *importantThingTextField;

@end

FOUNDATION_STATIC_INLINE KeyCombo SRMakeKeyComboFromDictionary(NSDictionary *dictionary) {
  return SRMakeKeyCombo([dictionary[@"keyCode"] intValue],
                        [dictionary[@"modifierFlags"] intValue]);
}

@implementation AppController

- (id)init
{
	[[DBUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithInt:10],
		@"displayNum",
		[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:[NSNumber numberWithInt:9],[NSNumber numberWithLong:1179648],nil] forKeys:[NSArray arrayWithObjects:@"keyCode",@"modifierFlags",nil]],
		kFCMainHotKey,
		[NSNumber numberWithInt:40],
		@"rememberNum",
		[NSNumber numberWithInt:1],
		@"savePreference",
		[NSNumber numberWithInt:0],
		@"menuIcon",
		[NSNumber numberWithFloat:.25],
		@"bezelAlpha",
		[NSNumber numberWithBool:YES],
		@"stickyBezel",
		[NSNumber numberWithBool:NO],
		@"wraparoundBezel",
		[NSNumber numberWithBool:NO],// No by default
		@"loadOnStartup",
		[NSNumber numberWithBool:YES], 
		@"menuSelectionPastes",
        // Flycut new options
        [NSNumber numberWithFloat:500.0],
        @"bezelWidth",
        [NSNumber numberWithFloat:320.0],
        @"bezelHeight",
        [NSDictionary dictionary],
        @"store",
        [NSNumber numberWithBool:YES],
        @"skipPasswordFields",
        [NSNumber numberWithBool:NO],
        @"removeDuplicates",
        [NSNumber numberWithBool:YES],
        @"popUpAnimation",
        [NSNumber numberWithBool:NO],
        @"pasteMovesToTop",
        nil]];
	return [super init];
}

- (void)awakeFromNib
{
	// We no longer get autosave from ShortcutRecorder, so let's set the recorder by hand
  NSDictionary *serializedMainHotKey = [[DBUserDefaults standardUserDefaults] dictionaryForKey:kFCMainHotKey];
  if(serializedMainHotKey)
  {
    [mainRecorder setKeyCombo:SRMakeKeyComboFromDictionary(serializedMainHotKey)];
	};
  
  NSDictionary *serializedCrucibleHotKey = [[DBUserDefaults standardUserDefaults] dictionaryForKey:kFCImportantThingHotKey];
  if(serializedCrucibleHotKey)
  {
    [self.importantThingRecorder setKeyCombo:SRMakeKeyComboFromDictionary(serializedCrucibleHotKey)];
  };
  NSString *importantThingText = [[DBUserDefaults standardUserDefaults] stringForKey:kFCImportantThingText];
  if (importantThingText)
  {
    self.importantThingTextField.stringValue = importantThingText;
  }
	// Initialize the JumpcutStore
	clippingStore = [[JumpcutStore alloc] initRemembering:[[DBUserDefaults standardUserDefaults] integerForKey:@"rememberNum"]
											   displaying:[[DBUserDefaults standardUserDefaults] integerForKey:@"displayNum"]
										withDisplayLength:_DISPLENGTH];
    
    NSRect screenFrame = [[NSScreen mainScreen] frame];
    widthSlider.maxValue = screenFrame.size.width;
    heightSlider.maxValue = screenFrame.size.height;
    
	// Set up the bezel window
	NSRect windowFrame = NSMakeRect(0, 0,
                                    [[DBUserDefaults standardUserDefaults] floatForKey:@"bezelWidth"],
                                    [[DBUserDefaults standardUserDefaults] floatForKey:@"bezelHeight"]);
	bezel = [[BezelWindow alloc] initWithContentRect:windowFrame
										   styleMask:NSBorderlessWindowMask
											 backing:NSBackingStoreBuffered
											   defer:NO];
    [bezel trueCenter];
	[bezel setDelegate:self];

	// Create our pasteboard interface
    jcPasteboard = [NSPasteboard generalPasteboard];
    [jcPasteboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    pbCount = [[NSNumber numberWithInt:[jcPasteboard changeCount]] retain];

	// Build the statusbar menu
    statusItem = [[[NSStatusBar systemStatusBar]
            statusItemWithLength:NSVariableStatusItemLength] retain];
    [statusItem setHighlightMode:YES];
    [self switchMenuIconTo: [[DBUserDefaults standardUserDefaults] integerForKey:@"menuIcon"]];
	[statusItem setMenu:jcMenu];
    [jcMenu setDelegate:self];
    [statusItem setEnabled:YES];
	
    // If our preferences indicate that we are saving, load the dictionary from the saved plist
    // and use it to get everything set up.
	if ( [[DBUserDefaults standardUserDefaults] integerForKey:@"savePreference"] >= 1 ) {
		[self loadEngineFromPList];
	}
	// Build our listener timer
    pollPBTimer = [[NSTimer scheduledTimerWithTimeInterval:(1.0)
													target:self
												  selector:@selector(pollPB:)
												  userInfo:nil
												   repeats:YES] retain];
	
    // Finish up
	srTransformer = [[[SRKeyCodeTransformer alloc] init] retain];
    pbBlockCount = [[NSNumber numberWithInt:0] retain];
    [pollPBTimer fire];

	// Stack position starts @ 0 by default
	stackPosition = 0;

    [[NSNotificationCenter defaultCenter] addObserverForName:@"DBSyncPromptUserDidCancelNotification" 
     object:nil queue:nil usingBlock:^(NSNotification *notification) {
                  [self setDropboxSync:NO];

         //[[DBUserDefaults standardUserDefaults] setDropboxSyncEnabled:NO];

     }];
	[NSApp activateIgnoringOtherApps: YES];
}

-(void)menuWillOpen:(NSMenu *)menu
{
    NSEvent *event = [NSApp currentEvent];
    if([event modifierFlags] & NSAlternateKeyMask) {
        [menu cancelTracking];
        if (disableStore)
        {
            // Update the pbCount so we don't enable and have it immediately copy the thing the user was trying to avoid.
            // Code copied from pollPB, which is disabled at this point, so the "should be okay" should still be okay.
            
            // Reload pbCount with the current changeCount
            // Probably poor coding technique, but pollPB should be the only thing messing with pbCount, so it should be okay
            [pbCount release];
            pbCount = [[NSNumber numberWithInt:[jcPasteboard changeCount]] retain];
        }
        disableStore = [self toggleMenuIconDisabled];
    }
}

-(bool)toggleMenuIconDisabled
{
    // Toggles the "disabled" look of the menu icon.  Returns if the icon looks disabled or not, allowing the caller to decide if anything is actually being disabled or if they just wanted the icon to be a status display.
    if (nil == statusItemText)
    {
        statusItemText = [statusItem title];
        statusItemImage = [statusItem image];
        [statusItem setTitle: @""];
        [statusItem setImage: [NSImage imageNamed:@"com.generalarcade.flycut.disabled.16.png"]];
        return true;
    }
    else
    {
        [statusItem setTitle: statusItemText];
        [statusItem setImage: statusItemImage];
        statusItemText = nil;
        statusItemImage = nil;
    }
    return false;
}

-(IBAction) activateAndOrderFrontStandardAboutPanel:(id)sender
{
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
    [[NSApplication sharedApplication] orderFrontStandardAboutPanel:sender];
}

-(IBAction) setBezelAlpha:(id)sender
{
	// In a masterpiece of poorly-considered design--because I want to eventually 
	// allow users to select from a variety of bezels--I've decided to create the
	// bezel programatically, meaning that I have to go through AppController as
	// a cutout to allow the user interface to interact w/the bezel.
	[bezel setAlpha:[sender floatValue]];
}

-(IBAction) setBezelWidth:(id)sender
{
    NSSize bezelSize = NSMakeSize([sender floatValue], bezel.frame.size.height);
	NSRect windowFrame = NSMakeRect( 0, 0, bezelSize.width, bezelSize.height);
	[bezel setFrame:windowFrame display:NO];
    [bezel trueCenter];
}

-(IBAction) setBezelHeight:(id)sender
{
    NSSize bezelSize = NSMakeSize(bezel.frame.size.width, [sender floatValue]);
	NSRect windowFrame = NSMakeRect( 0, 0, bezelSize.width, bezelSize.height);
	[bezel setFrame:windowFrame display:NO];
    [bezel trueCenter];
}


-(IBAction) switchMenuIcon:(id)sender
{
    [self switchMenuIconTo: [sender indexOfSelectedItem]];
}

-(void) switchMenuIconTo:(int)number
{
    if (number == 1 ) {
        [statusItem setTitle:@""];
        [statusItem setImage:[NSImage imageNamed:@"com.generalarcade.flycut.black.16.png"]];
    } else if (number == 2 ) {
        [statusItem setImage:nil];
        [statusItem setTitle:[NSString stringWithFormat:@"%C",0x2704]];
    } else if ( number == 3 ) {
        [statusItem setImage:nil];
        [statusItem setTitle:[NSString stringWithFormat:@"%C",0x2702]];
    } else {
        [statusItem setTitle:@""];
        [statusItem setImage:[NSImage imageNamed:@"com.generalarcade.flycut.16.png"]];
    }
}

-(IBAction) setRememberNumPref:(id)sender
{
	int choice;
	int newRemember = [sender intValue];
	if ( newRemember < [clippingStore jcListCount] &&
		 ! issuedRememberResizeWarning &&
		 ! [[DBUserDefaults standardUserDefaults] boolForKey:@"stifleRememberResizeWarning"]
		 ) {
		choice = NSRunAlertPanel(@"Resize Stack", 
								 @"Resizing the stack to a value below its present size will cause clippings to be lost.",
								 @"Resize", @"Cancel", @"Don't Warn Me Again");
		if ( choice == NSAlertAlternateReturn ) {
			[[DBUserDefaults standardUserDefaults] setValue:[NSNumber numberWithInt:[clippingStore jcListCount]]
													 forKey:@"rememberNum"];
			[self updateMenu];
			return;
		} else if ( choice == NSAlertOtherReturn ) {
			[[DBUserDefaults standardUserDefaults] setValue:[NSNumber numberWithBool:YES]
													 forKey:@"stifleRememberResizeWarning"];
		} else {
			issuedRememberResizeWarning = YES;
		}
	}
	if ( newRemember < [[DBUserDefaults standardUserDefaults] integerForKey:@"displayNum"] ) {
		[[DBUserDefaults standardUserDefaults] setValue:[NSNumber numberWithInt:newRemember]
												 forKey:@"displayNum"];
	}
	[clippingStore setRememberNum:newRemember];
	[self updateMenu];
}

-(IBAction) setDisplayNumPref:(id)sender
{
	[self updateMenu];
}

-(IBAction) showPreferencePanel:(id)sender
{                                    
	int checkLoginRegistry = [UKLoginItemRegistry indexForLoginItemWithPath:[[NSBundle mainBundle] bundlePath]];
	if ( checkLoginRegistry >= 1 ) {
		[[DBUserDefaults standardUserDefaults] setValue:[NSNumber numberWithBool:YES]
												 forKey:@"loadOnStartup"];
	} else {
		[[DBUserDefaults standardUserDefaults] setValue:[NSNumber numberWithBool:NO]
												 forKey:@"loadOnStartup"];
	}
	
	if ([prefsPanel respondsToSelector:@selector(setCollectionBehavior:)])
		[prefsPanel setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces];
	[NSApp activateIgnoringOtherApps: YES];
	[prefsPanel makeKeyAndOrderFront:self];
	issuedRememberResizeWarning = NO;
}

-(IBAction)toggleLoadOnStartup:(id)sender {
	if ( [[DBUserDefaults standardUserDefaults] boolForKey:@"loadOnStartup"] ) {
		[UKLoginItemRegistry addLoginItemWithPath:[[NSBundle mainBundle] bundlePath] hideIt:NO];
	} else {
		[UKLoginItemRegistry removeLoginItemWithPath:[[NSBundle mainBundle] bundlePath]];
	}
}


- (void)pasteFromStack
{
	if ( [clippingStore jcListCount] > stackPosition ) {
		[self pasteIndex: stackPosition];
		[self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
		[self performSelector:@selector(fakeCommandV) withObject:nil afterDelay:0.2];
	} else {
		[self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
	}
}

- (void)saveFromStack
{
    if ( [clippingStore jcListCount] > stackPosition ) {
        // Get text from clipping store.
        NSString *pbFullText = [self clippingStringWithCount:stackPosition];
        pbFullText = [pbFullText stringByReplacingOccurrencesOfString:@"\r" withString:@"\r\n"];
        
        // Get the Desktop directory:
        NSArray *paths = NSSearchPathForDirectoriesInDomains
        (NSDesktopDirectory, NSUserDomainMask, YES);
        NSString *desktopDirectory = [paths objectAtIndex:0];
        
        // Get the timestamp string:
        NSDate *currentDate = [NSDate date];
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"YYYY-MM-dd 'at' HH.mm.ss"];
        NSString *dateString = [dateFormatter stringFromDate:currentDate];
        
        // Make a file name to write the data to using the Desktop directory:
        NSString *fileName = [NSString stringWithFormat:@"%@/Clipping %@.txt",
                              desktopDirectory, dateString];
        
        // Save content to the file
        [pbFullText writeToFile:fileName
                  atomically:NO
                    encoding:NSNonLossyASCIIStringEncoding
                       error:nil];
    }
    
    [self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
}

- (void)changeStack
{
	if ( [clippingStore jcListCount] > stackPosition ) {
		[self pasteIndex: stackPosition];
		[self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
	} else {
		[self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
	}
}

- (void)pasteIndex:(int) position {
	[self addClipToPasteboardFromCount:position];

	if ( [[DBUserDefaults standardUserDefaults] boolForKey:@"pasteMovesToTop"] ) {
		[clippingStore clippingMoveToTop:position];
		stackPosition = 0;
		[self updateMenu];
	}
}

- (void)metaKeysReleased
{
	if ( ! isBezelPinned ) {
		[self pasteFromStack];
	}
}

-(void)fakeCommandV
	/*" +fakeCommandV synthesizes keyboard events for Cmd-v Paste 
	shortcut. "*/ 
{     
    CGEventSourceRef sourceRef = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    if (!sourceRef)
    {
        NSLog(@"No event source");
        return;
    }
    NSNumber *keyCode = [srTransformer reverseTransformedValue:@"V"];                               
    CGKeyCode veeCode = (CGKeyCode)[keyCode intValue];
    CGEventRef eventDown = CGEventCreateKeyboardEvent(sourceRef, veeCode, true);
    CGEventSetFlags(eventDown, kCGEventFlagMaskCommand|0x000008); // some apps want bit set for one of the command keys
    CGEventRef eventUp = CGEventCreateKeyboardEvent(sourceRef, veeCode, false);
    CGEventPost(kCGHIDEventTap, eventDown);
    CGEventPost(kCGHIDEventTap, eventUp);
    CFRelease(eventDown);
    CFRelease(eventUp);
    CFRelease(sourceRef);
} 


-(void)pollPB:(NSTimer *)timer
{
    NSString *type = [jcPasteboard availableTypeFromArray:[NSArray arrayWithObject:NSStringPboardType]];
    if ( [pbCount intValue] != [jcPasteboard changeCount] && !disableStore ) {
        // Reload pbCount with the current changeCount
        // Probably poor coding technique, but pollPB should be the only thing messing with pbCount, so it should be okay
        [pbCount release];
        pbCount = [[NSNumber numberWithInt:[jcPasteboard changeCount]] retain];
        if ( type != nil ) {
			NSString *contents = [jcPasteboard stringForType:type];
			if ( contents == nil || ([jcPasteboard stringForType:@"PasswordPboardType"] && [[DBUserDefaults standardUserDefaults] boolForKey:@"skipPasswordFields"]) ) {
                NSLog(@"Contents: Empty");
            } else {
				if (( [clippingStore jcListCount] == 0 || ! [contents isEqualToString:[clippingStore clippingContentsAtPosition:0]])
					&&  ! [pbCount isEqualTo:pbBlockCount] ) {
                    [clippingStore addClipping:contents
										ofType:type	];
//					The below tracks our position down down down... Maybe as an option?
//					if ( [clippingStore jcListCount] > 1 ) stackPosition++;
					stackPosition = 0;
                    [self updateMenu];
					if ( [[DBUserDefaults standardUserDefaults] integerForKey:@"savePreference"] >= 2 )
                        [self saveEngine];
                }
            }
        } 
    }
}

- (void)processBezelKeyDown:(NSEvent *)theEvent {
	int newStackPosition;
	// AppControl should only be getting these directly from bezel via delegation
	if ([theEvent type] == NSKeyDown) {
		if ([theEvent keyCode] == [mainRecorder keyCombo].code ) {
			if ([theEvent modifierFlags] & NSShiftKeyMask) [self stackUp];
			 else [self stackDown];
			return;
		}
		unichar pressed = [[theEvent charactersIgnoringModifiers] characterAtIndex:0];
        NSUInteger modifiers = [theEvent modifierFlags];
		switch (pressed) {
			case 0x1B:
				[self hideApp];
				break;
            case 0xD: // Enter or Return
				[self pasteFromStack];
				break;
			case 0x3:
                [self changeStack];
                break;
            case 0x2C: // Comma
                if ( modifiers & NSCommandKeyMask ) {
                    [self showPreferencePanel:nil];
                }
                break;
			case NSUpArrowFunctionKey: 
			case NSLeftArrowFunctionKey: 
            case 0x6B: // k
				[self stackUp];
				break;
			case NSDownArrowFunctionKey: 
			case NSRightArrowFunctionKey:
            case 0x6A: // j
				[self stackDown];
				break;
            case NSHomeFunctionKey:
				if ( [clippingStore jcListCount] > 0 ) {
					stackPosition = 0;
					[self updateBezel];
				}
				break;
            case NSEndFunctionKey:
				if ( [clippingStore jcListCount] > 0 ) {
					stackPosition = [clippingStore jcListCount] - 1;
					[self updateBezel];
				}
				break;
            case NSPageUpFunctionKey:
				if ( [clippingStore jcListCount] > 0 ) {
					stackPosition = stackPosition - 10; if ( stackPosition < 0 ) stackPosition = 0;
					[self updateBezel];
				}
				break;
			case NSPageDownFunctionKey:
				if ( [clippingStore jcListCount] > 0 ) {
					stackPosition = stackPosition + 10; if ( stackPosition >= [clippingStore jcListCount] ) stackPosition = [clippingStore jcListCount] - 1;
                    [self updateBezel];
                }
				break;
			case NSBackspaceCharacter:
            case NSDeleteCharacter:
                if ([clippingStore jcListCount] == 0)
                    return;

                [clippingStore clearItem:stackPosition];
                [self updateBezel];
                [self updateMenu];
                break;
            case NSDeleteFunctionKey: break;
			case 0x30: case 0x31: case 0x32: case 0x33: case 0x34: 				// Numeral 
			case 0x35: case 0x36: case 0x37: case 0x38: case 0x39:
				// We'll currently ignore the possibility that the user wants to do something with shift.
				// First, let's set the new stack count to "10" if the user pressed "0"
				newStackPosition = pressed == 0x30 ? 9 : [[NSString stringWithCharacters:&pressed length:1] intValue] - 1;
				if ( [clippingStore jcListCount] >= newStackPosition ) {
					stackPosition = newStackPosition;
					[bezel setCharString:[NSString stringWithFormat:@"%d of %d", stackPosition + 1, [clippingStore jcListCount]]];
					[bezel setText:[clippingStore clippingContentsAtPosition:stackPosition]];
				}
				break;
            case 's': case 'S': // Save / Save-and-delete
                if ([clippingStore jcListCount] == 0)
                    return;

                [self saveFromStack];
                if ( modifiers & NSShiftKeyMask ) {
                    [clippingStore clearItem:stackPosition];
                    [self updateBezel];
                    [self updateMenu];
                }
                break;
            default: // It's not a navigation/application-defined thing, so let's figure out what to do with it.
				NSLog(@"PRESSED %d", pressed);
				NSLog(@"CODE %ld", (long)[mainRecorder keyCombo].code);
				break;
		}		
	}
}

- (void) updateBezel
{
	if (stackPosition >= [clippingStore jcListCount] && stackPosition != 0) { // deleted last item
		stackPosition = [clippingStore jcListCount] - 1;
	}
	if (stackPosition == 0 && [clippingStore jcListCount] == 0) { // empty
		[bezel setText:@""];
		[bezel setCharString:@"Empty"];
	}
	else { // normal
		[bezel setText:[clippingStore clippingContentsAtPosition:stackPosition]];
		[bezel setCharString:[NSString stringWithFormat:@"%d of %d", stackPosition + 1, [clippingStore jcListCount]]];
	}
}

- (void) showBezel
{
	if ( [clippingStore jcListCount] > 0 && [clippingStore jcListCount] > stackPosition ) {
		[bezel setCharString:[NSString stringWithFormat:@"%d of %d", stackPosition + 1, [clippingStore jcListCount]]];
		[bezel setText:[clippingStore clippingContentsAtPosition:stackPosition]];
	}
	NSRect mainScreenRect = [NSScreen mainScreen].visibleFrame;
	[bezel setFrame:NSMakeRect(mainScreenRect.origin.x + mainScreenRect.size.width/2 - bezel.frame.size.width/2,
							   mainScreenRect.origin.y + mainScreenRect.size.height/2 - bezel.frame.size.height/2,
							   bezel.frame.size.width,
							   bezel.frame.size.height) display:YES];
	if ([bezel respondsToSelector:@selector(setCollectionBehavior:)])
		[bezel setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces];
	if ([[DBUserDefaults standardUserDefaults] boolForKey:@"popUpAnimation"])
		[bezel makeKeyAndOrderFrontWithPopEffect];
	else [bezel makeKeyAndOrderFront:self];
	isBezelDisplayed = YES;
}

- (void) hideBezel
{
	[bezel orderOut:nil];
	[bezel setCharString:@""];
	isBezelDisplayed = NO;
}

-(void)hideApp
{
	[self hideBezel];
	isBezelPinned = NO;
	[NSApp hide:self];
}

- (void) applicationWillResignActive:(NSApplication *)app; {
	// This should be hidden anyway, but just in case it's not.
	[self hideBezel];
}

- (void)hitMainHotKey:(SGHotKey *)hotKey
{
	if ( ! isBezelDisplayed ) {
		[NSApp activateIgnoringOtherApps:YES];
		if ( [[DBUserDefaults standardUserDefaults] boolForKey:@"stickyBezel"] ) {
			isBezelPinned = YES;
		}
		[self showBezel];
	} else {
		[self stackDown];
	}
}

- (void)hitImportantThingHotKey:(SGHotKey *)hotKey
{
  NSString *pbFullText;
  NSArray *pbTypes;
  NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
  [pasteboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];

  pbFullText = self.importantThingTextField.stringValue;
  if (pbFullText)
  {
    pbTypes = [NSArray arrayWithObjects:@"NSStringPboardType",NULL];
    
    [pasteboard setString:pbFullText forType:@"NSStringPboardType"];
    [self performSelector:@selector(fakeCommandV) withObject:nil afterDelay:0.2];
  }
}

- (IBAction)toggleMainHotKey:(id)sender
{
  if(sender != mainRecorder)
  {
    return;
  }

	if (mainHotKey != nil)
	{
    [[SGHotKeyCenter sharedCenter] unregisterHotKey:mainHotKey];
    [mainHotKey release];
    mainHotKey = nil;
	}
  SRRecorderControl *recorder = (SRRecorderControl *)sender;
  KeyCombo combo = [recorder keyCombo];
	mainHotKey = [[SGHotKey alloc] initWithIdentifier:@"mainHotKey"
											   keyCombo:[SGKeyCombo keyComboWithKeyCode:combo.code
																			  modifiers:[recorder cocoaToCarbonFlags:combo.flags]]];
	[mainHotKey setName: @"Activate Flycut HotKey"]; //This is typically used by PTKeyComboPanel
	[mainHotKey setTarget: self];
	[mainHotKey setAction: @selector(hitMainHotKey:)];
	[[SGHotKeyCenter sharedCenter] registerHotKey:mainHotKey];
}

- (IBAction)toggleImportantThingHotKey:(id)sender
{
  if(sender != self.importantThingRecorder)
  {
    return;
  }
  
  if (self.pasteImportantThingHotKey != nil)
  {
    [[SGHotKeyCenter sharedCenter] unregisterHotKey:self.pasteImportantThingHotKey];
    [self.pasteImportantThingHotKey release];
    self.pasteImportantThingHotKey = nil;
  }
  SRRecorderControl *recorder = (SRRecorderControl *)sender;
  KeyCombo combo = [recorder keyCombo];
  self.pasteImportantThingHotKey = [[SGHotKey alloc] initWithIdentifier:@"mainHotKey"
                                           keyCombo:[SGKeyCombo keyComboWithKeyCode:combo.code
                                                                          modifiers:[recorder cocoaToCarbonFlags:combo.flags]]];
  [self.pasteImportantThingHotKey  setName: @"Activate Paste Crucible HotKey"]; //This is typically used by PTKeyComboPanel
  [self.pasteImportantThingHotKey  setTarget: self];
  [self.pasteImportantThingHotKey  setAction: @selector(hitImportantThingHotKey:)];
  [[SGHotKeyCenter sharedCenter] registerHotKey:self.pasteImportantThingHotKey ];
}

-(IBAction)clearClippingList:(id)sender {
    int choice;
	
	[NSApp activateIgnoringOtherApps:YES];
    choice = NSRunAlertPanel(@"Clear Clipping List", 
							 @"Do you want to clear all recent clippings?",
							 @"Clear", @"Cancel", nil);
	
    // on clear, zap the list and redraw the menu
    if ( choice == NSAlertDefaultReturn ) {
        [clippingStore clearList];
        [self updateMenu];
		if ( [[DBUserDefaults standardUserDefaults] integerForKey:@"savePreference"] >= 1 ) {
			[self saveEngine];
		}
		[bezel setText:@""];
    }
}

-(IBAction)mergeClippingList:(id)sender {
    [clippingStore mergeList];
    [self updateMenu];
}

- (void)updateMenu {
    
    NSArray *returnedDisplayStrings = [clippingStore previousDisplayStrings:[[DBUserDefaults standardUserDefaults] integerForKey:@"displayNum"]];
    
    NSArray *menuItems = [[[jcMenu itemArray] reverseObjectEnumerator] allObjects];
    
    NSArray *clipStrings = [[returnedDisplayStrings reverseObjectEnumerator] allObjects];

    int passedSeparator = 0;
	
    //remove clippings from menu
    for (NSMenuItem *oldItem in menuItems) {
		if( [oldItem isSeparatorItem]) {
            passedSeparator++;
        } else if ( passedSeparator == 2 ) {
            [jcMenu removeItem:oldItem];
        }     
    }
	
    for(NSString *pbMenuTitle in clipStrings) {
        NSMenuItem *item;
        item = [[NSMenuItem alloc] initWithTitle:pbMenuTitle
										  action:@selector(processMenuClippingSelection:)
								   keyEquivalent:@""];
        [item setTarget:self];
        [item setEnabled:YES];
        [jcMenu insertItem:item atIndex:0];
        // Way back in 0.2, failure to release the new item here was causing a quite atrocious memory leak.
        [item release];
	} 
}

-(IBAction)processMenuClippingSelection:(id)sender
{
	int index=[[sender menu] indexOfItem:sender];
	[self pasteIndex:index];

	if ( [[DBUserDefaults standardUserDefaults] boolForKey:@"menuSelectionPastes"] ) {
		[self performSelector:@selector(hideApp) withObject:nil];
		[self performSelector:@selector(fakeCommandV) withObject:nil afterDelay:0.2];
	}
}

-(BOOL) isValidClippingNumber:(NSNumber *)number {
    return ( ([number intValue] + 1) <= [clippingStore jcListCount] );
}

-(NSString *) clippingStringWithCount:(int)count {
    if ( [self isValidClippingNumber:[NSNumber numberWithInt:count]] ) {
        return [clippingStore clippingContentsAtPosition:count];
    } else { // It fails -- we shouldn't be passed this, but...
        return @"";
    }
}

-(void) setPBBlockCount:(NSNumber *)newPBBlockCount
{
    [newPBBlockCount retain];
    [pbBlockCount release];
    pbBlockCount = newPBBlockCount;
}

-(BOOL)addClipToPasteboardFromCount:(int)indexInt
{
    NSString *pbFullText;
    NSArray *pbTypes;
    if ( (indexInt + 1) > [clippingStore jcListCount] ) {
        // We're asking for a clipping that isn't there yet
		// This only tends to happen immediately on startup when not saving, as the entire list is empty.
        NSLog(@"Out of bounds request to jcList ignored.");
        return false;
    }
    pbFullText = [self clippingStringWithCount:indexInt];
    pbTypes = [NSArray arrayWithObjects:@"NSStringPboardType",NULL];
    
    [jcPasteboard declareTypes:pbTypes owner:NULL];
	
    [jcPasteboard setString:pbFullText forType:@"NSStringPboardType"];
    [self setPBBlockCount:[NSNumber numberWithInt:[jcPasteboard changeCount]]];
    return true;
  
}

-(void) loadEngineFromPList
{
    NSDictionary *loadDict = [[[DBUserDefaults standardUserDefaults] dictionaryForKey:@"store"] copy];   
    NSArray *savedJCList;
	NSRange loadRange;
	
    int rangeCap;
	
    if ( loadDict != nil ) {

        savedJCList = [loadDict objectForKey:@"jcList"];
        
        if ( [savedJCList isKindOfClass:[NSArray class]] ) {
            int rememberNumPref = [[DBUserDefaults standardUserDefaults] 
                                   integerForKey:@"rememberNum"];
            // There's probably a nicer way to prevent the range from going out of bounds, but this works.
			rangeCap = [savedJCList count] < rememberNumPref ? [savedJCList count] : rememberNumPref;
			loadRange = NSMakeRange(0, rangeCap);
            NSArray *toBeRestoredClips = [[[savedJCList subarrayWithRange:loadRange] reverseObjectEnumerator] allObjects];
            for( NSDictionary *aSavedClipping in toBeRestoredClips)
				[clippingStore addClipping:[aSavedClipping objectForKey:@"Contents"]
									ofType:[aSavedClipping objectForKey:@"Type"]];
        } else NSLog(@"Not array");
        [self updateMenu];
        [loadDict release];
    }
}


-(void) stackDown
{
	stackPosition++;
	if ( [clippingStore jcListCount] > stackPosition ) {
		[bezel setCharString:[NSString stringWithFormat:@"%d of %d", stackPosition + 1, [clippingStore jcListCount]]];
		[bezel setText:[clippingStore clippingContentsAtPosition:stackPosition]];
	} else {
		if ( [[DBUserDefaults standardUserDefaults] boolForKey:@"wraparoundBezel"] ) {
			stackPosition = 0;
			[bezel setCharString:[NSString stringWithFormat:@"%d of %d", 1, [clippingStore jcListCount]]];
			[bezel setText:[clippingStore clippingContentsAtPosition:stackPosition]];
		} else {
			stackPosition--;
		}
	}
}

-(void) stackUp
{
	stackPosition--;
	if ( stackPosition < 0 ) {
		if ( [[DBUserDefaults standardUserDefaults] boolForKey:@"wraparoundBezel"] ) {
			stackPosition = [clippingStore jcListCount] - 1;
					[bezel setCharString:[NSString stringWithFormat:@"%d of %d", stackPosition + 1, [clippingStore jcListCount]]];
			[bezel setText:[clippingStore clippingContentsAtPosition:stackPosition]];
		} else {
			stackPosition = 0;
		}
	}
	if ( [clippingStore jcListCount] > stackPosition ) {
					[bezel setCharString:[NSString stringWithFormat:@"%d of %d", stackPosition + 1, [clippingStore jcListCount]]];
		[bezel setText:[clippingStore clippingContentsAtPosition:stackPosition]];
	}
}

-(void) saveEngine {
  DBUserDefaults *standardDefaults = [DBUserDefaults standardUserDefaults];
  
  if (self.importantThingTextField.stringValue.length > 0)
  {
    [standardDefaults setObject:self.importantThingTextField.stringValue forKey:kFCImportantThingText];
  }
    NSMutableDictionary *saveDict;
    NSMutableArray *jcListArray = [NSMutableArray array];
    saveDict = [NSMutableDictionary dictionaryWithCapacity:3];
    [saveDict setObject:@"0.7" forKey:@"version"];
    [saveDict setObject:[NSNumber numberWithInt:[standardDefaults integerForKey:@"rememberNum"]]
                 forKey:@"rememberNum"];
    [saveDict setObject:[NSNumber numberWithInt:_DISPLENGTH]
                 forKey:@"displayLen"];
    [saveDict setObject:[NSNumber numberWithInt:[standardDefaults integerForKey:@"displayNum"]]
                 forKey:@"displayNum"];
    for (int i = 0 ; i < [clippingStore jcListCount]; i++)
      [jcListArray addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                              [clippingStore clippingContentsAtPosition:i], @"Contents",
                              [clippingStore clippingTypeAtPosition:i], @"Type",
                              [NSNumber numberWithInt:i], @"Position",nil]];
    [saveDict setObject:jcListArray forKey:@"jcList"];
    [standardDefaults setObject:saveDict forKey:@"store"];
    [standardDefaults synchronize];
}

- (void)setHotKeyPreferenceForRecorder:(SRRecorderControl *)aRecorder {
  if (aRecorder == mainRecorder) {
    KeyCombo combo = [mainRecorder keyCombo];
    NSDictionary *serializedMainHotKey = [NSDictionary dictionaryWithObjects:@[@(combo.code), @(combo.flags)]
                                                                     forKeys:@[@"keyCode", @"modifierFlags"]];
    [[DBUserDefaults standardUserDefaults] setObject:serializedMainHotKey
                                              forKey:kFCMainHotKey];
  }
  if (aRecorder == self.importantThingRecorder) {
    KeyCombo combo = [self.importantThingRecorder keyCombo];
    NSDictionary *serializeCrucibleHotKey = [NSDictionary dictionaryWithObjects:@[@(combo.code), @(combo.flags)]
                                                                     forKeys:@[@"keyCode", @"modifierFlags"]];
    [[DBUserDefaults standardUserDefaults] setObject:serializeCrucibleHotKey
                                              forKey:kFCImportantThingHotKey];
  }
  
  [[DBUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)shortcutRecorder:(SRRecorderControl *)aRecorder isKeyCode:(NSInteger)keyCode andFlagsTaken:(NSUInteger)flags reason:(NSString **)aReason {
	return NO;
}

- (void)shortcutRecorder:(SRRecorderControl *)aRecorder keyComboDidChange:(KeyCombo)newKeyCombo
{
	if (aRecorder == mainRecorder)
  {
		[self toggleMainHotKey: aRecorder];
	}
  
  if (aRecorder == self.importantThingRecorder)
  {
    [self toggleImportantThingHotKey:aRecorder];
  }
  
  [self setHotKeyPreferenceForRecorder: aRecorder];
	NSLog(@"code: %ld, flags: %lu", (long)newKeyCombo.code, (unsigned long)newKeyCombo.flags);
}

- (IBAction)toggleDropboxSync:(NSButtonCell*)sender {

    DBUserDefaults * defaults = [DBUserDefaults standardUserDefaults];
    // First, let's check to make sure Dropbox is available on this machine
    if (sender.state == 1) { 
        if([DBUserDefaults isDropboxAvailable])
            [defaults promptDropboxUnavailable];        
        else [[DBUserDefaults standardUserDefaults] setDropboxSyncEnabled:YES];
    } else [[DBUserDefaults standardUserDefaults] setDropboxSyncEnabled:NO];
}


- (void)applicationWillTerminate:(NSNotification *)notification {
	if ( [[DBUserDefaults standardUserDefaults] integerForKey:@"savePreference"] >= 1 ) {
		NSLog(@"Saving on exit");
        [self saveEngine];
    } else {
        // Remove clips from store
        [[DBUserDefaults standardUserDefaults] setValue:[NSDictionary dictionary] forKey:@"store"];
        NSLog(@"Saving preferences on exit");
        [[DBUserDefaults standardUserDefaults] synchronize];
    }
	//Unregister our hot key (not required)
	[[SGHotKeyCenter sharedCenter] unregisterHotKey: mainHotKey];
	[mainHotKey release];
	mainHotKey = nil;
  
  [[SGHotKeyCenter sharedCenter] unregisterHotKey:self.pasteImportantThingHotKey];
  [self.pasteImportantThingHotKey release];
  self.pasteImportantThingHotKey = nil;

  
	[self hideBezel];
	[[NSDistributedNotificationCenter defaultCenter]
		removeObserver:self
        		  name:@"AppleKeyboardPreferencesChangedNotification"
				object:nil];
	[[NSDistributedNotificationCenter defaultCenter]
		removeObserver:self
				  name:@"AppleSelectedInputSourcesChangedNotification"
				object:nil];
}

-(BOOL) dropboxSync {
    return [DBUserDefaults isDropboxSyncEnabled];
}
-(void)setDropboxSync:(BOOL)enable {
    DBUserDefaults * defaults = [DBUserDefaults standardUserDefaults];
    if (enable) { 
        if([DBUserDefaults isDropboxAvailable])
            [defaults promptDropboxUnavailable];        
        else [[DBUserDefaults standardUserDefaults] setDropboxSyncEnabled:YES];
    } else {
        [[DBUserDefaults standardUserDefaults] setDropboxSyncEnabled:NO];
        [dropboxCheckbox setState:NSOffState];   
    }
}

- (void) dealloc {
	[bezel release];
	[srTransformer release];
	[super dealloc];
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidChange:(NSNotification *)aNotification
{
  if ([aNotification object] == self.importantThingTextField)
  {
    
  }
}

- (void)controlTextDidEndEditing:(NSNotification *)aNotification
{
  
}

@end
