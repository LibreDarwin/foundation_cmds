/* Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 * defaults: read and write the user's defaults (NSUserDefaults-backed) from
 * the command line.  Supports read, read-type, write (including the
 * compositing -array/-dict forms), rename, delete, delete-all, import,
 * export, domains, find and help, plus -currentHost/-host and -app/-globalDomain
 * domain resolution.
 * Clean-room reimplementation, byte-identical to Apple's defaults. */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>

/* -[NSString propertyList] is published but not exposed in the SDK
 * headers; declare it so we can use the exact API Apple's binary uses. */
@interface NSString (NSStringPropertyListMethods)
- (id)propertyList;
@end

/* Private CoreFoundation exports used by Apple's binary.  Declared with
 * asm labels so the assembler-level names match Apple's exactly:
 * the C identifier spelling in Apple's source was a single leading
 * underscore (e.g. `_CFPrefsSetSynchronizeIsSynchronous`), which this
 * toolchain would otherwise mangle with a double leading underscore. */
extern CFStringRef __CFXPreferencesGetByHostIdentifierString(void) __asm("__CFXPreferencesGetByHostIdentifierString");
extern void __CFPrefsSynchronizeForProcessTermination(void) __asm("__CFPrefsSynchronizeForProcessTermination");
extern void __CFPreferencesFlushCachesForIdentifier(CFStringRef, CFStringRef) __asm("__CFPreferencesFlushCachesForIdentifier");
extern CFURLRef __CFPreferencesCopyInUseContainerURLMatchingApplication(CFStringRef, CFStringRef, CFStringRef) __asm("__CFPreferencesCopyInUseContainerURLMatchingApplication");
extern CFDictionaryRef __CFPreferencesCopyApplicationMap(CFStringRef, CFStringRef) __asm("__CFPreferencesCopyApplicationMap");
extern void __CFPrefsSetSynchronizeIsSynchronous(int) __asm("__CFPrefsSetSynchronizeIsSynchronous");
extern void __CFPrefSetInvalidPropertyListDeletionEnabled(int) __asm("__CFPrefSetInvalidPropertyListDeletionEnabled");

static void usage(void);
static NSArray *pathsForTriple(CFStringRef, CFStringRef, CFStringRef, BOOL);
static id getValue(NSArray *, NSUInteger *, BOOL, BOOL *);
static int match(id, NSString *);
static id createPlist(NSString *);
static BOOL SYNC(CFStringRef, CFStringRef, CFStringRef);
static void doReadType(CFStringRef, CFStringRef, CFStringRef, NSArray *, NSUInteger);
static void doWrite(CFStringRef, CFStringRef, CFStringRef, NSArray *, NSUInteger);
static void doRename(CFStringRef, CFStringRef, CFStringRef, NSArray *, NSUInteger);
static void doDelete(BOOL, CFStringRef, CFStringRef, CFStringRef, NSArray *, NSUInteger);
static void doImport(CFStringRef, CFStringRef, CFStringRef, NSArray *, NSUInteger);
static void doExport(CFStringRef, CFStringRef, CFStringRef, NSArray *, NSUInteger);

static const char HELP_TEXT[] =
    "Command line interface to a user's defaults.\n"
    "Syntax:\n"
    "\n"
    "'defaults' [-currentHost | -host <hostname>] followed by one of the following:\n"
    "\n"
    "  read                                 shows all defaults\n"
    "  read <domain>                        shows defaults for given domain\n"
    "  read <domain> <key>                  shows defaults for given domain, key\n"
    "\n"
    "  read-type <domain> <key>             shows the type for the given domain, key\n"
    "\n"
    "  write <domain> <domain_rep>          writes domain (overwrites existing)\n"
    "  write <domain> <key> <value>         writes key for domain\n"
    "\n"
    "  rename <domain> <old_key> <new_key>  renames old_key to new_key\n"
    "\n"
    "  delete <domain>                      deletes domain\n"
    "  delete <domain> <key>                deletes key in domain\n"
    "  delete-all <domain>                  deletes the domain from all containers\n"
    "  delete-all <domain> Key>             deletes key in domain from all containers\n"
    "\n"
    "  import <domain> <path to plist>      writes the plist at path to domain\n"
    "  import <domain> -                    writes a plist from stdin to domain\n"
    "  export <domain> <path to plist>      saves domain as a binary plist to path\n"
    "  export <domain> -                    writes domain as an xml plist to stdout\n"
    "  domains                              lists all domains\n"
    "  find <word>                          lists all entries containing word\n"
    "  help                                 print this help\n"
    "\n"
    "<domain> is ( <domain_name> | -app <application_name> | -globalDomain )\n"
    "         or a path to a file omitting the '.plist' extension\n"
    "\n"
    "<value> is one of:\n"
    "  <value_rep>\n"
    "  -string <string_value>\n"
    "  -data <hex_digits>\n"
    "  -int[eger] <integer_value>\n"
    "  -float  <floating-point_value>\n"
    "  -bool[ean] (true | false | yes | no)\n"
    "  -date <date_rep>\n"
    "  -array <value1> <value2> ...\n"
    "  -array-add <value1> <value2> ...\n"
    "  -dict <key1> <value1> <key2> <value2> ...\n"
    "  -dict-add <key1> <value1> ...\n";

