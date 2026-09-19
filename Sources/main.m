#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <signal.h>
#import <unistd.h>

// MARK: - Poppler Locator
@interface PopplerLocator : NSObject
+ (NSString *)findExecutable;
+ (void)prewarmCache;
@end

@implementation PopplerLocator
static NSString *sCachedPopplerPath = nil;

+ (void)prewarmCache {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self findExecutable];
    });
}

+ (NSString *)findExecutable {
    @synchronized (self) {
        if (sCachedPopplerPath && [[NSFileManager defaultManager] isExecutableFileAtPath:sCachedPopplerPath]) {
            return sCachedPopplerPath;
        }
        NSArray *candidates = @[
            @"/opt/homebrew/bin/pdftoppm",
            @"/usr/local/bin/pdftoppm",
            @"/usr/bin/pdftoppm"
        ];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *path in candidates) {
            if ([fm isExecutableFileAtPath:path]) {
                sCachedPopplerPath = path;
                return path;
            }
        }
        // Fallback: which pdftoppm
        NSTask *whichTask = [[NSTask alloc] init];
        whichTask.executableURL = [NSURL fileURLWithPath:@"/usr/bin/which"];
        whichTask.arguments = @[@"pdftoppm"];
        NSPipe *pipe = [NSPipe pipe];
        whichTask.standardOutput = pipe;
        whichTask.standardError = [NSFileHandle fileHandleWithNullDevice];
        NSError *err = nil;
        if ([whichTask launchAndReturnError:&err]) {
            [whichTask waitUntilExit];
            NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
            NSString *outPath = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (outPath.length > 0 && [fm isExecutableFileAtPath:outPath]) {
                sCachedPopplerPath = outPath;
                return outPath;
            }
        }
        return nil;
    }
}
@end

// MARK: - Job Manager
@interface JobManager : NSObject
@property (nonatomic, copy) void (^onBatchProgress)(NSString *msg, BOOL inProgress, NSURL *latestFolder);
+ (instancetype)shared;
- (void)enqueueURLs:(NSArray<NSURL *> *)urls dpi:(NSInteger)dpi;
- (void)cancelAll;
@end

@interface JobManager ()
@property (nonatomic, strong) NSOperationQueue *queue;
@property (nonatomic, strong) NSMutableSet<NSTask *> *activeTasks;
@property (nonatomic, strong) NSMutableSet<NSURL *> *activeOutputFolders;
@property (nonatomic, strong) NSLock *stateLock;
@property (nonatomic, assign) BOOL isCancelled;

// Aggregate batch tracking
@property (nonatomic, assign) NSInteger totalBatchJobs;
@property (nonatomic, assign) NSInteger pendingBatchJobs;
@property (nonatomic, assign) NSInteger successCount;
@property (nonatomic, assign) NSInteger failureCount;
@property (nonatomic, strong) NSURL *latestBatchFolder;
@end

@implementation JobManager

+ (instancetype)shared {
    static JobManager *mgr = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mgr = [[JobManager alloc] init];
    });
    return mgr;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = [[NSOperationQueue alloc] init];
        _queue.maxConcurrentOperationCount = 2;
        _queue.qualityOfService = NSQualityOfServiceUserInitiated;
        _activeTasks = [NSMutableSet set];
        _activeOutputFolders = [NSMutableSet set];
        _stateLock = [[NSLock alloc] init];
        _isCancelled = NO;
        _latestBatchFolder = nil;
    }
    return self;
}

- (void)cancelAll {
    [self.stateLock lock];
    self.isCancelled = YES;
    [self.queue cancelAllOperations];

    // Terminate all actively running tasks with SIGTERM and escalation to SIGKILL
    for (NSTask *task in self.activeTasks) {
        if (task.isRunning) {
            pid_t pid = task.processIdentifier;
            [task terminate];
            for (int i = 0; i < 10 && task.isRunning; i++) {
                usleep(50000); // 50ms polling up to 500ms
            }
            if (task.isRunning && pid > 0) {
                kill(pid, SIGKILL);
            }
            while (task.isRunning) {
                usleep(10000);
            }
        }
    }
    [self.activeTasks removeAllObjects];

    // Synchronously clean up partial output folders
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSURL *folder in self.activeOutputFolders) {
        [fm removeItemAtURL:folder error:nil];
    }
    [self.activeOutputFolders removeAllObjects];

    self.pendingBatchJobs = 0;
    self.totalBatchJobs = 0;
    self.latestBatchFolder = nil;
    [self.stateLock unlock];
}

