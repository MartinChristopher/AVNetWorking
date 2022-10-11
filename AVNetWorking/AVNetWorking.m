//
//  AVNetWorking.m
//
//  Created by Apple on 16/3/31.
//

#import "AVNetWorking.h"
#import <CommonCrypto/CommonDigest.h>

#ifdef DEBUG
#define AVAppLog(format, ...) do { \
fprintf(stderr, "<%s : 第%d行> %s\n", \
[[[NSString stringWithUTF8String:__FILE__] lastPathComponent] UTF8String], \
__LINE__, __func__);\
(NSLog)((format), ##__VA_ARGS__);\
} while (0)
#else
#define AVAppLog(...)
#endif

#define CODE_TIMEOUT -1001
NSString *const AVNetworkStatus = @"NetWorkStatus";
static NSString *av_privateNetworkBaseUrl = nil;
static BOOL av_isEnableInterfaceDebug = NO;
static BOOL av_shouldAutoEncode = NO;
static NSMutableDictionary *av_httpHeaders = nil;
static AVResponseType av_responseType = AVResponseTypeJSON;
static AVRequestType  av_requestType  = AVRequestTypeJSON;
static NSMutableArray *av_requestTasks;
static BOOL av_cacheGet = YES;
static BOOL av_cachePost = NO;
static BOOL av_shouldCallbackOnCancelRequest = YES;
static NSInteger av_numberOfTimesToRetry = 3;
static NSTimeInterval av_timeoutInterval = 15.0f;
static NSMutableDictionary *av_timesOfRetryURLs;

@implementation AVNetWorking

+ (void)cacheGetRequest:(BOOL)isCacheGet shoulCachePost:(BOOL)shouldCachePost {
    av_cacheGet = isCacheGet;
    av_cachePost = shouldCachePost;
}

+ (void)setNumberOfTimesToRetryOnTimeout:(NSInteger)number {
    av_numberOfTimesToRetry = number;
}

+ (void)setTimeoutInterval:(NSTimeInterval)timeoutInterval {
    av_timeoutInterval = timeoutInterval;
}

+ (void)updateBaseUrl:(NSString *)baseUrl {
    av_privateNetworkBaseUrl = baseUrl;
}

+ (NSString *)baseUrl {
    return av_privateNetworkBaseUrl;
}

+ (void)enableInterfaceDebug:(BOOL)isDebug {
    av_isEnableInterfaceDebug = isDebug;
}

+ (BOOL)isDebug {
    return av_isEnableInterfaceDebug;
}

static inline NSString *cachePath() {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *docPath = [paths lastObject];
    return [docPath stringByAppendingPathComponent:@"AVNetWorkingCaches"];
}

+ (void)clearCaches {
    NSString *directoryPath = cachePath();
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:directoryPath isDirectory:nil]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:directoryPath error:&error];
        
        if (error) {
            NSLog(@"AVNetWorking clear caches error: %@", error);
        } else {
            NSLog(@"AVNetWorking clear caches ok");
        }
    }
}

+ (unsigned long long)totalCacheSize {
    NSString *directoryPath = cachePath();
    BOOL isDir = NO;
    unsigned long long total = 0;
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:directoryPath isDirectory:&isDir]) {
        if (isDir) {
            NSError *error = nil;
            NSArray *array = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directoryPath error:&error];
            
            if (error == nil) {
                for (NSString *subpath in array) {
                    NSString *path = [directoryPath stringByAppendingPathComponent:subpath];
                    NSDictionary *dict = [[NSFileManager defaultManager] attributesOfItemAtPath:path
                                                                                          error:&error];
                    if (!error) {
                        total += [dict[NSFileSize] unsignedIntegerValue];
                    }
                }
            }
        }
    }
    
    return total;
}

+ (NSMutableArray *)allTasks {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (av_requestTasks == nil) {
            av_requestTasks = [[NSMutableArray alloc] init];
        }
    });
    
    return av_requestTasks;
}
+ (NSMutableDictionary *)allTimesOfRetryURLs {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (av_timesOfRetryURLs == nil) {
            av_timesOfRetryURLs = [[NSMutableDictionary alloc] init];
        }
    });
    
    return av_timesOfRetryURLs;
}
+ (void)cancelAllRequest {
    @synchronized(self) {
        [[self allTasks] enumerateObjectsUsingBlock:^(AVURLSessionTask * _Nonnull task, NSUInteger idx, BOOL * _Nonnull stop) {
            if ([task isKindOfClass:[AVURLSessionTask class]]) {
                [task cancel];
            }
        }];
        
        [[self allTasks] removeAllObjects];
    };
}

+ (void)cancelRequestWithURL:(NSString *)url {
    if (url == nil) {
        return;
    }
    
    @synchronized(self) {
        [[self allTasks] enumerateObjectsUsingBlock:^(AVURLSessionTask * _Nonnull task, NSUInteger idx, BOOL * _Nonnull stop) {
            if ([task isKindOfClass:[AVURLSessionTask class]]
                && [task.currentRequest.URL.absoluteString hasSuffix:url]) {
                [task cancel];
                [[self allTasks] removeObject:task];
                return;
            }
        }];
    };
}

