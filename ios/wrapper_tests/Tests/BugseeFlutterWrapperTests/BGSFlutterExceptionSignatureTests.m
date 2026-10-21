#import <XCTest/XCTest.h>

#import "BGSFlutterExceptionOps.h"

@import Bugsee;

/// The SDK's OWN signature code (`BGSExceptionSignature`, which `+logException:reason:...` feeds with the
/// exception's name, reason and frames, and which reads the `signature` KEY of a JSON reason) fed with
/// the documents of `test/fixtures/exceptions/signature_cases.json`: a1 and a2 are one Dart error on two
/// days, b another. The frames of an `NSException` the SDK builds from a name and a reason are empty,
/// so without the document's `signature` every Dart error would have ONE signature: the server matches
/// issues on it before the worker looks at the document, drops what it has too many of and tells the
/// device to blacklist a signature for good.
@interface BGSFlutterExceptionSignatureTests : XCTestCase
@end

@implementation BGSFlutterExceptionSignatureTests

- (NSDictionary<NSString *, NSString *> *)documents {
  NSString *path = [[[@(__FILE__) stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"../../../../test/fixtures/exceptions/signature_cases.json"]
      stringByStandardizingPath];
  NSData *data = [NSData dataWithContentsOfFile:path];
  XCTAssertNotNil(data, @"%@", path);
  return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL][@"documents"];
}

/// `+[BGSExceptionSignature signatureForExceptionName:reason:frames:skipFrames:]`, found at run time
/// (the class is private to the framework).
- (NSString *)sdkSignatureForReason:(NSString *)reason {
  Class cls = NSClassFromString(@"BGSExceptionSignature");
  XCTAssertNotNil(cls, @"the SDK's signature class is gone: look at how the SDK hashes exceptions now");
  SEL selector = NSSelectorFromString(@"signatureForExceptionName:reason:frames:skipFrames:");
  XCTAssertTrue([cls respondsToSelector:selector], @"the SDK's signature method is gone");
  NSMethodSignature *method = [cls methodSignatureForSelector:selector];
  NSInvocation *call = [NSInvocation invocationWithMethodSignature:method];
  call.target = cls;
  call.selector = selector;
  NSString *name = BGSFlutterExceptionOps.exceptionName;
  NSArray *frames = @[];
  int skip = 0;
  [call setArgument:&name atIndex:2];
  [call setArgument:&reason atIndex:3];
  [call setArgument:&frames atIndex:4];
  [call setArgument:&skip atIndex:5];
  [call invoke];
  __unsafe_unretained NSString *result = nil;
  [call getReturnValue:&result];
  return result;
}

- (NSString *)reasonWithoutSignature:(NSString *)document {
  NSMutableDictionary *json = [[NSJSONSerialization JSONObjectWithData:[document dataUsingEncoding:NSUTF8StringEncoding]
                                                               options:0
                                                                 error:NULL] mutableCopy];
  [json removeObjectForKey:@"signature"];
  NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)testEqualErrorsShareTheSdkSignatureAndDifferentOnesDoNot {
  NSDictionary *docs = [self documents];
  NSString *a1 = [self sdkSignatureForReason:docs[@"a1"]];
  NSString *a2 = [self sdkSignatureForReason:docs[@"a2"]];
  NSString *b = [self sdkSignatureForReason:docs[@"b"]];
  XCTAssertEqual(a1.length, 40u);
  XCTAssertEqualObjects(a1, a2, @"one error on two days is one signature");
  XCTAssertNotEqualObjects(a1, b, @"another error is another signature");
}

- (void)testWithoutTheDocumentsSignatureEveryDartErrorWouldShareOne {
  NSDictionary *docs = [self documents];
  NSString *a1 = [self sdkSignatureForReason:[self reasonWithoutSignature:docs[@"a1"]]];
  NSString *b = [self sdkSignatureForReason:[self reasonWithoutSignature:docs[@"b"]]];
  XCTAssertEqualObjects(a1, b);
}

- (void)testTheDocumentsSignatureIsAStringKeyAtTheTopLevel {
  for (NSString *document in [[self documents] allValues]) {
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[document dataUsingEncoding:NSUTF8StringEncoding]
                                                         options:0
                                                           error:NULL];
    XCTAssertTrue([json[@"signature"] isKindOfClass:[NSString class]]);
    XCTAssertEqual([json[@"signature"] length], 40u);
  }
}

@end
