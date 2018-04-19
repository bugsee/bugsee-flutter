#import "BugseePlugin.h"
#import "Bugsee/Bugsee.h"

@implementation BugseePlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:@"bugsee"
            binaryMessenger:[registrar messenger]];
  BugseePlugin* instance = [[BugseePlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([@"event" isEqualToString:call.method]) {
        NSString *name = call.arguments[@"name"];
        id parameterMap = call.arguments[@"parameters"];

        if (parameterMap != [NSNull null]) {
            [Bugsee registerEvent:name withParams:parameterMap];
        } else {
            [Bugsee registerEvent:name];
        }

        result(nil);
    }

    else if ([@"trace" isEqualToString:call.method]) {
        NSString *name = call.arguments[@"name"];
        id value = call.arguments[@"value"];
        [Bugsee traceKey:name withValue:value];

        result(nil);
    }

    else if ([@"setAttribute" isEqualToString:call.method]) {
        NSString *key = call.arguments[@"key"];
        id value = call.arguments[@"value"];

        [Bugsee setAttribute:key withValue:value];

        result(nil);
    }

    else if ([@"clearAttribute" isEqualToString:call.method]) {
        NSString *key = call.arguments[@"key"];

        [Bugsee clearAttribute:key];

        result(nil);
    }

    else if ([@"logException" isEqualToString:call.method]) {
        NSString *name = call.arguments[@"name"];
        NSString *reason = call.arguments[@"reason"];
        BOOL handled = [call.arguments[@"handled"] boolValue];
        id frames = call.arguments[@"frames"];

        [Bugsee logException:name
                      reason:reason
                      frames:frames
                        type:@"flutter"
                     handled:handled];

        result(nil);
    }

    else if ([@"addSecureRect" isEqualToString:call.method]) {
        CGRect rect;
        if (CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)call.arguments, &rect)){

            CGFloat scale = [UIScreen mainScreen].scale;
            rect.size.width /= scale; rect.size.height /= scale;
            rect.origin.x /= scale; rect.origin.y /= scale;

            [Bugsee addSecureRect:rect];
        }

        result(nil);
    }

    else if ([@"removeSecureRect" isEqualToString:call.method]) {
        CGRect rect;
        if (CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)call.arguments, &rect)){

            CGFloat scale = [UIScreen mainScreen].scale;
            rect.size.width /= scale; rect.size.height /= scale;
            rect.origin.x /= scale; rect.origin.y /= scale;

            [Bugsee removeSecureRect:rect];
        }

        result(nil);
    }

    else if ([@"removeAllSecureRects" isEqualToString:call.method]) {
        [Bugsee removeAllSecureRects];

        result(nil);
    }

    else {
        result(FlutterMethodNotImplemented);
    }
}

@end
