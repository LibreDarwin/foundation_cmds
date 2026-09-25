/* Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 * pl: parse a property list of any supported format and write it back out
 * as a readable ASCII property list.  Reads old-style ASCII property list
 * text (or XML) from the standard input, or from a file given with
 * -input, and writes it to the standard output, or to a file given with
 * -output.
 * Clean-room reimplementation, byte-identical to Apple's pl. */
#import <Foundation/Foundation.h>

/* -[NSString propertyList] is published but not exposed in the SDK
 * headers; declare it so we can use the exact API Apple's binary uses. */
@interface NSString (NSStringPropertyListMethods)
- (id)propertyList;
@end

static void usage(void)
{
    printf("pl {-input <file>} {-output <file>}\n"
           "\tReads ASCII PL from stdin (or file if -input specified)\n"
           "\tand writes ASCII PL to stdout (or file if -output)\n"
           "\tNOTE: binary serialization is no longer supported\n");
}

int main(void)
{
    @autoreleasepool {
        NSString *inputPath = nil;
        NSString *outputPath = nil;
        NSArray *arguments = [[NSProcessInfo processInfo] arguments];
        NSUInteger count = [arguments count];

        if (count >= 2) {
            NSUInteger i = 2;
            do {
                NSString *arg = [arguments objectAtIndex:(i - 1)];
                if ([arg isEqual:@"-input"] && i < count) {
                    inputPath = [arguments objectAtIndex:i];
                } else if ([arg isEqual:@"-output"] && i < count) {
                    outputPath = [arguments objectAtIndex:i];
                } else {
                    usage();
                    exit(-1);
                }
                i += 2;
            } while ((i - 1) < count);
        }

        NSData *inputData;
        if (inputPath == nil) {
            inputData = [[NSFileHandle fileHandleWithStandardInput]
                readDataToEndOfFile];
            if ([inputData length] == 0)
                exit(0);
        } else {
            inputData = [NSData dataWithContentsOfFile:inputPath];
            if (inputData == nil) {
                NSLog(@"*** Can't read file %@", inputPath);
                exit(-2);
            }
            if ([inputData length] == 0) {
                NSLog(@"*** File is zero length: %@", inputPath);
                exit(-2);
            }
        }

        NSString *inputString;
        const unsigned char *bytes = [inputData bytes];
        NSUInteger length = [inputData length];
        if (length >= 2 &&
            ((bytes[0] == 0xFE && bytes[1] == 0xFF) ||
             (bytes[0] == 0xFF && bytes[1] == 0xFE))) {
            inputString = [[NSString alloc] initWithData:inputData
                                                encoding:NSUTF16StringEncoding];
        } else {
            inputString = [[NSString alloc] initWithData:inputData
                                                encoding:NSUTF8StringEncoding];
        }

        id propertyList;
        @try {
            propertyList = [inputString propertyList];
        } @catch (NSException *exception) {
            NSLog(@"*** Exception parsing ASCII property list: %@ %@",
                  [exception name], [exception reason]);
            exit(-2);
        }

        NSString *outputString = [[propertyList description]
            stringByAppendingString:@"\n"];
        NSData *outputData = [outputString
            dataUsingEncoding:NSASCIIStringEncoding];
        if (outputData == nil) {
            outputData = [outputString
                dataUsingEncoding:NSUTF16StringEncoding];
        }

        if (outputPath == nil) {
            [[NSFileHandle fileHandleWithStandardOutput]
                writeData:outputData];
        } else {
            if (![outputData writeToFile:outputPath atomically:YES]) {
                NSLog(@"*** Failed writing file %@", outputPath);
                exit(-3);
            }
        }
    }
    return 0;
}