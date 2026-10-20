//
//  daemon_catalog.m
//

#import "daemon_catalog.h"

@interface CYDaemonGroup ()
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, copy) NSArray<NSString *> *labels;
@property (nonatomic, copy) NSString *caution;
@property (nonatomic) BOOL advanced;
@end

@implementation CYDaemonGroup
@end

static CYDaemonGroup *group(NSString *identifier, NSString *title, NSString *symbol, NSString *summary,
                            NSString *caution, NSArray<NSString *> *labels)
{
    CYDaemonGroup *g = [CYDaemonGroup new];
    g.identifier = identifier;
    g.title = title;
    g.symbol = symbol;
    g.summary = summary;
    g.caution = caution;
    g.labels = labels;
    return g;
}

static CYDaemonGroup *advanced(NSString *identifier, NSString *title, NSString *symbol, NSString *summary,
                               NSString *caution, NSArray<NSString *> *labels)
{
    CYDaemonGroup *g = group(identifier, title, symbol, summary, caution, labels);
    g.advanced = YES;
    return g;
}

NSArray<CYDaemonGroup *> *daemon_catalog_groups(void)
{
    static NSArray<CYDaemonGroup *> *groups;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        groups = @[
            group(@"ota", @"Software Updates", @"arrow.down.circle",
                  @"iOS stops checking for and downloading updates. Same switch as OTA Updates.", nil,
                  @[ @"com.apple.mobile.softwareupdated", @"com.apple.OTATaskingAgent",
                     @"com.apple.softwareupdateservicesd", @"com.apple.mobile.NRDUpdated" ]),
            group(@"usage", @"Usage Tracking", @"chart.bar",
                  @"Stops collecting app usage statistics.", nil,
                  @[ @"com.apple.UsageTrackingAgent" ]),
            group(@"screentime", @"Screen Time", @"hourglass",
                  @"Screen Time limits, Ask to Buy and Family Sharing requests stop working.", nil,
                  @[ @"com.apple.ScreenTimeAgent", @"com.apple.familycircled",
                     @"com.apple.familynotification", @"com.apple.asktod" ]),
            group(@"gamecenter", @"Game Center", @"gamecontroller",
                  @"Game Center sign-in, achievements and leaderboards stop working.", nil,
                  @[ @"com.apple.gamed" ]),
            group(@"tips", @"Tips", @"lightbulb",
                  @"No more Tips notifications.", nil,
                  @[ @"com.apple.tipsd" ]),
            group(@"followup", @"Setup Suggestions", @"exclamationmark.bubble",
                  @"Removes Settings suggestions such as “Finish setting up your iPhone”.", nil,
                  @[ @"com.apple.followupd" ]),
            group(@"wapi", @"Chinese WLAN (WAPI)", @"wifi",
                  @"WAPI networks, used mainly in China, can no longer be joined.", nil,
                  @[ @"com.apple.wifi.wapic" ]),
            group(@"vpn", @"IPsec VPN", @"lock.shield",
                  @"The built-in IPsec (IKEv1) VPN stops working. VPN apps are not affected.", nil,
                  @[ @"com.apple.racoon" ]),
            group(@"assistivetouch", @"AssistiveTouch", @"circle.circle",
                  @"The AssistiveTouch button stops working.", nil,
                  @[ @"com.apple.assistivetouchd" ]),
            group(@"hotspot", @"Personal Hotspot", @"personalhotspot",
                  @"Sharing your cellular connection stops working.", nil,
                  @[ @"com.apple.MobileInternetSharing" ]),
            group(@"watchface", @"Watch Face Sync", @"applewatch",
                  @"Apple Watch faces no longer sync from this iPhone.", nil,
                  @[ @"com.apple.nanotimekitcompaniond" ]),
            group(@"musiccloud", @"Music Cloud Library", @"music.note",
                  @"Apple Music / iTunes cloud library sync stops.", nil,
                  @[ @"com.apple.itunescloudd" ]),
            advanced(@"diagnostics", @"Diagnostics", @"stethoscope",
                  @"Hardware and performance diagnostics stop, including sysdiagnose.", nil,
                  @[ @"com.apple.diagnosticd", @"com.apple.diagnosticextensionsd",
                     @"com.apple.diagnosticservicesd", @"com.apple.diagnosticspushd",
                     @"com.apple.symptomsd-diag", @"com.apple.sysdiagnose",
                     @"com.apple.sysdiagnose_helper" ]),
            advanced(@"crashreports", @"Logs & Crash Reports", @"doc.text.magnifyingglass",
                  @"System logging and crash reports stop.",
                  @"Panic and crash logs are no longer saved, so a reboot from a failed run can't be diagnosed. Turn this back on before reporting a bug.",
                  @[ @"com.apple.ReportCrash", @"com.apple.ReportMemoryException", @"com.apple.OTACrashCopier",
                     @"com.apple.analyticsd", @"com.apple.wifianalyticsd", @"com.apple.aslmanager",
                     @"com.apple.coresymbolicationd", @"com.apple.crash_mover",
                     @"com.apple.crashreportcopymobile", @"com.apple.DumpBasebandCrash",
                     @"com.apple.DumpPanic", @"com.apple.logd", @"com.apple.logd_helper",
                     @"com.apple.logd_reporter", @"com.apple.hangreporter", @"com.apple.hangtracerd",
                     @"com.apple.spindump", @"com.apple.tailspind", @"com.apple.rtcreportingd",
                     @"com.apple.syslogd", @"com.apple.signpost.signpost_reporter",
                     @"com.apple.pluginkit.pkreporter", @"com.apple.ProxiedCrashCopier.ProxyingDevice", @"com.apple.ReportSystemMemory" ]),
            advanced(@"spotlight", @"Spotlight", @"magnifyingglass",
                  @"Searching from the Home Screen and in apps stops working.",
                  @"Spotlight search, app search and Siri Suggestions stop working.",
                  @[ @"com.apple.searchd", @"com.apple.corespotlightservice",
                     @"com.apple.spotlightknowledged", @"com.apple.spotlightknowledged.updater",
                     @"com.apple.spotlight.IndexAgent" ]),
            advanced(@"siri", @"Siri & Dictation", @"waveform",
                  @"Siri, Voice Control and dictation stop working.",
                  @"Siri, “Hey Siri”, Voice Control and keyboard dictation stop working.",
                  @[ @"com.apple.assistant_service", @"com.apple.assistantd", @"com.apple.voiced" ]),
            advanced(@"health", @"HealthKit", @"heart",
                  @"The Health app and apps that use health data stop getting updates.",
                  @"Health data stops being recorded and synced, including from Apple Watch.",
                  @[ @"com.apple.healthd" ]),
            advanced(@"wallet", @"Wallet", @"wallet.pass",
                  @"Wallet passes and Apple Pay stop working.",
                  @"Apple Pay, transit cards, car keys and all Wallet passes stop working.",
                  @[ @"com.apple.passd" ]),
            advanced(@"location", @"Location Services", @"location",
                  @"GPS and everything that needs your location stops working.",
                  @"Maps, Find My, Weather, location-based reminders and Cyanide's Location Services toggle stop working.",
                  @[ @"com.apple.locationd" ]),
            advanced(@"thermal", @"Thermal Monitor", @"thermometer.medium",
                  @"iOS stops lowering performance when the device gets warm.",
                  @"Without thermalmonitord iOS no longer throttles when hot. The device can get very warm under load; the hardware still shuts down at critical temperatures.",
                  @[ @"com.apple.thermalmonitord" ]),
        ];
    });
    return groups;
}

BOOL daemon_catalog_contains_label(NSString *label)
{
    static NSSet<NSString *> *all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet *s = [NSMutableSet set];
        for (CYDaemonGroup *g in daemon_catalog_groups()) [s addObjectsFromArray:g.labels];
        all = s;
    });
    return [label isKindOfClass:NSString.class] && [all containsObject:label];
}

NSString *daemon_catalog_executable_guess(NSString *label)
{
    static NSDictionary<NSString *, NSString *> *known;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        known = @{
            @"com.apple.ProxiedCrashCopier.ProxyingDevice": @"ProxiedCrashCopier",
            @"com.apple.spotlightknowledged.updater": @"spotlightknowledged",
        };
    });
    return known[label] ?: [label componentsSeparatedByString:@"."].lastObject;
}