+ (void)configRequestType:(AVRequestType)requestType
             responseType:(AVResponseType)responseType
      shouldAutoEncodeUrl:(BOOL)shouldAutoEncode
  callbackOnCancelRequest:(BOOL)shouldCallbackOnCancelRequest {
    av_requestType = requestType;
    av_responseType = responseType;
    av_shouldAutoEncode = shouldAutoEncode;
    av_shouldCallbackOnCancelRequest = shouldCallbackOnCancelRequest;
}

+ (BOOL)shouldEncode {
    return av_shouldAutoEncode;
}

+ (void)shouldAutoEncodeUrl:(BOOL)shouldAutoEncode {
    av_shouldAutoEncode = shouldAutoEncode;
}

+ (void)configCommonHttpHeaders:(NSDictionary *)httpHeaders {
    av_httpHeaders = httpHeaders.mutableCopy;
}

+ (void)setHttpHeaderValue:(id)value forKey:(NSString *)key {
    [av_httpHeaders setValue:value forKey:key];
}

+ (void)removeHttpHeaderforKey:(NSString *)key {
    [av_httpHeaders removeObjectForKey:key];
}

+ (AVURLSessionTask *)getWithUrl:(NSString *)url
                     refreshCache:(BOOL)refreshCache
                          success:(SuccessBlock)success
                             fail:(FailureBlock)fail {
    return [self getWithUrl:url
               refreshCache:refreshCache
                     params:nil
                    success:success
                       fail:fail];
}

+ (AVURLSessionTask *)getWithUrl:(NSString *)url
                     refreshCache:(BOOL)refreshCache
                           params:(NSDictionary *)params
                          success:(SuccessBlock)success
                             fail:(FailureBlock)fail {
    return [self getWithUrl:url
               refreshCache:refreshCache
                     params:params
                   progress:nil
                    success:success
                       fail:fail];
}

+ (AVURLSessionTask *)getWithUrl:(NSString *)url
                     refreshCache:(BOOL)refreshCache
                           params:(NSDictionary *)params
                         progress:(AVGetProgress)progress
                          success:(SuccessBlock)success
                             fail:(FailureBlock)fail {
    return [self _requestWithUrl:url
                    refreshCache:refreshCache
                       httpMedth:AVNetRequestMethodGet
                          params:params
                        progress:progress
                         success:success
                            fail:fail];
}

+ (AVURLSessionTask *)postWithUrl:(NSString *)url
                      refreshCache:(BOOL)refreshCache
                            params:(NSDictionary *)params
                           success:(SuccessBlock)success
                              fail:(FailureBlock)fail {
    return [self postWithUrl:url
                refreshCache:refreshCache
                      params:params
                    progress:nil
                     success:success
                        fail:fail];
}

+ (AVURLSessionTask *)postWithUrl:(NSString *)url
                      refreshCache:(BOOL)refreshCache
                            params:(NSDictionary *)params
                          progress:(AVPostProgress)progress
                           success:(SuccessBlock)success
                              fail:(FailureBlock)fail {
    return [self _requestWithUrl:url
                    refreshCache:refreshCache
                       httpMedth:AVNetRequestMethodPost
                          params:params
                        progress:progress
                         success:success
                            fail:fail];
}

+ (AVURLSessionTask *)deleteWithUrl:(NSString *)url refreshCache:(BOOL)refreshCache params:(NSDictionary *)params success:(SuccessBlock)success fail:(FailureBlock)fail {
    return [self _requestWithUrl:url
                    refreshCache:refreshCache
                       httpMedth:AVNetRequestMethodDelete
                          params:params
                        progress:nil
                         success:success
                            fail:fail];
}

+ (AVURLSessionTask *)putWithUrl:(NSString *)url refreshCache:(BOOL)refreshCache params:(NSDictionary *)params success:(SuccessBlock)success fail:(FailureBlock)fail {
    return [self _requestWithUrl:url
                    refreshCache:refreshCache
                       httpMedth:AVNetRequestMethodPut
                          params:params
                        progress:nil
                         success:success
                            fail:fail];
}

