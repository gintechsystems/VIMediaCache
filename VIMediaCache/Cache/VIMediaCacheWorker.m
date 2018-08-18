//
//  VIMediaCacheWorker.m
//  VIMediaCacheDemo
//
//  Created by Vito on 4/21/16.
//  Copyright © 2016 Vito. All rights reserved.
//

#import "VIMediaCacheWorker.h"
#import "VICacheAction.h"
#import "VICacheManager.h"

@import UIKit;

static NSInteger const kPackageLength = 204800; // 200kb per package
static NSString *kMCMediaCacheResponseKey = @"kMCMediaCacheResponseKey";
static NSString *VIMediaCacheErrorDoamin = @"com.vimediacache";

@interface VIMediaCacheWorker ()

@property (nonatomic, strong) NSFileHandle *readFileHandle;
@property (nonatomic, strong) NSFileHandle *writeFileHandle;
@property (nonatomic, strong, readwrite) NSError *setupError;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, strong) VICacheConfiguration *internalCacheConfiguration;

@property (nonatomic) long long currentOffset;

@property (nonatomic, strong) NSDate *startWriteDate;
@property (nonatomic) float writeBytes;
@property (nonatomic) BOOL writting;

@property (nonatomic, assign) unsigned long long leftSpace;
@property (nonatomic, strong) dispatch_queue_t fileWriteQueue;
@property (nonatomic, strong) dispatch_queue_t fileReadQueue;

@end

@implementation VIMediaCacheWorker

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    NSFileHandle *readHandle = self.readFileHandle;
    NSFileHandle *writeHandle = self.writeFileHandle;
    [self saveWithCompletion:^(NSError *error) {
        [readHandle closeFile];
        [writeHandle closeFile];
    }];
}

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        NSString *path = [VICacheManager cachedFilePathForURL:url];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        _filePath = path;
        _leftSpace = 0;
        NSError *error;
        NSString *cacheFolder = [path stringByDeletingLastPathComponent];
        if (![fileManager fileExistsAtPath:cacheFolder]) {
            [fileManager createDirectoryAtPath:cacheFolder
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:&error];
        }
        
        if (!error) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            }
            NSURL *fileURL = [NSURL fileURLWithPath:path];
            _readFileHandle = [NSFileHandle fileHandleForReadingFromURL:fileURL error:&error];
            _fileReadQueue = dispatch_queue_create("vicache_a_file_read_queue", NULL);
            if (!error) {
                _writeFileHandle = [NSFileHandle fileHandleForWritingToURL:fileURL error:&error];
                _internalCacheConfiguration = [VICacheConfiguration configurationWithFilePath:path];
                _internalCacheConfiguration.url = url;
                _fileWriteQueue = dispatch_queue_create("vicache_a_file_write_queue", NULL);

                unsigned long long usedSpace = [VICacheManager calculateCachedSizeWithError:&error];
                if (!error) {
                    _leftSpace = [VICacheManager maxCacheSize] >= usedSpace ? [VICacheManager maxCacheSize] - usedSpace : 0;
                }
            }
        }

        _setupError = error;
    }
    return self;
}

- (VICacheConfiguration *)cacheConfiguration {
    return self.internalCacheConfiguration;
}

- (void)cacheData:(NSData *)data forRange:(NSRange)range error:(NSError **)error {
    dispatch_async(self.fileWriteQueue, ^{
        @try {
            [self.writeFileHandle seekToFileOffset:range.location];
            [self.writeFileHandle writeData:data];
            self.writeBytes += data.length;
            [self.internalCacheConfiguration addCacheFragment:range];
        } @catch (NSException *exception) {
            NSLog(@"write to file error");
            *error = [NSError errorWithDomain:exception.name code:123 userInfo:@{NSLocalizedDescriptionKey: exception.reason, @"exception": exception}];
        }
    });
}

- (NSData *)cachedDataForRange:(NSRange)range error:(NSError **)error {
    __block NSData *data;
    dispatch_sync(self.fileReadQueue, ^{
        @try {
            [self.readFileHandle seekToFileOffset:range.location];
            data = [self.readFileHandle readDataOfLength:range.length]; // 空数据也会返回，所以如果 range 错误，会导致播放失效
        } @catch (NSException *exception) {
            NSLog(@"read cached data error %@",exception);
            *error = [NSError errorWithDomain:exception.name code:123 userInfo:@{NSLocalizedDescriptionKey: exception.reason, @"exception": exception}];
        }
    });
    return data;
}