static void show(NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    fputs([s UTF8String], stdout);
    [s release];
}

static CFStringRef getDomain(NSArray *args, NSUInteger *index)
{
    NSUInteger i = *index;
    if (i >= [args count])
        usage();
    NSString *candidate = [args objectAtIndex:i];
    if (candidate == nil)
        usage();

    if ([candidate isEqualToString:@"-globalDomain"] ||
        [candidate isEqualToString:@"-g"] ||
        [candidate isEqualToString:@"Apple Global Domain"] ||
        [candidate isEqualToString:@"NSGlobalDomain"]) {
        *index = i + 1;
        return kCFPreferencesAnyApplication;
    }

    if (![candidate isEqualToString:@"-app"]) {
        *index = i + 1;
        return (CFStringRef)candidate;
    }

    i += 1;
    if (i >= [args count])
        usage();
    NSString *appName = [args objectAtIndex:i];
    *index = i + 1;

    NSString *appPath = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:appName isDirectory:NULL]) {
        appPath = appName;
    } else {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationDirectory,
                                                            NSAllDomainsMask, YES);
        NSEnumerator *e = [dirs objectEnumerator];
        NSString *dir;
        while ((dir = [e nextObject])) {
            NSString *p = [[dir stringByAppendingPathComponent:appName]
                stringByAppendingPathExtension:@"app"];
            BOOL isDir = NO;
            if ([[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir] && isDir) {
                appPath = p;
                break;
            }
        }
    }
    if (appPath == nil) {
        NSLog(@"Couldn't find an application named \"%@\"; defaults unchanged", appName);
        exit(1);
    }

    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, (CFStringRef)appPath,
                                                 kCFURLPOSIXPathStyle, true);
    if (url == NULL) {
        NSLog(@"Couldn't open application %@; defaults unchanged", appPath);
        exit(1);
    }
    CFBundleRef bundle = CFBundleCreate(NULL, url);
    CFRelease(url);
    if (bundle == NULL) {
        NSLog(@"Couldn't open application %@; defaults unchanged", appPath);
        exit(1);
    }
    CFStringRef bundleID = CFBundleGetIdentifier(bundle);
    if (bundleID != NULL && CFStringGetLength(bundleID) > 0) {
        CFStringRef result = CFStringCreateCopy(NULL, bundleID);
        CFRelease(bundle);
        return result;
    }
    CFURLRef execURL = CFBundleCopyExecutableURL(bundle);
    CFRelease(bundle);
    if (execURL != NULL) {
        NSString *execPath = [(NSURL *)execURL path];
        CFRelease(execURL);
        return (CFStringRef)[execPath lastPathComponent];
    }
    NSLog(@"Can't determine domain name for application %@; defaults unchanged", appPath);
    exit(1);
}

static CFStringRef getHost(NSArray *args, NSUInteger *index)
{
    NSUInteger i = *index;
    if (i >= [args count])
        return kCFPreferencesAnyHost;
    NSString *candidate = [args objectAtIndex:i];
    if (candidate == nil)
        return kCFPreferencesAnyHost;

    if ([candidate isEqualToString:@"-currentHost"]) {
        *index = i + 1;
        return kCFPreferencesCurrentHost;
    }
    if ([candidate isEqualToString:@"-host"]) {
        if (*index + 1 == [args count])
            usage();
        *index = i + 2;
        return (CFStringRef)[args objectAtIndex:i + 1];
    }
    return kCFPreferencesAnyHost;
}

