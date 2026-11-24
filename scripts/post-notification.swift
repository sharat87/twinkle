import Foundation
// Posts a distributed notification: post-notification <name> [object]
let args = CommandLine.arguments
DistributedNotificationCenter.default().postNotificationName(
    .init(args[1]), object: args.count > 2 ? args[2] : nil, userInfo: nil, deliverImmediately: true)