+ (AVURLSessionTask *)_requestWithUrl:(NSString *)url
                          refreshCache:(BOOL)refreshCache
                             httpMedth:(AVNetRequestMethod)httpMethod
                                params:(NSDictionary *)params
                              progress:(AVDownloadProgress)progress
                               success:(SuccessBlock)success
                                  fail:(FailureBlock)fail {
    //设置请求超时重试次数
    if (url) {
        if (![[self allTimesOfRetryURLs] objectForKey:url]) {
            [[self allTimesOfRetryURLs] setObject:@(av_numberOfTimesToRetry) forKey:url];
        }
    }
    AFHTTPSessionManager *manager = [self manager];
    NSString *absolute = [self absoluteUrlWithPath:url];
    
    if ([self baseUrl] == nil) {
        if ([NSURL URLWithString:url] == nil) {
            AVAppLog(@"URLString无效，无法生成URL。可能是URL中有中文，请尝试Encode URL");
            return nil;
        }
    } else {
        NSURL *absouluteURL = [NSURL URLWithString:absolute];
        
        if (absouluteURL == nil) {
            AVAppLog(@"URLString无效，无法生成URL。可能是URL中有中文，请尝试Encode URL");
            return nil;
        }
    }
    
    if ([self shouldEncode]) {
        url = [self encodeUrl:url];
    }
    
    AVURLSessionTask *session = nil;
    
    if (httpMethod == AVNetRequestMethodGet) {
        if (av_cacheGet && !refreshCache) {// 获取缓存
            id response = [[self class] cahceResponseWithURL:absolute
                                                   parameters:params];
            if (response) {
                if (success) {
                    [self successResponse:response callback:success];
                    
                    if ([self isDebug]) {
                        [self logWithSuccessResponse:response
                                                 url:absolute
                                              params:params];
                    }
                }
                
                return nil;
            }
        }
        
        session = [manager GET:url parameters:params headers:nil progress:^(NSProgress * _Nonnull downloadProgress) {
            if (progress) {
                progress(downloadProgress.completedUnitCount, downloadProgress.totalUnitCount);
            }
        } success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
            [self successResponse:responseObject callback:success];
            
            if (av_cacheGet) {
                [self cacheResponseObject:responseObject request:task.currentRequest parameters:params];
            }
            [[self allTimesOfRetryURLs] removeObjectForKey:url]; //移除关联的超时重试次数
            [[self allTasks] removeObject:task];
            
            if ([self isDebug]) {
                [self logWithSuccessResponse:responseObject
                                         url:absolute
                                      params:params];
            }
        } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
            //判断超时重试条件,满足则发起重试请求
            NSInteger timesOfRetry = [[[self allTimesOfRetryURLs] objectForKey:url] integerValue];
            if (error.code == CODE_TIMEOUT && timesOfRetry > 0) {
                [task cancel];
                [self _requestWithUrl:url refreshCache:refreshCache httpMedth:httpMethod params:params progress:progress success:success fail:fail];
                AVAppLog(@"%@超时重试%@",url,@(timesOfRetry));
                //设置请求超时重试次数
                timesOfRetry--;
                [[self allTimesOfRetryURLs] setObject:@(timesOfRetry) forKey:url];
                return ;
            }
            [[self allTimesOfRetryURLs] removeObjectForKey:url]; //移除关联的超时重试次数
            [[self allTasks] removeObject:task];
            
            [self handleCallbackWithError:error fail:fail];
            
            if ([self isDebug]) {
                [self logWithFailError:error url:absolute params:params];
            }
        }];
    } else if (httpMethod == AVNetRequestMethodPost) {
        if (av_cachePost && !refreshCache) {// 获取缓存
            id response = [[self class] cahceResponseWithURL:absolute
                                                   parameters:params];
            
            if (response) {
                if (success) {
                    [self successResponse:response callback:success];
                    
                    if ([self isDebug]) {
                        [self logWithSuccessResponse:response
                                                 url:absolute
                                              params:params];
                    }
                }
                
                return nil;
            }
        }
        
        session = [manager POST:url parameters:params headers:nil progress:^(NSProgress * _Nonnull downloadProgress) {
            if (progress) {
                progress(downloadProgress.completedUnitCount, downloadProgress.totalUnitCount);
            }
        } success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
            [self successResponse:responseObject callback:success];
            
            if (av_cachePost) {
                [self cacheResponseObject:responseObject request:task.currentRequest  parameters:params];
            }
            [[self allTimesOfRetryURLs] removeObjectForKey:url]; //移除关联的超时重试次数
            [[self allTasks] removeObject:task];
            
            if ([self isDebug]) {
                [self logWithSuccessResponse:responseObject
                                         url:absolute
                                      params:params];
            }
            
        } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
            //判断超时重试条件,满足则发起重试请求
            NSInteger timesOfRetry = [[[self allTimesOfRetryURLs] objectForKey:url] integerValue];
            if (error.code == CODE_TIMEOUT && timesOfRetry > 0) {
                [task cancel];
                [self _requestWithUrl:url refreshCache:refreshCache httpMedth:httpMethod params:params progress:progress success:success fail:fail];
                AVAppLog(@"%@超时重试%@",url,@(timesOfRetry));
                //设置请求超时重试次数
                timesOfRetry--;
                [[self allTimesOfRetryURLs] setObject:@(timesOfRetry) forKey:url];
                return ;
            }
            [[self allTimesOfRetryURLs] removeObjectForKey:url]; //移除关联的超时重试次数
            [[self allTasks] removeObject:task];
            
            [self handleCallbackWithError:error fail:fail];
            
            if ([self isDebug]) {
                [self logWithFailError:error url:absolute params:params];
            }
        }];
    } else if (httpMethod == AVNetRequestMethodDelete) {
        session = [manager DELETE:url parameters:params headers:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
            [self successResponse:responseObject callback:success];
            if ([self isDebug]) {
                [self logWithSuccessResponse:responseObject
                                         url:absolute
                                      params:params];
            }
        } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
            [self handleCallbackWithError:error fail:fail];
            if ([self isDebug]) {
                [self logWithFailError:error url:absolute params:params];
            }
        }];
    } else if (httpMethod == AVNetRequestMethodPut) {
        session = [manager PUT:url parameters:params headers:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
            [self successResponse:responseObject callback:success];
            if ([self isDebug]) {
                [self logWithSuccessResponse:responseObject
                                         url:absolute
                                      params:params];
            }
        } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
            [self handleCallbackWithError:error fail:fail];
            if ([self isDebug]) {
                [self logWithFailError:error url:absolute params:params];
            }
        }];
    }
    
    if (session) {
        [[self allTasks] addObject:session];
    }
    
    return session;
}

