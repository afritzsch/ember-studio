// ARC (SwiftPM compiles Objective-C++ with -fobjc-arc). The pool drains what Foundation autoreleases.
#include "plugins/AUPluginConfig.h"

#import <Foundation/Foundation.h>

namespace daw {

namespace {

Error invalid(const std::string& message) { return makeError(ErrorCode::invalidArgument, "AU config: " + message); }

} // namespace

Result<AUPluginConfig> AUPluginConfig::parse(std::string_view configJSON) {
    @autoreleasepool {
        NSData* data = [NSData dataWithBytes:configJSON.data() length:configJSON.size()];
        NSError* error = nil;
        id doc = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (![doc isKindOfClass:[NSDictionary class]]) return invalid("not a JSON object");
        NSDictionary* dict = doc;

        id identifier = dict[@"identifier"];
        if (![identifier isKindOfClass:[NSString class]]) return invalid("needs a string \"identifier\"");
        auto component = parseAUIdentifier([(NSString*)identifier UTF8String]);
        if (!component) return invalid(component.error().message);

        AUPluginConfig config;
        config.component = component.value();
        config.identifier = formatAUIdentifier(config.component);

        id state = dict[@"state"];
        if (state != nil && state != [NSNull null]) {
            if (![state isKindOfClass:[NSString class]]) return invalid("\"state\" is not a string");
            if ([(NSString*)state length] > 0) {
                NSData* bytes = [[NSData alloc] initWithBase64EncodedString:state options:0];
                if (bytes == nil) return invalid("\"state\" is not base64");
                const auto* p = static_cast<const uint8_t*>(bytes.bytes);
                config.state.assign(p, p + bytes.length);
            }
        }
        return config;
    }
}

std::string AUPluginConfig::makeJSON(std::string_view identifier, const std::vector<uint8_t>& state) {
    @autoreleasepool {
        NSMutableDictionary* dict = [NSMutableDictionary dictionary];
        dict[@"identifier"] = [[NSString alloc] initWithBytes:identifier.data()
                                                       length:identifier.size()
                                                     encoding:NSUTF8StringEncoding]
                                  ?: @"";
        if (!state.empty())
            dict[@"state"] = [[NSData dataWithBytes:state.data() length:state.size()] base64EncodedStringWithOptions:0];
        NSData* data = [NSJSONSerialization dataWithJSONObject:dict
                                                       options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                                         error:nil];
        return data ? std::string(static_cast<const char*>(data.bytes), data.length) : std::string("{}");
    }
}

} // namespace daw