- (NSArray<VICacheAction *> *)cachedDataActionsForRange:(NSRange)range {
    NSArray *cachedFragments = [self.internalCacheConfiguration cacheFragments];
    NSMutableArray *actions = [NSMutableArray array];
    
    if (range.location == NSNotFound) {
        return [actions copy];
    }
    NSInteger endOffset = range.location + range.length;
    // Delete header and footer not in range
    [cachedFragments enumerateObjectsUsingBlock:^(NSValue * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        NSRange fragmentRange = obj.rangeValue;
        NSRange intersectionRange = NSIntersectionRange(range, fragmentRange);
        if (intersectionRange.length > 0) {
            NSInteger package = intersectionRange.length / kPackageLength;
            for (NSInteger i = 0; i <= package; i++) {
                VICacheAction *action = [VICacheAction new];
                action.actionType = VICacheAtionTypeLocal;
                
                NSInteger offset = i * kPackageLength;
                NSInteger offsetLocation = intersectionRange.location + offset;
                NSInteger maxLocation = intersectionRange.location + intersectionRange.length;
                NSInteger length = (offsetLocation + kPackageLength) > maxLocation ? (maxLocation - offsetLocation) : kPackageLength;
                action.range = NSMakeRange(offsetLocation, length);
                
                [actions addObject:action];
            }
        } else if (fragmentRange.location >= endOffset) {
            *stop = YES;
        }
    }];
    
    if (actions.count == 0) {
        VICacheAction *action = [VICacheAction new];
        action.actionType = VICacheAtionTypeRemote;
        action.range = range;
        [actions addObject:action];
    } else {
        // Add remote fragments
        NSMutableArray *localRemoteActions = [NSMutableArray array];
        [actions enumerateObjectsUsingBlock:^(VICacheAction * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            NSRange actionRange = obj.range;
            if (idx == 0) {
                if (range.location < actionRange.location) {
                    VICacheAction *action = [VICacheAction new];
                    action.actionType = VICacheAtionTypeRemote;
                    action.range = NSMakeRange(range.location, actionRange.location - range.location);
                    [localRemoteActions addObject:action];
                }
                [localRemoteActions addObject:obj];
            } else {
                VICacheAction *lastAction = [localRemoteActions lastObject];
                NSInteger lastOffset = lastAction.range.location + lastAction.range.length;
                if (actionRange.location > lastOffset) {
                    VICacheAction *action = [VICacheAction new];
                    action.actionType = VICacheAtionTypeRemote;
                    action.range = NSMakeRange(lastOffset, actionRange.location - lastOffset);
                    [localRemoteActions addObject:action];
                }
                [localRemoteActions addObject:obj];
            }
            
            if (idx == actions.count - 1) {
                NSInteger localEndOffset = actionRange.location + actionRange.length;
                if (endOffset > localEndOffset) {
                    VICacheAction *action = [VICacheAction new];
                    action.actionType = VICacheAtionTypeRemote;
                    action.range = NSMakeRange(localEndOffset, endOffset - localEndOffset);
                    [localRemoteActions addObject:action];
                }
            }
        }];
        
        actions = localRemoteActions;
    }
    
    return [actions copy];
}

- (void)setContentInfo:(VIContentInfo *)contentInfo error:(NSError **)error {
    self.internalCacheConfiguration.contentInfo = contentInfo;
    @try {
        [self.writeFileHandle truncateFileAtOffset:contentInfo.contentLength];
        [self.writeFileHandle synchronizeFile];
    } @catch (NSException *exception) {
        NSLog(@"read cached data error %@", exception);
        *error = [NSError errorWithDomain:exception.name code:123 userInfo:@{NSLocalizedDescriptionKey: exception.reason, @"exception": exception}];
    }
}

- (void)saveWithCompletion:(void(^)(NSError *error))completion {
    NSFileHandle *writeHandle = self.writeFileHandle;
    VICacheConfiguration *configuration = self.internalCacheConfiguration;
    dispatch_async(self.fileWriteQueue, ^{
        @try {
            [writeHandle synchronizeFile];
            [configuration save];
            if (completion) {
                completion(nil);
            }
        } @catch (NSException *exception) {
            if (completion) {
                NSError *error = [NSError errorWithDomain:exception.name code:123 userInfo:@{NSLocalizedDescriptionKey: exception.reason, @"exception": exception}];
                completion(error);
            }
            NSLog(@"save data error %@", exception);
        }
    });
}

- (void)startWritting {
    if (!self.writting) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    }
    self.writting = YES;
    self.startWriteDate = [NSDate date];
    self.writeBytes = 0;
}

- (void)finishWritting {
    dispatch_async(self.fileWriteQueue, ^{
        if (self.writting) {
            self.writting = NO;
            [[NSNotificationCenter defaultCenter] removeObserver:self];
            NSTimeInterval time = [[NSDate date] timeIntervalSinceDate:self.startWriteDate];
            [self.internalCacheConfiguration addDownloadedBytes:self.writeBytes spent:time];
        }
        
        // Free some cache if needed.
        if (_leftSpace < _writeBytes) {
            NSError *error;
            unsigned long long cleanedSize = [VICacheManager cleanCacheWithSize:_writeBytes error:&error];
            if (error) {
                return;
            }
            self.leftSpace += cleanedSize;
            
            NSAssert(_leftSpace >= _writeBytes, @"cleanCacheWithSize:error: method error.");
        }
        self.leftSpace -= _writeBytes;
    });
}

#pragma mark - Notification

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    [self saveWithCompletion:nil];
}

@end