#pragma mark 上传图片
+ (AVURLSessionTask *)uploadImageWithURL:(NSString *)url
                                   image:(UIImage *)image
                                  params:(NSDictionary *)params
                                progress:(AVUploadProgress)progress
                                 success:(SuccessBlock)success
                                 failure:(FailureBlock)failure
{
    NSArray *array;
    if (image) {
        array = [NSArray arrayWithObject:image];
    }
    return [self uploadImageWithURL:url photos:array params:params progress:progress success:success failure:failure];
}

+ (AVURLSessionTask *)uploadImageWithURL:(NSString *)url
                                  photos:(NSArray *)photos
                                  params:(NSDictionary *)params
                                progress:(AVUploadProgress)progress
                                 success:(SuccessBlock)success
                                 failure:(FailureBlock)failure
{
    if ([self baseUrl] == nil) {
        if ([NSURL URLWithString:url] == nil) {
            AVAppLog(@"URLString无效，无法生成URL。可能是URL中有中文，请尝试Encode URL");
            return nil;
        }
    } else {
        if ([NSURL URLWithString:[NSString stringWithFormat:@"%@%@", [self baseUrl], url]] == nil) {
            AVAppLog(@"URLString无效，无法生成URL。可能是URL中有中文，请尝试Encode URL");
            return nil;
        }
    }
    
    if ([self shouldEncode]) {
        url = [self encodeUrl:url];
    }
    
    NSString *absolute = [self absoluteUrlWithPath:url];
    
    AFHTTPSessionManager *manager = [self manager];
    AVURLSessionTask *session = [manager POST:url parameters:params headers:nil constructingBodyWithBlock:^(id<AFMultipartFormData>  _Nonnull formData) {
        for (int i = 0; i < photos.count; i ++) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.dateFormat = @"yyyyMMddHHmmss";
            NSString *timeStr = [formatter stringFromDate:[NSDate date]];
            NSString *fileName = [NSString stringWithFormat:@"%@.png", timeStr];
            UIImage *image = photos[i];
            NSData *imageData = [self compressImageToData:image];
            [formData appendPartWithFileData:imageData name:@"file" fileName:fileName mimeType:@"image/jpeg"];
        }
    } progress:^(NSProgress * _Nonnull uploadProgress) {
        if (progress) {
            progress(uploadProgress.completedUnitCount, uploadProgress.totalUnitCount);
        }
        NSLog(@"上传字节 %lld, 总字节 %lld", uploadProgress.completedUnitCount, uploadProgress.totalUnitCount);
    } success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        [[self allTasks] removeObject:task];
        [self successResponse:responseObject callback:success];
        
        if ([self isDebug]) {
            [self logWithSuccessResponse:responseObject
                                     url:absolute
                                  params:params];
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        
        [[self allTasks] removeObject:task];
        [self handleCallbackWithError:error fail:failure];
        if ([self isDebug]) {
            [self logWithFailError:error url:absolute params:nil];
        }
    }];
    [session resume];
    if (session) {
        [[self allTasks] addObject:session];
    }
    
    return session;
}

+ (AVURLSessionTask *)uploadDataWithURL:(NSString *)url
                                    data:(NSData *)data
                                  params:(NSDictionary *)params
                                    name:(NSString *)name
                                fileType:(AVUploadType)fileType
                                progress:(AVUploadProgress)progress
                                 success:(SuccessBlock)success
                                 failure:(FailureBlock)failure
{
    AVUploadModel * model = [[AVUploadModel alloc] init];
    model.keyName = name;
    model.type = fileType;
    model.data = data;
    return [self submitFormWithURL:url params:params uploadFiles:@[model] progress:progress success:success failure:failure];
}

