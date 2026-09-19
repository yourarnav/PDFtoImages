#define TESTING_RUNNER 1
#import "../Sources/main.m"

static BOOL waitForSemaphoreWithTimeout(dispatch_semaphore_t sema, NSTimeInterval timeoutSeconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        if ([deadline timeIntervalSinceNow] <= 0) {
            return NO;
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return YES;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"[Integration Test] Starting JobManager & Core Conversion Tests...");
        [NSApplication sharedApplication]; // Initialize NSApp for runloops

        NSString *testDir = @"build/test_core_workspace";
        [[NSFileManager defaultManager] removeItemAtPath:testDir error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:testDir withIntermediateDirectories:YES attributes:nil error:nil];

        // 1. Create 12-page minimal valid PDF
        NSString *multiPdfPath = [testDir stringByAppendingPathComponent:@"multi_12.pdf"];
        NSMutableString *pdfBody = [NSMutableString stringWithString:@"%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n"];
        [pdfBody appendString:@"2 0 obj << /Type /Pages /Kids ["];
        for (int i = 0; i < 12; i++) {
            [pdfBody appendFormat:@"%d 0 R ", 3 + i * 2];
        }
        [pdfBody appendString:@"] /Count 12 >> endobj\n"];
        for (int i = 0; i < 12; i++) {
            int pageObj = 3 + i * 2;
            int streamObj = 4 + i * 2;
            [pdfBody appendFormat:@"%d 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents %d 0 R >> endobj\n", pageObj, streamObj];
            [pdfBody appendFormat:@"%d 0 obj << /Length 0 >> stream\nendstream\nendobj\n", streamObj];
        }
        [pdfBody appendString:@"xref\n0 27\n0000000000 65535 f \ntrailer << /Size 27 /Root 1 0 R >>\nstartxref\n9\n%%EOF\n"];
        [pdfBody writeToFile:multiPdfPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // 2. Create special characters PDF
        NSString *specialPdfPath = [testDir stringByAppendingPathComponent:@"Doc [2026] 📊.pdf"];
        [pdfBody writeToFile:specialPdfPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // 3. Create fake PDF
        NSString *fakePdfPath = [testDir stringByAppendingPathComponent:@"fake.pdf"];
        [@"This is plain text pretending to be a PDF" writeToFile:fakePdfPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // 4. Create zero byte PDF
        NSString *emptyPdfPath = [testDir stringByAppendingPathComponent:@"empty.pdf"];
        [[NSData data] writeToFile:emptyPdfPath atomically:YES];

        __block BOOL testPassed = YES;
        NSMutableArray<NSURL *> *createdFolders = [NSMutableArray array];

        // TEST 1: Multi-page 12 conversion & natural sorting
        {
            NSLog(@"→ Test 1: Exercising JobManager with 12-page PDF...");
            dispatch_semaphore_t sema = dispatch_semaphore_create(0);
            __block NSURL *resultFolder = nil;
            __block NSString *lastMsg = nil;

            JobManager *mgr = [JobManager shared];
            mgr.onBatchProgress = ^(NSString *msg, BOOL inProgress, NSURL *latestFolder) {
                lastMsg = msg;
                if (!inProgress) {
                    resultFolder = latestFolder;
                    dispatch_semaphore_signal(sema);
                }
            };

            [mgr enqueueURLs:@[[NSURL fileURLWithPath:multiPdfPath]] dpi:150];

            if (!waitForSemaphoreWithTimeout(sema, 60.0)) {
                NSLog(@"✗ Test 1 Failed: Timed out waiting for JobManager to finish (60s deadline).");
                return 1;
            }

            if (!resultFolder) {
                NSLog(@"✗ Test 1 Failed: Batch did not return an output folder. Last msg: %@", lastMsg);
                return 1;
            }
            [createdFolders addObject:resultFolder];

            // Verify sequential files page_1.png ... page_12.png exist
            NSFileManager *fm = [NSFileManager defaultManager];
            for (int p = 1; p <= 12; p++) {
                NSString *pageName = [NSString stringWithFormat:@"page_%d.png", p];
                NSURL *pageURL = [resultFolder URLByAppendingPathComponent:pageName];
                if (![fm fileExistsAtPath:pageURL.path]) {
                    NSLog(@"✗ Test 1 Failed: Missing sequential file %@", pageName);
                    return 1;
                }
            }
            NSLog(@"  ✓ Test 1 Passed: Generated and naturally renamed all 12 sequential pages (page_1.png ... page_12.png).");
        }

        // TEST 2: Special characters / emoji path handling
        {
            NSLog(@"→ Test 2: Exercising JobManager with special characters/emoji filename...");
            dispatch_semaphore_t sema = dispatch_semaphore_create(0);
            __block NSURL *resultFolder = nil;

            JobManager *mgr = [JobManager shared];
            mgr.onBatchProgress = ^(NSString *msg, BOOL inProgress, NSURL *latestFolder) {
                if (!inProgress) {
                    resultFolder = latestFolder;
                    dispatch_semaphore_signal(sema);
                }
            };

            [mgr enqueueURLs:@[[NSURL fileURLWithPath:specialPdfPath]] dpi:150];

            if (!waitForSemaphoreWithTimeout(sema, 60.0)) {
                NSLog(@"✗ Test 2 Failed: Timed out waiting for JobManager to finish (60s deadline).");
                return 1;
            }

            if (!resultFolder) {
                NSLog(@"✗ Test 2 Failed: Special characters PDF failed conversion.");
                return 1;
            }
            [createdFolders addObject:resultFolder];
            NSLog(@"  ✓ Test 2 Passed: Successfully converted unicode/emoji filename into folder: %@", resultFolder.lastPathComponent);
        }

        // TEST 3: Fake PDF rejection (magic bytes check)
        {
            NSLog(@"→ Test 3: Testing non-PDF rejection...");
            dispatch_semaphore_t sema = dispatch_semaphore_create(0);
            __block NSString *errMsg = nil;
            __block NSURL *resultFolder = nil;

            JobManager *mgr = [JobManager shared];
            mgr.onBatchProgress = ^(NSString *msg, BOOL inProgress, NSURL *latestFolder) {
                if (!inProgress) {
                    errMsg = msg;
                    resultFolder = latestFolder;
                    dispatch_semaphore_signal(sema);
                }
            };

            [mgr enqueueURLs:@[[NSURL fileURLWithPath:fakePdfPath]] dpi:150];

            if (!waitForSemaphoreWithTimeout(sema, 60.0)) {
                NSLog(@"✗ Test 3 Failed: Timed out waiting for JobManager to finish (60s deadline).");
                return 1;
            }

            if (resultFolder != nil || ![errMsg containsString:@"missing %PDF- header"]) {
                NSLog(@"✗ Test 3 Failed: Fake PDF was not correctly rejected: %@", errMsg);
                return 1;
            }
            NSLog(@"  ✓ Test 3 Passed: Fake PDF correctly rejected: %@", errMsg);
        }

        // TEST 4: Zero-byte file rejection
        {
            NSLog(@"→ Test 4: Testing zero-byte file rejection...");
            dispatch_semaphore_t sema = dispatch_semaphore_create(0);
            __block NSString *errMsg = nil;
            __block NSURL *resultFolder = nil;

            JobManager *mgr = [JobManager shared];
            mgr.onBatchProgress = ^(NSString *msg, BOOL inProgress, NSURL *latestFolder) {
                if (!inProgress) {
                    errMsg = msg;
                    resultFolder = latestFolder;
                    dispatch_semaphore_signal(sema);
                }
            };

            [mgr enqueueURLs:@[[NSURL fileURLWithPath:emptyPdfPath]] dpi:150];

            if (!waitForSemaphoreWithTimeout(sema, 60.0)) {
                NSLog(@"✗ Test 4 Failed: Timed out waiting for JobManager to finish (60s deadline).");
                return 1;
            }

            if (resultFolder != nil || ![errMsg containsString:@"is empty"]) {
                NSLog(@"✗ Test 4 Failed: Zero-byte PDF was not correctly rejected: %@", errMsg);
                return 1;
            }
            NSLog(@"  ✓ Test 4 Passed: Empty file correctly rejected: %@", errMsg);
        }

        // Cleanup created test folders
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSURL *f in createdFolders) {
            [fm removeItemAtURL:f error:nil];
        }
        [fm removeItemAtPath:testDir error:nil];

        NSLog(@"\n=== All 4 Core JobManager Tests Passed with 100%% Success! ===");
        return 0;
    }
}