static CFStringRef getUserNameFromDomain(NSString **domain)
{
    NSString *d = *domain;
    if ([d hasPrefix:@"/Library/Preferences/"]) {
        if ([d length] == 0)
            return kCFPreferencesCurrentUser;
        return kCFPreferencesAnyUser;
    }
    return kCFPreferencesCurrentUser;
}

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSArray *args = [[NSProcessInfo processInfo] arguments];
    NSUInteger count = [args count];

    if (count == 2 && [[args objectAtIndex:1] isEqualToString:@"printHostIdentifier"]) {
        puts([(NSString *)__CFXPreferencesGetByHostIdentifierString() UTF8String]);
        exit(0);
    }

    NSUInteger index = 1;
    CFStringRef rawHost = getHost(args, &index);
    if (index == count || rawHost == nil)
        usage();
    NSString *verb = [[args objectAtIndex:index] uppercaseString];
    index += 1;

    __CFPrefsSetSynchronizeIsSynchronous(1);
    __CFPrefSetInvalidPropertyListDeletionEnabled(0);

    if ([verb isEqualToString:@"FIND"]) {
        if (index == count)
            usage();
        NSString *word = [args objectAtIndex:index];
        CFDictionaryRef map = __CFPreferencesCopyApplicationMap(kCFPreferencesCurrentUser, rawHost);
        NSUInteger foundCount = 0;
        NSEnumerator *de = [(NSDictionary *)map keyEnumerator];
        NSString *domainKey;
        while ((domainKey = [de nextObject])) {
            NSString *path;
            if ([domainKey isEqualToString:(NSString *)kCFPreferencesAnyApplication]) {
                path = domainKey;
            } else {
                NSArray *container = [(NSDictionary *)map objectForKey:domainKey];
                path = [[[container objectAtIndex:0] URLByAppendingPathComponent:domainKey] path];
            }
            id plist = (id)CFPreferencesCopyMultiple(NULL, (CFStringRef)path,
                                                     kCFPreferencesCurrentUser, rawHost);
            if (plist == nil)
                continue;
            NSMutableDictionary *results = nil;
            NSArray *keys = [[(NSDictionary *)plist allKeys]
                sortedArrayUsingSelector:@selector(compare:)];
            NSEnumerator *ke = [keys objectEnumerator];
            NSString *key;
            while ((key = [ke nextObject])) {
                id value = [(NSDictionary *)plist objectForKey:key];
                if (match(domainKey, word) || match(key, word) || match(value, word)) {
                    if (results == nil)
                        results = [NSMutableDictionary dictionary];
                    [results setObject:value forKey:key];
                }
            }
            if (results != nil) {
                NSString *display = [domainKey isEqualToString:(NSString *)kCFPreferencesAnyApplication]
                    ? @"Apple Global Domain" : domainKey;
                show(@"Found %lu keys in domain '%@': %@\n",
                     (unsigned long)[results count], display, [results description]);
                foundCount += 1;
            }
            CFRelease(plist);
        }
        if (map != NULL)
            CFRelease(map);
        if (foundCount == 0)
            NSLog(@"No domain, key, nor value containing '%@'", word);
        exit(0);
    }

    if ([verb isEqualToString:@"HELP"]) {
        show(@"%s", HELP_TEXT);
        exit(0);
    }

    if ([verb isEqualToString:@"DOMAINS"]) {
        CFDictionaryRef map = __CFPreferencesCopyApplicationMap(kCFPreferencesCurrentUser, rawHost);
        NSMutableArray *keys = [[(NSDictionary *)map allKeys] mutableCopy];
        if (map != NULL)
            CFRelease(map);
        NSUInteger aix = [keys indexOfObject:(NSString *)kCFPreferencesAnyApplication];
        if (aix != NSNotFound)
            [keys removeObjectAtIndex:aix];
        NSArray *sorted = [keys sortedArrayUsingSelector:@selector(compare:)];
        [keys release];
        show(@"%@\n", [sorted componentsJoinedByString:@", "]);
        exit(0);
    }

    if ([verb isEqualToString:@"READ"] && index == count) {
        CFDictionaryRef map = __CFPreferencesCopyApplicationMap(kCFPreferencesCurrentUser, rawHost);
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        NSEnumerator *de = [(NSDictionary *)map keyEnumerator];
        NSString *domainKey;
        while ((domainKey = [de nextObject])) {
            NSArray *container = [(NSDictionary *)map objectForKey:domainKey];
            NSString *path = [[[container objectAtIndex:0] URLByAppendingPathComponent:domainKey] path];
            id plist = (id)CFPreferencesCopyMultiple(NULL, (CFStringRef)path,
                                                     kCFPreferencesCurrentUser, rawHost);
            if (plist != nil) {
                NSString *display = [domainKey isEqualToString:(NSString *)kCFPreferencesAnyApplication]
                    ? @"Apple Global Domain" : domainKey;
                [result setObject:(NSDictionary *)plist forKey:display];
                CFRelease(plist);
            }
        }
        if (map != NULL)
            CFRelease(map);
        show(@"%@\n", [result description]);
        exit(0);
    }

    NSString *domain = (NSString *)getDomain(args, &index);
    if (domain == nil)
        usage();
    CFStringRef user = getUserNameFromDomain(&domain);
    CFStringRef effectiveHost = (user == kCFPreferencesAnyUser &&
                                 rawHost == kCFPreferencesAnyHost)
        ? kCFPreferencesCurrentHost : rawHost;

    if ([verb isEqualToString:@"READ"]) {
        NSString *path = [pathsForTriple((CFStringRef)domain, user, effectiveHost, YES) objectAtIndex:0];
        if (index == count) {
            id plist = (id)CFPreferencesCopyMultiple(NULL, (CFStringRef)path, user, effectiveHost);
            if (plist == nil || CFDictionaryGetCount((CFDictionaryRef)plist) == 0) {
                NSString *display = [path isEqualToString:(NSString *)kCFPreferencesAnyApplication]
                    ? @"Apple Global Domain" : path;
                NSLog(@"\nDomain %@ does not exist\n", display);
                exit(1);
            }
            show(@"%@\n", [(NSDictionary *)plist description]);
            CFRelease(plist);
            exit(0);
        }
        NSString *key = [args objectAtIndex:index];
        id value = (id)CFPreferencesCopyValue((CFStringRef)key, (CFStringRef)path, user, effectiveHost);
        if (value != nil) {
            show(@"%@\n", [value description]);
            CFRelease(value);
            exit(0);
        }
        NSLog(@"\nThe domain/default pair of (%@, %@) does not exist\n", path, key);
        exit(1);
    }

    if ([verb isEqualToString:@"READ-TYPE"]) {
        doReadType(effectiveHost, (CFStringRef)domain, user, args, index);
    } else if ([verb isEqualToString:@"WRITE"]) {
        doWrite(effectiveHost, (CFStringRef)domain, user, args, index);
    } else if ([verb isEqualToString:@"RENAME"]) {
        doRename(effectiveHost, (CFStringRef)domain, user, args, index);
    } else if ([verb isEqualToString:@"DELETE"] || [verb isEqualToString:@"REMOVE"]) {
        doDelete(NO, effectiveHost, (CFStringRef)domain, user, args, index);
    } else if ([verb isEqualToString:@"DELETE-ALL"]) {
        doDelete(YES, effectiveHost, (CFStringRef)domain, user, args, index);
    } else if ([verb isEqualToString:@"IMPORT"]) {
        doImport(effectiveHost, (CFStringRef)domain, user, args, index);
    } else if ([verb isEqualToString:@"EXPORT"]) {
        doExport(effectiveHost, (CFStringRef)domain, user, args, index);
    } else {
        usage();
    }

    [pool release];
    return 0;
}