+ (AVURLSessionTask *)submitFormWithURL:(NSString *)url
                                  params:(NSDictionary *)params
                            uploadFiles:(NSArray <AVUploadModel *>*)uploadFiles
                                progress:(AVUploadProgress)progress
                                 success:(SuccessBlock)success
                                 failure:(FailureBlock)failure
{
    if ([self baseUrl] == nil) {
        if ([NSURL URLWithString:url] == nil) {
            AVAppLog(@"URLString无效，无法生成URL。可能是URL中有中文，请尝试Encode URL");
            return nil;
        }
    } else {
        if ([NSURL URLWithString:[NSString stringWithFormat:@"%@%@", [self baseUrl], url]] == nil) {
            AVAppLog(@"URLString无效，无法生成URL。可能是URL中有中文，请尝试Encode URL");
            return nil;
        }
    }
    
    if ([self shouldEncode]) {
        url = [self encodeUrl:url];
    }
    
    NSString *absolute = [self absoluteUrlWithPath:url];
    
    AFHTTPSessionManager *manager = [self manager];
    manager.requestSerializer.timeoutInterval = 60.0f;
    AVURLSessionTask *session = [manager POST:url parameters:params headers:nil constructingBodyWithBlock:^(id<AFMultipartFormData>  _Nonnull formData) {
        if (uploadFiles) {
            [uploadFiles enumerateObjectsUsingBlock:^(AVUploadModel * _Nonnull uploadModel, NSUInteger idx, BOOL * _Nonnull stop) {
                NSString * formKeyName = uploadModel.keyName ? : [NSString stringWithFormat:@"file%ld", idx+1];
                NSData * fileData = uploadModel.image ? [self compressImageToData:uploadModel.image] : uploadModel.data;
                if (fileData) {
                    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                    formatter.dateFormat = @"yyyyMMddHHmmss";
                    NSString *timeStr = [formatter stringFromDate:[NSDate date]];
                    NSString *fileName;
                    switch (uploadModel.type) {
                        case AVUploadTypeTxt:
                            fileName = [NSString stringWithFormat:@"%@.txt", timeStr];
                            [formData appendPartWithFileData:fileData name:formKeyName fileName:fileName mimeType:@"text/txt"];
                            break;
                        case AVUploadTypeImage:
                            fileName = [NSString stringWithFormat:@"%@.jpeg", timeStr];
                            [formData appendPartWithFileData:fileData name:formKeyName fileName:fileName mimeType:@"image/jpeg"];
                            break;
                        case AVUploadTypeAudio:
                            fileName = [NSString stringWithFormat:@"%@.mp3", timeStr];
                            [formData appendPartWithFileData:fileData name:formKeyName fileName:fileName mimeType:@"audio/quicktime"];
                            break;
                        case AVUploadTypeVideo:
                            fileName = [NSString stringWithFormat:@"%@.mp4", timeStr];
                            [formData appendPartWithFileData:fileData name:formKeyName fileName:fileName mimeType:@"video/quicktime"];
                            break;
                        default:
                            break;
                    }
                }
            }];
        }
    } progress:^(NSProgress * _Nonnull uploadProgress) {
        if (progress) {
            progress(uploadProgress.completedUnitCount, uploadProgress.totalUnitCount);
        }
    } success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        [[self allTasks] removeObject:task];
        [self successResponse:responseObject callback:success];
        
        if ([self isDebug]) {
            [self logWithSuccessResponse:responseObject
                                     url:absolute
                                  params:params];
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        
        [[self allTasks] removeObject:task];
        [self handleCallbackWithError:error fail:failure];
        if ([self isDebug]) {
            [self logWithFailError:error url:absolute params:nil];
        }
    }];
    [session resume];
    if (session) {
        [[self allTasks] addObject:session];
    }
    return session;
}

+ (AVURLSessionTask *)uploadFileWithUrl:(NSString *)url
                           uploadingFile:(NSString *)uploadingFile
                                progress:(AVUploadProgress)progress
                                 success:(SuccessBlock)success
                                    fail:(FailureBlock)fail {
    if ([NSURL URLWithString:uploadingFile] == nil) {
        AVAppLog(@"uploadingFile无效，无法生成URL。请检查待上传文件是否存在");
        return nil;
    }
    
    NSURL *uploadURL = nil;
    if ([self baseUrl] == nil) {
        uploadURL = [NSURL URLWithString:url];
    } else {
        uploadURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@", [self baseUrl], url]];
    }
    
    if (uploadURL == nil) {
        AVAppLog(@"URLString无效，无法生成URL。可能是URL中有中文或特殊字符，请尝试Encode URL");
        return nil;
    }
    
    if ([self shouldEncode]) {
        url = [self encodeUrl:url];
    }
    
    AFHTTPSessionManager *manager = [self manager];
    NSURLRequest *request = [NSURLRequest requestWithURL:uploadURL];
    AVURLSessionTask *session = nil;
    
    NSURLSessionUploadTask *task = [manager uploadTaskWithRequest:request fromFile:[NSURL URLWithString:uploadingFile] progress:^(NSProgress * _Nonnull uploadProgress) {
        if (progress) {
            progress(uploadProgress.completedUnitCount, uploadProgress.totalUnitCount);
        }
    } completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
        [[self allTasks] removeObject:session];
        
        [self successResponse:responseObject callback:success];
        
        if (error) {
            [self handleCallbackWithError:error fail:fail];
            
            if ([self isDebug]) {
                [self logWithFailError:error url:response.URL.absoluteString params:nil];
            }
        } else {
            if ([self isDebug]) {
                [self logWithSuccessResponse:responseObject
                                         url:response.URL.absoluteString
                                      params:nil];
            }
        }
    }];
    [task resume];
    if (session) {
        [[self allTasks] addObject:session];
    }
    
    return session;
}