- (void)enqueueURLs:(NSArray<NSURL *> *)urls dpi:(NSInteger)dpi {
    [self.stateLock lock];
    self.isCancelled = NO;
    // Reset state if previous batch completely finished
    if (self.pendingBatchJobs <= 0) {
        self.totalBatchJobs = 0;
        self.successCount = 0;
        self.failureCount = 0;
        self.latestBatchFolder = nil;
    }
    self.totalBatchJobs += urls.count;
    self.pendingBatchJobs += urls.count;
    [self.stateLock unlock];

    NSString *pdftoppm = [PopplerLocator findExecutable];
    if (!pdftoppm) {
        [self.stateLock lock];
        self.pendingBatchJobs = 0;
        self.totalBatchJobs = 0;
        self.latestBatchFolder = nil;
        [self.stateLock unlock];
        [self notifyUI:@"Error: Poppler (pdftoppm) not found. Please install via Homebrew: brew install poppler" inProgress:NO folder:nil];
        return;
    }

    for (NSURL *fileURL in urls) {
        __weak typeof(self) weakSelf = self;
        [self.queue addOperationWithBlock:^{
            [weakSelf processFile:fileURL pdftoppmPath:pdftoppm dpi:dpi];
        }];
    }
}

- (void)processFile:(NSURL *)fileURL pdftoppmPath:(NSString *)pdftoppm dpi:(NSInteger)dpi {
    [self.stateLock lock];
    if (self.isCancelled) {
        [self.stateLock unlock];
        return;
    }
    [self.stateLock unlock];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *fileName = fileURL.lastPathComponent;

    // 1. Validate file exists
    if (![fm fileExistsAtPath:fileURL.path]) {
        [self finishJobWithError:[NSString stringWithFormat:@"File '%@' does not exist.", fileName] folder:nil];
        return;
    }

    // 2. Validate file attributes and non-empty size (distinguish attribute error from empty file)
    NSError *attrErr = nil;
    NSDictionary *attrs = [fm attributesOfItemAtPath:fileURL.path error:&attrErr];
    if (!attrs) {
        [self finishJobWithError:[NSString stringWithFormat:@"Cannot read attributes for '%@': %@", fileName, attrErr.localizedDescription] folder:nil];
        return;
    }
    if ([attrs fileSize] == 0) {
        [self finishJobWithError:[NSString stringWithFormat:@"'%@' is empty (0 bytes).", fileName] folder:nil];
        return;
    }

    // 3. Binary header check for %PDF- within the first 1024 bytes (zero string-encoding dependency)
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:fileURL.path];
    if (!handle) {
        [self finishJobWithError:[NSString stringWithFormat:@"Cannot open '%@' for reading.", fileName] folder:nil];
        return;
    }
    NSData *initialBytes = [handle readDataOfLength:1024];
    [handle closeFile];

    const char *pdfMagic = "%PDF-";
    NSData *magicData = [NSData dataWithBytes:pdfMagic length:5];
    NSRange found = [initialBytes rangeOfData:magicData options:0 range:NSMakeRange(0, initialBytes.length)];
    if (found.location == NSNotFound) {
        [self finishJobWithError:[NSString stringWithFormat:@"'%@' is not a valid PDF (missing %%PDF- header).", fileName] folder:nil];
        return;
    }

    // 4. Create atomic unique folder on Desktop with Unicode-safe truncation
    NSURL *outputFolder = [self createUniqueOutputFolderForPDF:fileURL];
    if (!outputFolder) {
        [self finishJobWithError:[NSString stringWithFormat:@"Cannot create folder on Desktop for '%@'.", fileName] folder:nil];
        return;
    }

    // Register active folder for cancellation cleanup
    [self.stateLock lock];
    if (self.isCancelled) {
        [self cleanupFolder:outputFolder];
        [self.stateLock unlock];
        return;
    }
    [self.activeOutputFolders addObject:outputFolder];
    [self.stateLock unlock];

    // Inspect page count natively via CoreGraphics (0ms overhead)
    size_t pageCount = 0;
    CGPDFDocumentRef pdfDoc = CGPDFDocumentCreateWithURL((__bridge CFURLRef)fileURL);
    if (pdfDoc) {
        pageCount = CGPDFDocumentGetNumberOfPages(pdfDoc);
        CGPDFDocumentRelease(pdfDoc);
    }

    // Dynamic disk space estimate: 150 DPI ~ 2MB/page, 300 DPI ~ 4MB/page, 600 DPI ~ 15MB/page
    unsigned long long bytesPerPage = (dpi >= 600) ? (15ULL * 1024ULL * 1024ULL) : ((dpi >= 300) ? (4ULL * 1024ULL * 1024ULL) : (2ULL * 1024ULL * 1024ULL));
    unsigned long long estPages = (pageCount > 0) ? (unsigned long long)pageCount : 20ULL;
    unsigned long long requiredBytes = MAX(100ULL * 1024ULL * 1024ULL, estPages * bytesPerPage);

    NSDictionary *fsAttrs = [fm attributesOfFileSystemForPath:outputFolder.path error:nil];
    NSNumber *freeSpace = fsAttrs[NSFileSystemFreeSize];
    if (freeSpace && [freeSpace unsignedLongLongValue] < requiredBytes) {
        [self cleanupFolder:outputFolder];
        [self.stateLock lock];
        [self.activeOutputFolders removeObject:outputFolder];
        [self.stateLock unlock];
        double reqMB = (double)requiredBytes / (1024.0 * 1024.0);
        double availMB = (double)[freeSpace unsignedLongLongValue] / (1024.0 * 1024.0);
        [self finishJobWithError:[NSString stringWithFormat:@"'%@': Insufficient disk space (~%.0f MB required, %.0f MB available).", fileName, reqMB, availMB] folder:nil];
        return;
    }

    [self updateProgressStatus:[NSString stringWithFormat:@"Converting '%@'...", fileName]];

    // 5. Setup NSTask
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:pdftoppm];
    NSString *prefix = [outputFolder.path stringByAppendingPathComponent:@"rawpage"];
    task.arguments = @[@"-png", @"-r", [NSString stringWithFormat:@"%ld", (long)dpi], fileURL.path, prefix];

    // Discard stdout to /dev/null to avoid unused pipe deadlock
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];

    // Pipe stderr and drain asynchronously
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardError = stderrPipe;

    // Atomic launch & registration check to eliminate quit race condition
    [self.stateLock lock];
    if (self.isCancelled) {
        [self cleanupFolder:outputFolder];
        [self.activeOutputFolders removeObject:outputFolder];
        [self.stateLock unlock];
        return;
    }

    NSError *launchErr = nil;
    if (![task launchAndReturnError:&launchErr]) {
        [self cleanupFolder:outputFolder];
        [self.activeOutputFolders removeObject:outputFolder];
        [self.stateLock unlock];
        [self finishJobWithError:[NSString stringWithFormat:@"Launch failed for '%@': %@", fileName, launchErr.localizedDescription] folder:nil];
        return;
    }
    [self.activeTasks addObject:task];
    [self.stateLock unlock];

    // Drain stderr in background (capped at 64 KB to prevent memory exhaustion)
    __block NSData *stderrData = [NSData data];
    dispatch_group_t pipeGroup = dispatch_group_create();
    dispatch_group_enter(pipeGroup);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableData *accumulated = [NSMutableData data];
        NSFileHandle *readHandle = stderrPipe.fileHandleForReading;
        while (YES) {
            NSData *chunk = [readHandle readDataOfLength:4096];
            if (chunk.length == 0) break;
            if (accumulated.length < 65536) { // Cap at 64 KB
                [accumulated appendData:chunk];
            }
        }
        stderrData = accumulated;
        dispatch_group_leave(pipeGroup);
    });

    // Dynamic timeout: 300s baseline, plus 3s per page (e.g. 500 pages = ~25.5 minutes)
    NSTimeInterval timeoutSeconds = (pageCount > 0) ? MAX(300.0, 30.0 + ((double)pageCount * 3.0)) : 600.0;
    NSDate *timeoutDate = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    BOOL didTimeout = NO;
    while ([task isRunning]) {
        if ([[NSDate date] compare:timeoutDate] == NSOrderedDescending) {
            didTimeout = YES;
            [task terminate];
            for (int i = 0; i < 10 && task.isRunning; i++) {
                usleep(50000);
            }
            if (task.isRunning) {
                kill(task.processIdentifier, SIGKILL);
            }
            while (task.isRunning) {
                usleep(10000);
            }
            break;
        }
        usleep(100000); // 100ms polling
    }
    dispatch_group_wait(pipeGroup, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));

    if (didTimeout) {
        [self cleanupFolder:outputFolder];
        [self.stateLock lock];
        [self.activeTasks removeObject:task];
        [self.activeOutputFolders removeObject:outputFolder];
        [self.stateLock unlock];
        NSString *pageNote = (pageCount > 0) ? [NSString stringWithFormat:@" for %zu pages", pageCount] : @"";
        [self finishJobWithError:[NSString stringWithFormat:@"'%@': Conversion timed out (exceeded %.0f seconds%@).", fileName, timeoutSeconds, pageNote] folder:nil];
        return;
    }

    // Unregister task
    [self.stateLock lock];
    [self.activeTasks removeObject:task];
    BOOL wasCancelled = self.isCancelled;
    [self.stateLock unlock];

    if (wasCancelled) {
        [self cleanupFolder:outputFolder];
        [self.stateLock lock];
        [self.activeOutputFolders removeObject:outputFolder];
        [self.stateLock unlock];
        return;
    }

    int status = task.terminationStatus;
    NSString *stderrString = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";

    // Detailed Poppler exit code & stderr classification
    if (status != 0) {
        [self cleanupFolder:outputFolder];
        [self.stateLock lock];
        [self.activeOutputFolders removeObject:outputFolder];
        [self.stateLock unlock];

        NSString *errLower = [stderrString lowercaseString];
        NSString *firstLine = [self firstNonEmptyLine:stderrString];

        if ([errLower containsString:@"password"] || [errLower containsString:@"incorrect password"]) {
            [self finishJobWithError:[NSString stringWithFormat:@"'%@': Protected by password.", fileName] folder:nil];
        } else if ([errLower containsString:@"no space left on device"] || [errLower containsString:@"enospc"]) {
            [self finishJobWithError:[NSString stringWithFormat:@"'%@': Disk full — no space left on device to save converted images.", fileName] folder:nil];
        } else if (status == 3) {
            [self finishJobWithError:[NSString stringWithFormat:@"'%@': PDF permissions / security restriction prevented rendering.", fileName] folder:nil];
        } else if (status == 2 || [errLower containsString:@"permission denied"]) {
            [self finishJobWithError:[NSString stringWithFormat:@"'%@': Error writing output to Desktop (disk full or permissions).", fileName] folder:nil];
        } else if (status == 1) {
            NSString *detail = (firstLine.length > 0) ? firstLine : @"unsupported or unreadable PDF";
            [self finishJobWithError:[NSString stringWithFormat:@"'%@': Could not open PDF (%@).", fileName, detail] folder:nil];
        } else {
            NSString *detail = (firstLine.length > 0) ? firstLine : [NSString stringWithFormat:@"Poppler error (code %d)", status];
            [self finishJobWithError:[NSString stringWithFormat:@"'%@': %@", fileName, detail] folder:nil];
        }
        return;
    }

    // 6. Rename pages sequentially with strict error checking
    NSError *dirErr = nil;
    NSArray *dirContents = [fm contentsOfDirectoryAtURL:outputFolder includingPropertiesForKeys:nil options:0 error:&dirErr];
    if (!dirContents) {
        [self cleanupFolder:outputFolder];
        [self.stateLock lock];
        [self.activeOutputFolders removeObject:outputFolder];
        [self.stateLock unlock];
        [self finishJobWithError:[NSString stringWithFormat:@"Error reading output directory for '%@': %@", fileName, dirErr.localizedDescription] folder:nil];
        return;
    }

    NSMutableArray<NSURL *> *pngFiles = [NSMutableArray array];
    for (NSURL *item in dirContents) {
        if ([[item.pathExtension lowercaseString] isEqualToString:@"png"]) {
            [pngFiles addObject:item];
        }
    }

    if (pngFiles.count == 0) {
        [self cleanupFolder:outputFolder];
        [self.stateLock lock];
        [self.activeOutputFolders removeObject:outputFolder];
        [self.stateLock unlock];
        [self finishJobWithError:[NSString stringWithFormat:@"'%@': Document produced 0 pages.", fileName] folder:nil];
        return;
    }

    // Natural numeric sort
    [pngFiles sortUsingComparator:^NSComparisonResult(NSURL *url1, NSURL *url2) {
        return [url1.lastPathComponent compare:url2.lastPathComponent options:NSNumericSearch];
    }];

    // Execute renames and check every operation
    BOOL renameFailed = NO;
    NSString *renameErrorMsg = nil;
    for (NSUInteger i = 0; i < pngFiles.count; i++) {
        NSURL *source = pngFiles[i];
        NSString *newName = [NSString stringWithFormat:@"page_%lu.png", (unsigned long)(i + 1)];
        NSURL *destination = [outputFolder URLByAppendingPathComponent:newName];
        NSError *moveErr = nil;
        if (![fm moveItemAtURL:source toURL:destination error:&moveErr]) {
            renameFailed = YES;
            renameErrorMsg = moveErr.localizedDescription;
            break;
        }
    }

    if (renameFailed) {
        [self cleanupFolder:outputFolder];
        [self.stateLock lock];
        [self.activeOutputFolders removeObject:outputFolder];
        [self.stateLock unlock];
        [self finishJobWithError:[NSString stringWithFormat:@"Error renaming pages for '%@': %@", fileName, renameErrorMsg] folder:nil];
        return;
    }

    // Unregister from active list now that it is completed and safe
    [self.stateLock lock];
    [self.activeOutputFolders removeObject:outputFolder];
    [self.stateLock unlock];

    [self finishJobWithSuccess:outputFolder pageCount:pngFiles.count fileName:fileName];
}