static void doReadType(CFStringRef host, CFStringRef domain, CFStringRef user,
                       NSArray *args, NSUInteger index)
{
    NSString *path = [pathsForTriple(domain, user, host, YES) objectAtIndex:0];
    if (index == [args count])
        usage();
    NSString *key = [args objectAtIndex:index];
    CFTypeRef value = CFPreferencesCopyValue((CFStringRef)key, (CFStringRef)path, user, host);
    if (value == NULL) {
        NSLog(@"\nThe domain/default pair of (%@, %@) does not exist\n", path, key);
        exit(1);
    }
    CFTypeID tid = CFGetTypeID(value);
    show(@"Type is ");
    if (tid == CFStringGetTypeID()) {
        show(@"string\n");
    } else if (tid == CFDataGetTypeID()) {
        show(@"data\n");
    } else if (tid == CFNumberGetTypeID()) {
        CFNumberType ntype = CFNumberGetType((CFNumberRef)value);
        if (ntype == kCFNumberFloatType || ntype == kCFNumberDoubleType)
            show(@"float\n");
        else
            show(@"integer\n");
    } else if (tid == CFBooleanGetTypeID()) {
        show(@"boolean\n");
    } else if (tid == CFDateGetTypeID()) {
        show(@"date\n");
    } else if (tid == CFArrayGetTypeID()) {
        show(@"array\n");
    } else if (tid == CFDictionaryGetTypeID()) {
        show(@"dictionary\n");
    } else {
        NSLog(@"Found a value that is not of a known property list type");
        exit(1);
    }
    CFRelease(value);
    exit(0);
}

