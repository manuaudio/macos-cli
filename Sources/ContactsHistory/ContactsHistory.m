#import "ContactsHistory.h"

@interface MCContactChanges ()
@property (nonatomic, readwrite) NSArray<CNContact *> *changed;
@property (nonatomic, readwrite) NSArray<NSString *> *deletedIdentifiers;
@property (nonatomic, readwrite, nullable) NSData *token;
@end

@implementation MCContactChanges
@end

MCContactChanges *MCContactChangesSince(CNContactStore *store, NSData *token,
                                        NSArray<id<CNKeyDescriptor>> *keys, NSError **error) {
    CNChangeHistoryFetchRequest *request = [CNChangeHistoryFetchRequest new];
    request.startingToken = token;
    request.additionalContactKeyDescriptors = keys;
    request.shouldUnifyResults = YES;
    request.mutableObjects = NO;

    CNFetchResult<NSEnumerator<CNChangeHistoryEvent *> *> *result =
        [store enumeratorForChangeHistoryFetchRequest:request error:error];
    if (result == nil) return nil;

    // A contact changed twice is reported twice; the last state wins, and a later
    // delete removes it from the changed set.
    NSMutableDictionary<NSString *, CNContact *> *changed = [NSMutableDictionary new];
    NSMutableOrderedSet<NSString *> *deleted = [NSMutableOrderedSet new];
    for (CNChangeHistoryEvent *event in result.value) {
        CNContact *contact = nil;
        NSString *deletedID = nil;
        if ([event isKindOfClass:[CNChangeHistoryAddContactEvent class]]) {
            contact = ((CNChangeHistoryAddContactEvent *)event).contact;
        } else if ([event isKindOfClass:[CNChangeHistoryUpdateContactEvent class]]) {
            contact = ((CNChangeHistoryUpdateContactEvent *)event).contact;
        } else if ([event isKindOfClass:[CNChangeHistoryDeleteContactEvent class]]) {
            deletedID = ((CNChangeHistoryDeleteContactEvent *)event).contactIdentifier;
        }
        if (contact != nil) {
            changed[contact.identifier] = contact;
            [deleted removeObject:contact.identifier];
        } else if (deletedID != nil) {
            [changed removeObjectForKey:deletedID];
            [deleted addObject:deletedID];
        }
    }

    MCContactChanges *changes = [MCContactChanges new];
    changes.changed = changed.allValues;
    changes.deletedIdentifiers = deleted.array;
    changes.token = result.currentHistoryToken;
    return changes;
}