- (NSURL *)createUniqueOutputFolderForPDF:(NSURL *)pdfURL {
    [self.stateLock lock];
    @try {
        NSString *rawBaseName = [pdfURL.URLByDeletingPathExtension lastPathComponent];
        // Unicode-safe grapheme cluster truncation (max 180 UTF-8 bytes to stay safely under APFS 255-byte limit)
        NSString *safeBaseName = [self safelyTruncatedBaseName:rawBaseName maxUTF8Bytes:180];

        NSURL *desktop = [[NSFileManager defaultManager] URLsForDirectory:NSDesktopDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *imagesDir = [desktop URLByAppendingPathComponent:@"images"];
        NSFileManager *fm = [NSFileManager defaultManager];

        // Ensure ~/Desktop/images directory exists
        if (![fm fileExistsAtPath:imagesDir.path]) {
            NSError *imgDirErr = nil;
            if (![fm createDirectoryAtURL:imagesDir withIntermediateDirectories:YES attributes:nil error:&imgDirErr]) {
                NSLog(@"[PDF to Images] Error creating ~/Desktop/images directory: %@", imgDirErr.localizedDescription);
                return nil;
            }
        }

        NSURL *candidate = [imagesDir URLByAppendingPathComponent:safeBaseName];
        NSInteger counter = 1;
        while ([fm fileExistsAtPath:candidate.path]) {
            candidate = [imagesDir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ (%ld)", safeBaseName, (long)counter]];
            counter++;
        }
        NSError *err = nil;
        if ([fm createDirectoryAtURL:candidate withIntermediateDirectories:YES attributes:nil error:&err]) {
            return candidate;
        }
        return nil;
    } @finally {
        [self.stateLock unlock];
    }
}

- (NSString *)safelyTruncatedBaseName:(NSString *)rawBaseName maxUTF8Bytes:(NSUInteger)maxBytes {
    NSData *data = [rawBaseName dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length <= maxBytes) {
        return rawBaseName;
    }
    NSMutableString *truncated = [NSMutableString string];
    [rawBaseName enumerateSubstringsInRange:NSMakeRange(0, rawBaseName.length)
                                    options:NSStringEnumerationByComposedCharacterSequences
                                 usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
        NSString *candidate = [truncated stringByAppendingString:substring];
        if ([candidate lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > maxBytes) {
            *stop = YES;
        } else {
            [truncated appendString:substring];
        }
    }];
    return (truncated.length > 0) ? truncated : @"Document";
}

- (void)cleanupFolder:(NSURL *)url {
    NSError *err = nil;
    if (![[NSFileManager defaultManager] removeItemAtURL:url error:&err]) {
        NSLog(@"[PDF to Images] Warning: Could not remove partial folder %@: %@", url.path, err.localizedDescription);
    }
}

- (void)finishJobWithSuccess:(NSURL *)outputFolder pageCount:(NSUInteger)pages fileName:(NSString *)name {
    [self.stateLock lock];
    self.pendingBatchJobs--;
    self.successCount++;
    self.latestBatchFolder = outputFolder;
    BOOL allDone = (self.pendingBatchJobs <= 0);
    NSInteger total = self.totalBatchJobs;
    NSInteger succeeded = self.successCount;
    NSInteger failed = self.failureCount;
    NSURL *folder = self.latestBatchFolder;
    if (allDone) {
        self.totalBatchJobs = 0;
        self.pendingBatchJobs = 0;
        self.successCount = 0;
        self.failureCount = 0;
        // Notice: latestBatchFolder is retained for the completed batch so Show in Finder works
    }
    [self.stateLock unlock];

    if (allDone) {
        NSString *msg;
        if (total == 1) {
            msg = [NSString stringWithFormat:@"Done! '%@' -> %lu pages saved to Desktop/images/%@", name, (unsigned long)pages, folder.lastPathComponent];
        } else {
            msg = [NSString stringWithFormat:@"Finished batch: %ld succeeded, %ld failed. Last: Desktop/images/%@", (long)succeeded, (long)failed, folder.lastPathComponent];
        }
        [self notifyUI:msg inProgress:NO folder:folder];
    } else {
        NSString *msg = [NSString stringWithFormat:@"Finished '%@' (%lu pages). Continuing batch...", name, (unsigned long)pages];
        [self notifyUI:msg inProgress:YES folder:folder];
    }
}

- (void)finishJobWithError:(NSString *)errMsg folder:(NSURL *)folder {
    [self.stateLock lock];
    self.pendingBatchJobs--;
    self.failureCount++;
    BOOL allDone = (self.pendingBatchJobs <= 0);
    NSInteger succeeded = self.successCount;
    NSInteger failed = self.failureCount;
    // CRITICAL: If all jobs in this batch failed (succeeded == 0), folderToReport MUST be nil so stale folders from previous batches are never passed!
    NSURL *folderToReport = (succeeded > 0) ? self.latestBatchFolder : nil;
    if (allDone) {
        self.totalBatchJobs = 0;
        self.pendingBatchJobs = 0;
        self.successCount = 0;
        self.failureCount = 0;
        self.latestBatchFolder = nil;
    }
    [self.stateLock unlock];

    if (allDone) {
        NSString *msg = (succeeded > 0) ? [NSString stringWithFormat:@"Batch done: %ld succeeded, %ld failed. Last: Desktop/images/%@", (long)succeeded, (long)failed, folderToReport.lastPathComponent] : [NSString stringWithFormat:@"Batch failed: %@", errMsg];
        [self notifyUI:msg inProgress:NO folder:folderToReport];
    } else {
        [self notifyUI:[NSString stringWithFormat:@"%@ Continuing batch...", errMsg] inProgress:YES folder:nil];
    }
}

- (void)updateProgressStatus:(NSString *)status {
    [self.stateLock lock];
    NSInteger pending = self.pendingBatchJobs;
    NSInteger total = self.totalBatchJobs;
    [self.stateLock unlock];

    NSString *formatted = (total > 1) ? [NSString stringWithFormat:@"[%ld remaining] %@", (long)pending, status] : status;
    [self notifyUI:formatted inProgress:YES folder:nil];
}

- (void)notifyUI:(NSString *)msg inProgress:(BOOL)inProgress folder:(NSURL *)folder {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onBatchProgress) {
            self.onBatchProgress(msg, inProgress, folder);
        }
    });
}