+ (AVURLSessionTask *)downloadWithUrl:(NSString *)url
                              progress:(AVDownloadProgress)progressBlock
                               success:(void(^)(NSURL *fileUrl))success
                               failure:(FailureBlock)failure {
    if ([self baseUrl] == nil) {
        if ([NSURL URLWithString:url] == nil) {
            AVAppLog(@"URLString无效，无法生成URL。可能是URL中有中文，请尝试Encode URL");
            return nil;
        }
    } else {
        if ([NSURL URLWithString:[NSString stringWithFormat:@"%@%@", [self baseUrl], url]] == nil) {
            AVAppLog(@"URLString无效，无法生成URL。可能是URL中有中文，请尝试Encode URL");
            return nil;
        }
    }
    
    NSURLRequest *downloadRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
    AFHTTPSessionManager *manager = [self manager];
    
    AVURLSessionTask *session = nil;
    
    session = [manager downloadTaskWithRequest:downloadRequest progress:^(NSProgress * _Nonnull downloadProgress) {
        if (progressBlock) {
            progressBlock(downloadProgress.completedUnitCount, downloadProgress.totalUnitCount);
        }
    } destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
        
        NSURL *documentsDirectoryURL = [[NSFileManager defaultManager] URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
        return [documentsDirectoryURL URLByAppendingPathComponent:[response suggestedFilename]];
        
    } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
        [[self allTasks] removeObject:session];
        
        if (error == nil) {
            if (success) {
                success(filePath);
            }
            
            if ([self isDebug]) {
                AVAppLog(@"Download success for url %@",
                          [self absoluteUrlWithPath:url]);
            }
        } else {
            [self handleCallbackWithError:error fail:failure];
            
            if ([self isDebug]) {
                AVAppLog(@"Download fail for url %@, reason : %@",
                          [self absoluteUrlWithPath:url],
                          [error description]);
            }
        }
    }];
    [session resume];
    if (session) {
        [[self allTasks] addObject:session];
    }
    
    return session;
}

#pragma mark - Private
+ (AFHTTPSessionManager *)manager {
    // 开启转圈圈
    [AFNetworkActivityIndicatorManager sharedManager].enabled = YES;
    
    AFHTTPSessionManager *manager = nil;;
    if ([self baseUrl] != nil) {
        manager = [[AFHTTPSessionManager alloc] initWithBaseURL:[NSURL URLWithString:[self baseUrl]]];
    } else {
        manager = [AFHTTPSessionManager manager];
    }
    
    switch (av_requestType) {
        case AVRequestTypeJSON: {
            manager.requestSerializer = [AFJSONRequestSerializer serializer];
            break;
        }
        case AVRequestTypePlainText: {
            manager.requestSerializer = [AFHTTPRequestSerializer serializer];
            break;
        }
        default: {
            break;
        }
    }
    
    switch (av_responseType) {
        case AVResponseTypeJSON: {
            manager.responseSerializer = [AFJSONResponseSerializer serializer];
            break;
        }
        case AVResponseTypeXML: {
            manager.responseSerializer = [AFXMLParserResponseSerializer serializer];
            break;
        }
        case AVResponseTypeData: {
            manager.responseSerializer = [AFHTTPResponseSerializer serializer];
            break;
        }
        default: {
            break;
        }
    }
    
    manager.requestSerializer.stringEncoding = NSUTF8StringEncoding;
    
    
    for (NSString *key in av_httpHeaders.allKeys) {
        if (av_httpHeaders[key] != nil) {
            [manager.requestSerializer setValue:av_httpHeaders[key] forHTTPHeaderField:key];
        }
    }
    manager.responseSerializer.acceptableContentTypes = [NSSet setWithArray:@[@"application/json",
                                                                              @"text/html",
                                                                              @"text/json",
                                                                              @"text/plain",
                                                                              @"text/javascript",
                                                                              @"text/xml",
                                                                              @"image/*"]];
    
    // 设置允许同时最大并发数量，过大容易出问题
    manager.operationQueue.maxConcurrentOperationCount = 5;
    // 设置超时限制
    [manager.requestSerializer willChangeValueForKey:@"timeoutInterval"];
    
    manager.requestSerializer.timeoutInterval = av_timeoutInterval;
    
    [manager.requestSerializer didChangeValueForKey:@"timeoutInterval"];
    return manager;
}