static void doWrite(CFStringRef host, CFStringRef domain, CFStringRef user,
                    NSArray *args, NSUInteger index)
{
    NSString *path = [pathsForTriple(domain, user, host, YES) objectAtIndex:0];
    if (index == [args count])
        usage();

    if (index + 1 == [args count]) {
        id value = createPlist([args objectAtIndex:index]);
        if (![value isKindOfClass:[NSDictionary class]]) {
            NSLog(@"\nRep argument is not a dictionary\nDefaults have not been changed.\n");
            exit(1);
        }
        NSArray *newKeys = [value allKeys];
        NSMutableArray *toRemove = nil;
        CFArrayRef existing = CFPreferencesCopyKeyList((CFStringRef)path, user, host);
        if (existing != NULL) {
            toRemove = [[(NSArray *)existing mutableCopy] autorelease];
            CFRelease(existing);
            [toRemove removeObjectsInArray:newKeys];
        }
        CFPreferencesSetMultiple((CFDictionaryRef)value, (CFArrayRef)toRemove,
                                 (CFStringRef)path, user, host);
        SYNC((CFStringRef)path, user, host);
        exit(0);
    }

    NSString *key = [args objectAtIndex:index++];
    BOOL addFlag = NO;
    id value = getValue(args, &index, YES, &addFlag);
    if (index < [args count]) {
        NSLog(@"Unexpected argument %@; leaving defaults unchanged.", [args objectAtIndex:index]);
        exit(1);
    }
    if (addFlag) {
        CFTypeRef existing = CFPreferencesCopyValue((CFStringRef)key, (CFStringRef)path, user, host);
        if (existing != NULL) {
            if ([value isKindOfClass:[NSArray class]]) {
                if (![(id)existing isKindOfClass:[NSArray class]]) {
                    NSLog(@"Value for key %@ is not an array; cannot append.  Leaving defaults unchanged.", key);
                    exit(1);
                }
                value = [(NSArray *)existing arrayByAddingObjectsFromArray:(NSArray *)value];
            } else {
                if (![(id)existing isKindOfClass:[NSDictionary class]]) {
                    NSLog(@"Value for key %@ is not a dictionary; cannot append.  Leaving defaults unchanged.", key);
                    exit(1);
                }
                NSMutableDictionary *md = [(NSDictionary *)existing mutableCopy];
                [md addEntriesFromDictionary:(NSDictionary *)value];
                value = [md autorelease];
            }
            CFRelease(existing);
        }
    }
    CFPreferencesSetValue((CFStringRef)key, (CFTypeRef)value, (CFStringRef)path, user, host);
    if (SYNC((CFStringRef)path, user, host))
        exit(0);
    NSString *display = [path isEqualToString:(NSString *)kCFPreferencesAnyApplication]
        ? @"Apple Global Domain" : path;
    NSLog(@"Could not write domain %@; exiting", display);
    exit(1);
}