- (NSString *)firstNonEmptyLine:(NSString *)str {
    NSArray *lines = [str componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length > 0) return trimmed;
    }
    return @"";
}

@end

// MARK: - Drop Zone View
@interface DropZoneView : NSView
@property (nonatomic, copy) void (^onFilesDropped)(NSArray<NSURL *> *validPDFs, NSInteger skippedCount);
@property (nonatomic, assign) BOOL isHighlighted;
@end

@implementation DropZoneView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect bounds = NSInsetRect(self.bounds, 10, 10);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:12 yRadius:12];
    path.lineWidth = self.isHighlighted ? 3.0 : 1.5;
    CGFloat dash[2] = {6.0, 4.0};
    [path setLineDash:dash count:2 phase:0.0];

    if (self.isHighlighted) {
        [[[NSColor controlAccentColor] colorWithAlphaComponent:0.12] setFill];
        [path fill];
        [[NSColor controlAccentColor] setStroke];
    } else {
        [[NSColor quaternaryLabelColor] setStroke];
    }
    [path stroke];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard *pboard = [sender draggingPasteboard];
    NSArray *items = [pboard readObjectsForClasses:@[[NSURL class]] options:nil];
    for (NSURL *url in items) {
        if ([[url.pathExtension lowercaseString] isEqualToString:@"pdf"]) {
            self.isHighlighted = YES;
            self.needsDisplay = YES;
            return NSDragOperationCopy;
        }
    }
    return NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    self.isHighlighted = NO;
    self.needsDisplay = YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    self.isHighlighted = NO;
    self.needsDisplay = YES;

    NSPasteboard *pboard = [sender draggingPasteboard];
    NSArray *items = [pboard readObjectsForClasses:@[[NSURL class]] options:nil];
    NSMutableArray<NSURL *> *validPDFs = [NSMutableArray array];
    NSInteger skipped = 0;

    for (NSURL *url in items) {
        if ([[url.pathExtension lowercaseString] isEqualToString:@"pdf"]) {
            [validPDFs addObject:url];
        } else {
            skipped++;
        }
    }

    if (self.onFilesDropped) {
        self.onFilesDropped(validPDFs, skipped);
    }
    return YES;
}

