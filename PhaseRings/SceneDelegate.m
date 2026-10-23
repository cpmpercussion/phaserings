//
//  SceneDelegate.m
//  PhaseRings
//
//  See SceneDelegate.h. The scene callbacks map 1:1 onto the former
//  UIApplicationDelegate ones so the audio engine still shuts down on resign
//  and restarts on becoming active (#27 retired the storyboard; this retires
//  the app-delegate window).
//

#import "SceneDelegate.h"
#import "AppDelegate.h"

@implementation SceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    UIWindowScene *windowScene = (UIWindowScene *)scene;

    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    ViewController *viewController = [[ViewController alloc] init];
    self.viewController = viewController;
    self.window.rootViewController = viewController;

    // Let the app delegate reach the controller for applicationWillTerminate.
    id<UIApplicationDelegate> appDelegate = [UIApplication sharedApplication].delegate;
    if ([appDelegate isKindOfClass:[AppDelegate class]]) {
        ((AppDelegate *)appDelegate).viewController = viewController;
    }

    // Screenshot mode: force a UI appearance so light/dark App Store captures
    // are deterministic regardless of the simulator's current setting. The
    // -uiStyle flag lands in NSArgumentDomain.
    NSString *uiStyle = [[NSUserDefaults standardUserDefaults] stringForKey:@"uiStyle"];
    if ([uiStyle isEqualToString:@"light"]) {
        self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    } else if ([uiStyle isEqualToString:@"dark"]) {
        self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }

    [self.window makeKeyAndVisible];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    [self.viewController restartSoundProcessing];
}

- (void)sceneWillResignActive:(UIScene *)scene {
    [self.viewController shutdownSoundProcessing];
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    [self.viewController openPdPatch];
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    [UIApplication sharedApplication].idleTimerDisabled = NO;
}

@end