static void doRename(CFStringRef host, CFStringRef domain, CFStringRef user,
                     NSArray *args, NSUInteger index)
{
    NSString *path = [pathsForTriple(domain, user, host, YES) objectAtIndex:0];
    if ([args count] != index + 2)
        usage();
    NSString *oldKey = [args objectAtIndex:index];
    NSString *newKey = [args objectAtIndex:index + 1];
    CFTypeRef value = CFPreferencesCopyValue((CFStringRef)oldKey, (CFStringRef)path, user, host);
    if (value == NULL) {
        NSString *display = [path isEqualToString:(NSString *)kCFPreferencesAnyApplication]
            ? @"Apple Global Domain" : path;
        NSLog(@"Key %@ does not exist in domain %@; leaving defaults unchanged", oldKey, display);
        exit(1);
    }
    CFPreferencesSetValue((CFStringRef)newKey, value, (CFStringRef)path, user, host);
    CFPreferencesSetValue((CFStringRef)oldKey, NULL, (CFStringRef)path, user, host);
    CFRelease(value);
    if (SYNC((CFStringRef)path, user, host))
        exit(0);
    NSString *display = [path isEqualToString:(NSString *)kCFPreferencesAnyApplication]
        ? @"Apple Global Domain" : path;
    NSLog(@"Failed to write domain %@", display);
    exit(1);
}

static void doDelete(BOOL deleteAll, CFStringRef host, CFStringRef domain,
                     CFStringRef user, NSArray *args, NSUInteger index)
{
    if (index != [args count]) {
        if (index + 1 != [args count])
            usage();
        NSString *key = [args objectAtIndex:index];
        NSArray *paths = pathsForTriple(domain, user, host, !deleteAll);
        BOOL success = NO;
        NSEnumerator *e = [paths objectEnumerator];
        NSString *path;
        while ((path = [e nextObject])) {
            CFTypeRef value = CFPreferencesCopyValue((CFStringRef)key, (CFStringRef)path, user, host);
            if (value != NULL) {
                CFRelease(value);
                CFPreferencesSetValue((CFStringRef)key, NULL, (CFStringRef)path, user, host);
                success |= SYNC((CFStringRef)path, user, host);
            }
        }
        if (success)
            exit(0);
    } else {
        NSArray *paths = pathsForTriple(domain, user, host, !deleteAll);
        BOOL success = NO;
        NSEnumerator *e = [paths objectEnumerator];
        NSString *path;
        while ((path = [e nextObject])) {
            CFArrayRef keys = CFPreferencesCopyKeyList((CFStringRef)path, user, host);
            if (keys != NULL) {
                CFPreferencesSetMultiple(NULL, keys, (CFStringRef)path, user, host);
                CFRelease(keys);
                success |= SYNC((CFStringRef)path, user, host);
            }
        }
        if (success)
            exit(0);
    }
    NSLog(@"\nDomain (%@) not found.\nDefaults have not been changed.\n", (NSString *)domain);
    exit(1);
}

static void doImport(CFStringRef host, CFStringRef domain, CFStringRef user,
                     NSArray *args, NSUInteger index)
{
    if (index == [args count]) {
        NSLog(@"\nNeed a path to read from");
        exit(1);
    }
    NSString *source = [args objectAtIndex:index];
    NSString *trimmed = [source stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSData *data;
    if ([trimmed isEqualToString:@"-"]) {
        data = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    } else {
        data = [NSData dataWithContentsOfFile:source];
    }
    if (data == nil) {
        NSLog(@"Could not read data from %@", source);
        exit(1);
    }
    NSError *error = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:0
                                                          format:NULL error:&error];
    if (plist == nil) {
        NSLog(@"Could not parse property list from %@ due to %@", source, error);
        exit(1);
    }
    if (![plist isKindOfClass:[NSDictionary class]]) {
        NSLog(@"Property list %@ was not a dictionary\nDefaults have not been changed.\n", plist);
        exit(1);
    }
    NSString *path = [pathsForTriple(domain, user, host, YES) objectAtIndex:0];
    CFPreferencesSetMultiple((CFDictionaryRef)plist, NULL, (CFStringRef)path, user, host);
    SYNC((CFStringRef)path, user, host);
    exit(0);
}

