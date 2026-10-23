//
//  AppDelegate.m
//  PhaseRings
//
//  Created by Charles Martin on 20/01/2014.
//  Copyright (c) 2014 Charles Martin. All rights reserved.
//

#import "AppDelegate.h"
#import "SceneDelegate.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options
{
    return NO;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // Register defaults
    NSDictionary *defaults = @{@"sound":@2,
                               @"note_labels":@YES,
                               @"setup_label":@YES,
                               @"composition":@1,
                               @"note_1":@1,
                               @"note_2":@3,
                               @"note_3":@4,
                               @"scale_1":@3,
                               @"scale_2":@8,
                               @"scale_3":@9,
                               @"midi_in":@YES,
                               @"process_effects":@YES,
                               @"reverb_volume":@0.5,
                               @"master_volume":@1.0};

    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];

    // Window + root view controller are created by SceneDelegate (UIScene
    // life cycle, required by the iOS 27 SDK). Scene lifecycle callbacks
    // there handle the audio engine; this delegate keeps process-level duties.
    return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                   options:(UISceneConnectionOptions *)options
{
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Default"
                                                                  sessionRole:connectingSceneSession.role];
    config.delegateClass = [SceneDelegate class];
    return config;
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self.viewController stopOSCLogging];
}

@end