+ (void)logWithSuccessResponse:(id)response url:(NSString *)url params:(NSDictionary *)params {
    AVAppLog(@"\n");
    AVAppLog(@"\nRequest success, URL: %@\n params:%@\n response:%@\n\n",
              [self generateGETAbsoluteURL:url params:params],
              params,
              [self tryToParseData:response]);
}

+ (void)logWithFailError:(NSError *)error url:(NSString *)url params:(id)params {
    NSString *format = @" params: ";
    if (params == nil || ![params isKindOfClass:[NSDictionary class]]) {
        format = @"";
        params = @"";
    }
    
    AVAppLog(@"\n");
    if ([error code] == NSURLErrorCancelled) {
        AVAppLog(@"\nRequest was canceled mannully, URL: %@ %@%@\n\n",
                  [self generateGETAbsoluteURL:url params:params],
                  format,
                  params);
    } else {
        AVAppLog(@"\nRequest error, URL: %@ %@%@\n errorInfos:%@\n\n",
                  [self generateGETAbsoluteURL:url params:params],
                  format,
                  params,
                  [error localizedDescription]);
    }
}

// 仅对一级字典结构起作用
+ (NSString *)generateGETAbsoluteURL:(NSString *)url params:(id)params {
    if (params == nil || ![params isKindOfClass:[NSDictionary class]] || [params count] == 0) {
        return url;
    }
    
    NSString *queries = @"";
    for (NSString *key in params) {
        id value = [params objectForKey:key];
        
        if ([value isKindOfClass:[NSDictionary class]]) {
            continue;
        } else if ([value isKindOfClass:[NSArray class]]) {
            continue;
        } else if ([value isKindOfClass:[NSSet class]]) {
            continue;
        } else {
            queries = [NSString stringWithFormat:@"%@%@=%@&",
                       (queries.length == 0 ? @"&" : queries),
                       key,
                       value];
        }
    }
    
    if (queries.length > 1) {
        queries = [queries substringToIndex:queries.length - 1];
    }
    
    if (([url hasPrefix:@"http://"] || [url hasPrefix:@"https://"]) && queries.length > 1) {
        if ([url rangeOfString:@"?"].location != NSNotFound
            || [url rangeOfString:@"#"].location != NSNotFound) {
            url = [NSString stringWithFormat:@"%@%@", url, queries];
        } else {
            queries = [queries substringFromIndex:1];
            url = [NSString stringWithFormat:@"%@?%@", url, queries];
        }
    }
    
    return url.length == 0 ? queries : url;
}


+ (id)tryToParseData:(id)responseData {
    if ([responseData isKindOfClass:[NSData class]]) {
        // 尝试解析成JSON
        if (responseData == nil) {
            return responseData;
        } else {
            NSError *error = nil;
            NSDictionary *response = [NSJSONSerialization JSONObjectWithData:responseData
                                                                     options:NSJSONReadingMutableContainers
                                                                       error:&error];
            
            if (error != nil) {
                return responseData;
            } else {
                return response;
            }
        }
    } else {
        return responseData;
    }
}

+ (void)successResponse:(id)responseData callback:(SuccessBlock)success {
    if (success) {
        success([self tryToParseData:responseData]);
    }
}


+ (NSString *)encodeUrl:(NSString *)url {
    return [self URLEncode:url];
}

+ (NSString *)URLEncode:(NSString *)url {
#pragma clang diagnostic push
#pragma clang diagnostic ignored"-Wdeprecated-declarations"
    NSString *newString =
    CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                                              (CFStringRef)url,
                                                              NULL,
                                                              CFSTR(":/?#[]@!$ &'()*+,;=\"<>%{}|\\^~`"), CFStringConvertNSStringEncodingToEncoding(NSUTF8StringEncoding)));
#pragma clang diagnostic pop
    if (newString) {
        return newString;
    }
    
    return url;
}

+ (id)cahceResponseWithURL:(NSString *)url parameters:params {
    id cacheData = nil;
    
    if (url) {
        // Try to get datas from disk
        NSString *directoryPath = cachePath();
        NSString *absoluteURL = [self generateGETAbsoluteURL:url params:params];
        NSString *key = [NSString AVNetWorking_MD5:absoluteURL];
        NSString *path = [directoryPath stringByAppendingPathComponent:key];
        
        NSData *data = [[NSFileManager defaultManager] contentsAtPath:path];
        if (data) {
            cacheData = data;
            AVAppLog(@"Read data from cache for url: %@\n", url);
        }
    }
    
    return cacheData;
}