static void doExport(CFStringRef host, CFStringRef domain, CFStringRef user,
                     NSArray *args, NSUInteger index)
{
    NSString *path = [pathsForTriple(domain, user, host, YES) objectAtIndex:0];
    if (index == [args count]) {
        NSLog(@"\nNeed a path to write to");
        exit(1);
    }
    NSString *dest = [args objectAtIndex:index];
    NSString *trimmed = [dest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *name = [trimmed isEqualToString:@"-"] ? nil : dest;

    CFDictionaryRef plist = CFPreferencesCopyMultiple(NULL, (CFStringRef)path, user, host);
    if (plist == NULL) {
        NSLog(@"\nThe domain %@ does not exist\n", path);
        exit(1);
    }
    NSPropertyListFormat format = (name == nil)
        ? NSPropertyListBinaryFormat_v1_0 : NSPropertyListXMLFormat_v1_0;
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:(id)plist
                                                              format:format
                                                             options:0 error:&error];
    CFRelease(plist);
    if (data == nil) {
        NSLog(@"Could not export domain %@ to %@ due to %@", path, name, error);
        exit(1);
    }
    if (name == nil) {
        [[NSFileHandle fileHandleWithStandardOutput] writeData:data];
    } else {
        [data writeToFile:dest atomically:YES];
    }
    exit(0);
}

static int match(id value, NSString *word)
{
    if ([value isKindOfClass:[NSString class]]) {
        NSRange r = [value rangeOfString:word options:NSCaseInsensitiveSearch];
        return (r.length != 0);
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *a = (NSArray *)value;
        NSUInteger i;
        for (i = [a count]; i != 0; i--) {
            if (match([a objectAtIndex:i - 1], word))
                return 1;
        }
        return 0;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)value;
        NSEnumerator *e = [d keyEnumerator];
        NSString *key;
        while ((key = [e nextObject])) {
            if (match(key, word) || match([d objectForKey:key], word))
                return 1;
        }
        return 0;
    }
    return 0;
}

static NSArray *pathsForTriple(CFStringRef domain, CFStringRef user,
                               CFStringRef host, BOOL abbreviated)
{
    if (domain == kCFPreferencesAnyApplication ||
        [(NSString *)domain hasPrefix:@"/"]) {
        return [NSArray arrayWithObject:(id)domain];
    }

    NSMutableArray *paths = [NSMutableArray array];
    if (abbreviated) {
        CFURLRef url = __CFPreferencesCopyInUseContainerURLMatchingApplication(domain, user, host);
        if (url != NULL) {
            [paths addObject:[[(NSURL *)url path] stringByAppendingPathComponent:(NSString *)domain]];
            CFRelease(url);
        } else {
            [paths addObject:(id)domain];
        }
    } else {
        CFDictionaryRef map = __CFPreferencesCopyApplicationMap(user, host);
        if (map != NULL) {
            NSArray *container = [(NSDictionary *)map objectForKey:(id)domain];
            if (container != nil) {
                NSEnumerator *e = [container objectEnumerator];
                NSURL *url;
                while ((url = [e nextObject])) {
                    [paths addObject:[[url path] stringByAppendingPathComponent:(NSString *)domain]];
                }
            } else {
                [paths addObject:(id)domain];
            }
            CFRelease(map);
        } else {
            [paths addObject:(id)domain];
        }
    }
    return paths;
}

static id createPlist(NSString *source)
{
    static NSCharacterSet *magic = nil;
    if (magic == nil)
        magic = [NSCharacterSet characterSetWithCharactersInString:@"\"()][{}><"];
    if ([source rangeOfCharacterFromSet:magic].location == NSNotFound)
        source = [NSString stringWithFormat:@"\"%@\"", source];

    id result = nil;
    @try {
        result = [source propertyList];
    } @catch (NSException *e) {
        result = nil;
    }
    if (result == nil) {
        NSLog(@"Could not parse: %@.  Try single-quoting it.", source);
        exit(1);
    }
    return result;
}

static BOOL SYNC(CFStringRef path, CFStringRef user, CFStringRef host)
{
    BOOL ok = (CFPreferencesSynchronize(path, user, host) != 0);
    __CFPrefsSynchronizeForProcessTermination();
    __CFPreferencesFlushCachesForIdentifier(path, user);
    return ok;
}

