#import <Contacts/Contacts.h>

NS_ASSUME_NONNULL_BEGIN

/// The contacts added or changed, and the identifiers deleted, since `token`
/// (a `currentHistoryToken` from an earlier read). Contacts' change-history
/// enumerator is not callable from Swift, so this shim walks it.
@interface MCContactChanges : NSObject
@property (nonatomic, readonly) NSArray<CNContact *> *changed;
@property (nonatomic, readonly) NSArray<NSString *> *deletedIdentifiers;
/// The token to pass next time.
@property (nonatomic, readonly, nullable) NSData *token;
@end

/// Nil with `error` set when the store refuses the request (an expired token among them).
MCContactChanges *_Nullable MCContactChangesSince(CNContactStore *store, NSData *token,
                                                  NSArray<id<CNKeyDescriptor>> *keys,
                                                  NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