@end

// MARK: - Main Window Controller
@interface MainWindowController : NSWindowController <NSWindowDelegate>
@property (nonatomic, strong) DropZoneView *dropZone;
@property (nonatomic, strong) NSSegmentedControl *dpiControl;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) NSButton *showFinderButton;
@property (nonatomic, strong) NSURL *latestFolder;
- (void)handleFiles:(NSArray<NSURL *> *)urls skippedCount:(NSInteger)skipped;
- (void)browseFiles:(id)sender;
@end

@implementation MainWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, 370)
                                                   styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"PDF to Images";
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        window.delegate = self;
        [self setupUIInWindow:window];
        [self setupBindings];
    }
    return self;
}

- (void)windowWillClose:(NSNotification *)notification {
    [[JobManager shared] cancelAll];
    [NSApp terminate:self];
}

- (void)setupUIInWindow:(NSWindow *)window {
    NSView *contentView = window.contentView;

    // Dropzone
    _dropZone = [[DropZoneView alloc] initWithFrame:NSMakeRect(20, 140, 420, 180)];
    [contentView addSubview:_dropZone];

    // Icon
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(185, 95, 50, 50)];
    NSImage *docImg = [NSImage imageWithSystemSymbolName:@"doc.viewfinder" accessibilityDescription:@"Drop PDF"];
    if (docImg) {
        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:40 weight:NSFontWeightRegular];
        icon.image = [docImg imageWithSymbolConfiguration:cfg];
        icon.contentTintColor = [NSColor secondaryLabelColor];
    }
    [_dropZone addSubview:icon];

    // Titles
    NSTextField *title = [NSTextField labelWithString:@"Drag & Drop PDFs Here"];
    title.frame = NSMakeRect(10, 65, 400, 22);
    title.alignment = NSTextAlignmentCenter;
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    [_dropZone addSubview:title];

    NSTextField *sub = [NSTextField labelWithString:@"Saves neat numbered folders to Desktop/images/"];
    sub.frame = NSMakeRect(10, 44, 400, 18);
    sub.alignment = NSTextAlignmentCenter;
    sub.font = [NSFont systemFontOfSize:12];
    sub.textColor = [NSColor secondaryLabelColor];
    [_dropZone addSubview:sub];

    NSButton *browse = [NSButton buttonWithTitle:@"Choose PDF..." target:self action:@selector(browseFiles:)];
    browse.frame = NSMakeRect(160, 12, 100, 26);
    browse.bezelStyle = NSBezelStyleRounded;
    [_dropZone addSubview:browse];

    // DPI Selector
    NSTextField *dpiLabel = [NSTextField labelWithString:@"Resolution:"];
    dpiLabel.frame = NSMakeRect(24, 102, 85, 20);
    dpiLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    [contentView addSubview:dpiLabel];

    _dpiControl = [NSSegmentedControl segmentedControlWithLabels:@[@"150 DPI (Screen)", @"300 DPI (Print)", @"600 DPI (Ultra)"]
                                                    trackingMode:NSSegmentSwitchTrackingSelectOne
                                                          target:nil
                                                          action:nil];
    _dpiControl.frame = NSMakeRect(115, 98, 325, 24);
    _dpiControl.selectedSegment = 1; // Default 300 DPI
    [contentView addSubview:_dpiControl];

    // Status Label
    _statusLabel = [NSTextField labelWithString:@"Ready. Drop one or more PDFs to begin."];
    _statusLabel.frame = NSMakeRect(24, 50, 412, 40);
    _statusLabel.font = [NSFont systemFontOfSize:12];
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    _statusLabel.maximumNumberOfLines = 2;
    [contentView addSubview:_statusLabel];

    // Spinner
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(24, 32, 412, 12)];
    _spinner.indeterminate = YES;
    _spinner.style = NSProgressIndicatorStyleBar;
    _spinner.hidden = YES;
    [contentView addSubview:_spinner];

    // Show Finder button
    _showFinderButton = [NSButton buttonWithTitle:@"Show in Finder" target:self action:@selector(openInFinder:)];
    _showFinderButton.frame = NSMakeRect(305, 8, 135, 24);
    _showFinderButton.bezelStyle = NSBezelStyleRounded;
    _showFinderButton.hidden = YES;
    [contentView addSubview:_showFinderButton];
}

