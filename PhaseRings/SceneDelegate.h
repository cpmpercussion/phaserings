//
//  SceneDelegate.h
//  PhaseRings
//
//  UIScene life cycle for the standalone app. The iOS 27 SDK refuses to
//  launch apps that still rely on the UIApplicationDelegate window/lifecycle
//  path, so the window + root ViewController and the foreground/background
//  audio handling live here. AppDelegate keeps process-level duties only.
//

#import <UIKit/UIKit.h>
#import "ViewController.h"

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>

@property (strong, nonatomic) UIWindow *window;
@property (weak, nonatomic) ViewController *viewController;

@end
