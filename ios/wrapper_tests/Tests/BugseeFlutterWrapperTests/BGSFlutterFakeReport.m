#import "BGSFlutterFakeReport.h"

static void Unmodeled(SEL selector) {
  [NSException raise:NSInternalInconsistencyException
              format:@"BGSFlutterFakeReport does not model %@", NSStringFromSelector(selector)];
}

@implementation BGSFlutterFakeReport

- (instancetype)init {
  self = [super init];
  if (self) {
    _fakeReportId = @"report-1";
    _fakeType = @"bug";
    _fakeLabels = [NSMutableArray array];
    _fakeAttributes = [NSMutableDictionary dictionary];
    _mutations = [NSMutableArray array];
  }
  return self;
}

- (void)record:(SEL)selector {
  @synchronized(self) {
    [_mutations addObject:NSStringFromSelector(selector)];
  }
}

#pragma mark - Modelled

- (NSString *)reportId {
  _reads++;
  return _fakeReportId;
}
- (NSString *)type {
  _reads++;
  return _fakeType;
}

- (NSString *)summary { return _fakeSummary; }
- (void)setSummary:(NSString *)summary {
  [self record:_cmd];
  if (_beforeSetSummary != nil) {
    _beforeSetSummary();
  }
  _fakeSummary = [summary copy];
  if (_onSummarySet != nil) {
    _onSummarySet();
  }
}

- (NSString *)reportDescription { return _fakeDescription; }
- (void)setReportDescription:(NSString *)reportDescription {
  [self record:_cmd];
  _fakeDescription = [reportDescription copy];
}

- (NSString *)email { return _fakeEmail; }
- (void)setEmail:(NSString *)email {
  [self record:_cmd];
  _fakeEmail = [email copy];
}

- (BugseeSeverityLevel)severity { return _fakeSeverity; }
- (void)setSeverity:(BugseeSeverityLevel)severity {
  [self record:_cmd];
  // The SDK's own refusal: out of range keeps the current value, silently.
  if (severity >= BugseeSeverityLow && severity <= BugseeSeverityBlocker) {
    _fakeSeverity = severity;
  }
}

- (NSMutableArray<NSString *> *)labels { return [_fakeLabels mutableCopy]; }
- (void)addLabel:(NSString *)label {
  [self record:_cmd];
  [_fakeLabels addObject:label];
}
- (void)addLabels:(NSArray<NSString *> *)labels {
  [self record:_cmd];
  [_fakeLabels addObjectsFromArray:labels];
}
- (void)clearLabels {
  [self record:_cmd];
  [_fakeLabels removeAllObjects];
}
- (void)replaceLabels:(NSArray<NSString *> *)labels {
  [self record:_cmd];
  [_fakeLabels setArray:labels];
}

- (NSMutableDictionary<NSString *, id> *)attributes { return [_fakeAttributes mutableCopy]; }
- (id)attributeForName:(NSString *)name { return _fakeAttributes[name]; }
- (void)setAttribute:(id)value forName:(NSString *)name {
  [self record:_cmd];
  _fakeAttributes[name] = value;
}
- (void)removeAttributeForName:(NSString *)name {
  [self record:_cmd];
  [_fakeAttributes removeObjectForKey:name];
}
- (void)clearAllAttributes {
  [self record:_cmd];
  [_fakeAttributes removeAllObjects];
}

#pragma mark - Not modelled

- (NSMutableArray<id<BGSAttachmentContract>> *)attachments { Unmodeled(_cmd); return nil; }
- (NSArray<NSNumber *> *)screenshotDisplayIds { Unmodeled(_cmd); return nil; }
- (id<BGSAttachmentContract>)createAndAddAttachmentWithName:(NSString *)name { Unmodeled(_cmd); return nil; }
- (void)addAttachment:(id<BGSAttachmentContract>)attachment { Unmodeled(_cmd); }
- (id<BGSAttachmentContract>)addAttachmentWithFilePath:(NSString *)filePath name:(NSString *)name mimeType:(NSString *)mimeType move:(BOOL)move { Unmodeled(_cmd); return nil; }
- (id<BGSAttachmentContract>)addAttachmentWithData:(NSData *)data name:(NSString *)name mimeType:(NSString *)mimeType { Unmodeled(_cmd); return nil; }
- (void)clearAttachments { Unmodeled(_cmd); }
- (void)getScreenshotForDisplayId:(NSInteger)displayId completion:(void (^)(UIImage *))completion { Unmodeled(_cmd); }
- (void)enumerateScreenshots:(void (^)(NSInteger, UIImage *))callback blockAndWait:(BOOL)blockAndWait { Unmodeled(_cmd); }
- (void)releaseScreenshotBitmaps { Unmodeled(_cmd); }
- (void)setScreenshot:(UIImage *)screenshot displayId:(NSInteger)displayId annotated:(BOOL)annotated completion:(BGSCallback)completion { Unmodeled(_cmd); }
- (void)setScreenshot:(UIImage *)screenshot displayId:(NSInteger)displayId { Unmodeled(_cmd); }
- (void)setScreenshot:(UIImage *)screenshot displayId:(NSInteger)displayId completion:(BGSCallback)completion { Unmodeled(_cmd); }
- (void)setScreenshot:(UIImage *)screenshot displayId:(NSInteger)displayId annotated:(BOOL)annotated { Unmodeled(_cmd); }
- (NSDictionary<NSString *, id> *)screenshotAttributesForDisplayId:(NSInteger)displayId { Unmodeled(_cmd); return nil; }
- (BOOL)isScreenshotChanged { Unmodeled(_cmd); return NO; }
- (void)updateFromReport:(id<BGSReportContract>)report { Unmodeled(_cmd); }
- (void)updateFromReport:(id<BGSReportContract>)report completion:(BGSCallback)completion { Unmodeled(_cmd); }
- (void)exportVideoToPath:(NSString *)exportPath completion:(void (^)(NSArray<NSString *> *))completion { Unmodeled(_cmd); }

@end