- (void)setupBindings {
    __weak typeof(self) weakSelf = self;
    _dropZone.onFilesDropped = ^(NSArray<NSURL *> *validPDFs, NSInteger skippedCount) {
        [weakSelf handleFiles:validPDFs skippedCount:skippedCount];
    };

    [JobManager shared].onBatchProgress = ^(NSString *msg, BOOL inProgress, NSURL *finishedFolder) {
        weakSelf.statusLabel.stringValue = msg;
        if (inProgress) {
            weakSelf.spinner.hidden = NO;
            [weakSelf.spinner startAnimation:nil];
            weakSelf.showFinderButton.hidden = YES;
        } else {
            weakSelf.spinner.hidden = YES;
            [weakSelf.spinner stopAnimation:nil];
            if (finishedFolder) {
                weakSelf.latestFolder = finishedFolder;
                weakSelf.showFinderButton.hidden = NO;
            } else {
                weakSelf.latestFolder = nil;
                weakSelf.showFinderButton.hidden = YES;
            }
        }
    };
}

- (void)browseFiles:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypePDF];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = NO;
    panel.message = @"Select PDF files to convert to images";

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSModalResponseOK) {
            [self handleFiles:panel.URLs skippedCount:0];
        }
    }];
}

- (void)handleFiles:(NSArray<NSURL *> *)urls skippedCount:(NSInteger)skipped {
    // Reset any stale folder reference immediately on new batch
    self.latestFolder = nil;
    self.showFinderButton.hidden = YES;

    if (urls.count == 0) {
        if (skipped > 0) {
            self.statusLabel.stringValue = [NSString stringWithFormat:@"Skipped %ld file(s): Only .pdf files are supported.", (long)skipped];
        }
        return;
    }

    NSInteger dpi = 300;
    if (self.dpiControl.selectedSegment == 0) dpi = 150;
    if (self.dpiControl.selectedSegment == 2) dpi = 600;

    self.spinner.hidden = NO;
    [self.spinner startAnimation:nil];

    if (skipped > 0) {
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Enqueuing %lu PDF(s) (skipped %ld non-PDF files)...", (unsigned long)urls.count, (long)skipped];
    } else {
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Enqueuing %lu PDF document(s)...", (unsigned long)urls.count];
    }

    [[JobManager shared] enqueueURLs:urls dpi:dpi];
}

