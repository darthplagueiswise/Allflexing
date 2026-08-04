#import "FLEXHookableObjectExplorerViewController.h"

#import "FLEXMetadataSection.h"
#import "FLEXMethod.h"
#import "FLEXObjCHookResolver.h"
#import "FLEXObjectExplorer.h"
#import "FLEXProperty.h"

@implementation FLEXHookableObjectExplorerViewController

- (Class)allflexing_currentScopeClass {
    NSArray<Class> *classes = self.explorer.classHierarchyClasses;
    NSInteger scope = self.explorer.classScope;
    if (scope < 0 || scope >= (NSInteger)classes.count) {
        return object_isClass(self.object) ? (Class)self.object : object_getClass(self.object);
    }
    return classes[(NSUInteger)scope];
}

- (NSSet<NSString *> *)allflexing_excludedMetadataFrom:(NSArray *)metadata
                                           targetClass:(Class)targetClass {
    NSMutableSet<NSString *> *excluded = [NSMutableSet set];
    for (id item in metadata) {
        BOOL supported = NO;
        if ([item isKindOfClass:FLEXMethod.class]) {
            supported = [FLEXObjCHookResolver entryForMethod:item
                                                targetClass:targetClass] != nil;
        } else if ([item isKindOfClass:FLEXProperty.class]) {
            supported = [FLEXObjCHookResolver entryForProperty:item
                                                  targetClass:targetClass] != nil;
        }
        if (!supported) {
            NSString *name = [item respondsToSelector:@selector(name)] ? [item name] : nil;
            if (name.length) {
                [excluded addObject:name];
            }
        }
    }
    return excluded.copy;
}

- (FLEXMetadataSection *)allflexing_sectionForKind:(FLEXMetadataKind)kind
                                          metadata:(NSArray *)metadata
                                       targetClass:(Class)targetClass {
    FLEXMetadataSection *section = [FLEXMetadataSection explorer:self.explorer kind:kind];
    section.excludedMetadata = [self allflexing_excludedMetadataFrom:metadata
                                                         targetClass:targetClass];
    return section;
}

- (NSArray<FLEXTableViewSection *> *)makeSections {
    Class targetClass = [self allflexing_currentScopeClass];
    if (!targetClass) {
        return @[];
    }

    // These are the original FLEX metadata sections. Their standard rendering,
    // search, type declarations, argument encodings, previews and context menus
    // remain intact; only unsupported rows are excluded.
    return @[
        [self allflexing_sectionForKind:FLEXMetadataKindProperties
                                metadata:self.explorer.properties
                             targetClass:targetClass],
        [self allflexing_sectionForKind:FLEXMetadataKindClassProperties
                                metadata:self.explorer.classProperties
                             targetClass:targetClass],
        [self allflexing_sectionForKind:FLEXMetadataKindMethods
                                metadata:self.explorer.methods
                             targetClass:targetClass],
        [self allflexing_sectionForKind:FLEXMetadataKindClassMethods
                                metadata:self.explorer.classMethods
                             targetClass:targetClass],
    ];
}

- (BOOL)shouldShowDescription {
    return NO;
}

@end
