//
//  AVUploadModel.m
//
//  Created by Apple on 2021/9/23.
//

#import "AVUploadModel.h"

@implementation AVUploadModel

- (instancetype)initWithType:(AVUploadType)type {
    if (self = [super init]) {
        self.type = type;
    }
    return self;
}

@end