- (void)openInFinder:(id)sender {
    if (self.latestFolder) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[self.latestFolder]];
    }
}

@end

// MARK: - App Delegate & Menu Setup
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) MainWindowController *windowController;
@end

@implementation AppDelegate

- (void)setupMenuBar {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    // Application Menu
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"PDF to Images"];
    [appMenu addItemWithTitle:@"About PDF to Images" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide PDF to Images" action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *hideOthers = [[NSMenuItem alloc] initWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
    [appMenu addItem:hideOthers];
    [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit PDF to Images" action:@selector(terminate:) keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;
    [mainMenu addItem:appMenuItem];

    // File Menu (Provides Cmd+W, Cmd+O)
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Open PDF..." action:@selector(browseFilesFromMenu:) keyEquivalent:@"o"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    fileMenuItem.submenu = fileMenu;
    [mainMenu addItem:fileMenuItem];

    [NSApp setMainMenu:mainMenu];
}

- (void)browseFilesFromMenu:(id)sender {
    [self.windowController browseFiles:sender];
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    [self setupMenuBar];
    [PopplerLocator prewarmCache];
    if (!self.windowController) {
        self.windowController = [[MainWindowController alloc] init];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if (!self.windowController) {
        self.windowController = [[MainWindowController alloc] init];
    }
    [self.windowController showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSInteger skipped = 0;
    for (NSString *fn in filenames) {
        if ([[fn.pathExtension lowercaseString] isEqualToString:@"pdf"]) {
            [urls addObject:[NSURL fileURLWithPath:fn]];
        } else {
            skipped++;
        }
    }
    if (!self.windowController) {
        self.windowController = [[MainWindowController alloc] init];
        [self.windowController showWindow:nil];
    }
    [self.windowController handleFiles:urls skippedCount:skipped];
    [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    NSMutableArray<NSURL *> *pdfs = [NSMutableArray array];
    NSInteger skipped = 0;
    for (NSURL *u in urls) {
        if ([[u.pathExtension lowercaseString] isEqualToString:@"pdf"]) {
            [pdfs addObject:u];
        } else {
            skipped++;
        }
    }
    if (!self.windowController) {
        self.windowController = [[MainWindowController alloc] init];
        [self.windowController showWindow:nil];
    }
    [self.windowController handleFiles:pdfs skippedCount:skipped];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [[JobManager shared] cancelAll];
}

@end

#ifndef TESTING_RUNNER
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
#endif
