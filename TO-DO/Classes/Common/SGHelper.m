//
//  SGHelper.m
//  TO-DO
//
//  Created by Siegrain on 16/5/7.
//  Copyright © 2016年 com.siegrain. All rights reserved.
//

#import "DateUtil.h"
#import "SCLAlertHelper.h"
#import "MBProgressHUD.h"
#import "LCActionSheet.h"
#import "MBProgressHUD+SGExtension.h"
#import <AVFoundation/AVFoundation.h>
#import <MobileCoreServices/UTCoreTypes.h>

@implementation SGHelper
#pragma mark - font

+ (UIFont *)themeFontWithSize:(CGFloat)size {
    return [UIFont fontWithName:@"Avenir" size:size];
}

+ (UIFont *)themeFontDefault {
    return [self themeFontWithSize:13];
}

#pragma mark - color

+ (UIColor *)themeColorSubTitle {
    return ColorWithRGB(0xCCCCCC);
}

+ (UIColor *)themeColorGray {
    return ColorWithRGB(0x999999);
}

+ (UIColor *)themeColorLightGray {
    return ColorWithRGB(0xEEEEEE);
}

+ (UIColor *)themeColorNormal {
    return ColorWithRGB(0xFF3366);
}

+ (UIColor *)themeColorHighlighted {
    return ColorWithRGB(0xEE2B5B);
}

+ (UIColor *)themeColorDisabled {
    return ColorWithRGB(0xFE7295);
}

#pragma mark - 创建一个选择照片的 action sheet

+ (void)photoPickerFromTarget:(UIViewController <UINavigationControllerDelegate, UIImagePickerControllerDelegate> *)viewController {
    LCActionSheet *sheet = [LCActionSheet sheetWithTitle:Localized(@"Choose photo") buttonTitles:@[Localized(@"Take a photo"), Localized(@"Pick from album")] redButtonIndex:-1 clicked:^(NSInteger buttonIndex) {
        if (buttonIndex == 0)
            [self pickPictureFromSource:UIImagePickerControllerSourceTypeCamera target:viewController error:nil];
        else if (buttonIndex == 1)
            [self pickPictureFromSource:UIImagePickerControllerSourceTypePhotoLibrary target:viewController error:nil];
    }];
    [sheet show];
}

#pragma mark - pick a picture by camera or album

+ (void)pickPictureFromSource:(UIImagePickerControllerSourceType)sourceType target:(UIViewController <UINavigationControllerDelegate, UIImagePickerControllerDelegate> *)target error:(BOOL *)error {
    // 判断相机权限
    if (sourceType == UIImagePickerControllerSourceTypeCamera) {
        AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        if (authStatus == AVAuthorizationStatusRestricted || authStatus == AVAuthorizationStatusDenied) {
            [SCLAlertHelper errorAlertWithContent:NSLocalizedString(@"Please allow app to access your device's camera in \"Settings\" -> \"Privacy\" -> \"Camera\"", nil)];
            if (error) *error = true;
            return;
        }
    }
    
    if ([UIImagePickerController isSourceTypeAvailable:sourceType]) {
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.mediaTypes = @[(NSString *) kUTTypeImage];
        picker.delegate = target;
        picker.allowsEditing = true;
        picker.sourceType = sourceType;
        [target presentViewController:picker animated:true completion:nil];
    } else {
        if (error) *error = true;
        return;
    }
}

#pragma mark - alerts

+ (void)waitingAlert {
    [MBProgressHUD show];
}

+ (void)dismissAlert {
    [MBProgressHUD dismiss];
}

+ (void)errorAlertWithMessage:(NSString *)message {
    [SCLAlertHelper errorAlertWithContent:message];
}

+ (void)alertWithMessage:(NSString *)message {
    [MBProgressHUD showWithText:message dismissAfter:3];
}

#pragma mark - get localized format date string

+ (NSString *)localizedFormatDate:(NSDate *)date {
    NSString *dateFormat = isChina ? @"yyyy MMM d" : @"MMM d, yyyy";
    return [DateUtil dateString:date withFormat:dateFormat];
}

#pragma mark -

+ (UIColor *)subTextColor {
    return ColorWithRGB(0x777777);
}
@end