static id getValue(NSArray *args, NSUInteger *index, BOOL compositesAllowed, BOOL *addFlag)
{
    *addFlag = NO;
    NSUInteger i = *index;
    if (i >= [args count])
        usage();
    NSString *token = [args objectAtIndex:i];
    *index = i + 1;

    if ([token isEqualToString:@"-string"]) {
        if (i + 1 >= [args count])
            usage();
        *index = i + 2;
        return [args objectAtIndex:i + 1];
    }
    if ([token isEqualToString:@"-data"]) {
        if (i + 1 >= [args count])
            usage();
        NSString *hex = [args objectAtIndex:i + 1];
        NSUInteger len = [hex length];
        NSMutableData *data = [NSMutableData dataWithCapacity:(len + 1) / 2];
        NSUInteger j = 0;
        if (len % 2 == 1) {
            unsigned int h = 0;
            if (![[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(0, 1)]] scanHexInt:&h])
                usage();
            unsigned char b = (unsigned char)(h & 0xf);
            [data appendBytes:&b length:1];
            j = 1;
        }
        for (; j + 1 <= len; j += 2) {
            unsigned int hi = 0, lo = 0;
            if (![[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(j, 1)]] scanHexInt:&hi])
                usage();
            if (![[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(j + 1, 1)]] scanHexInt:&lo])
                usage();
            unsigned char b = (unsigned char)(((hi & 0xf) << 4) | (lo & 0xf));
            [data appendBytes:&b length:1];
        }
        *index = i + 2;
        return data;
    }
    if ([token isEqualToString:@"-int"] || [token isEqualToString:@"-integer"]) {
        if (i + 1 >= [args count])
            usage();
        *index = i + 2;
        return [NSNumber numberWithLongLong:[[args objectAtIndex:i + 1] longLongValue]];
    }
    if ([token isEqualToString:@"-float"]) {
        if (i + 1 >= [args count])
            usage();
        *index = i + 2;
        return [NSNumber numberWithFloat:[[args objectAtIndex:i + 1] floatValue]];
    }
    if ([token isEqualToString:@"-bool"] || [token isEqualToString:@"-boolean"]) {
        if (i + 1 >= [args count])
            usage();
        NSString *s = [args objectAtIndex:i + 1];
        if ([s caseInsensitiveCompare:@"yes"] == NSOrderedSame ||
            [s caseInsensitiveCompare:@"true"] == NSOrderedSame) {
            *index = i + 2;
            return (id)kCFBooleanTrue;
        }
        if ([s caseInsensitiveCompare:@"no"] == NSOrderedSame ||
            [s caseInsensitiveCompare:@"false"] == NSOrderedSame) {
            *index = i + 2;
            return (id)kCFBooleanFalse;
        }
        usage();
    }
    if ([token isEqualToString:@"-date"]) {
        if (i + 1 >= [args count])
            usage();
        NSString *ds = [args objectAtIndex:i + 1];
        NSDate *d = [[[NSDate alloc] initWithString:ds] autorelease];
        if (d == nil)
            d = [NSDate dateWithNaturalLanguageString:ds];
        if (d == nil)
            usage();
        *index = i + 2;
        return d;
    }
    if ([token isEqualToString:@"-array"] || [token isEqualToString:@"-array-add"]) {
        if (!compositesAllowed) {
            NSLog(@"Cannot nest composite types (arrays and dictionaries); exiting");
            exit(1);
        }
        *addFlag = [token isEqualToString:@"-array-add"];
        NSMutableArray *array = [NSMutableArray array];
        while (*index < [args count]) {
            BOOL subAdd = NO;
            [array addObject:getValue(args, index, NO, &subAdd)];
        }
        return array;
    }
    if ([token isEqualToString:@"-dict"] || [token isEqualToString:@"-dict-add"]) {
        if (!compositesAllowed) {
            NSLog(@"Cannot nest composite types (arrays and dictionaries); exiting");
            exit(1);
        }
        *addFlag = [token isEqualToString:@"-dict-add"];
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        while (*index < [args count]) {
            BOOL subAdd = NO;
            id k = getValue(args, index, NO, &subAdd);
            if (![k isKindOfClass:[NSString class]]) {
                NSLog(@"Dictionary keys must be strings");
                exit(1);
            }
            if (*index >= [args count]) {
                NSLog(@"Key %@ lacks a corresponding value", k);
                exit(1);
            }
            id v = getValue(args, index, NO, &subAdd);
            [dict setObject:v forKey:k];
        }
        return dict;
    }
    return createPlist(token);
}

static void usage(void)
{
    show(@"%s", HELP_TEXT);
    exit(-1);
}