+ (void)cacheResponseObject:(id)responseObject request:(NSURLRequest *)request parameters:params {
    if (request && responseObject && ![responseObject isKindOfClass:[NSNull class]]) {
        NSString *directoryPath = cachePath();
        
        NSError *error = nil;
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:directoryPath isDirectory:nil]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:directoryPath
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&error];
            if (error) {
                AVAppLog(@"create cache dir error: %@\n", error);
                return;
            }
        }
        
        NSString *absoluteURL = [self generateGETAbsoluteURL:request.URL.absoluteString params:params];
        NSString *key = [NSString AVNetWorking_MD5:absoluteURL];
        NSString *path = [directoryPath stringByAppendingPathComponent:key];
        NSDictionary *dict = (NSDictionary *)responseObject;
        
        NSData *data = nil;
        if ([dict isKindOfClass:[NSData class]]) {
            data = responseObject;
        } else {
            data = [NSJSONSerialization dataWithJSONObject:dict
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&error];
        }
        
        if (data && error == nil) {
            BOOL isOk = [[NSFileManager defaultManager] createFileAtPath:path contents:data attributes:nil];
            if (isOk) {
                AVAppLog(@"cache file ok for request: %@\n", absoluteURL);
            } else {
                AVAppLog(@"cache file error for request: %@\n", absoluteURL);
            }
        }
    }
}

+ (NSString *)absoluteUrlWithPath:(NSString *)path {
    if (path == nil || path.length == 0) {
        return @"";
    }
    
    if ([self baseUrl] == nil || [[self baseUrl] length] == 0) {
        return path;
    }
    
    NSString *absoluteUrl = path;
    
    if (![path hasPrefix:@"http://"] && ![path hasPrefix:@"https://"]) {
        absoluteUrl = [NSString stringWithFormat:@"%@%@",
                       [self baseUrl], path];
    }
    
    return absoluteUrl;
}

+ (void)handleCallbackWithError:(NSError *)error fail:(FailureBlock)fail {
    if ([error code] == NSURLErrorCancelled) {
        if (av_shouldCallbackOnCancelRequest) {
            if (fail) {
                fail(error);
            }
        }
    } else {
        if (fail) {
            fail(error);
        }
    }
}

+ (void)startMonitoringNetStatus:(NetStatus)netStatus {
    //获得网络监控的管理者
    AFNetworkReachabilityManager *manager = [AFNetworkReachabilityManager sharedManager];
    //设置网络状态改变后的处理
    [manager setReachabilityStatusChangeBlock:^(AFNetworkReachabilityStatus status) {
        switch (status) {
            case AFNetworkReachabilityStatusUnknown:
                AVAppLog(@"未知网络");
                [[NSNotificationCenter defaultCenter] postNotificationName:AppNetworkChangedNotification object:@(NO)];
                break;
                
            case AFNetworkReachabilityStatusNotReachable:
                AVAppLog(@"没有网络");
                [[NSNotificationCenter defaultCenter] postNotificationName:AppNetworkChangedNotification object:@(NO)];
                break;
                
            case AFNetworkReachabilityStatusReachableViaWWAN:
                AVAppLog(@"当前非WiFi环境");
                [[NSNotificationCenter defaultCenter] postNotificationName:AppNetworkChangedNotification object:@(YES)];
                break;
                
            case AFNetworkReachabilityStatusReachableViaWiFi:
                AVAppLog(@"已加入WiFi环境");
                [[NSNotificationCenter defaultCenter] postNotificationName:AppNetworkChangedNotification object:@(YES)];
                break;
        }
        if (netStatus) {
            netStatus(status);
        }
    }];
    //开始监控
    [manager startMonitoring];
}

+ (void)stopMonitoring {
    //获得网络监控的管理者
    AFNetworkReachabilityManager *manager = [AFNetworkReachabilityManager sharedManager];
    //停止监控
    [manager stopMonitoring];
}

+ (BOOL)hasNetWithStatus:(AFNetworkReachabilityStatus)status {
    return (status== AFNetworkReachabilityStatusReachableViaWWAN || status == AFNetworkReachabilityStatusReachableViaWiFi);
}

+ (NSDictionary *)httpHeader {
    return av_httpHeaders.copy;
}

+ (NSData *)compressImageToData:(UIImage *)image {
    // UIImageJPEGRepresentation第二个参数为压缩比率
    NSData *data = UIImageJPEGRepresentation(image, 1.0);
    if (data.length > 100 * 1024) {
        if (data.length > 1024 * 1024) {//1M以及以上
            data = UIImageJPEGRepresentation(image, 0.1);
        }
        else if (data.length > 512 * 1024) {//0.5M-1M
            data = UIImageJPEGRepresentation(image, 0.5);
        }
        else if (data.length > 200 * 1024) {//0.25M-0.5M
            data = UIImageJPEGRepresentation(image, 0.9);
        }
    }
    return data;
}

@end
